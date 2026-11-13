defmodule Malachi.KafkaSpike.Handler do
  @moduledoc """
  The answers of the spike's Kafka listener: ApiVersions, Metadata, Produce, Fetch, and InitProducerId when
  the listener advertises idempotence.

  Each answer is the response body as a map holding the fields of every version the spike advertises
  (`Malachi.KafkaSpike.Codec.encode_response/4` takes the ones the negotiated version names), so one
  function serves every version. The node is the only broker and the leader of partition 0 of the one
  topic it serves (`Malachi.KafkaSpike.Topic`); every other topic or partition is answered
  `UNKNOWN_TOPIC_OR_PARTITION`.

  Leader epochs are announced as -1 (unknown) on purpose: a Java consumer that learns a leader epoch
  validates its position with OffsetsForLeaderEpoch, an API the spike does not answer.
  """
  alias Malachi.Broker
  alias Malachi.Broker.ReadView
  alias Malachi.BrokerServer
  alias Malachi.Cluster.ReplicationServer
  alias Malachi.KafkaSpike.ErrorCodes
  alias Malachi.KafkaSpike.RecordBatch
  alias Malachi.KafkaSpike.Records
  alias Malachi.KafkaSpike.Topic

  @typedoc "What a request is answered with: a response body, or nothing (a Produce with acks=0)."
  @type answer :: {:reply, map()} | :noreply

  @typedoc """
  The listener's configuration, as `Malachi.KafkaSpike` builds it: the topic served, the node id, host and
  port Metadata advertises, whether InitProducerId is advertised, the cap on a Fetch's wait, the counter
  producer ids are drawn from, and where request frames are captured, if anywhere.
  """
  @type ctx :: %{
          topic: binary(),
          node_id: non_neg_integer(),
          host: binary(),
          port: :inet.port_number(),
          idempotence: :advertise | :hide,
          max_wait_cap_ms: non_neg_integer(),
          producer_ids: :atomics.atomics_ref(),
          capture_dir: Path.t() | nil
        }

  # The versions served, each within what kafka_protocol has schemas for. Produce starts at v3 and Fetch
  # at v4, the first versions that carry RecordBatch v2; Metadata at v1, where a null topic list (rather
  # than an empty one) means every topic.
  @versions %{
    api_versions: {0, 3},
    metadata: {1, 9},
    produce: {3, 8},
    fetch: {4, 11},
    init_producer_id: {0, 2}
  }

  # The most records one Fetch partition reads before its byte limit trims them: the native fetch's
  # default page (`max`), so the two paths read the same amount from storage per request. A Malachi read
  # is bounded by records, not bytes, so a Kafka fetch with a large max_bytes still gets at most this many;
  # a byte-bounded read is the gateway's to add (#168).
  @fetch_max_records 100

  @doc "The versions of `api` the listener advertises under `ctx`, or nil for an API it does not serve."
  @spec versions(atom() | nil, ctx()) :: {integer(), integer()} | nil
  def versions(:init_producer_id, %{idempotence: :hide}), do: nil
  def versions(api, _ctx), do: Map.get(@versions, api)

  @doc """
  The ApiVersions body listing what the listener advertises, with `error`: `:none`, or
  `:unsupported_version` for a client that asked a version above the listener's (answered as v0, which
  every client reads before retrying at a version the list allows).
  """
  @spec api_versions_body(ctx(), ErrorCodes.name()) :: map()
  def api_versions_body(ctx, error) do
    api_keys =
      Enum.flat_map(Map.keys(@versions), fn api ->
        case versions(api, ctx) do
          {min, max} -> [%{api_key: :kpro_schema.api_key(api), min_version: min, max_version: max}]
          nil -> []
        end
      end)

    %{error_code: ErrorCodes.code(error), api_keys: Enum.sort_by(api_keys, & &1.api_key), throttle_time_ms: 0}
  end

  @doc "The answer to a decoded request of `api` (one `versions/2` advertises) with body `body`."
  @spec handle(atom(), map(), ctx()) :: answer()
  def handle(:api_versions, _body, ctx), do: {:reply, api_versions_body(ctx, :none)}
  def handle(:metadata, body, ctx), do: {:reply, metadata(body, ctx)}
  def handle(:produce, body, ctx), do: produce(body, ctx)
  def handle(:fetch, body, ctx), do: {:reply, fetch(body, ctx)}
  def handle(:init_producer_id, _body, ctx), do: {:reply, init_producer_id(ctx)}

  ## Metadata

  defp metadata(body, ctx) do
    names =
      case body.topics do
        topics when is_list(topics) -> Enum.map(topics, & &1.name)
        # null (v1+): every topic, which for the spike is its one topic
        _null -> [ctx.topic]
      end

    %{
      throttle_time_ms: 0,
      brokers: [%{node_id: ctx.node_id, host: ctx.host, port: ctx.port, rack: nil}],
      cluster_id: "malachi-kafka-spike",
      controller_id: ctx.node_id,
      topics: Enum.map(names, &topic_metadata(&1, ctx)),
      cluster_authorized_operations: -2_147_483_648
    }
  end

  defp topic_metadata(name, ctx) do
    {error, partitions} =
      if name == ctx.topic do
        case Topic.resolve(name) do
          {:ok, _range_id} -> {:none, [partition_metadata(ctx)]}
          {:error, reason} -> {ErrorCodes.from_reason(reason), []}
        end
      else
        {:unknown_topic_or_partition, []}
      end

    %{
      error_code: ErrorCodes.code(error),
      name: name,
      is_internal: false,
      partitions: partitions,
      topic_authorized_operations: -2_147_483_648
    }
  end

  defp partition_metadata(ctx) do
    %{
      error_code: 0,
      partition_index: 0,
      leader_id: ctx.node_id,
      leader_epoch: -1,
      replica_nodes: [ctx.node_id],
      isr_nodes: [ctx.node_id],
      offline_replicas: []
    }
  end

  ## Produce

  defp produce(body, ctx) do
    responses =
      for %{topic: topic, data: partitions} <- body.topic_data do
        %{topic: topic, partition_responses: Enum.map(partitions, &produce_partition(topic, &1, body, ctx))}
      end

    if body.acks == 0, do: :noreply, else: {:reply, %{responses: responses, throttle_time_ms: 0}}
  end

  defp produce_partition(topic, %{partition: partition, record_set: record_set}, body, ctx) do
    result =
      with :ok <- served(topic, partition, ctx),
           :ok <- not_transactional(body.transactional_id),
           {:ok, batches} <- RecordBatch.decode(record_set),
           {:ok, records} <- Records.to_log(Enum.flat_map(batches, & &1.records)),
           :ok <- not_empty(records),
           {:ok, range_id} <- Topic.resolve(topic) do
        append(topic, range_id, records)
      end

    case result do
      {:ok, base_offset} -> produce_partition_response(partition, :none, base_offset)
      {:error, reason} -> produce_partition_response(partition, ErrorCodes.from_reason(reason), -1)
    end
  end

  defp produce_partition_response(partition, error, base_offset) do
    %{
      partition: partition,
      error_code: ErrorCodes.code(error),
      base_offset: base_offset,
      log_append_time: -1,
      log_start_offset: 0,
      record_errors: [],
      error_message: nil
    }
  end

  # kafka_protocol decodes a null nullable_string as <<>>, so an empty transactional id reads as none.
  defp not_transactional(<<>>), do: :ok
  defp not_transactional(_transactional_id), do: {:error, :transactions_unsupported}

  defp not_empty([]), do: {:error, :corrupt_batch}
  defp not_empty(_records), do: :ok

  # The Kafka base offset of the append is the first offset the range assigned it.
  defp append(topic, range_id, records) do
    case BrokerServer.produce(Topic.broker(topic), topic, records) do
      {:ok, %{^range_id => {first, _last}}} -> {:ok, first}
      {:ok, _placements} -> {:error, :split_topic}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> {:error, :timeout}
  end

  ## Fetch

  defp fetch(body, ctx) do
    wait_ms = if body.min_bytes <= 0, do: 0, else: body.max_wait_time |> max(0) |> min(ctx.max_wait_cap_ms)

    responses =
      for %{topic: topic, partitions: partitions} <- body.topics do
        %{
          topic: topic,
          partition_responses: Enum.map(partitions, &fetch_partition(topic, &1, wait_ms, body.max_bytes, ctx))
        }
      end

    %{throttle_time_ms: 0, error_code: 0, session_id: 0, responses: responses}
  end

  defp fetch_partition(topic, %{partition: partition, fetch_offset: offset} = request, wait_ms, max_bytes, ctx) do
    max_bytes = min(Map.get(request, :partition_max_bytes, max_bytes), max_bytes)

    with :ok <- served(topic, partition, ctx),
         :ok <- valid_offset(offset),
         {:ok, range_id} <- Topic.resolve(topic),
         {:ok, position, view, _reporter} <- fetch_range(topic, range_id, offset, wait_ms),
         {:ok, positioned, _cursor, _skips} <-
           Broker.read_consume_positioned(view, range_id, position, @fetch_max_records, &ReplicationServer.read/4) do
      records = positioned |> Enum.map(&kafka_record/1) |> within_bytes(max_bytes)
      fetch_partition_response(partition, :none, high_watermark(view, range_id), RecordBatch.encode(records))
    else
      {:error, reason} -> fetch_partition_response(partition, ErrorCodes.from_reason(reason), -1, <<>>)
    end
  end

  defp valid_offset(offset) when offset >= 0, do: :ok
  defp valid_offset(_offset), do: {:error, :invalid_position}

  # The root range's records sit at source index 0 of its history, so Kafka offset N is position {0, N}.
  defp fetch_range(topic, range_id, offset, wait_ms) do
    case BrokerServer.fetch_range(Topic.broker(topic), range_id, {:position, {0, offset}}, wait_ms) do
      {:moved, _reason, _targets} -> {:error, :not_primary}
      other -> other
    end
  catch
    :exit, _reason -> {:error, :broker_down}
  end

  defp kafka_record({{_index, offset}, record}), do: Records.from_log(%{record | offset: offset})

  # At most `max_bytes` of record payload, and always the first record, as Kafka answers (KIP-74), so a
  # record larger than the limit still makes progress.
  defp within_bytes(records, max_bytes) do
    records
    |> Enum.reduce_while({[], 0}, fn record, {kept, bytes} ->
      bytes = bytes + record_bytes(record)
      if kept == [] or bytes <= max_bytes, do: {:cont, {[record | kept], bytes}}, else: {:halt, {kept, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp record_bytes(record) do
    header_bytes = Enum.reduce(record.headers, 0, fn {key, value}, sum -> sum + byte_size(key) + byte_size(value) end)
    byte_size(record.key || <<>>) + byte_size(record.value) + header_bytes
  end

  defp high_watermark(view, range_id) do
    case ReadView.fetch_end(view, range_id) do
      {:ok, range_end} -> range_end
      :error -> 0
    end
  end

  defp fetch_partition_response(partition, error, high_watermark, record_set) do
    %{
      partition_header: %{
        partition: partition,
        error_code: ErrorCodes.code(error),
        high_watermark: high_watermark,
        last_stable_offset: high_watermark,
        log_start_offset: 0,
        aborted_transactions: [],
        preferred_read_replica: -1
      },
      record_set: record_set
    }
  end

  ## InitProducerId

  # Producer ids are drawn from a counter and never deduplicated against: the spike accepts sequences
  # without checking them, since deduplication is #168's.
  defp init_producer_id(ctx) do
    %{
      throttle_time_ms: 0,
      error_code: 0,
      producer_id: :atomics.add_get(ctx.producer_ids, 1, 1),
      producer_epoch: 0
    }
  end

  defp served(topic, 0, %{topic: topic}), do: :ok
  defp served(_topic, _partition, _ctx), do: {:error, :no_such_topic}
end
