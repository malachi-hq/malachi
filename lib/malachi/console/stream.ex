defmodule Malachi.Console.Stream do
  @moduledoc """
  `GET /api/v1/stream`: one Server-Sent Events stream per client carrying the overview's deltas from
  `Malachi.Console.StreamHub`, discriminated by `event:` (section 10.5 of
  `docs/design/operator-interfaces.md`).

  What the wire carries, against what today's dashboard stream does not:

    * an `id:` on every event, which a client sends back as `Last-Event-ID` to resume (the hub describes
      how a resume either replays what it missed or says it cannot);
    * `retry:` set explicitly when the stream opens;
    * a `:` comment every heartbeat interval while nothing else is sent, so a proxy's idle timeout never
      closes a quiet stream;
    * deltas rather than a whole snapshot every second.

  A refusal before the stream opens keeps its status (401, 403, 429 as `application/problem+json`, from
  `Malachi.Console.Api`), because the client reads the stream through `fetch` and can re-authenticate on
  it. Once the 200 is sent, an error is an `error` event on the stream.

  The stream is authorized once, when it opens, as `Malachi.Console.Access` describes. A subscriber that
  falls behind (its mailbox holds more than 100 events) drops what is queued and resubscribes from the
  last event it wrote, which replays from the ring, so a slow client costs itself and nobody else; an
  event that reaches it after a replay already wrote it is not written again. A stream watches its hub: if
  the hub restarts, the stream subscribes to the new one from the last event it wrote and receives a `gap`
  and a `snapshot`, rather than staying open with nothing on it.
  """

  import Plug.Conn

  alias Malachi.Console.StreamHub

  @retry_ms 5_000
  @default_heartbeat_ms 15_000
  @behind_threshold 100

  @doc "Opens the stream on an authorized `conn` and serves it until the client goes away."
  @spec serve(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def serve(conn, opts \\ []) do
    hub = Keyword.get(opts, :hub, StreamHub)
    heartbeat = Keyword.get_lazy(opts, :heartbeat_ms, &heartbeat_ms/0)
    last_event_id = last_event_id(conn)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    with {:ok, conn} <- chunk(conn, "retry: #{@retry_ms}\n\n"),
         {:ok, monitor} <- watch_hub(hub),
         {:ok, conn, last} <- write_events(conn, StreamHub.subscribe(last_event_id, hub), last_event_id) do
      loop(conn, %{hub: hub, heartbeat: heartbeat, last: last, monitor: monitor})
    else
      # no hub to stream from: the client reconnects and finds one
      :no_hub -> halt(conn)
      # the client went away before the first events reached it
      {:error, _closed} -> halt(conn)
    end
  end

  # Runs until a write fails, which is how a client that went away shows: the response is then over.
  defp loop(conn, state) do
    written =
      receive do
        {:console_stream_event, event} ->
          cond do
            behind?() ->
              drain()
              write_events(conn, StreamHub.subscribe(state.last, state.hub), state.last)

            # already written by a replay that raced it
            not newer?(event.id, state.last) ->
              {:ok, conn, state.last}

            true ->
              write_events(conn, [event], state.last)
          end

        {:DOWN, monitor, :process, _hub, _reason} when monitor == state.monitor ->
          resubscribe(conn, state)
      after
        state.heartbeat -> heartbeat(conn, state.last)
      end

    case written do
      {:ok, conn, last} -> loop(conn, %{state | last: last})
      {:ok, conn, last, monitor} -> loop(conn, %{state | last: last, monitor: monitor})
      {:error, _closed} -> halt(conn)
    end
  end

  # The hub restarted under a stream that stays open: subscribe to the new one from the last event written.
  # Its epoch is new, so it answers with a `gap` and a `snapshot`, and the client goes on without
  # reconnecting. A hub that does not come back within the wait ends the response, and the client reconnects.
  defp resubscribe(conn, state) do
    case watch_hub(state.hub) do
      {:ok, monitor} ->
        case write_events(conn, StreamHub.subscribe(state.last, state.hub), state.last) do
          {:ok, conn, last} -> {:ok, conn, last, monitor}
          error -> error
        end

      :no_hub ->
        {:error, :no_hub}
    end
  end

  @hub_wait_ms 5_000
  @hub_poll_ms 50

  defp watch_hub(hub, waited \\ 0) do
    case GenServer.whereis(hub) do
      pid when is_pid(pid) ->
        {:ok, Process.monitor(pid)}

      nil when waited < @hub_wait_ms ->
        Process.sleep(@hub_poll_ms)
        watch_hub(hub, waited + @hub_poll_ms)

      nil ->
        :no_hub
    end
  end

  @doc """
  Whether event `id` comes after `last`, the id of the last event written: a later sequence of the same
  hub, or any event of another hub (a restarted one, whose epoch is new). Every event is newer than none.

  ## Examples

      iex> Malachi.Console.Stream.newer?("abc.5", "abc.4")
      true
      iex> Malachi.Console.Stream.newer?("abc.4", "abc.4")
      false
      iex> Malachi.Console.Stream.newer?("new.1", "abc.9")
      true

  """
  @spec newer?(String.t(), String.t() | nil) :: boolean()
  def newer?(_id, nil), do: true

  def newer?(id, last) do
    with [epoch, sequence] <- String.split(id, ".", parts: 2),
         [^epoch, last_sequence] <- String.split(last, ".", parts: 2),
         {sequence, ""} <- Integer.parse(sequence),
         {last_sequence, ""} <- Integer.parse(last_sequence) do
      sequence > last_sequence
    else
      _other_epoch_or_shape -> true
    end
  end

  defp behind? do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)
    queued > @behind_threshold
  end

  defp drain do
    receive do
      {:console_stream_event, _event} -> drain()
    after
      0 -> :ok
    end
  end

  defp heartbeat(conn, last) do
    case chunk(conn, ": heartbeat\n\n") do
      {:ok, conn} -> {:ok, conn, last}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_events(conn, events, last) do
    Enum.reduce_while(events, {:ok, conn, last}, fn event, {:ok, conn, _last} ->
      case chunk(conn, encode(event)) do
        {:ok, conn} -> {:cont, {:ok, conn, event.id}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "One event in the Server-Sent Events wire format."
  @spec encode(StreamHub.event()) :: iodata()
  def encode(%{id: id, event: event, data: data}),
    do: ["id: ", id, "\nevent: ", event, "\ndata: ", Jason.encode_to_iodata!(data), "\n\n"]

  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [id | _rest] when id != "" -> id
      _none -> nil
    end
  end

  @doc "How long a quiet stream waits before a heartbeat comment: `:console_stream_heartbeat_ms`, 15 s by default."
  @spec heartbeat_ms() :: pos_integer()
  def heartbeat_ms do
    case Application.get_env(:malachi, :console_stream_heartbeat_ms, @default_heartbeat_ms) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_heartbeat_ms
    end
  end
end
