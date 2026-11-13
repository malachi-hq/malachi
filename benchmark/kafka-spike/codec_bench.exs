# The Kafka spike's codec alone (#166): the time to decode a Produce request and to encode a Fetch
# response, which is the gateway's own share of its overhead (the rest is the broker's, as on the native
# path). Run by overhead.sh in the load generator's image (Linux): mix run --no-start codec_bench.exs
#
# Shapes match overhead.sh: a Produce of 1 and of 10 records, a Fetch response of 100 records, 256-byte
# values. Each figure is the median of 7 rounds of 20_000 (or 2_000) calls, in microseconds per call.
alias Malachi.KafkaSpike.{Codec, RecordBatch, Records}

record = fn i -> %{offset: i, timestamp: 1_700_000_000_000 + i, key: "k#{i}", value: :binary.copy("x", 256), headers: []} end

produce_frame = fn count ->
  batch = IO.iodata_to_binary(RecordBatch.encode(Enum.map(0..(count - 1), record)))

  fields = %{
    transactional_id: :undefined,
    acks: -1,
    timeout: 10_000,
    topic_data: [%{topic: "kafka-spike", data: [%{partition: 0, record_set: batch}]}]
  }

  IO.iodata_to_binary(:kpro_req_lib.encode("bench", 1, :kpro_req_lib.make(:produce, 8, fields)))
end

decode_produce = fn frame ->
  {:ok, header, body} = Codec.decode_header(frame)
  {:ok, request} = Codec.decode_body(header.api, header.vsn, body)
  [%{data: [%{record_set: set}]}] = request.topic_data
  {:ok, batches} = RecordBatch.decode(set)
  {:ok, _records} = Records.to_log(Enum.flat_map(batches, & &1.records))
end

stored = for i <- 0..99, do: %Malachi.Log.Record{offset: i, timestamp: 1_700_000_000_000 + i, key: "k#{i}", value: :binary.copy("x", 256), headers: []}

encode_fetch = fn ->
  set = stored |> Enum.map(&Records.from_log/1) |> RecordBatch.encode()

  body = %{
    throttle_time_ms: 0,
    error_code: 0,
    session_id: 0,
    responses: [
      %{
        topic: "kafka-spike",
        partition_responses: [
          %{
            partition_header: %{
              partition: 0,
              error_code: 0,
              high_watermark: 100,
              last_stable_offset: 100,
              log_start_offset: 0,
              aborted_transactions: [],
              preferred_read_replica: -1
            },
            record_set: set
          }
        ]
      }
    ]
  }

  IO.iodata_to_binary(Codec.encode_response(:fetch, 11, 1, body))
end

measure = fn name, calls, fun ->
  rounds =
    for _ <- 1..7 do
      {us, _} = :timer.tc(fn -> Enum.each(1..calls, fn _ -> fun.() end) end)
      us / calls
    end

  median = rounds |> Enum.sort() |> Enum.at(3)
  IO.puts(String.pad_trailing(name, 42) <> String.pad_leading(:erlang.float_to_binary(median, decimals: 2), 8) <> " us/call")
end

one = produce_frame.(1)
ten = produce_frame.(10)

IO.puts("otp #{System.otp_release()}, elixir #{System.version()}, #{:erlang.system_info(:system_architecture)}")
measure.("decode Produce v8, 1 record of 256B", 20_000, fn -> decode_produce.(one) end)
measure.("decode Produce v8, 10 records of 256B", 20_000, fn -> decode_produce.(ten) end)
measure.("encode Fetch v11 response, 100 records", 2_000, encode_fetch)
