defmodule Malachi.KafkaSpikeTest do
  # One spike listener at a time: it is registered under the module name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Malachi.Test.KafkaClient

  alias Malachi.KafkaSpike
  alias Malachi.KafkaSpike.RecordBatch
  alias Malachi.Test.KafkaClient

  defp start_spike(config \\ []) do
    topic = "kafka-spike-it-#{System.unique_integer([:positive])}"
    config = Keyword.merge([port: 0, topic: topic, max_wait_cap_ms: 200], config)
    start_supervised!({KafkaSpike, config})
    %{topic: Keyword.fetch!(config, :topic), port: KafkaSpike.port()}
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: 0], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}

  describe "children/1" do
    test "is empty without a port, which is the default" do
      assert KafkaSpike.children([]) == []
      assert KafkaSpike.children(port: nil) == []
      assert KafkaSpike.children() == []
    end

    test "starts the listener when a port is set" do
      assert KafkaSpike.children(port: 9092) == [{KafkaSpike, [port: 9092]}]
    end
  end

  describe "start_link/1" do
    test "binds loopback by default, on the port the system picked" do
      %{port: port} = start_spike()

      assert is_integer(port) and port > 0
      assert {:ok, _socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    end

    test "refuses an idempotence mode it does not know" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               KafkaSpike.start_link(port: 0, idempotence: :sometimes)

      assert message =~ ":sometimes"
    end

    test "advertises the bound port unless told another, and the configured host and node" do
      start_spike(node_id: 3, advertised_host: "kafka.example")
      assert %{node_id: 3, host: "kafka.example", port: port} = KafkaSpike.ctx()
      assert port == KafkaSpike.port()
    end

    test "advertises the configured port" do
      start_spike(advertised_port: 29_092)
      assert KafkaSpike.ctx().port == 29_092
    end

    test "max_frame_size/0 is the Malachi listener's" do
      assert KafkaSpike.max_frame_size() == Application.get_env(:malachi, :max_frame_size)
    end
  end

  describe "a connection" do
    test "answers pipelined requests in the order they came" do
      %{port: port} = start_spike()
      socket = connect(port)

      frames =
        for correlation_id <- 1..5 do
          frame =
            KafkaClient.request(
              :api_versions,
              3,
              %{client_software_name: "t", client_software_version: "1"},
              correlation_id
            )

          [<<byte_size(frame)::32-signed>>, frame]
        end

      :ok = :gen_tcp.send(socket, frames)

      assert Enum.map(1..5, fn _ ->
               socket |> KafkaClient.read_response() |> then(&KafkaClient.response(:api_versions, 3, &1)) |> elem(0)
             end) ==
               [1, 2, 3, 4, 5]
    end

    test "produces and fetches back over the socket" do
      %{port: port, topic: topic} = start_spike()
      socket = connect(port)
      record = %{offset: 0, timestamp: 42, key: nil, value: "over the wire", headers: [{"h", "v"}]}

      produce = %{
        transactional_id: :undefined,
        acks: -1,
        timeout: 5_000,
        topic_data: [
          %{topic: topic, data: [%{partition: 0, record_set: IO.iodata_to_binary(RecordBatch.encode([record]))}]}
        ]
      }

      {1, %{responses: [%{partition_responses: [%{base_offset: 0, error_code: :no_error}]}]}} =
        KafkaClient.response(:produce, 8, KafkaClient.round_trip(socket, KafkaClient.request(:produce, 8, produce)))

      {1, %{responses: [%{partition_responses: [%{record_set: record_set}]}]}} =
        KafkaClient.response(
          :fetch,
          11,
          KafkaClient.round_trip(socket, KafkaClient.fetch(11, topic, 0, %{max_wait_time: 0}))
        )

      assert {:ok, [%{records: [^record]}]} = RecordBatch.decode(record_set)
    end

    test "is closed for an API the spike does not serve, which is logged with what the client asked" do
      %{port: port} = start_spike()
      socket = connect(port)

      log =
        capture_log(fn ->
          frame = <<10::16, 4::16, 77::32, 3::16, "cli", 0>>
          :ok = :gen_tcp.send(socket, [<<byte_size(frame)::32>>, frame])
          assert closed?(socket)
        end)

      assert log =~ "api_key=10"
      assert log =~ "version=4"
      assert log =~ ~s("cli")
    end

    for {name, size} <- [{"empty", 0}, {"negative", -1}, {"larger than max_frame_size", 16_777_217}] do
      test "is closed for a #{name} frame size" do
        %{port: port} = start_spike()
        socket = connect(port)

        log =
          capture_log(fn ->
            :ok = :gen_tcp.send(socket, <<unquote(size)::32-signed>>)
            assert closed?(socket)
          end)

        assert log =~ "frame_size"
      end
    end

    test "a produce with acks=0 is not answered, and the next request is" do
      %{port: port, topic: topic} = start_spike()
      socket = connect(port)
      record = %{offset: 0, timestamp: 1, key: "k", value: "v", headers: []}

      produce = %{
        transactional_id: :undefined,
        acks: 0,
        timeout: 5_000,
        topic_data: [
          %{topic: topic, data: [%{partition: 0, record_set: IO.iodata_to_binary(RecordBatch.encode([record]))}]}
        ]
      }

      frame = KafkaClient.request(:produce, 8, produce, 1)
      :ok = :gen_tcp.send(socket, [<<byte_size(frame)::32-signed>>, frame])
      next = KafkaClient.request(:api_versions, 0, %{}, 2)

      assert {2, %{error_code: :no_error}} =
               KafkaClient.response(:api_versions, 0, KafkaClient.round_trip(socket, next))
    end

    test "a client gone in the middle of a frame leaves the listener serving others" do
      %{port: port} = start_spike()
      gone = connect(port)
      :ok = :gen_tcp.send(gone, <<100::32, 1, 2, 3>>)
      :gen_tcp.close(gone)

      socket = connect(port)
      frame = KafkaClient.request(:api_versions, 0, %{})

      assert {1, %{error_code: :no_error}} =
               KafkaClient.response(:api_versions, 0, KafkaClient.round_trip(socket, frame))
    end
  end

  describe "kafka_protocol's own client" do
    test "negotiates versions, produces and fetches through the spike" do
      %{port: port, topic: topic} = start_spike()
      {:ok, conn} = :kpro.connect({~c"127.0.0.1", port}, %{})
      on_exit(fn -> :kpro.close_connection(conn) end)

      {:ok, {_min, produce_vsn}} = :kpro.get_api_vsn_range(conn, :produce)
      {:ok, {_min, fetch_vsn}} = :kpro.get_api_vsn_range(conn, :fetch)
      assert {produce_vsn, fetch_vsn} == {8, 11}

      messages = [%{key: "a", value: "1", headers: [{"x", "y"}]}, %{key: "b", value: "2"}]
      produce = :kpro_req_lib.produce(produce_vsn, topic, 0, messages)
      {:ok, produced} = :kpro.request_sync(conn, produce, 5_000)

      assert [%{partition_responses: [%{error_code: :no_error, base_offset: 0}]}] =
               KafkaClient.kpro_rsp(produced, :msg).responses

      fetch = :kpro_req_lib.fetch(fetch_vsn, topic, 0, 0, %{max_wait_time: 0})
      {:ok, fetched} = :kpro.request_sync(conn, fetch, 5_000)
      [%{partition_responses: [%{record_set: record_set}]}] = KafkaClient.kpro_rsp(fetched, :msg).responses
      [{_meta, decoded}] = :kpro.decode_batches(record_set)

      assert Enum.map(decoded, &{elem(&1, 1), elem(&1, 2), elem(&1, 3), elem(&1, 6)}) ==
               [{0, "a", "1", [{"x", "y"}]}, {1, "b", "2", []}]
    end
  end
end
