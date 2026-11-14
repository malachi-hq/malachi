defmodule Malachi.Console.GroupsView do
  @moduledoc """
  The Consumers view's data (section 6.5 of `docs/design/operator-interfaces.md`), for `GET /api/v1/groups`
  and `GET /api/v1/groups/:group?topic=`.

  A consumer group is keyed by `{group, topic}`, and two sources describe it:

    * **its coordinator**, which holds who is in the group, what each member was assigned and the
      generation (`Malachi.Consumer.GroupCoordinator.describe/2`, gathered from every node by
      `Malachi.Console.Reads.groups/0`). That state is soft: a coordinator that restarted knows only the
      members that joined since, and a group whose members all left is not listed by it;
    * **the control plane**, which holds each range's committed position and the group's fence epoch
      (`Malachi.Metadata.committed_offsets/3`, `Malachi.Metadata.group_fence/3`), read from this node's
      sampled metadata. A group that committed once is listed for as long as its positions are kept.

  A group either source knows is listed. A position is shown decomposed (`start`, or a source index and
  offset within the range), never as a number to subtract: the time lag, the records and bytes behind and
  the headroom before retention removes a position are not served (`null`), since nothing records when a
  position was committed or how far behind it is (a GAP in section 6.5).
  """

  alias Malachi.Console.Fanout
  alias Malachi.Metadata

  @typedoc "What the view is built from: the coordinators' groups by node, and the metadata."
  @type gathered :: %{fanout: Fanout.result(), metadata: Metadata.t()}

  @doc """
  Every group either source knows, as `{group, topic}` order sorts them, each with its coordinator's view
  when one holds it. Where two coordinators hold the same group (a leadership change in flight), the one
  with the higher generation is the current one.
  """
  @spec groups(gathered()) :: [map()]
  def groups(%{fanout: fanout, metadata: metadata}) do
    coordinated = coordinated(fanout)
    committed = Map.keys(metadata.committed_offsets)

    (Map.keys(coordinated) ++ committed)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {group, topic} = key ->
      %{
        group: group,
        topic: topic,
        coordinator: Map.get(coordinated, key),
        positions: Metadata.committed_offsets(metadata, group, topic),
        epoch: Metadata.group_fence(metadata, group, topic).epoch
      }
    end)
  end

  defp coordinated(%{answers: answers}) do
    answers
    |> Enum.flat_map(fn {node, %{groups: groups}} -> Enum.map(groups, &Map.put(&1, :node, node)) end)
    |> Enum.group_by(&{&1.group, &1.topic})
    |> Map.new(fn {key, held} -> {key, Enum.max_by(held, &(&1.generation || -1))} end)
  end

  @doc "How many coordinators did not answer across the nodes that did."
  @spec unanswered_coordinators(Fanout.result()) :: non_neg_integer()
  def unanswered_coordinators(%{answers: answers}),
    do: answers |> Enum.map(fn {_node, %{unanswered: n}} -> n end) |> Enum.sum()

  @doc "A group as a listing row."
  @spec render_summary(map()) :: map()
  def render_summary(%{group: group, topic: topic, coordinator: coordinator, positions: positions, epoch: epoch}) do
    %{
      "group" => group,
      "topic" => topic,
      "coordinator" => coordinator && Atom.to_string(coordinator.node),
      "generation" => coordinator && coordinator.generation,
      "members" => if(coordinator, do: length(coordinator.members), else: 0),
      "committed_ranges" => map_size(positions),
      "epoch" => epoch
    }
  end

  @doc "A group in full: its members and their ranges, and the committed position of each range."
  @spec render_detail(map()) :: map()
  def render_detail(%{coordinator: coordinator, positions: positions} = group) do
    group
    |> render_summary()
    |> Map.merge(%{
      "members" => if(coordinator, do: Enum.map(coordinator.members, &render_member/1), else: []),
      "positions" =>
        positions
        |> Enum.map(fn {{_topic, range}, position} -> render_position(range, position) end)
        |> Enum.sort_by(& &1["range"])
    })
  end

  defp render_member(%{member: member, idle_ms: idle_ms, ranges: ranges}) do
    %{"member" => to_text(member), "idle_ms" => idle_ms, "ranges" => Enum.map(ranges, &range_seq/1)}
  end

  # What a position is, and the three numbers that would say how far behind it is, which no source has.
  defp render_position(range, position) do
    decoded =
      case position do
        :start -> %{"at" => "start", "source_index" => nil, "source_offset" => nil}
        {index, offset} -> %{"at" => "position", "source_index" => index, "source_offset" => offset}
      end

    Map.merge(%{"range" => range, "time_lag_ms" => nil, "behind" => nil, "headroom" => nil}, decoded)
  end

  defp range_seq({_topic, seq}) when is_integer(seq), do: seq
  defp range_seq(other), do: to_text(other)

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_atom(value), do: Atom.to_string(value)
  defp to_text(value), do: inspect(value)
end
