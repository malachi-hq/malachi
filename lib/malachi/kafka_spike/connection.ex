defmodule Malachi.KafkaSpike.Connection do
  @moduledoc """
  One Kafka connection of the spike: requests read one frame at a time and answered in order.

  Kafka answers the requests of one connection in the order they came, and a broker reads the next request
  of a connection only once the previous one is answered, so serving one frame at a time is the protocol's
  own model rather than a simplification. A Fetch that waits for records holds its connection the same way.

  A request the spike does not serve is logged with its API key, version and client id, and the connection
  is closed, which is what a Kafka broker does with an API it does not know. Those log lines are how the
  spike learns which APIs a client needs beyond the four it answers. ApiVersions at a version above the
  spike's is the exception the protocol defines: it is answered `UNSUPPORTED_VERSION` as v0, with the list.

  Each answered request emits `[:malachi, :kafka_spike, :request]` with the native time spent decoding it
  (`:decode`), answering it against the broker (`:broker`) and encoding the answer (`:encode`), and the
  `:api` and `:vsn` as metadata: the split of the gateway's overhead the spike measures.
  """
  require Logger
  alias Malachi.I18n
  alias Malachi.KafkaSpike.Codec
  alias Malachi.KafkaSpike.Handler

  @typedoc "What a frame is answered with."
  @type outcome :: {:reply, iodata()} | :noreply | {:close, term()}

  @doc """
  Serves `socket` (a `:gen_tcp` socket in passive mode) until the client closes it or sends a frame the
  spike does not serve.
  """
  @spec serve(:gen_tcp.socket(), Handler.ctx(), pos_integer()) :: :ok
  def serve(socket, ctx, max_frame_size) do
    case read_frame(socket, max_frame_size) do
      {:ok, frame} ->
        capture(frame, ctx)

        case handle_frame(frame, ctx) do
          {:reply, response} ->
            case :gen_tcp.send(socket, response) do
              :ok -> serve(socket, ctx, max_frame_size)
              {:error, _reason} -> :gen_tcp.close(socket)
            end

          :noreply ->
            serve(socket, ctx, max_frame_size)

          {:close, reason} ->
            log_close(reason)
            :gen_tcp.close(socket)
        end

      {:error, reason} ->
        log_close(reason)
        :gen_tcp.close(socket)
    end

    :ok
  end

  # A size of 0 is refused before the read: `:gen_tcp.recv/2` takes a length of 0 to mean "whatever is
  # there", which would hand the next request's bytes to this one.
  defp read_frame(socket, max_frame_size) do
    case :gen_tcp.recv(socket, 4) do
      {:ok, <<size::32-signed>>} when size > 0 and size <= max_frame_size -> :gen_tcp.recv(socket, size)
      {:ok, <<size::32-signed>>} -> {:error, {:frame_size, size}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Writes `frame` under `ctx.capture_dir` as `<client_id>-<api_key>-v<version>.bin` when no frame of that
  client, API and version was written before: the golden frames the codec tests replay. Nothing without a
  capture directory, or for a frame whose header does not parse.
  """
  @spec capture(binary(), map()) :: :ok
  def capture(frame, %{capture_dir: dir}) when is_binary(dir) do
    with {:ok, %{api_key: api_key, vsn: vsn, client_id: client_id}, _body} <- Codec.decode_header(frame) do
      client = String.replace(client_id || "null", ~r/[^A-Za-z0-9._-]/, "_")
      path = Path.join(dir, "#{client}-#{api_key}-v#{vsn}.bin")
      unless File.exists?(path), do: File.write!(path, frame)
    end

    :ok
  end

  def capture(_frame, _ctx), do: :ok

  @doc "The outcome of one request frame (without its size prefix), under `ctx`."
  @spec handle_frame(binary(), Handler.ctx()) :: outcome()
  def handle_frame(frame, ctx) do
    started = System.monotonic_time()

    case Codec.decode_header(frame) do
      {:ok, header, body} -> answer(header, body, ctx, started)
      {:error, :malformed} -> {:close, :malformed_header}
    end
  end

  defp answer(%{api: api, vsn: vsn} = header, body, ctx, started) do
    case Handler.versions(api, ctx) do
      nil ->
        {:close, {:unsupported_api, header}}

      {min, max} when vsn < min or vsn > max ->
        unsupported_version(header, ctx)

      _range ->
        case Codec.decode_body(api, vsn, body) do
          {:ok, request} -> answer_decoded(header, request, ctx, started)
          {:error, :malformed} -> {:close, {:malformed_body, header}}
        end
    end
  end

  defp unsupported_version(%{api: :api_versions, correlation_id: correlation_id}, ctx) do
    body = Handler.api_versions_body(ctx, :unsupported_version)
    {:reply, Codec.encode_response(:api_versions, 0, correlation_id, body)}
  end

  defp unsupported_version(header, _ctx), do: {:close, {:unsupported_version, header}}

  defp answer_decoded(%{api: api, vsn: vsn, correlation_id: correlation_id}, request, ctx, started) do
    decoded = System.monotonic_time()
    answer = Handler.handle(api, request, ctx)
    answered = System.monotonic_time()

    outcome =
      case answer do
        {:reply, body} -> {:reply, Codec.encode_response(api, vsn, correlation_id, body)}
        :noreply -> :noreply
      end

    :telemetry.execute(
      [:malachi, :kafka_spike, :request],
      %{decode: decoded - started, broker: answered - decoded, encode: System.monotonic_time() - answered},
      %{api: api, vsn: vsn}
    )

    outcome
  end

  defp log_close(:closed), do: :ok

  defp log_close({kind, %{api_key: api_key, vsn: vsn, client_id: client_id}}) do
    Logger.warning(
      I18n.t(:kafka_spike_request_refused,
        kind: kind,
        api_key: api_key,
        vsn: vsn,
        client_id: inspect(client_id)
      )
    )
  end

  defp log_close(reason), do: Logger.warning(I18n.t(:kafka_spike_connection_closed, reason: inspect(reason)))
end
