defmodule Malachi.Cluster.RetentionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.Cluster.Retention
  alias Malachi.Metadata

  doctest Retention

  @range {"t", 0}

  # Builds metadata with topic "t" and the given sealed segments.
  # Each: {segment_id, start_offset, byte_size, sealed_at}.
  defp with_sealed(segments) do
    base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)

    Enum.reduce(segments, base, fn {id, start_offset, bytes, sealed_at}, metadata ->
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, @range, id, [:b1], start_offset})
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, id, 1, bytes, sealed_at})
      metadata
    end)
  end

  defp expired(metadata, now, policy, policies \\ %{}, unresolved \\ nil),
    do: metadata |> Retention.expired(now, policy, policies, unresolved) |> Enum.sort()

  test "expires sealed segments older than max_age_ms" do
    metadata = with_sealed([{"old", 0, 100, 1_000}, {"new", 1, 100, 9_500}])
    # at now=10_000, old's age is 9000 (> 5000), new's is 500
    assert expired(metadata, 10_000, %{max_age_ms: 5_000}) == ["old"]
  end

  test "a nil bound disables that rule" do
    metadata = with_sealed([{"old", 0, 100, 1_000}])
    assert expired(metadata, 10_000, %{max_age_ms: nil, max_bytes: nil}) == []
    assert expired(metadata, 10_000, %{}) == []
  end

  test "expires the oldest sealed segments once a range exceeds max_bytes" do
    metadata = with_sealed([{"s0", 0, 100, 0}, {"s1", 1, 100, 0}, {"s2", 2, 100, 0}])
    # total 300, keep <= 150: drop the two oldest (s0, s1), keep the newest (s2)
    assert expired(metadata, 999, %{max_bytes: 150}) == ["s0", "s1"]
  end

  test "size retention is per range, not across ranges" do
    # split the root so segments land on two different ranges
    base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)
    {base, {:ok, left, right}} = Metadata.apply(base, {:split_range, @range})

    seal = fn metadata, range, id ->
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, range, id, [:b1], 0})
      elem(Metadata.apply(metadata, {:seal_segment, id, 1, 100, 0}), 0)
    end

    metadata = base |> seal.(left, "l") |> seal.(right, "r")
    # each range holds 100 bytes; a 150-byte limit is per range, so neither is over
    assert expired(metadata, 999, %{max_bytes: 150}) == []
  end

  test "never expires the active segment, even under an aggressive policy" do
    base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)
    {metadata, :ok} = Metadata.apply(base, {:register_segment, @range, "active", [:b1], 0})

    assert Retention.expired(metadata, 10_000, %{max_age_ms: 0, max_bytes: 0}) == []
  end

  test "unions the age and size rules" do
    # s0 expired by age (old); s2 also dropped by size (total 300 > 150)
    metadata = with_sealed([{"s0", 0, 100, 1_000}, {"s1", 1, 100, 9_900}, {"s2", 2, 100, 9_900}])
    result = expired(metadata, 10_000, %{max_age_ms: 5_000, max_bytes: 150})
    # by age: s0. by size (oldest-first until <= 150): s0, s1. union: s0, s1
    assert result == ["s0", "s1"]
  end

  describe "below the logical start (the manual purge, #198)" do
    defp purged(metadata, start) do
      {metadata, {:ok, _moves}} = Metadata.apply(metadata, {:set_range_starts, "t", %{@range => start}})
      metadata
    end

    test "sealed segments wholly below the start expire regardless of age and size; the boundary stays" do
      # each segment is one offset long: s0 = [0,1), s1 = [1,2), s2 = [2,3)
      metadata = [{"s0", 0, 100, 9_999}, {"s1", 1, 100, 9_999}, {"s2", 2, 100, 9_999}] |> with_sealed() |> purged(2)
      assert expired(metadata, 10_000, %{}) == ["s0", "s1"]
    end

    test "a start inside a segment keeps that segment" do
      base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)
      {metadata, :ok} = Metadata.apply(base, {:register_segment, @range, "wide", [:b1], 0})
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, "wide", 10, 100, 0})

      assert metadata |> purged(9) |> expired(10_000, %{}) == []
      assert metadata |> purged(10) |> expired(10_000, %{}) == ["wide"]
    end

    test "unions with the age and size rules without duplicates" do
      metadata = [{"s0", 0, 100, 1_000}, {"s1", 1, 100, 9_900}, {"s2", 2, 100, 9_900}] |> with_sealed() |> purged(2)
      assert expired(metadata, 10_000, %{max_age_ms: 5_000}) == ["s0", "s1"]
    end

    test "a policy that keeps everything still lets a purge reclaim" do
      metadata = [{"s0", 0, 100, 0}, {"s1", 1, 100, 0}] |> with_sealed() |> purged(1)
      assert expired(metadata, 10_000, %{max_age_ms: nil, max_bytes: nil}) == ["s0"]
    end

    test "never expires the active segment, however far the start is" do
      base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)
      {metadata, :ok} = Metadata.apply(base, {:register_segment, @range, "active", [:b1], 0})
      assert metadata |> purged(50) |> expired(10_000, %{}) == []
    end

    property "no segment holding an offset at or above the start is expired by the purge rule" do
      check all(
              count <- integer(1..8),
              start <- integer(0..9),
              max_runs: 100
            ) do
        metadata = 0..(count - 1) |> Enum.map(&{"s#{&1}", &1, 100, 0}) |> with_sealed()
        start = min(start, count)
        result = metadata |> purged(start) |> expired(10_000, %{})

        assert Enum.sort(result) == Enum.sort(for i <- 0..(count - 1), i + 1 <= start, do: "s#{i}")
      end
    end
  end

  describe "per-topic policy" do
    # The topic points at a name (its own state, in its vnode); the definitions come from the cluster's
    # policy store, which the sweep resolves once per pass and hands in.
    defp with_policy(metadata, topic) do
      {metadata, :ok} = Metadata.apply(metadata, {:bind_topic_policy, topic, "p"})
      metadata
    end

    defp definitions(policy), do: %{"p" => policy}

    test "a topic's policy retention overrides the global policy" do
      metadata =
        [{"old", 0, 100, 1_000}, {"new", 1, 100, 9_500}]
        |> with_sealed()
        |> with_policy("t")

      # global has no age limit, but the topic's policy expires anything older than 5_000
      assert expired(metadata, 10_000, %{}, definitions(%{retention: %{max_age_ms: 5_000}})) == ["old"]
    end

    test "a topic policy merges over the global (keys it does not set fall back)" do
      metadata =
        [{"s0", 0, 100, 1_000}, {"s1", 1, 100, 9_900}, {"s2", 2, 100, 9_900}]
        |> with_sealed()
        |> with_policy("t")

      # policy sets only max_age_ms (s0 by age); max_bytes falls back to the global 150 (s0, s1 by size)
      definitions = definitions(%{retention: %{max_age_ms: 5_000}})
      assert expired(metadata, 10_000, %{max_bytes: 150}, definitions) == ["s0", "s1"]
    end

    test "a topic without a policy uses the global policy" do
      metadata = with_sealed([{"old", 0, 100, 1_000}])
      assert expired(metadata, 10_000, %{max_age_ms: 5_000}) == ["old"]
    end

    test "a topic pointing at a policy that does not resolve expires nothing under the global limits" do
      metadata =
        [{"old", 0, 100, 1_000}]
        |> with_sealed()
        |> with_policy("t")

      # The name exists because the administrator wanted something other than the default, and the
      # usual something is to keep data LONGER. Expiring under the global bound would delete exactly
      # what the policy was there to hold, on every replica, with no way back.
      assert expired(metadata, 10_000, %{max_age_ms: 5_000}, %{}) == []
    end

    test "the operator's backstop is the one bound that does apply to an unresolved name" do
      metadata =
        [{"old", 0, 100, 1_000}, {"newer", 1, 100, 9_000}]
        |> with_sealed()
        |> with_policy("t")

      # Nothing invents this bound: it applies only because someone set it for this case.
      assert expired(metadata, 10_000, %{max_age_ms: 5_000}, %{}, 5_000) == ["old"]
    end

    test "an unresolved name ignores the global byte budget too, not just the age" do
      metadata =
        [{"s0", 0, 100, 1_000}, {"s1", 1, 100, 1_000}]
        |> with_sealed()
        |> with_policy("t")

      assert expired(metadata, 10_000, %{max_bytes: 150}, %{}) == []
    end

    test "a policy that only constrains placement expires under the global limits" do
      metadata =
        [{"old", 0, 100, 1_000}, {"new", 1, 100, 9_500}]
        |> with_sealed()
        |> with_policy("t")

      # The middle of three answers that are easy to confuse: no policy at all, a policy that resolves
      # and says nothing about retention, and a name nothing defines. Only the last one holds data back.
      # This one resolved, so the cluster's own limits apply exactly as they would without a policy.
      assert expired(metadata, 10_000, %{max_age_ms: 5_000}, definitions(%{spread_by: "rack"})) == ["old"]
    end

    test "unresolved_policies/2 names the topics that are being held, so the disk is not invisible" do
      metadata =
        [{"old", 0, 100, 1_000}]
        |> with_sealed()
        |> with_policy("t")

      assert Retention.unresolved_policies(metadata, %{}) == ["t"]
      assert Retention.unresolved_policies(metadata, %{"p" => %{}}) == []
    end

    test "unresolved_policies/2 sorts, which only shows above the 32 keys a map holds in key order" do
      # The topic map iterates in key order while it is a flatmap and in hash order once it grows past
      # 32 keys, so a comprehension over it reads as sorted on every cluster small enough to appear in
      # a test and unsorted on a real one. Forty topics is the smallest round number past that line.
      names = for i <- 0..39, do: "t#{String.pad_leading(to_string(i), 2, "0")}"

      metadata =
        Enum.reduce(names, Metadata.new(), fn topic, metadata ->
          {metadata, {:ok, _root}} = Metadata.apply(metadata, {:create_topic, topic, 4})
          {metadata, :ok} = Metadata.apply(metadata, {:bind_topic_policy, topic, "p"})
          metadata
        end)

      unresolved = Retention.unresolved_policies(metadata, %{})

      assert unresolved == Enum.sort(unresolved), "the order a caller gets must not depend on hashing"
      assert unresolved == names
    end
  end

  describe "effective/4 (what a topic's retention is, and where each bound comes from)" do
    test "a topic with no policy takes every bound from the global policy" do
      assert Retention.effective(nil, %{}, %{max_age_ms: 5_000}, 99) == %{
               resolution: :none,
               retention: %{max_age_ms: {5_000, :global}, max_bytes: {nil, :global}, segment_max_age_ms: {nil, :global}}
             }
    end

    test "a resolved policy wins the bounds it sets and inherits the rest, nil and 0 included" do
      policies = %{"p" => %{retention: %{max_age_ms: nil, max_bytes: 0}}}

      assert Retention.effective("p", policies, %{max_age_ms: 5_000, max_bytes: 10}, nil) == %{
               resolution: :resolved,
               retention: %{max_age_ms: {nil, :policy}, max_bytes: {0, :policy}, segment_max_age_ms: {nil, :global}}
             }

      partial = %{"p" => %{retention: %{max_bytes: 7}}}

      assert Retention.effective("p", partial, %{max_age_ms: 5_000}, nil).retention ==
               %{max_age_ms: {5_000, :global}, max_bytes: {7, :policy}, segment_max_age_ms: {nil, :global}}
    end

    test "a resolved policy that says nothing about retention inherits every bound" do
      policies = %{"p" => %{spread_by: "rack"}}

      assert Retention.effective("p", policies, %{max_age_ms: 5_000}, 1) == %{
               resolution: :resolved,
               retention: %{max_age_ms: {5_000, :global}, max_bytes: {nil, :global}, segment_max_age_ms: {nil, :global}}
             }
    end

    test "an unresolved name holds everything except the operator's backstop age" do
      assert Retention.effective("ghost", %{}, %{max_age_ms: 5_000, max_bytes: 10}, 42) == %{
               resolution: :unresolved,
               retention: %{
                 max_age_ms: {42, :unresolved_backstop},
                 max_bytes: {nil, :unresolved_backstop},
                 segment_max_age_ms: {nil, :unresolved_backstop}
               }
             }
    end

    property "what effective/4 reports is exactly what the sweep applies" do
      # Parity, not a second implementation: the bounds read back for a topic, applied as the global
      # policy of the same topic without a binding, expire the same segments the sweep expires with the
      # binding. A read-back that drifted from the sweep would tell an operator a limit the data never
      # sees.
      check all(
              segments <- sealed_segments(),
              global <- retention_bounds(),
              bound <- member_of([nil, "p", "ghost"]),
              policy <- one_of([constant(%{}), map(retention_bounds(), &%{retention: &1})]),
              backstop <- one_of([constant(nil), integer(0..20_000)]),
              now <- integer(0..20_000)
            ) do
        base = with_sealed(segments)
        policies = %{"p" => policy}

        bound_metadata =
          if bound, do: elem(Metadata.apply(base, {:bind_topic_policy, "t", bound}), 0), else: base

        reported = Retention.effective(bound, policies, global, backstop).retention
        as_global = Map.new(reported, fn {key, {value, _origin}} -> {key, value} end)

        assert expired(bound_metadata, now, global, policies, backstop) == expired(base, now, as_global)
      end
    end

    defp sealed_segments do
      gen all(specs <- list_of({integer(1..300), integer(0..20_000)}, max_length: 8)) do
        specs |> Enum.with_index() |> Enum.map(fn {{bytes, at}, i} -> {"s#{i}", i, bytes, at} end)
      end
    end

    defp retention_bounds do
      bound = one_of([constant(nil), integer(0..2_000)])

      gen all(age <- bound, bytes <- bound, keys <- list_of(member_of([:max_age_ms, :max_bytes]), max_length: 2)) do
        Map.take(%{max_age_ms: age, max_bytes: bytes}, keys)
      end
    end
  end

  describe "reply_label/1 (what an expire answered, as a bounded label)" do
    test "the replies the control plane gives a delete each have a label of their own" do
      assert Retention.reply_label(:ok) == :ok
      assert Retention.reply_label({:error, :no_such_segment}) == :no_such_segment
      assert Retention.reply_label({:error, :migrating}) == :migrating
      assert Retention.reply_label({:error, :segment_active}) == :segment_active
    end

    test "anything else folds into :other, so a label set can never grow with the replies" do
      assert Retention.reply_label({:error, :timeout}) == :other
      assert Retention.reply_label({:error, {:unexpected, make_ref()}}) == :other
      assert Retention.reply_label(:done) == :other
      assert Retention.reply_label(nil) == :other
    end
  end

  describe "delete_replicas?/1 (whether an answer authorizes destroying the stored bytes)" do
    test "the two answers that mean the control plane no longer lists the segment" do
      assert Retention.delete_replicas?(:ok)
      # An earlier sweep dropped it and died before deleting the files: the only retry those files get.
      assert Retention.delete_replicas?({:error, :no_such_segment})
    end

    test "a refusal keeps the bytes, because the segment is still listed with its replica set" do
      refute Retention.delete_replicas?({:error, :migrating})
      refute Retention.delete_replicas?({:error, :segment_active})
    end

    test "an ambiguous answer keeps the bytes: the next sweep can delete, an undelete does not exist" do
      refute Retention.delete_replicas?({:error, :timeout})
      refute Retention.delete_replicas?({:error, :call_failed})
    end

    property "no answer outside those two ever authorizes a delete" do
      check all(reply <- StreamData.term(), reply not in [:ok, {:error, :no_such_segment}], max_runs: 200) do
        refute Retention.delete_replicas?(reply)
      end
    end
  end

  describe "legal hold (#307)" do
    @hold %{reason: "case 2026-114", actor: "admin"}

    defp held(metadata, topic \\ "t") do
      {metadata, :ok} = Metadata.apply(metadata, {:set_topic_hold, topic, @hold}, 1)
      metadata
    end

    defp released(metadata, topic \\ "t") do
      {metadata, :ok} = Metadata.apply(metadata, {:set_topic_hold, topic, nil}, 1)
      metadata
    end

    # Topics "t" and "u", each with one sealed segment per entry of `segments` in its root range.
    defp two_topics(segments) do
      base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)
      base = elem(Metadata.apply(base, {:create_topic, "u", 4}), 0)

      for topic <- ["t", "u"], {id, start_offset, bytes, sealed_at} <- segments, reduce: base do
        metadata ->
          range = {topic, 0}
          {metadata, :ok} = Metadata.apply(metadata, {:register_segment, range, {topic, id}, [:b1], start_offset})
          elem(Metadata.apply(metadata, {:seal_segment, {topic, id}, 1, bytes, sealed_at}), 0)
      end
    end

    test "expired/3 returns nothing for a held topic, whatever its age, size and purged start" do
      metadata = [{"s0", 0, 100, 0}, {"s1", 1, 100, 0}, {"s2", 2, 100, 0}] |> with_sealed() |> purged(2)
      policy = %{max_age_ms: 0, max_bytes: 0}

      assert Retention.expired(metadata, 10_000, policy) != []
      assert Retention.expired(held(metadata), 10_000, policy) == []
    end

    test "releasing the hold makes the next sweep expire the same segments" do
      metadata = with_sealed([{"s0", 0, 100, 0}, {"s1", 1, 100, 9_999}])
      policy = %{max_age_ms: 5_000}
      before_hold = expired(metadata, 10_000, policy)

      assert before_hold == ["s0"]
      assert expired(held(metadata), 10_000, policy) == []
      assert metadata |> held() |> released() |> expired(10_000, policy) == before_hold
    end

    test "plan/5 reports what the hold keeps, per topic, with the bytes the segments take on disk" do
      metadata = [{"s0", 0, 100, 0}, {"s1", 1, 250, 0}, {"s2", 2, 40, 9_999}] |> two_topics() |> held("t")

      assert %{expired: expired, held: held} = Retention.plan(metadata, 10_000, %{max_age_ms: 5_000})
      assert Enum.sort(expired) == [{"u", "s0"}, {"u", "s1"}]
      assert held == %{"t" => %{segments: 2, bytes: 350}}
    end

    test "a held topic that no rule touches is not listed" do
      metadata = [{"s0", 0, 100, 9_999}] |> with_sealed() |> held()
      assert Retention.plan(metadata, 10_000, %{max_age_ms: 5_000}) == %{expired: [], held: %{}}
    end

    test "a held topic's ranges are summed under the topic" do
      base = elem(Metadata.apply(Metadata.new(), {:create_topic, "t", 4}), 0)
      {base, {:ok, left, right}} = Metadata.apply(base, {:split_range, @range})

      metadata =
        for {range, id} <- [{left, "l"}, {right, "r"}], reduce: base do
          metadata ->
            {metadata, :ok} = Metadata.apply(metadata, {:register_segment, range, id, [:b1], 0})
            elem(Metadata.apply(metadata, {:seal_segment, id, 1, 100, 0}), 0)
        end

      assert Retention.plan(held(metadata), 10_000, %{max_age_ms: 0}).held == %{"t" => %{segments: 2, bytes: 200}}
    end

    test "a refusal for a hold is labeled and keeps the replicas' bytes" do
      assert Retention.reply_label({:error, :legal_hold}) == :legal_hold
      refute Retention.delete_replicas?({:error, :legal_hold})
    end

    property "the hold moves exactly what would expire into what it reports, and touches no other topic" do
      check all(
              segments <- list_of(tuple({integer(1..500), integer(0..10_000)}), max_length: 6),
              max_age <- one_of([constant(nil), integer(0..10_000)]),
              max_bytes <- one_of([constant(nil), integer(0..1_500)]),
              max_runs: 200
            ) do
        # Contiguous one-offset segments, so each registers right after the one before it seals.
        metadata =
          segments
          |> Enum.with_index()
          |> Enum.map(fn {{bytes, sealed_at}, offset} -> {"s#{offset}", offset, bytes, sealed_at} end)
          |> two_topics()

        policy = %{max_age_ms: max_age, max_bytes: max_bytes}

        free = Retention.plan(metadata, 10_000, policy)
        kept = Retention.plan(held(metadata), 10_000, policy)

        {of_t, of_u} = Enum.split_with(free.expired, &(elem(&1, 0) == "t"))
        assert Enum.sort(kept.expired) == Enum.sort(of_u)
        assert free.held == %{}

        bytes =
          for id <- of_t, reduce: 0, do: (total -> total + Metadata.stored_bytes(Metadata.get_segment(metadata, id)))

        expected_held = if of_t == [], do: %{}, else: %{"t" => %{segments: length(of_t), bytes: bytes}}
        assert kept.held == expected_held
      end
    end
  end
end
