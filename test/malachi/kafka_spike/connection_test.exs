defmodule Malachi.KafkaSpike.ConnectionTest do
  # The broker the topics land on is the application's, shared by every test of the suite.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias Malachi.BrokerServer
  alias Malachi.KafkaSpike.Connection
  alias Malachi.KafkaSpike.RecordBatch
  alias Malachi.KafkaSpike.Topic
  alias Malachi.Test.KafkaClient
  alias Malachi.Test.TmpDir

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        topic: "kafka-spike-#{System.unique_integer([:positive])}",
        node_id: 7,
        host: "spike.test",
        port: 19_092,
        idempotence: :hide,
        max_wait_cap_ms: 200,
        producer_ids: :atomics.new(1, signed: true)
      },
      overrides
    )
  end

  defp reply!(frame, ctx) do
    assert {:reply, response} = Connection.handle_frame(frame, ctx)
    response
  end

  defp api_keys(body), do: Map.new(body.api_keys, &{&1.api_key, {&1.min_version, &1.max_version}})

  # A RecordBatch v2 the way a client sends it, with the record fields kafka_protocol cannot encode (a
  # null key or value, a null header value) and an arbitrary first offset.
  defp batch(records), do: IO.iodata_to_binary(RecordBatch.encode(records))

  defp idempotent(
         <<head::binary-size(17), _crc::32, attributes::binary-size(22), _producer::binary-size(14), rest::binary>>,
         id,
         epoch,
         sequence
       ) do
    checked = <<attributes::binary, id::64, epoch::16, sequence::32, rest::binary>>
    <<head::binary, :crc32cer.nif(checked)::32, checked::binary>>
  end

  defp kafka_record(offset, fields),
    do: Map.merge(%{offset: offset, timestamp: 1_700_000_000_000 + offset, key: "k", value: "v", headers: []}, fields)

  defp produce_frame(vsn, topic, record_set, acks \\ -1) do
    fields = %{
      transactional_id: :undefined,
      acks: acks,
      timeout: 5_000,
      topic_data: [%{topic: topic, data: [%{partition: 0, record_set: record_set}]}]
    }

    KafkaClient.request(:produce, vsn, fields)
  end

  defp produce!(ctx, records, vsn \\ 8) do
    frame = produce_frame(vsn, ctx.topic, batch(records))
    {1, body} = KafkaClient.response(:produce, vsn, reply!(frame, ctx))
    [%{partition_responses: [partition]}] = body.responses
    partition
  end

  defp fetch!(ctx, offset, vsn \\ 11, opts \\ %{}) do
    frame = KafkaClient.fetch(vsn, ctx.topic, offset, Map.merge(%{max_wait_time: 0}, opts))
    {1, body} = KafkaClient.response(:fetch, vsn, reply!(frame, ctx))
    [%{partition_responses: [partition]}] = body.responses
    partition
  end

  defp fetched_records(%{record_set: record_set}) do
    {:ok, batches} = RecordBatch.decode(record_set)
    Enum.flat_map(batches, & &1.records)
  end

  describe "ApiVersions" do
    test "lists the four APIs and leaves InitProducerId out when idempotence is hidden" do
      for vsn <- 0..3 do
        {1, body} =
          KafkaClient.response(
            :api_versions,
            vsn,
            reply!(KafkaClient.request(:api_versions, vsn, request_fields(vsn)), ctx())
          )

        assert body.error_code == :no_error
        assert api_keys(body) == %{produce: {3, 8}, fetch: {4, 11}, metadata: {1, 9}, api_versions: {0, 3}}
      end
    end

    test "adds InitProducerId when idempotence is advertised" do
      frame = KafkaClient.request(:api_versions, 3, request_fields(3))
      {1, body} = KafkaClient.response(:api_versions, 3, reply!(frame, ctx(%{idempotence: :advertise})))

      assert api_keys(body)[:init_producer_id] == {0, 2}
    end

    test "answers a version above its own as v0 with UNSUPPORTED_VERSION and the list" do
      # ApiVersions v4 as the Java client sends it first: header v2, a body the spike does not decode
      frame = <<18::16, 4::16, 9::32, 4::16, "java", 0, 3, "j", 2, "4", 0>>
      {9, body} = KafkaClient.response(:api_versions, 0, reply!(frame, ctx()))

      assert body.error_code == :unsupported_version
      assert api_keys(body)[:produce] == {3, 8}
    end
  end

  describe "Metadata" do
    test "announces the node as the leader of partition 0 of the topic, with no leader epoch" do
      ctx = ctx()

      for vsn <- 1..9 do
        frame = KafkaClient.request(:metadata, vsn, metadata_fields(vsn, [ctx.topic]))
        {1, body} = KafkaClient.response(:metadata, vsn, reply!(frame, ctx))

        assert [%{node_id: 7, host: "spike.test", port: 19_092}] = body.brokers
        assert body.controller_id == 7
        assert [%{error_code: :no_error, name: name, partitions: [partition]}] = body.topics
        assert name == ctx.topic

        assert %{error_code: :no_error, partition_index: 0, leader_id: 7, replica_nodes: [7], isr_nodes: [7]} =
                 partition

        if vsn >= 7, do: assert(partition.leader_epoch == -1)
      end
    end

    test "a null topic list answers the topic served" do
      ctx = ctx()
      frame = KafkaClient.request(:metadata, 9, metadata_fields(9, :undefined))
      {1, body} = KafkaClient.response(:metadata, 9, reply!(frame, ctx))

      assert [%{name: name}] = body.topics
      assert name == ctx.topic
    end

    test "any other topic is UNKNOWN_TOPIC_OR_PARTITION" do
      frame = KafkaClient.request(:metadata, 9, metadata_fields(9, ["not-served"]))
      {1, body} = KafkaClient.response(:metadata, 9, reply!(frame, ctx()))

      assert [%{name: "not-served", error_code: :unknown_topic_or_partition, partitions: []}] = body.topics
    end
  end

  describe "Produce and Fetch" do
    test "a record comes back byte for byte, with its headers, key and timestamp" do
      ctx = ctx()
      headers = [{"trace", <<0, 1, 2, 255>>}, {"trace", "repeated"}, {"empty", ""}]
      record = kafka_record(0, %{key: <<1, 2, 3>>, value: :crypto.strong_rand_bytes(300), headers: headers})

      assert %{error_code: :no_error, base_offset: 0} = produce!(ctx, [record])
      fetched = fetch!(ctx, 0)

      assert fetched.partition_header.error_code == :no_error
      assert fetched.partition_header.high_watermark == 1
      assert fetched_records(fetched) == [record]
    end

    test "a null key, an empty key and an empty value survive the round trip" do
      ctx = ctx()
      records = [kafka_record(0, %{key: nil}), kafka_record(1, %{key: ""}), kafka_record(2, %{value: ""})]

      assert %{base_offset: 0} = produce!(ctx, records)
      assert fetched_records(fetch!(ctx, 0)) == records
    end

    test "base offsets follow the partition's offsets across produces" do
      ctx = ctx()

      assert %{base_offset: 0} = produce!(ctx, [kafka_record(0, %{}), kafka_record(1, %{})])
      assert %{base_offset: 2} = produce!(ctx, [kafka_record(0, %{})])
      assert [%{offset: 2}] = fetched_records(fetch!(ctx, 2))
      assert fetch!(ctx, 0).partition_header.high_watermark == 3
    end

    test "every advertised Produce and Fetch version round trips" do
      ctx = ctx()

      for vsn <- 3..8, do: assert(%{error_code: :no_error} = produce!(ctx, [kafka_record(0, %{value: "v#{vsn}"})], vsn))

      for vsn <- 4..11 do
        assert ctx |> fetch!(0, vsn) |> fetched_records() |> Enum.map(& &1.value) == Enum.map(3..8, &"v#{&1}")
      end
    end

    test "acks=0 is not answered" do
      ctx = ctx()
      assert :noreply = Connection.handle_frame(produce_frame(8, ctx.topic, batch([kafka_record(0, %{})]), 0), ctx)
      assert [%{offset: 0}] = fetched_records(fetch!(ctx, 0))
    end

    test "a fetch at the end waits up to the cap and answers no records" do
      ctx = ctx(%{max_wait_cap_ms: 150})
      produce!(ctx, [kafka_record(0, %{})])

      {elapsed_us, fetched} = :timer.tc(fn -> fetch!(ctx, 1, 11, %{max_wait_time: 60_000, min_bytes: 1}) end)

      assert fetched.partition_header.error_code == :no_error
      assert fetched_records(fetched) == []
      assert elapsed_us >= 150_000 and elapsed_us < 5_000_000
    end

    test "a fetch past the end is OFFSET_OUT_OF_RANGE" do
      ctx = ctx()
      produce!(ctx, [kafka_record(0, %{})])

      assert fetch!(ctx, 5).partition_header.error_code == :offset_out_of_range
      assert fetch!(ctx, -1).partition_header.error_code == :offset_out_of_range
    end

    test "max_bytes trims a page but always keeps one record" do
      ctx = ctx()
      big = :binary.copy("x", 1_000)
      produce!(ctx, [kafka_record(0, %{value: big}), kafka_record(1, %{value: big})])

      assert [%{offset: 0}] = fetched_records(fetch!(ctx, 0, 11, %{max_bytes: 10}))
      assert length(fetched_records(fetch!(ctx, 0, 11, %{max_bytes: 1 <<< 20}))) == 2
    end

    test "another topic or partition is UNKNOWN_TOPIC_OR_PARTITION" do
      ctx = ctx()
      frame = produce_frame(8, "not-served", batch([kafka_record(0, %{})]))
      {1, body} = KafkaClient.response(:produce, 8, reply!(frame, ctx))
      assert [%{partition_responses: [%{error_code: :unknown_topic_or_partition}]}] = body.responses

      fields = %{
        transactional_id: :undefined,
        acks: -1,
        timeout: 5_000,
        topic_data: [%{topic: ctx.topic, data: [%{partition: 1, record_set: batch([kafka_record(0, %{})])}]}]
      }

      {1, body} = KafkaClient.response(:produce, 8, reply!(KafkaClient.request(:produce, 8, fields), ctx))
      assert [%{partition_responses: [%{partition: 1, error_code: :unknown_topic_or_partition}]}] = body.responses
    end
  end

  describe "a topic split into ranges" do
    test "is no longer served: its offsets would restart in the children" do
      ctx = ctx()
      assert %{base_offset: 0} = produce!(ctx, [kafka_record(0, %{})])

      {:ok, range_id} = Topic.resolve(ctx.topic)
      assert {:ok, _left, _right} = BrokerServer.split_range(Topic.broker(ctx.topic), range_id)

      # the range resolved before the split: the produce lands in the children, and is refused
      assert %{error_code: :unknown_topic_or_partition} = produce!(ctx, [kafka_record(0, %{})])

      # resolved again: the topic has several ranges now
      Topic.forget(ctx.topic)
      assert Topic.resolve(ctx.topic) == {:error, :split_topic}
      frame = KafkaClient.request(:metadata, 9, metadata_fields(9, [ctx.topic]))
      {1, body} = KafkaClient.response(:metadata, 9, reply!(frame, ctx))
      assert [%{error_code: :unknown_topic_or_partition, partitions: []}] = body.topics
    end
  end

  describe "Produce refusals" do
    test "an empty record set is CORRUPT_MESSAGE" do
      ctx = ctx()
      {1, body} = KafkaClient.response(:produce, 8, reply!(produce_frame(8, ctx.topic, <<>>), ctx))
      assert [%{partition_responses: [%{error_code: :corrupt_message}]}] = body.responses
    end

    for {name, fields, error} <- [
          {"a null value (tombstone)", quote(do: %{value: nil}), :invalid_record},
          {"a null header value", quote(do: %{headers: [{"h", nil}]}), :invalid_record},
          {"a negative timestamp", quote(do: %{timestamp: -1}), :invalid_record}
        ] do
      test "#{name} is #{error} and stores nothing" do
        ctx = ctx()
        assert %{error_code: unquote(error), base_offset: -1} = produce!(ctx, [kafka_record(0, unquote(fields))])
        assert fetch!(ctx, 0).partition_header.high_watermark == 0
      end
    end

    test "a compressed batch is UNSUPPORTED_COMPRESSION_TYPE" do
      ctx = ctx()
      frame = KafkaClient.produce(8, ctx.topic, [%{key: "k", value: "v"}], %{compression: :gzip})
      {1, body} = KafkaClient.response(:produce, 8, reply!(frame, ctx))

      assert [%{partition_responses: [%{error_code: :unsupported_compression_type}]}] = body.responses
    end

    test "a batch whose CRC does not match is CORRUPT_MESSAGE" do
      ctx = ctx()
      <<head::binary-size(17), crc::32, rest::binary>> = batch([kafka_record(0, %{})])
      corrupt = <<head::binary, Bitwise.bxor(crc, 1)::32, rest::binary>>
      {1, body} = KafkaClient.response(:produce, 8, reply!(produce_frame(8, ctx.topic, corrupt), ctx))

      assert [%{partition_responses: [%{error_code: :corrupt_message}]}] = body.responses
    end

    test "a transactional produce is INVALID_REQUEST" do
      ctx = ctx()

      fields = %{
        transactional_id: "txn",
        acks: -1,
        timeout: 5_000,
        topic_data: [%{topic: ctx.topic, data: [%{partition: 0, record_set: batch([kafka_record(0, %{})])}]}]
      }

      {1, body} = KafkaClient.response(:produce, 8, reply!(KafkaClient.request(:produce, 8, fields), ctx))
      assert [%{partition_responses: [%{error_code: :invalid_request}]}] = body.responses
    end
  end

  describe "InitProducerId" do
    test "hands out increasing producer ids at epoch 0 when advertised" do
      ctx = ctx(%{idempotence: :advertise})
      frame = KafkaClient.request(:init_producer_id, 2, %{transactional_id: :undefined, transaction_timeout_ms: 60_000})

      ids =
        for _ <- 1..3 do
          {1, body} = KafkaClient.response(:init_producer_id, 2, reply!(frame, ctx))
          assert %{error_code: :no_error, producer_epoch: 0} = body
          body.producer_id
        end

      assert ids == [1, 2, 3]
    end

    test "an idempotent batch (producer id and sequence set) is accepted, its sequence unchecked" do
      ctx = ctx(%{idempotence: :advertise})
      # kafka_protocol marks every batch with a producer id as transactional, so the idempotent batch a
      # Java producer sends is built by hand: producer id 1, epoch 0, base sequence 0
      frame = produce_frame(8, ctx.topic, idempotent(batch([kafka_record(0, %{})]), 1, 0, 0))

      for expected <- [0, 1] do
        {1, body} = KafkaClient.response(:produce, 8, reply!(frame, ctx))
        assert [%{partition_responses: [%{error_code: :no_error, base_offset: ^expected}]}] = body.responses
      end
    end

    test "is closed as an unsupported API when idempotence is hidden" do
      frame = KafkaClient.request(:init_producer_id, 2, %{transactional_id: :undefined, transaction_timeout_ms: 60_000})

      log =
        capture_log(fn ->
          assert {:close, {:unsupported_api, %{api_key: 22, vsn: 2}}} = Connection.handle_frame(frame, ctx())
        end)

      assert log == ""
    end
  end

  describe "requests the spike does not serve" do
    test "an API it does not advertise closes the connection" do
      # ListOffsets v5, as a consumer sends it to resolve a logical offset; its body is never read
      frame = <<2::16, 5::16, 1::32, 12::16, "malachi-test", 0::32>>

      assert {:close, {:unsupported_api, %{api_key: 2, vsn: 5, client_id: "malachi-test"}}} =
               Connection.handle_frame(frame, ctx())
    end

    test "an API kafka_protocol does not know closes the connection" do
      assert {:close, {:unsupported_api, %{api_key: 999, api: nil}}} =
               Connection.handle_frame(<<999::16, 0::16, 1::32, -1::16-signed>>, ctx())
    end

    test "a version outside the advertised range closes the connection" do
      frame = KafkaClient.request(:metadata, 0, %{topics: []})
      assert {:close, {:unsupported_version, %{api: :metadata, vsn: 0}}} = Connection.handle_frame(frame, ctx())
    end

    test "a header that does not parse closes the connection" do
      assert {:close, :malformed_header} = Connection.handle_frame(<<0, 1>>, ctx())
      assert {:close, :malformed_header} = Connection.handle_frame(<<3::16, 9::16, 1::32, 50::16, "short">>, ctx())
    end

    test "a body that does not parse, or leaves bytes behind, closes the connection" do
      <<header::binary-size(23), _body::binary>> = frame = KafkaClient.request(:metadata, 1, %{topics: []})
      assert {:close, {:malformed_body, %{api: :metadata}}} = Connection.handle_frame(header <> <<0, 0>>, ctx())
      assert {:close, {:malformed_body, %{api: :metadata}}} = Connection.handle_frame(frame <> <<0>>, ctx())
    end
  end

  describe "capture/2" do
    test "writes the first frame of each client, API and version, and only that one" do
      dir = TmpDir.path("kafka_spike_capture")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      ctx = ctx(%{capture_dir: dir})

      first = KafkaClient.request(:api_versions, 3, request_fields(3), 1, "java client/1")
      Connection.capture(first, ctx)
      Connection.capture(KafkaClient.request(:api_versions, 3, request_fields(3), 2, "java client/1"), ctx)
      Connection.capture(KafkaClient.request(:api_versions, 0, %{}, 3, "java client/1"), ctx)
      Connection.capture(<<0, 1>>, ctx)

      assert File.read!(Path.join(dir, "java_client_1-18-v3.bin")) == first
      assert Enum.sort(File.ls!(dir)) == ["java_client_1-18-v0.bin", "java_client_1-18-v3.bin"]
    end

    test "names a null client id" do
      dir = TmpDir.path("kafka_spike_capture")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Connection.capture(<<18::16, 0::16, 1::32, -1::16-signed>>, ctx(%{capture_dir: dir}))
      assert File.ls!(dir) == ["null-18-v0.bin"]
    end

    test "writes nothing without a capture directory" do
      assert Connection.capture(KafkaClient.request(:api_versions, 0, %{}), ctx(%{capture_dir: nil})) == :ok
      assert Connection.capture(KafkaClient.request(:api_versions, 0, %{}), ctx()) == :ok
    end
  end

  describe "telemetry" do
    test "every answered request reports decode, broker and encode time" do
      ref = make_ref()
      parent = self()

      handler = "kafka-spike-test-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:malachi, :kafka_spike, :request],
        &__MODULE__.forward_event/4,
        {parent, ref}
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      reply!(KafkaClient.request(:api_versions, 3, request_fields(3)), ctx())

      assert_receive {^ref, %{decode: decode, broker: broker, encode: encode}, %{api: :api_versions, vsn: 3}}
      assert Enum.all?([decode, broker, encode], &(is_integer(&1) and &1 >= 0))
    end
  end

  @doc false
  def forward_event(_event, measurements, metadata, {parent, ref}), do: send(parent, {ref, measurements, metadata})

  defp request_fields(vsn) when vsn >= 3, do: %{client_software_name: "malachi-test", client_software_version: "1"}
  defp request_fields(_vsn), do: %{}

  defp metadata_fields(vsn, topics) do
    topics = if is_list(topics), do: Enum.map(topics, &%{name: &1}), else: topics

    %{
      topics: topics,
      allow_auto_topic_creation: false,
      include_cluster_authorized_operations: false,
      include_topic_authorized_operations: false
    }
    |> then(fn fields -> if vsn >= 4, do: fields, else: Map.take(fields, [:topics]) end)
  end
end
