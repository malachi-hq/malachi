defmodule Malachi.Console.TopicsView do
  @moduledoc """
  The Topics and Segments views' data (sections 6.3 and 6.6 of `docs/design/operator-interfaces.md`), for
  `GET /api/v1/topics`, `GET /api/v1/topics/:topic/ranges` and `GET /api/v1/topics/:topic/segments`.

  Everything comes from this node's merged metadata (`Malachi.Console.Samples.metadata/0`), which is its
  cache of the control plane, sampled so a page of a large topic does not cost a call into the broker per
  request. Replicas are named by their node (`Malachi.Metadata.broker_ref_string/1`), never as a pid.

  ## Copy health

  A segment lists each of its copies with the conditions the cluster can distinguish about it, as a set of
  flags rather than one state, since a copy can be sealed and damaged at once (section 6.6):

    * `active` or `sealed`, from the segment;
    * `failed`, a copy whose storage failed and that its node will never write again;
    * `damaged`, a copy its node's scrubber found damaged;
    * `unknown`, a copy whose node did not answer, or could not read its own state.

  Each node answers for its own copies (`Malachi.Console.Reads.copy_health/0`, through
  `Malachi.Console.Fanout`). The segment as a whole is `under_replicated` when fewer of its replicas are on
  alive nodes than the replication factor asks, clamped to the alive nodes there are
  (`Malachi.Cluster.Placement.under_replicated/3`), and `null` when the membership that says which nodes are
  alive could not be read.

  `health` resolves those to a label and a severity: `error` when a copy failed or is damaged or the
  segment is under replicated, `warning` when a copy is unknown, `ok` otherwise. The label joins the
  conditions present, such as `sealed+damaged`.

  `behind` and `ahead`, a copy's replication progress against its primary, are not served: the replication
  server's per copy tracker has no read (a GAP in section 6.6).
  """

  alias Malachi.Cluster.Placement
  alias Malachi.Console.Fanout
  alias Malachi.Metadata

  @typedoc "What each node said about its copies, by node name, and the nodes that did not answer."
  @type health :: %{by_node: %{String.t() => map()}, unanswered: MapSet.t(String.t())}

  @doc "The topics, by name, as `Malachi.Metadata.overview/1` summarizes them."
  @spec topics(Metadata.t()) :: [map()]
  def topics(%Metadata{} = metadata), do: Metadata.overview(metadata)

  @doc "A topic's summary as JSON."
  @spec render_topic(map()) :: map()
  def render_topic(topic) do
    %{
      "name" => topic.name,
      "state" => Atom.to_string(topic.state),
      "keyspace_size" => topic.keyspace_size,
      "policy" => topic.policy,
      "ranges" => %{"active" => topic.active_range_count, "total" => topic.range_count},
      "segments" => %{"active" => topic.active_segment_count, "total" => topic.segment_count},
      "bytes" => topic.total_bytes,
      "groups" => topic.groups
    }
  end

  @doc "Whether `name` is a topic of `metadata`."
  @spec topic?(Metadata.t(), String.t()) :: boolean()
  def topic?(%Metadata{topics: topics}, name), do: Map.has_key?(topics, name)

  @doc "The ranges of topic `name`, in sequence order."
  @spec ranges(Metadata.t(), String.t()) :: [map()]
  def ranges(%Metadata{} = metadata, name) do
    metadata
    |> Metadata.ranges_of_topic(name)
    |> Enum.map(fn %{id: {_topic, seq}} = range ->
      %{
        seq: seq,
        key_start: range.key_start,
        key_end: range.key_end,
        state: range.state,
        parents: range.parents |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.seq)
  end

  @doc "A range as JSON. Its parents are the ranges it was split or merged from, by sequence."
  @spec render_range(map()) :: map()
  def render_range(range) do
    %{
      "range" => range.seq,
      "key_start" => range.key_start,
      "key_end" => range.key_end,
      "state" => Atom.to_string(range.state),
      "parents" => range.parents
    }
  end

  @doc """
  The segments of topic `name`, in `{range, segment}` order, each with the facts needed to render it. The
  copy health comes later, at render time, so only one page's copies are resolved.
  """
  @spec segments(Metadata.t(), String.t(), [node()] | :unknown, pos_integer()) :: [map()]
  def segments(%Metadata{} = metadata, name, alive_nodes, replication_factor) do
    ranges = Metadata.ranges_of_topic(metadata, name)
    segments = Enum.flat_map(ranges, &Metadata.segments_of_range(metadata, &1.id))
    under = under_replicated(metadata, segments, alive_nodes, replication_factor)

    segments
    |> Enum.map(fn segment ->
      {_topic, range_seq} = segment.range_id

      %{
        id: segment.id,
        range: range_seq,
        segment: Metadata.segment_seq(segment.id),
        state: segment.state,
        start_offset: segment.start_offset,
        length: segment.length,
        byte_size: segment.byte_size,
        opened_at: Map.get(segment, :opened_at),
        sealed_at: Map.get(segment, :sealed_at),
        replicas: Enum.map(segment.replica_set, &Metadata.broker_ref_string/1),
        under_replicated: if(under == :unknown, do: nil, else: Map.has_key?(under, segment.id))
      }
    end)
    |> Enum.sort_by(&{&1.range, &1.segment})
  end

  # Only this topic's segments are checked, against one live broker per alive node: the reference this
  # topic's replicas use for that node (a single node's replicas are pids), or the replication server as a
  # cluster names it when none of them is there. So the target is clamped by the nodes there are, not by the
  # ones this topic happens to use, and a node is never counted twice.
  # Which nodes are alive is not known when the membership could not be read: counting this node alone would
  # call nearly every segment under replicated, so none is called either way.
  defp under_replicated(_metadata, _segments, :unknown, _replication_factor), do: :unknown
  defp under_replicated(_metadata, [], _alive_nodes, _replication_factor), do: %{}

  defp under_replicated(metadata, segments, alive_nodes, replication_factor) do
    refs_by_node =
      segments
      |> Enum.flat_map(& &1.replica_set)
      |> Enum.uniq()
      |> Enum.group_by(&Metadata.broker_ref_string/1)

    live =
      Enum.flat_map(alive_nodes, fn node ->
        Map.get(refs_by_node, Atom.to_string(node), [{Malachi.LogReplication, node}])
      end)

    %{metadata | segments: Map.new(segments, &{&1.id, &1})}
    |> Placement.under_replicated(live, replication_factor)
    |> Map.new(&{&1, true})
  end

  @doc "The copy health of the cluster's nodes from a fan-out of `Malachi.Console.Reads.copy_health/0`."
  @spec health(Fanout.result()) :: health()
  def health(%{answers: answers, unanswered: unanswered, unsupported: unsupported}) do
    %{
      by_node: Map.new(answers, fn {node, health} -> {Atom.to_string(node), health} end),
      unanswered: MapSet.new(unanswered ++ unsupported, &Atom.to_string/1)
    }
  end

  @doc "A segment as JSON, its copies resolved against `health`."
  @spec render_segment(map(), health()) :: map()
  def render_segment(segment, health) do
    copies = Enum.map(segment.replicas, &copy(&1, segment, health))
    conditions = copies |> Enum.flat_map(& &1["conditions"]) |> Enum.uniq()

    %{
      "range" => segment.range,
      "segment" => segment.segment,
      "state" => Atom.to_string(segment.state),
      "start_offset" => segment.start_offset,
      "length" => segment.length,
      "byte_size" => segment.byte_size,
      "opened_at" => iso8601(segment.opened_at),
      "sealed_at" => iso8601(segment.sealed_at),
      "primary" => List.first(segment.replicas),
      "replica_set" => segment.replicas,
      "copies" => copies,
      "under_replicated" => segment.under_replicated,
      "health" => resolve(conditions, segment.under_replicated)
    }
  end

  defp copy(node, segment, health) do
    state = Atom.to_string(segment.state)

    conditions =
      case Map.fetch(health.by_node, node) do
        {:ok, %{failed: failed, damaged: damaged}} ->
          [state] ++ flag("failed", failed, segment.id) ++ flag("damaged", damaged, segment.id)

        :error ->
          [state, "unknown"]
      end

    %{"node" => node, "conditions" => conditions}
  end

  # A list the node could not read leaves the copy unknown on that count; a node that runs no scrubber says
  # nothing about damage.
  defp flag(_name, :unknown, _id), do: ["unknown"]
  defp flag(_name, :not_scrubbed, _id), do: []
  defp flag(name, ids, id) when is_list(ids), do: if(id in ids, do: [name], else: [])

  @order ~w(active sealed failed damaged unknown)

  defp resolve(conditions, under_replicated?) do
    present = Enum.filter(@order, &(&1 in conditions))
    labels = if under_replicated? == true, do: present ++ ["under_replicated"], else: present

    severity =
      cond do
        under_replicated? == true or "failed" in present or "damaged" in present -> "error"
        "unknown" in present -> "warning"
        true -> "ok"
      end

    %{"label" => Enum.join(labels, "+"), "severity" => severity}
  end

  defp iso8601(nil), do: nil
  defp iso8601(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
