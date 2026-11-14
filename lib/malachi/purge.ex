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

  ## Data subject requests

  A purge can answer a data subject's request (#308): `purge/4` takes a `Malachi.Purge.Request`, an
  opaque reference and a reason. The request is recorded in the audit trail as `:purge_request_recorded`
  before the purge runs, and the purge's own `:topic_purged` entry carries the same `request_id`, so a
  request that was recorded and then refused, or that moved nothing, can be read back as such. A purge
  removes every record below the point from every reader, whoever's records they are: it answers one
  subject's request without collateral only on a topic, or a range, that holds that subject alone. The
  guide "Data subject requests" states the limits and the open legal reading.

  ## What is checked before anything is written

  The request (`Malachi.Purge.Request`), the topic (`Malachi.AdminCall.check_topic/1`) and the point (a
  group name of at most 255 bytes of `Malachi.Purge.Request.safe_text?/1` text, a position token of at most
  1024 bytes) are checked before any audit entry or log line is written. A request that is not valid is
  refused with no request recorded. A valid request is recorded even when its topic or point is refused,
  and the refusal carries its id. A refused field is recorded by its size only, never by its bytes, and a
  log line is written only after the broker answered, so only checked values ever reach a line.

  The audit log is flushed after the request's entry and before the purge is sent, and again after the
  purge's entry: with file output both are on disk before the call returns.

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

  require Logger

  alias Malachi.AdminCall
  alias Malachi.AuditLog
  alias Malachi.Broker
  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.I18n
  alias Malachi.Metadata
  alias Malachi.Purge.Request

  @max_group_bytes 255
  @max_token_bytes 1024

  @typedoc "Each range's logical start before and after the purge."
  @type moves :: %{Metadata.range_id() => {non_neg_integer(), non_neg_integer()}}

  @typedoc "Why a purge was refused. `reason_string/1` renders every one of them."
  @type reason ::
          :invalid_topic
          | :invalid_purge_point
          | :invalid_request
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

  @typedoc "What `purge/4` accepts as a request: a validated one, its two fields, or none."
  @type request :: Request.t() | {term(), term()} | nil

  @doc """
  Purges `topic` up to `point` on behalf of `actor`. Answers each range's logical start before and after
  (an empty map when the point moves nothing), or the refusal. Audited either way.

  With a `request` (a `Malachi.Purge.Request`, or its id and reason, validated here either way), the
  request is first recorded as `:purge_request_recorded`, and the `:topic_purged` entry carries its id. A
  request that does not validate is refused as `:invalid_request` before the broker is asked.
  """
  @spec purge(String.t(), Broker.purge_point(), AdminCall.actor(), request()) ::
          {:ok, moves()} | {:error, reason()}
  def purge(topic, point, actor, request \\ nil) do
    case check(topic, point, request) do
      {:ok, request} ->
        run(topic, point, actor, request)

      {:error, reason, metadata, request} ->
        # A valid request is recorded even when its topic or point is refused, so every request that
        # reached the cluster can be found by its id; the refused field is in the metadata by size only.
        record(request, actor, metadata)
        refusal = put_request_id(metadata, request)
        AdminCall.audit(:topic_purged, actor, "purge_topic", {:error, reason}, refusal, &reason_string/1)
        flush_audit()
        {:error, reason}
    end
  end

  defp run(topic, point, actor, request) do
    metadata = %{topic: topic, point: describe_point(point)}
    record(request, actor, metadata)

    result = AdminCall.call(fn -> BrokerServer.purge(DataPlaneRouter.shard_for(topic), topic, point) end)

    metadata = put_request_id(metadata, request)
    AdminCall.audit(:topic_purged, actor, "purge_topic", result, with_moves(metadata, result), &reason_string/1)
    flush_audit()

    log(result, topic, point, actor, request)
    result
  end

  # Writes the request's entry and flushes the audit log before the caller goes on, so with file output
  # the entry is on disk (datasynced) before the purge is sent: a node killed right after the control
  # plane commits still leaves the request in the trail. Stdout output is handed to the logger.
  defp record(nil, _actor, _metadata), do: :ok

  defp record(request, actor, metadata) do
    recorded = Map.merge(metadata, %{request_id: request.id, request_reason: request.reason})
    AdminCall.audit(:purge_request_recorded, actor, "record_purge_request", :ok, recorded)
    flush_audit()
  end

  defp put_request_id(metadata, nil), do: metadata
  defp put_request_id(metadata, request), do: Map.put(metadata, :request_id, request.id)

  # A flush that cannot complete (the audit log restarting, a slow disk) must not take the purge down:
  # the entry is still in the log's mailbox or buffer and is written when it recovers. It is reported.
  defp flush_audit do
    AuditLog.flush()
  catch
    :exit, reason ->
      Logger.warning(I18n.t(:purge_audit_flush_failed, reason: inspect(reason)))
      :ok
  end

  # The request line says a request was recorded, whatever the broker answered; the purge line says a start
  # moved, so it is written only when one did. The audit entries record every request, a purge that moved
  # nothing included. Both are written after the broker answered, from values `check/3` accepted.
  defp log(result, topic, point, actor, request) do
    bindings = [topic: topic, point: describe_point(point), actor: actor]

    if request, do: AdminCall.log(:ok, :purge_request_recorded, [{:request, request.id} | bindings])

    moved = moved_count(result)

    cond do
      moved == 0 -> :ok
      request -> AdminCall.log(result, :topic_purged_for_request, [{:request, request.id}, {:ranges, moved} | bindings])
      true -> AdminCall.log(result, :topic_purged, [{:ranges, moved} | bindings])
    end
  end

  # The request first, then the topic, then the point. An invalid request is refused with nothing recorded
  # but its fields' sizes. A valid request whose topic or point is refused comes back with the refusal, so
  # it is still recorded. A refused field is described by its size only, so arbitrary bytes from a frame
  # never reach the audit trail.
  defp check(topic, point, request) do
    case check_request(request) do
      {:error, reason} ->
        {id, why} = request_fields(request)
        sizes = %{request_id: AdminCall.describe_invalid(id), request_reason: AdminCall.describe_invalid(why)}
        {:error, reason, Map.merge(%{topic: describe_topic(topic), point: describe_point_safely(point)}, sizes), nil}

      {:ok, request} ->
        with {:topic, :ok} <- {:topic, AdminCall.check_topic(topic)},
             {:point, :ok} <- {:point, check_point(point)} do
          {:ok, request}
        else
          {:topic, {:error, reason}} ->
            {:error, reason, %{topic: AdminCall.describe_invalid(topic), point: describe_point_safely(point)}, request}

          {:point, {:error, reason}} ->
            {:error, reason, %{topic: topic, point: describe_invalid_point(point)}, request}
        end
    end
  end

  defp describe_topic(topic) do
    if AdminCall.check_topic(topic) == :ok, do: topic, else: AdminCall.describe_invalid(topic)
  end

  defp describe_point_safely(point) do
    if check_point(point) == :ok, do: describe_point(point), else: describe_invalid_point(point)
  end

  defp check_request(nil), do: {:ok, nil}
  defp check_request(request), do: request |> request_fields() |> then(fn {id, why} -> Request.new(id, why) end)

  defp request_fields(%Request{id: id, reason: reason}), do: {id, reason}
  defp request_fields({id, reason}), do: {id, reason}
  defp request_fields(_other), do: {nil, nil}

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

  def reason_string(:invalid_purge_point),
    do:
      "invalid_purge_point: give exactly one point: a time of at least 0, a position token of 1 to " <>
        "#{@max_token_bytes} bytes, or a consumer group name of 1 to #{@max_group_bytes} bytes of UTF-8 text " <>
        "without control, format or separator characters; a group whose name is outside that can still be " <>
        "purged by time or by position"

  def reason_string(:invalid_request) do
    {id_bytes, reason_bytes} = Request.limits()

    "invalid_request: give both a request id (1 to #{id_bytes} bytes of printable ASCII, no spaces) and a reason " <>
      "(1 to #{reason_bytes} bytes of UTF-8 text without control, format or separator characters), " <>
      "and never the data subject's identity"
  end

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
  defp check_point({:position, token}) when is_binary(token) and byte_size(token) in 1..@max_token_bytes, do: :ok

  defp check_point({:group, group}) when is_binary(group) and byte_size(group) in 1..@max_group_bytes,
    do: if(Request.safe_text?(group), do: :ok, else: {:error, :invalid_purge_point})

  defp check_point(_point), do: {:error, :invalid_purge_point}

  defp describe_invalid_point({:before, time_ms}) when is_integer(time_ms), do: "before:<negative>"

  defp describe_invalid_point({kind, value}) when kind in [:position, :group],
    do: "#{kind}:" <> AdminCall.describe_invalid(value)

  defp describe_invalid_point(_point), do: "<unrecognized>"

  # The audit trail keeps each range's start before and after, so what a purge removed from every reader
  # can be read back later.
  defp with_moves(metadata, {:ok, moves}),
    do: Map.put(metadata, :moves, Map.new(moves, fn {range_id, {from, to}} -> {inspect(range_id), [from, to]} end))

  defp with_moves(metadata, _refused), do: metadata

  defp moved_count({:ok, moves}), do: Enum.count(moves, fn {_range_id, {from, to}} -> to > from end)
  defp moved_count(_refused), do: 0
end
