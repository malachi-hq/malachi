defmodule Malachi.Loadtest.KafkaConn do
  @moduledoc """
  One Kafka connection of the load generator, for `--wire kafka` (#166): the spike's Kafka listener
  measured with the same generator, connection count, batch and pipeline as the native protocol, so the
  difference between the two runs is the gateway's and not the client's.

  It speaks only what the spike answers, at the versions it advertises: Produce v8 and Fetch v11, to
  partition 0 of one topic, with no authentication. Requests are encoded with `kafka_protocol` (whose
  client side is what it was written for), record batches with the spike's own codec
  (`Malachi.KafkaSpike.RecordBatch`). Up to `pipeline` requests are in flight, answered in order, as Kafka
  answers a connection.
  """
  alias Malachi.KafkaSpike.RecordBatch

  require Record

  Record.defrecordp(:kpro_rsp, Record.extract(:kpro_rsp, from_lib: "kafka_protocol/include/kpro.hrl"))

  @produce_vsn 8
  @fetch_vsn 11
  @recv_timeout_ms 15_000

  defstruct [:socket, :topic, next_correlation: 1, in_flight: :queue.new(), fetch_offset: 0]

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket(),
          topic: binary(),
          next_correlation: pos_integer(),
          in_flight: :queue.queue({integer(), atom(), integer(), non_neg_integer()}),
          fetch_offset: non_neg_integer()
        }

  @typedoc "What an answered request did: records acknowledged or read, and its round trip in microseconds."
  @type answer :: {:ok, non_neg_integer(), non_neg_integer()} | {:error, term(), non_neg_integer()}

  @doc "Connects to the Kafka listener at `host:port` to drive `topic`."
  @spec connect(String.t(), :inet.port_number(), binary()) :: {:ok, t()} | {:error, term()}
  def connect(host, port, topic) do
    opts = [:binary, active: false, packet: 0, nodelay: true]

    case :gen_tcp.connect(String.to_charlist(host), port, opts, 5_000) do
      {:ok, socket} -> {:ok, %__MODULE__{socket: socket, topic: topic}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Closes the connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  @doc "How many requests are waiting for their answer."
  @spec in_flight(t()) :: non_neg_integer()
  def in_flight(%__MODULE__{in_flight: queue}), do: :queue.len(queue)

  @doc "Sends a Produce of `records` (Malachi records, acks=all) without waiting for its answer."
  @spec send_produce(t(), [Malachi.Log.Record.t()]) :: {:ok, t()} | {:error, term()}
  def send_produce(conn, records) do
    batch =
      records
      |> Enum.with_index()
      |> Enum.map(fn {record, i} ->
        %{offset: i, timestamp: record.timestamp, key: record.key, value: record.value, headers: record.headers}
      end)
      |> RecordBatch.encode()
      |> IO.iodata_to_binary()

    fields = %{
      transactional_id: :undefined,
      acks: -1,
      timeout: 10_000,
      topic_data: [%{topic: conn.topic, data: [%{partition: 0, record_set: batch}]}]
    }

    send_request(conn, :produce, @produce_vsn, fields, length(records))
  end

  @doc """
  Sends a Fetch of up to `max_bytes` from the connection's read position, which each answered fetch
  advances, and which goes back to 0 at the end of the partition (a fetch run rereads its backlog).
  """
  @spec send_fetch(t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def send_fetch(conn, max_bytes) do
    req = :kpro_req_lib.fetch(@fetch_vsn, conn.topic, 0, conn.fetch_offset, %{max_wait_time: 0, max_bytes: max_bytes})
    send_encoded(conn, req, :fetch, 0)
  end

  defp send_request(conn, api, vsn, fields, count),
    do: send_encoded(conn, :kpro_req_lib.make(api, vsn, fields), api, count)

  defp send_encoded(conn, req, api, count) do
    correlation = conn.next_correlation
    frame = :kpro_req_lib.encode("malachi-loadtest", correlation, req)

    case :gen_tcp.send(conn.socket, [<<IO.iodata_length(frame)::32-signed>>, frame]) do
      :ok ->
        entry = {correlation, api, System.monotonic_time(:microsecond), count}
        {:ok, %{conn | next_correlation: correlation + 1, in_flight: :queue.in(entry, conn.in_flight)}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Waits for the oldest request in flight to be answered: `{:ok, records, latency_us}` for an acknowledged
  produce or a fetch (its records read), `{:error, reason, latency_us}` for a Kafka error code, or
  `{:error, reason}` when the connection failed.
  """
  @spec await(t()) :: {answer(), t()} | {:error, term()}
  def await(conn) do
    {{:value, {correlation, api, sent_at, count}}, queue} = :queue.out(conn.in_flight)

    with {:ok, <<size::32-signed>>} <- :gen_tcp.recv(conn.socket, 4, @recv_timeout_ms),
         {:ok, <<^correlation::32-signed, body::binary>>} <- :gen_tcp.recv(conn.socket, size, @recv_timeout_ms) do
      latency = System.monotonic_time(:microsecond) - sent_at
      vsn = if api == :produce, do: @produce_vsn, else: @fetch_vsn
      msg = kpro_rsp(:kpro_rsp_lib.decode(api, vsn, body, false), :msg)
      answered(%{conn | in_flight: queue}, api, msg, count, latency)
    else
      {:ok, _other} -> {:error, :correlation_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp answered(conn, :produce, %{responses: [%{partition_responses: [partition]}]}, count, latency) do
    case partition.error_code do
      :no_error -> {{:ok, count, latency}, conn}
      error -> {{:error, error, latency}, conn}
    end
  end

  defp answered(conn, :fetch, %{responses: [%{partition_responses: [partition]}]}, _count, latency) do
    header = partition.partition_header

    case {header.error_code, RecordBatch.decode(partition.record_set)} do
      {:no_error, {:ok, batches}} ->
        records = Enum.flat_map(batches, & &1.records)
        next = next_offset(records, conn.fetch_offset, header.high_watermark)
        {{:ok, length(records), latency}, %{conn | fetch_offset: next}}

      {:no_error, {:error, reason}} ->
        {{:error, reason, latency}, conn}

      {error, _decoded} ->
        {{:error, error, latency}, %{conn | fetch_offset: 0}}
    end
  end

  defp next_offset([], offset, high_watermark) when offset >= high_watermark, do: 0
  defp next_offset([], offset, _high_watermark), do: offset
  defp next_offset(records, _offset, _high_watermark), do: List.last(records).offset + 1
end
