defmodule Malachi.Purge do
  @moduledoc """
  The administrative entry point for the manual purge (#198): move a topic's logical start up to a
  point, so no reader is served what lies below it. The wire key and `mix malachi.purge` are thin
  adapters over this module, so validation, the error vocabulary, the audit entry and the log line are
  written once.

  ## The point

  Clients never see offsets, so a point is one of (`t:Malachi.Broker.purge_point/0`):

    * `{:before, epoch_ms}`: every record in a segment the control plane sealed at or before that time.
      Record timestamps are client supplied, so the seal time is the only one the cluster vouches for,
      and the point rounds DOWN to a segment boundary; the active segment is never purged by time.
    * `{:position, token}`: up to an opaque position a read handed out, on the range that issued it. A
      position still inside an ancestor of that range is refused (`:cursor_in_ancestor`): the ancestor is
      read by the range's siblings too.
    * `{:group, name}`: everything the consumer group has read. An ancestor a split retired is purged
      only up to the least any of its active descendants' readers in the group has read, and a
      descendant the group never committed on pins it at 0 (`Malachi.Purge.Points.floors/2`).

  ## What a purge is, and is not

  This is a LOGICAL purge. Every read a consumer makes is clamped to the logical start
  (`Malachi.Broker`'s read path), and a reader below it is moved past and told so
  (`Malachi.Broker.Skip`, `cause: :purged`). The records stay on disk, on every replica of their
  segment, until retention removes the whole segment, which it does on its next sweep once the segment
  lies wholly below the start (`Malachi.Cluster.Retention.expired/5`). The segment that holds the start
  stays until the start passes its end. Copy repair, the scrubber and replication still read those bytes,
  since they keep segments whole. This is not erasure.

  ## When it takes effect

  The reply comes after the control plane committed the command and the frontend that ran it applied
  it, so that frontend clamps every read it serves from then on. Every other frontend applies it when it
  next reconciles its cache with the control plane (`:brokers_refresh_interval`, 1 s by default), and a
  stream already holding a read view serves at most the page it is reading.

  ## Upgrades

  Purging needs machine version 9. Until every member of a topic's metadata group runs a release that
  implements it and the operator has lifted the version pin, the control plane refuses it identically on
  every member with `{:unsupported_command, key, 9, effective}`, which `reason_string/1` turns into
  "finish the rolling upgrade".
  """

  alias Malachi.AdminCall
  alias Malachi.Broker
  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.Metadata

  @typedoc "Each range's logical start before and after the purge."
  @type moves :: %{Metadata.range_id() => {non_neg_integer(), non_neg_integer()}}

  @typedoc "Why a purge was refused. `reason_string/1` renders every one of them."
  @type reason ::
          :invalid_topic
          | :invalid_purge_point
          | :invalid_position
          | :cursor_in_ancestor
          | :no_such_topic
          | :no_such_range
          | :start_past_end
          | :metadata_unavailable
          | :migrating
          | :timeout
          | {:unsupported_command, term(), non_neg_integer(), non_neg_integer()}
          | term()

  @doc """
  Purges `topic` up to `point` on behalf of `actor`. Answers each range's logical start before and after
  (an empty map when the point moves nothing), or the refusal. Audited either way.
  """
  @spec purge(String.t(), Broker.purge_point(), AdminCall.actor()) :: {:ok, moves()} | {:error, reason()}
  def purge(topic, point, actor) do
    result =
      with :ok <- AdminCall.check_topic(topic),
           :ok <- check_point(point) do
        AdminCall.call(fn -> BrokerServer.purge(DataPlaneRouter.shard_for(topic), topic, point) end)
      end

    metadata = %{topic: topic, point: describe_point(point)}
    AdminCall.audit(:topic_purged, actor, "purge_topic", result, with_moves(metadata, result), &reason_string/1)

    # The log line says a start moved, so it is written only when one did; the audit entry above records
    # every request, a purge that moved nothing included.
    moved = moved_count(result)

    if moved > 0,
      do: AdminCall.log(result, :topic_purged, topic: topic, point: describe_point(point), actor: actor, ranges: moved)

    result
  end

  @doc """
  A stable, human-readable rendering of a refusal, the same on the wire and in the CLI. It starts with
  the reason's name, so a client can still branch on it.

  ## Examples

      iex> Malachi.Purge.reason_string(:cursor_in_ancestor)
      "cursor_in_ancestor: the position is still inside a range a split retired, which its siblings read too; purge by time or by a group instead"

      iex> Malachi.Purge.reason_string(:no_such_topic)
      "no_such_topic"

  """
  @spec reason_string(reason()) :: String.t()
  def reason_string(:cursor_in_ancestor),
    do:
      "cursor_in_ancestor: the position is still inside a range a split retired, which its siblings read too; " <>
        "purge by time or by a group instead"

  def reason_string(:start_past_end),
    do: "start_past_end: the point is past what this node knows of the range's end; retry once it has caught up"

  def reason_string(reason), do: AdminCall.reason_string(reason)

  @doc """
  How the audit entry and the log line name a point.

      iex> Malachi.Purge.describe_point({:before, 1_700_000_000_000})
      "before:1700000000000"
      iex> Malachi.Purge.describe_point({:group, "billing"})
      "group:billing"
      iex> Malachi.Purge.describe_point({:position, <<1, 2>>})
      "position:0102"
  """
  @spec describe_point(term()) :: String.t()
  def describe_point({:before, time_ms}) when is_integer(time_ms), do: "before:#{time_ms}"
  def describe_point({:group, group}) when is_binary(group), do: "group:" <> group
  def describe_point({:position, token}) when is_binary(token), do: "position:" <> Base.encode16(token, case: :lower)
  def describe_point(other), do: inspect(other)

  defp check_point({:before, time_ms}) when is_integer(time_ms) and time_ms >= 0, do: :ok
  defp check_point({:position, token}) when is_binary(token), do: :ok
  defp check_point({:group, group}) when is_binary(group) and group != "", do: :ok
  defp check_point(_point), do: {:error, :invalid_purge_point}

  # The audit trail keeps each range's start before and after, so what a purge removed from every reader
  # can be read back later.
  defp with_moves(metadata, {:ok, moves}),
    do: Map.put(metadata, :moves, Map.new(moves, fn {range_id, {from, to}} -> {inspect(range_id), [from, to]} end))

  defp with_moves(metadata, _refused), do: metadata

  defp moved_count({:ok, moves}), do: Enum.count(moves, fn {_range_id, {from, to}} -> to > from end)
  defp moved_count(_refused), do: 0
end
