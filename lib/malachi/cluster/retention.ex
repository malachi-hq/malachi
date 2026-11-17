defmodule Malachi.Cluster.Retention do
  @moduledoc """
  Pure retention policy for **sealed** segments: the decision layer, no storage or timers.

  Given the control-plane `Malachi.Metadata`, the current time, and a policy, it returns the sealed
  segment ids to expire. Independent rules, unioned (a segment any of them picks expires):

    * **age**. A sealed segment older than `:max_age_ms` (by its `sealed_at`) expires;
    * **size**. Per range, if the sealed segments total more than `:max_bytes`, the oldest expire
      until the range is back under the limit: the range keeps **at most** that many bytes;
    * **record count**. Per range, the oldest sealed segment expires only while the sealed segments newer
      than it still hold `:max_records` offsets: the range keeps **at least** that many (see below);
    * **purge**. A sealed segment wholly below its range's logical start expires (see `expired/5`).

  Size and count are scoped **per range** (the natural unit; a range's segments have contiguous offsets),
  age is per segment. The **active** segment is never returned: it is still being written, and its length
  is unknown until it seals, so neither bound counts it. A `nil` bound disables that rule.
  `Malachi.Cluster.RetentionCoordinator` executes the returned ids.

  ## Record count

  The count rule is the one place a bound reads "at least" rather than "at most", because it exists to keep
  the last N records. Read as "at most", a range whose segments each hold hundreds of thousands of records
  would expire every sealed segment under `max_records: 1_000` and keep only the active one. `0` keeps
  nothing sealed, as `max_bytes: 0` does.

  It counts **offsets**, from each segment's sealed `length`, and only those at or above the range's
  logical start, so a purge does not inflate the count. An offset is a record unless a produce that failed
  burned it, so a range can hold fewer readable records than the offsets counted; once log compaction
  (#206) separates a segment's span from what survives in it, `records/2` is the one place to change.

  A topic that split or merged keeps its retired ranges, and a reader of a range is served their history
  before its own, filtered to the reader's key slice (`Malachi.Metadata` seals a parent before it creates
  its children). A retired range's segments mix every child's keys, so counting them says nothing about any
  one reader. The rule therefore treats the two kinds of range apart:

    * a range nothing descends from (a live range, or the last of a sealed topic) keeps at least
      `max_records` of its own offsets, whatever its ancestors keep;
    * a range something descends from expires whole once every range descending from it with nothing
      below it holds `max_records` on its own, since all of its history is then older than the last
      `max_records` of every reader; until then it is kept whole.

  Every reader therefore keeps at least its last `max_records`, and a topic with R live ranges keeps up to
  R times the bound plus one segment each, and the history of the retired ranges not yet covered. The
  number moves with every split and merge, as the size rule's does. A reader's history can have a hole
  older than its last `max_records`, where a retired range expired while an older one is kept for another
  reader, and a consumer steps over it as it does over any expired segment.

  The record count bound is set by a policy only. The global policy never carries one (`effective/4`
  reports it off), so a policy written before the field existed never inherits a rule that deletes.

  The bound applied to each range is its **topic's policy retention merged over the global policy**
  (the policy overrides only the keys it sets), or the global policy passed in when the topic points at
  no policy, so retention is per-topic (C3c-2b). The topic's metadata says which policy NAME it points
  at (`Malachi.Metadata.topic_policy_name/2`); the definitions come from the cluster's policy store and
  are passed in already resolved, which keeps this module pure. A name the caller could not resolve
  expires nothing rather than falling back to the global limits: see `expired/5`.

  ## Legal hold

  A topic under a legal hold (#307, `Malachi.Metadata.legal_hold/2`) expires nothing, whatever its policy,
  its age, its size or its purged start say: `plan/5` reports what each rule would have expired as held
  instead, so the disk a hold keeps is visible, and the first sweep after the hold is released expires
  the same segments. The control plane refuses a `{:delete_segment, id}` of a held topic too, so a
  sweep planned before a hold landed cannot delete under it. A hold covers segment data only: it does
  not stop `ra` from snapshotting and truncating the control plane's own log.
  """

  alias Malachi.Cluster.Policy
  alias Malachi.Metadata

  @typedoc "A retention policy. A `nil` (or absent) bound disables that rule."
  @type policy :: %{
          optional(:max_age_ms) => non_neg_integer() | nil,
          optional(:max_bytes) => non_neg_integer() | nil,
          optional(:segment_max_age_ms) => pos_integer() | nil
        }

  # The retention bounds a policy can set, read from the one table of policy fields, so a bound added
  # there (#199) is reported and applied without a second list to keep in step.
  @retention_keys for %{path: [:retention, key]} <- Policy.fields(), do: key

  @typedoc "Where an effective bound came from."
  @type origin :: :policy | :global | :unresolved_backstop

  @typedoc "How a topic's policy name resolved: no name, a defined name, or a name nothing defines."
  @type resolution :: :none | :resolved | :unresolved

  @typedoc "A topic's effective retention, as `effective/4` reports it."
  @type effective :: %{
          resolution: resolution(),
          retention: %{atom() => {non_neg_integer() | nil, origin()}}
        }

  @typedoc """
  What an expire answered, as a closed set so it can label a metric: the control plane's own replies to a
  delete, and `:other` for anything else (a Raft timeout, an unexpected term).
  """
  @type reply_label :: :ok | :no_such_segment | :migrating | :segment_active | :legal_hold | :other

  @typedoc "What a legal hold keeps of one topic in a sweep: the segments the rules would have expired."
  @type held :: %{segments: pos_integer(), bytes: non_neg_integer()}

  @typedoc "One sweep's decision (`plan/5`): the segments to expire, and what each held topic keeps."
  @type plan :: %{expired: [Metadata.segment_id()], held: %{Metadata.topic_name() => held()}}

  @doc """
  The `reply_label` of an expire's answer. `:ok` deleted the segment; `:no_such_segment` means it was
  already gone (a retried sweep), which is neither an expiry nor a failure; `:migrating` (the topic is
  moving between vnodes), `:segment_active` (the segment is still the write head) and `:legal_hold` (a
  hold landed after the sweep read the metadata) are refusals.
  """
  @spec reply_label(term()) :: reply_label()
  def reply_label(:ok), do: :ok
  def reply_label({:error, :no_such_segment}), do: :no_such_segment
  def reply_label({:error, :migrating}), do: :migrating
  def reply_label({:error, :segment_active}), do: :segment_active
  def reply_label({:error, :legal_hold}), do: :legal_hold
  def reply_label(_other), do: :other

  @doc """
  Whether a control-plane answer authorizes deleting the segment's stored bytes on its replicas.

  Only two do, and both mean the same thing: the control plane no longer lists the segment, so no read
  can be served from it and nothing will ever repair it. `:ok` is this sweep having removed it;
  `:no_such_segment` is an earlier sweep having removed it and died before deleting the files, which is
  the only retry the files ever get, since a segment gone from the control plane never comes back from
  `expired/3`.

  Every other answer keeps the files. A refusal (`:migrating`, `:segment_active`, `:legal_hold`) leaves the segment
  listed with its replica set intact, and deleting the bytes under it would leave every replica short
  of its recorded `byte_size`: `Malachi.Cluster.SelfHealing` then finds no intact copy to repair from,
  and a consumer positioned in that segment reads `:eof` until some later sweep finally gets `:ok`.
  `:other` covers a Raft timeout, where the command may still have committed and may not: skipping the
  delete is the recoverable side of that ambiguity, because the next sweep gets `:no_such_segment` and
  deletes then, while deleting now cannot be undone.
  """
  @spec delete_replicas?(term()) :: boolean()
  def delete_replicas?(reply), do: reply_label(reply) in [:ok, :no_such_segment]

  @doc """
  The sealed segment ids to expire at `now_ms` (epoch ms): `plan/5`'s `expired`, which leaves out every
  segment of a topic under a legal hold. `global_policy` is the fallback; each range uses its topic's
  policy retention merged over it (see the module doc).

  A sealed segment wholly below its range's logical start (#198) expires too, whatever its age and
  size: an operator purged every record in it, and no reader is served any of them. The segment holding
  the logical start is kept until the start passes its end, so a purge reclaims disk segment by segment.

  `policies` maps a policy NAME to its definition. The metadata says which name a topic points at, and
  the definitions are an administrative object of the cluster
  (`Malachi.Cluster.PolicyStore.fetch_all/0`), so the caller resolves them once per sweep and hands
  them in:
  this stays pure, and a sweep costs one read of the policy store rather than one per range.
  """
  @spec expired(
          Metadata.t(),
          non_neg_integer(),
          policy(),
          %{Metadata.policy_name() => Policy.t()},
          non_neg_integer() | nil
        ) :: [Metadata.segment_id()]
  def expired(%Metadata{} = metadata, now_ms, global_policy, policies \\ %{}, unresolved_max_age_ms \\ nil),
    do: plan(metadata, now_ms, global_policy, policies, unresolved_max_age_ms).expired

  @doc """
  One sweep's decision at `now_ms`, in a single pass over the sealed segments: what to expire, and what
  a legal hold keeps.

  Every range is judged by the same rules (`expired/5`). The segments a rule picks in a range of a
  held topic go to `held`, counted with their bytes on disk under the topic, instead of to `expired`; a
  held topic no rule would touch is not listed. So `expired` without the hold is `expired` with it plus
  exactly the segments `held` counts.
  """
  @spec plan(
          Metadata.t(),
          non_neg_integer(),
          policy(),
          %{Metadata.policy_name() => Policy.t()},
          non_neg_integer() | nil
        ) :: plan()
  def plan(%Metadata{} = metadata, now_ms, global_policy, policies \\ %{}, unresolved_max_age_ms \\ nil) do
    # One pass over the ranges for the rules that judge a range alone, as the sweep always made. The count
    # rule reads a topic's ranges together and runs after, only for the topics whose policy sets it, so a
    # sweep where none does costs what it cost before the rule existed.
    judged =
      metadata.segments
      |> Map.values()
      |> Enum.filter(&(&1.state == :sealed))
      |> Enum.group_by(& &1.range_id)
      |> Enum.map(fn {range_id, sealed} ->
        topic = elem(range_id, 0)

        retention =
          bounds(effective(Metadata.topic_policy_name(metadata, topic), policies, global_policy, unresolved_max_age_ms))

        oldest_first = Enum.sort_by(sealed, & &1.start_offset)
        {range_id, retention, oldest_first, range_expired(metadata, range_id, oldest_first, now_ms, retention)}
      end)

    by_count = expired_by_count(metadata, judged)

    by_range =
      for {range_id, _retention, _oldest_first, ids} <- judged do
        topic = elem(range_id, 0)
        {topic, Metadata.legal_hold(metadata, topic) != nil, ids ++ Map.get(by_count, range_id, [])}
      end

    %{
      expired: Enum.uniq(for({_topic, false, ids} <- by_range, id <- ids, do: id)),
      held: held(metadata, by_range)
    }
  end

  # The ids the rules that judge one range alone pick in it, a segment two rules pick listed twice: the sweep
  # dedups once over every range, as it always has, and only a held range (rare) is deduplicated on its own.
  # The count rule is not among them, since it reads a range's descendants (`expired_by_count/2`).
  defp range_expired(metadata, range_id, oldest_first, now_ms, retention) do
    expired_by_age(oldest_first, now_ms, Map.get(retention, :max_age_ms)) ++
      expired_by_size(oldest_first, Map.get(retention, :max_bytes)) ++
      expired_by_purge(oldest_first, logical_start(metadata, range_id))
  end

  defp held(metadata, by_range) do
    for {topic, true, [_ | _] = ids} <- by_range, reduce: %{} do
      held ->
        ids = Enum.uniq(ids)
        bytes = Enum.reduce(ids, 0, &(bytes(Map.fetch!(metadata.segments, &1)) + &2))

        Map.update(held, topic, %{segments: length(ids), bytes: bytes}, fn so_far ->
          %{segments: so_far.segments + length(ids), bytes: so_far.bytes + bytes}
        end)
    end
  end

  @doc """
  A topic's effective retention: each bound's value and where it came from, and how the topic's policy
  NAME resolved against `policies`.

  The one place that decides what a topic's retention is. The sweep applies it (`expired/5`) and the
  admin read-back reports it (`Malachi.Policies.topic_policy/1`), so what an operator is told is what the
  data sees. Three cases, and the third is the one worth spelling out.

  A topic that points at no policy (`name` is `nil`) uses the global limits, as it always has. A topic
  whose policy resolves takes the bounds that policy sets, `nil` and `0` included, and inherits the
  others from the global limits.

  A topic that points at a NAME `policies` does not hold is neither. Falling back to the global limits
  there is what the administrator did not ask for: the name exists because they wanted something other
  than the default, and the most common reason a more permissive policy is asked for is to keep data
  longer. Expiring under the global bound would then delete exactly the data the policy existed to hold.
  So nothing expires, unless the operator has set a backstop bound for this case
  (`:retention_unresolved_policy_max_age_ms`), which is the only bound anyone has stated for it.

  ## Examples

      iex> Malachi.Cluster.Retention.effective(nil, %{}, %{max_age_ms: 1_000}, nil)
      %{
        resolution: :none,
        retention: %{
          max_age_ms: {1_000, :global},
          max_bytes: {nil, :global},
          max_records: {nil, :global},
          segment_max_age_ms: {nil, :global}
        }
      }

      iex> policies = %{"keep" => %{retention: %{max_bytes: 0}}}
      iex> Malachi.Cluster.Retention.effective("keep", policies, %{max_age_ms: 1_000}, nil)
      %{
        resolution: :resolved,
        retention: %{
          max_age_ms: {1_000, :global},
          max_bytes: {0, :policy},
          max_records: {nil, :global},
          segment_max_age_ms: {nil, :global}
        }
      }

  """
  @spec effective(
          Metadata.policy_name() | nil,
          %{Metadata.policy_name() => Policy.t()},
          policy(),
          non_neg_integer() | nil
        ) :: effective()
  def effective(nil, _policies, global_policy, _unresolved_max_age_ms),
    do: %{resolution: :none, retention: from_global(global_policy)}

  def effective(name, policies, global_policy, unresolved_max_age_ms) do
    case Map.fetch(policies, name) do
      {:ok, policy} ->
        overrides = Map.get(policy, :retention, %{})
        global = from_global(global_policy)

        retention =
          Map.new(global, fn {key, inherited} ->
            case Map.fetch(overrides, key) do
              {:ok, value} -> {key, {value, :policy}}
              :error -> {key, inherited}
            end
          end)

        %{resolution: :resolved, retention: retention}

      :error ->
        backstop = Map.new(@retention_keys, &{&1, {nil, :unresolved_backstop}})
        %{resolution: :unresolved, retention: %{backstop | max_age_ms: {unresolved_max_age_ms, :unresolved_backstop}}}
    end
  end

  defp from_global(global_policy), do: Map.new(@retention_keys, &{&1, {global_value(global_policy, &1), :global}})

  # A record count bound comes from a policy only (see "Record count" in the module doc), whatever the global
  # map carries, so no wiring mistake can make every policy that leaves it out inherit a rule that deletes.
  defp global_value(_global_policy, :max_records), do: nil
  defp global_value(global_policy, key), do: Map.get(global_policy, key)

  # The bounds alone, which is all the sweep needs.
  defp bounds(%{retention: retention}), do: Map.new(retention, fn {key, {value, _origin}} -> {key, value} end)

  @doc """
  The topics whose bound policy name `policies` does not resolve, sorted.

  What `effective/4` refuses to expire under the global limits, named so a caller can count
  it. A name that stays unresolved is a misconfiguration (a policy deleted, or a typo in the binding)
  and the disk it holds is invisible otherwise.

  Sorted explicitly, not by accident: `metadata.topics` is a map, and above 32 keys it iterates in hash
  order rather than key order, so the same set of topics would come back in a different order on a
  cluster large enough to matter and in a stable one on every cluster small enough to test.
  """
  @spec unresolved_policies(Metadata.t(), %{Metadata.policy_name() => Policy.t()}) :: [Metadata.topic_name()]
  def unresolved_policies(%Metadata{} = metadata, policies) do
    unresolved =
      for {topic, _meta} <- metadata.topics,
          name = Metadata.topic_policy_name(metadata, topic),
          name != nil and not Map.has_key?(policies, name),
          do: topic

    Enum.sort(unresolved)
  end

  defp expired_by_age(_segments, _now_ms, nil), do: []

  defp expired_by_age(segments, now_ms, max_age_ms) do
    for segment <- segments, is_integer(segment.sealed_at), now_ms - segment.sealed_at > max_age_ms do
      segment.id
    end
  end

  # Every sealed segment that ends at or below the logical start. Nothing for a range never purged.
  defp expired_by_purge(_segments, 0), do: []

  defp expired_by_purge(segments, logical_start) do
    for segment <- segments, segment.start_offset + segment.length <= logical_start, do: segment.id
  end

  # A segment always names a range the metadata holds; an absent one reads as never purged.
  defp logical_start(metadata, range_id), do: metadata.ranges |> Map.get(range_id, %{}) |> Metadata.logical_start()

  defp expired_by_size(_segments, nil), do: []
  defp expired_by_size(segments, max_bytes), do: expire_oldest(segments, &bytes/1, max_bytes, :at_most)

  # The record count rule over every topic whose policy sets it, as `%{range_id => ids}`. Nothing is grouped
  # or walked for a topic that does not set it, so a cluster that never uses the field pays nothing here.
  defp expired_by_count(metadata, judged) do
    counted =
      for {{topic, _seq}, %{max_records: max_records}, _oldest_first, _ids} when is_integer(max_records) <- judged,
          into: %{},
          do: {topic, max_records}

    if counted == %{} do
      %{}
    else
      ranges_by_topic =
        metadata.ranges |> Map.values() |> Enum.filter(&Map.has_key?(counted, &1.topic)) |> Enum.group_by(& &1.topic)

      sealed_by_range =
        for {{topic, _seq} = range_id, _retention, oldest_first, _ids} <- judged,
            Map.has_key?(counted, topic),
            into: %{},
            do: {range_id, oldest_first}

      sealed_ids_by_topic = sealed_by_range |> Map.keys() |> Enum.group_by(&elem(&1, 0))

      for {topic, max_records} <- counted, reduce: %{} do
        picked ->
          ranges = with_unknown_ranges(Map.get(ranges_by_topic, topic, []), Map.get(sealed_ids_by_topic, topic, []))
          Map.merge(picked, topic_expired_by_count(ranges, sealed_by_range, max_records))
      end
    end
  end

  # A segment always names a range the metadata holds; one that does not is judged as a range nothing
  # descends from, with no history, which is what the other rules already assume of it (`logical_start/2`).
  defp with_unknown_ranges(ranges, sealed_range_ids) do
    known = MapSet.new(ranges, & &1.id)

    unknown =
      for {topic, _seq} = range_id <- sealed_range_ids,
          not MapSet.member?(known, range_id),
          do: %{id: range_id, topic: topic, parents: []}

    ranges ++ unknown
  end

  defp topic_expired_by_count(ranges, sealed_by_range, max_records) do
    # The ranges nothing descends from, under each range they descend from. Parents lists are transitive (a
    # split or a merge gives a child its parents' lists plus the parents themselves), so this is every
    # descendant at the bottom of each line, however deep.
    ancestors = for range <- ranges, parent <- range.parents, into: MapSet.new(), do: parent
    leaves = Enum.reject(ranges, &MapSet.member?(ancestors, &1.id))

    leaves_under =
      for leaf <- leaves, parent <- leaf.parents, reduce: %{} do
        index -> Map.update(index, parent, [leaf.id], &[leaf.id | &1])
      end

    readable = Map.new(leaves, &{&1.id, readable_offsets(Map.get(sealed_by_range, &1.id, []), &1)})

    Map.new(ranges, fn range ->
      sealed = Map.get(sealed_by_range, range.id, [])
      {range.id, count_pick(range, sealed, Map.get(leaves_under, range.id, []), readable, max_records)}
    end)
  end

  # A range nothing descends from keeps at least `max_records` of its own offsets.
  defp count_pick(range, sealed, [], _readable, max_records) do
    start = Metadata.logical_start(range)
    expire_oldest(sealed, &records(&1, start), max_records, :at_least)
  end

  # A range something descends from goes whole once every range at the bottom of its lines holds
  # `max_records` on its own: all of its history is then older than the last `max_records` of every reader.
  # Never in part, since its segments mix every child's key slice and no count of them is any one reader's.
  defp count_pick(_range, sealed, leaves, readable, max_records) do
    if Enum.all?(leaves, &(Map.fetch!(readable, &1) >= max_records)), do: Enum.map(sealed, & &1.id), else: []
  end

  defp readable_offsets(sealed, range) do
    start = Metadata.logical_start(range)
    Enum.reduce(sealed, 0, &(records(&1, start) + &2))
  end

  # The oldest-first walk the size and count bounds share (`segments` is oldest-first), stopping at the first
  # segment it keeps, so what it returns is always a prefix of `segments`. `:at_most` drops while the
  # segments left weigh more than `limit`; `:at_least` drops while the segments newer than the next one still
  # weigh at least `limit`.
  defp expire_oldest(segments, weight, limit, bound) do
    total = Enum.reduce(segments, 0, &(weight.(&1) + &2))

    {expired, _left} =
      Enum.reduce_while(segments, {[], total}, fn segment, {expired, left} ->
        newer = left - weight.(segment)

        if drop?(bound, left, newer, limit),
          do: {:cont, {[segment.id | expired], newer}},
          else: {:halt, {expired, left}}
      end)

    expired
  end

  defp drop?(:at_most, left, _newer, limit), do: left > limit
  defp drop?(:at_least, _left, newer, limit), do: newer >= limit

  # The bytes the segment takes on disk, not its logical size: a size limit exists to bound the disk, so a
  # compressed segment counts what it actually occupies (`Malachi.Metadata.stored_bytes/1`).
  defp bytes(segment), do: Malachi.Metadata.stored_bytes(segment)

  # The offsets of `segment` at or above its range's logical start `start`. A sealed segment's `length` is its
  # offset span, which is its record count while nothing removes records from inside a segment (#206).
  defp records(segment, start),
    do: max(0, segment.start_offset + segment.length - max(segment.start_offset, start))
end
