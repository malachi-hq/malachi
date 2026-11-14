defmodule Malachi.Purge.Points do
  @moduledoc """
  Where a purge (#198) moves each range's logical start, from the point an operator names. Pure: it
  reads a snapshot of one topic's ranges and segments (`t:topic_view/0`) and answers a map from range id
  to offset, which `Malachi.Broker.set_range_starts/3` then submits in one command.

  Clients never see offsets (`Malachi.Position`), so a point is one of three things:

    * **A time** (`before_time/2`). Record timestamps are client supplied, so the only time the cluster
      can vouch for is when the control plane sealed a segment (`sealed_at`). Each range's start moves to
      the end of the longest run of its oldest sealed segments that were all sealed at or before the
      time. It rounds DOWN to a segment boundary, never reaches into the active segment, and a segment
      sealed later than a newer one (clocks that disagree across leaders) stops the run rather than
      being stepped over, so the start stays one point in the range's order.
    * **An opaque position** (`at_position/3`), as a read handed it out. It moves only the range that
      issued it, and only when it points into that range's own records: a position still inside an
      ancestor would move the ancestor, which the issuer's siblings read too, so it is refused.
    * **A consumer group's commit** (`floors/2`). Resolved through the split lineage: a range's own
      records are purged up to the group's position in it, and an ancestor up to the LEAST any active
      descendant of it has read, so nothing a sibling's consumers have not read is removed. A descendant
      with no commit has read nothing, and pins the ancestor at 0. `floors/2` is the low-water mark of one
      group, and is meant to be the one #200 takes the minimum of over groups.

  Every function answers only the ranges whose start would move forward (`moving/2`): a point at or
  below a range's current start leaves that range out, so a purge never regresses and a repeated one
  submits nothing.
  """

  alias Malachi.Broker
  alias Malachi.Metadata

  @typedoc "One topic's ranges and the segments of each, as the control plane lists them."
  @type topic_view :: %{
          ranges: %{Metadata.range_id() => Metadata.range_meta()},
          segments: %{Metadata.range_id() => [Metadata.segment_meta()]}
        }

  @typedoc "The logical start each range moves to."
  @type starts :: %{Metadata.range_id() => non_neg_integer()}

  @typedoc "A position in a range's history: the index of a source in `parents ++ [self]`, and an offset."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @doc """
  The starts that purge every range up to `time_ms`: each range's start moves to the end of the longest
  run of its oldest sealed segments that were all sealed at or before `time_ms`.

      iex> view = %{
      ...>   ranges: %{{"t", 0} => %{id: {"t", 0}, parents: []}},
      ...>   segments: %{{"t", 0} => [
      ...>     %{state: :sealed, start_offset: 0, length: 5, sealed_at: 100},
      ...>     %{state: :sealed, start_offset: 5, length: 5, sealed_at: 300},
      ...>     %{state: :active, start_offset: 10, length: nil, sealed_at: nil}
      ...>   ]}
      ...> }
      iex> Malachi.Purge.Points.before_time(view, 200)
      %{{"t", 0} => 5}
      iex> Malachi.Purge.Points.before_time(view, 50)
      %{}
  """
  @spec before_time(topic_view(), non_neg_integer()) :: starts()
  def before_time(%{ranges: ranges} = view, time_ms) when is_integer(time_ms) do
    starts =
      for {range_id, _range} <- ranges,
          offset = sealed_before(segments(view, range_id), time_ms),
          offset != nil,
          into: %{},
          do: {range_id, offset}

    moving(view, starts)
  end

  @doc """
  The starts that purge up to `position`, a position the read of `issuer_id` handed out: only the
  issuer's own records, up to the position's offset.

  `{:error, :invalid_position}` when the issuer is not a range of the topic or the position names a
  source its history does not have; `{:error, :cursor_in_ancestor}` when the position is still inside
  an ancestor, which the issuer's siblings read too, or when the issuer itself has since become one (a
  split or a merge retired it after the read handed the position out). Whether the offset is past the range's end is the
  broker's check (`Malachi.Broker.set_range_starts/3`), which knows the live end.
  """
  @spec at_position(topic_view(), Metadata.range_id(), position()) ::
          {:ok, starts()} | {:error, :invalid_position | :cursor_in_ancestor}
  def at_position(%{ranges: ranges} = view, issuer_id, {index, offset}) do
    case Map.fetch(ranges, issuer_id) do
      :error ->
        {:error, :invalid_position}

      {:ok, issuer} ->
        own = length(issuer.parents)

        cond do
          index > own -> {:error, :invalid_position}
          index < own -> {:error, :cursor_in_ancestor}
          # minted before a split or merge retired the issuer: its own records are now an ancestor's
          read_as_ancestor?(ranges, issuer_id) -> {:error, :cursor_in_ancestor}
          true -> {:ok, moving(view, %{issuer_id => offset})}
        end
    end
  end

  @doc """
  The starts that purge what one consumer group has read, given its commits (`range_id => position`,
  as `Malachi.Metadata` stores them for the group on the topic).

  Every active range reads its ancestors and then itself (`parents ++ [self]`). For each active range,
  its own start is its position's offset once the position is on its own records. For each ancestor, a
  descendant positioned past it has read it to its end, one positioned in it has read up to the offset,
  and one positioned before it, or with no commit at all, has read none of it; the ancestor's start is
  the least of those over every active descendant. An ancestor whose end the control plane no longer
  knows (no sealed segment left) is left out: there is nothing stored to purge, and no end to bound by.
  A range no active range reads (a sealed topic's) is left out too.

      iex> root = %{id: {"t", 0}, parents: [], state: :sealed}
      iex> left = %{id: {"t", 1}, parents: [{"t", 0}], state: :active}
      iex> right = %{id: {"t", 2}, parents: [{"t", 0}], state: :active}
      iex> view = %{
      ...>   ranges: %{root.id => root, left.id => left, right.id => right},
      ...>   segments: %{root.id => [%{state: :sealed, start_offset: 0, length: 10, sealed_at: 1}]}
      ...> }
      iex> # left read the root to 7, right read all of it and 3 of its own
      iex> Malachi.Purge.Points.floors(view, %{left.id => {0, 7}, right.id => {1, 3}})
      %{{"t", 0} => 7, {"t", 2} => 3}
      iex> # a child with no commit has read nothing of the root
      iex> Malachi.Purge.Points.floors(view, %{right.id => {1, 3}})
      %{{"t", 2} => 3}
  """
  @spec floors(topic_view(), %{Metadata.range_id() => position()}) :: starts()
  def floors(%{ranges: ranges} = view, commits) when is_map(commits) do
    active = for {_id, %{state: :active} = range} <- ranges, do: range

    needs =
      Enum.flat_map(active, fn range ->
        position = Map.get(commits, range.id, {0, 0})
        sources = range.parents ++ [range.id]

        sources
        |> Enum.with_index()
        |> Enum.map(fn {source_id, source_index} ->
          {source_id, read_up_to(view, source_id, source_index, position)}
        end)
      end)

    starts =
      needs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {source_id, reads} ->
        if Enum.member?(reads, :unknown), do: [], else: [{source_id, Enum.min(reads)}]
      end)
      |> Map.new()

    moving(view, starts)
  end

  @doc """
  `starts` without the ranges whose start would not move forward: a point at or below a range's current
  logical start, or a range the view does not hold.
  """
  @spec moving(topic_view(), starts()) :: starts()
  def moving(%{ranges: ranges}, starts) do
    for {range_id, offset} <- starts,
        range = Map.get(ranges, range_id),
        range != nil and offset > Metadata.logical_start(range),
        into: %{},
        do: {range_id, offset}
  end

  # How far a reader positioned at `{index, offset}` has read the source at `source_index`.
  defp read_up_to(_view, _source_id, source_index, {index, _offset}) when source_index > index, do: 0
  defp read_up_to(_view, _source_id, source_index, {source_index, offset}), do: offset

  # Past this source: read to its end, which the control plane knows only from its sealed segments.
  defp read_up_to(view, source_id, _source_index, _past) do
    case segments(view, source_id) do
      [] -> :unknown
      segments -> Broker.last_sealed_end(segments)
    end
  end

  defp segments(view, range_id), do: Map.get(view.segments, range_id, [])

  defp read_as_ancestor?(ranges, range_id), do: Enum.any?(ranges, fn {_id, range} -> range_id in range.parents end)

  # The end of the longest run of oldest sealed segments all sealed at or before `time_ms`, or nil.
  defp sealed_before(segments, time_ms) do
    segments
    |> Enum.sort_by(& &1.start_offset)
    |> Enum.take_while(&(&1.state == :sealed and is_integer(&1.sealed_at) and &1.sealed_at <= time_ms))
    |> List.last()
    |> case do
      nil -> nil
      last -> last.start_offset + last.length
    end
  end
end
