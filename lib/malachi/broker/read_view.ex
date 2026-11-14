defmodule Malachi.Broker.ReadView do
  @moduledoc """
  The slice of a `Malachi.Broker` that reading a set of ranges needs, and nothing else: each range's
  metadata, the segments of the range and of every ancestor it reads history from, where each of those
  ends on this frontend, and whether the range still waits for a recovery.

  It exists so a read can run outside the process that owns the broker. A `Malachi.Broker` carries the
  metadata cache of every vnode, all of which a read of a few ranges never looks at; a view carries
  only the ranges read, their ancestors' segments, their ends and their logical starts. Its size grows with the segments those
  ranges still retain, not with the cluster. `Malachi.BrokerServer` builds one for a range whose consume
  stream or `fetch_range` it wakes and hands it to the connection, which reads and writes its socket
  there (`Malachi.ConsumeStreams`), so a cold read never runs inside the loop that serializes appends. The
  broker's own reads take the same path through a view, so there is one read implementation whoever runs
  it.

  A view is a snapshot. A segment that seals, is deleted, or a range that grows after it was taken is
  not in it, and reads through it are bounded by what it holds: the end it holds for a range is the
  horizon, including for an active segment. A segment it lists that has since been deleted answers a
  read with nothing, and `Malachi.Broker` fails that read rather than taking it for the end of the data,
  so a stale view costs a retry, never a skip.
  """

  alias Malachi.Broker
  alias Malachi.Cluster.DSRSM
  alias Malachi.Metadata

  @type t :: %__MODULE__{
          ranges: %{Metadata.range_id() => Metadata.range_meta()},
          segments: %{Metadata.range_id() => [Metadata.segment_meta()]},
          ends: %{Metadata.range_id() => non_neg_integer()},
          starts: %{Metadata.range_id() => non_neg_integer()},
          live_starts: :ets.tid() | nil,
          unrecovered: MapSet.t(Metadata.range_id()),
          horizon_pending: MapSet.t(Metadata.range_id())
        }

  defstruct ranges: %{},
            segments: %{},
            ends: %{},
            starts: %{},
            live_starts: nil,
            unrecovered: MapSet.new(),
            horizon_pending: MapSet.new()

  @doc """
  The view of `range_ids` from `broker`: each range the control plane knows, plus the segments, the end
  and the logical start (#198) of every range a read of them can touch (the range itself and its
  ancestors). A range the control
  plane does not know is left out, and reads of it answer `:no_such_range`.
  """
  @spec new(Broker.t(), [Metadata.range_id()]) :: t()
  def new(%Broker{} = broker, range_ids) do
    ranges =
      for range_id <- Enum.uniq(range_ids),
          range = DSRSM.get_range(broker.dsrsm, topic_of(range_id), range_id),
          into: %{},
          do: {range_id, range}

    touched = ranges |> Enum.flat_map(fn {range_id, range} -> [range_id | range.parents] end) |> Enum.uniq()

    %__MODULE__{
      ranges: ranges,
      segments: Map.new(touched, &{&1, DSRSM.segments_of_range(broker.dsrsm, topic_of(&1), &1)}),
      ends: Map.take(broker.offsets, touched),
      starts: Map.new(touched, &{&1, range_logical_start(broker, &1)}),
      live_starts: broker.starts_table,
      unrecovered: touched |> Enum.filter(&Broker.unrecovered?(broker, &1)) |> MapSet.new(),
      horizon_pending: touched |> Enum.filter(&Broker.horizon_pending?(broker, &1)) |> MapSet.new()
    }
  end

  @doc "The metadata of `range_id`, or `nil` if the view does not hold it."
  @spec range(t(), Metadata.range_id()) :: Metadata.range_meta() | nil
  def range(%__MODULE__{ranges: ranges}, range_id), do: Map.get(ranges, range_id)

  @doc "The segments of `range_id` (the range or one of its ancestors), `[]` if it has none or is unknown."
  @spec segments(t(), Metadata.range_id()) :: [Metadata.segment_meta()]
  def segments(%__MODULE__{segments: segments}, range_id), do: Map.get(segments, range_id, [])

  @doc """
  The logical start of `range_id` (the range or one of its ancestors): no reader is served an offset
  below it (`Malachi.Metadata.logical_start/1`). 0 when no operator purged it or the view does not hold it.

  The higher of the start the view was built with and the one the broker publishes now (`live_starts`):
  a view is a snapshot, and a stream that keeps reading from the one it holds would otherwise go on
  serving what a purge removed after the snapshot, up to the end of its view. The start only moves
  forward, so the higher one is the current one. A broker that is gone leaves the view's own start.
  """
  @spec logical_start(t(), Metadata.range_id()) :: non_neg_integer()
  def logical_start(%__MODULE__{starts: starts, live_starts: table}, range_id),
    do: max(Map.get(starts, range_id, 0), live_start(table, range_id))

  defp live_start(nil, _range_id), do: 0

  defp live_start(table, range_id) do
    case :ets.lookup(table, range_id) do
      [{^range_id, start}] -> start
      [] -> 0
    end
  rescue
    # the table died with the broker that owned it, while this view was still being read
    ArgumentError -> 0
  end

  @doc "Where `range_id` ends on the frontend the view came from (its next offset), or `:error` if unknown."
  @spec fetch_end(t(), Metadata.range_id()) :: {:ok, non_neg_integer()} | :error
  def fetch_end(%__MODULE__{ends: ends}, range_id), do: Map.fetch(ends, range_id)

  @doc """
  The view with `range_end` as where `range_id` ends: the horizon a reader reads `range_id` up to, which
  the broker hands with each wake (`Malachi.Broker.durable_end/3`) for a view it built before.
  """
  @spec put_end(t(), Metadata.range_id(), non_neg_integer()) :: t()
  def put_end(%__MODULE__{} = view, range_id, range_end), do: %{view | ends: Map.put(view.ends, range_id, range_end)}

  @doc "Where the last sealed segment of `range_id` in the view ends, 0 when none is (`Malachi.Broker.last_sealed_end/1`)."
  @spec sealed_end(t(), Metadata.range_id()) :: non_neg_integer()
  def sealed_end(%__MODULE__{} = view, range_id), do: view |> segments(range_id) |> Broker.last_sealed_end()

  @doc "Whether `range_id` waits for a recovery that learns its end (see `Malachi.Broker.unrecovered?/2`)."
  @spec unrecovered?(t(), Metadata.range_id()) :: boolean()
  def unrecovered?(%__MODULE__{unrecovered: unrecovered}, range_id), do: MapSet.member?(unrecovered, range_id)

  @doc "Whether `range_id` waits for its horizon (see `Malachi.Broker.horizon_pending?/2`)."
  @spec horizon_pending?(t(), Metadata.range_id()) :: boolean()
  def horizon_pending?(%__MODULE__{horizon_pending: pending}, range_id), do: MapSet.member?(pending, range_id)

  defp topic_of(range_id), do: elem(range_id, 0)

  # An ancestor the cache does not hold (yet) reads as never purged, like a range no operator purged.
  defp range_logical_start(broker, range_id),
    do: Metadata.logical_start(DSRSM.get_range(broker.dsrsm, topic_of(range_id), range_id) || %{})
end
