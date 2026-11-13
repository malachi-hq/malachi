defmodule Malachi.Loadtest.KafkaWireTest do
  # One spike listener at a time: it is registered under its module name.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureIO

  alias Malachi.KafkaSpike
  alias Malachi.Loadtest
  alias Malachi.Loadtest.KafkaConn
  alias Malachi.Log.Record

  setup do
    topic = "kafka-loadtest-#{System.unique_integer([:positive])}"
    start_supervised!({KafkaSpike, port: 0, topic: topic, max_wait_cap_ms: 100})
    %{topic: topic, port: KafkaSpike.port()}
  end

  defp run(ctx, opts) do
    base = [wire: :kafka, kafka_port: ctx.port, host: "127.0.0.1", topic: ctx.topic, warmup: 0, duration: 1]
    capture_io(fn -> Process.put(:report, Loadtest.run(Keyword.merge(base, opts))) end)
    Process.get(:report)
  end

  defp record(value), do: %Record{key: "k", value: value, timestamp: 0, headers: []}

  describe "options" do
    test "the kafka wire only drives produce and fetch" do
      for scenario <- [:stream, :mixed, :user, :acl] do
        assert_raise ArgumentError, ~r/only drives the :produce and :fetch scenarios/, fn ->
          Loadtest.reproduce_command(wire: :kafka, scenario: scenario)
        end
      end
    end

    test "kafka_port is only accepted with the kafka wire" do
      assert_raise ArgumentError, ~r/kafka_port only applies to the :kafka wire/, fn ->
        Loadtest.reproduce_command(kafka_port: 9092)
      end
    end

    test "an unknown wire is refused" do
      assert_raise ArgumentError, ~r/unknown wire :amqp/, fn -> Loadtest.reproduce_command(wire: :amqp) end
    end

    test "the recorded command carries the wire and its port, and leaves the default out" do
      command = Loadtest.reproduce_command(wire: :kafka, kafka_port: 19_092)
      assert command =~ "--wire=kafka"
      assert command =~ "--kafka-port=19092"
      refute Loadtest.reproduce_command([]) =~ "--wire"
      refute command =~ "--protocol"
    end

    test "the mix task takes --wire and --kafka-port" do
      assert_raise Mix.Error, ~r/unknown --wire "amqp" \(expected one of: malachi, kafka\)/, fn ->
        Mix.Tasks.Malachi.Loadtest.run(["--wire", "amqp"])
      end
    end
  end

  describe "a run" do
    test "produces through the spike, pipelined, and counts every acknowledged batch", ctx do
      report = run(ctx, scenario: :produce, connections: 2, batch: 5, pipeline: 4)

      assert report.ops > 0
      assert report.records == report.ops * 5
      assert report.errors == 0
      assert report.dropped == 0
    end

    test "fetches a backlog it produced through the spike first", ctx do
      report = run(ctx, scenario: :fetch, connections: 2, prepopulate: 50, batch: 10, max: 20, pipeline: 2)

      assert report.ops > 0
      assert report.records > 0
      assert report.errors == 0
    end

    test "counts a refused produce under the Kafka error it got", ctx do
      report = run(ctx, scenario: :produce, connections: 1, topic: "not-the-spike-topic")

      assert report.ops == 0
      assert report.errors > 0
      assert Map.keys(report.error_reasons) == ["unknown_topic_or_partition"]
    end

    test "a listener that is not there fails the setup", ctx do
      {:ok, holder} = :gen_tcp.listen(0, [])
      {:ok, free} = :inet.port(holder)
      :gen_tcp.close(holder)

      assert_raise Loadtest.SetupError, fn ->
        run(%{ctx | port: free}, scenario: :fetch, connections: 1, prepopulate: 5)
      end
    end
  end

  describe "KafkaConn" do
    test "answers in the order sent, with the records acknowledged", ctx do
      {:ok, conn} = KafkaConn.connect("127.0.0.1", ctx.port, ctx.topic)
      {:ok, conn} = KafkaConn.send_produce(conn, [record("a"), record("b")])
      {:ok, conn} = KafkaConn.send_produce(conn, [record("c")])
      assert KafkaConn.in_flight(conn) == 2

      assert {{:ok, 2, latency}, conn} = KafkaConn.await(conn)
      assert latency >= 0
      assert {{:ok, 1, _latency}, conn} = KafkaConn.await(conn)
      assert KafkaConn.in_flight(conn) == 0
      KafkaConn.close(conn)
    end

    test "a fetch advances through the partition and starts over at its end", ctx do
      {:ok, conn} = KafkaConn.connect("127.0.0.1", ctx.port, ctx.topic)
      {:ok, conn} = KafkaConn.send_produce(conn, Enum.map(1..3, &record("#{&1}")))
      {{:ok, 3, _}, conn} = KafkaConn.await(conn)

      {:ok, conn} = KafkaConn.send_fetch(conn, 1)
      assert {{:ok, 1, _}, conn} = KafkaConn.await(conn)
      assert conn.fetch_offset == 1

      {:ok, conn} = KafkaConn.send_fetch(conn, 1 <<< 20)
      assert {{:ok, 2, _}, conn} = KafkaConn.await(conn)
      assert conn.fetch_offset == 3

      {:ok, conn} = KafkaConn.send_fetch(conn, 1 <<< 20)
      assert {{:ok, 0, _}, conn} = KafkaConn.await(conn)
      assert conn.fetch_offset == 0
    end

    test "a fetch past the end is the Kafka error, and starts over", ctx do
      {:ok, conn} = KafkaConn.connect("127.0.0.1", ctx.port, ctx.topic)
      conn = %{conn | fetch_offset: 99}
      {:ok, conn} = KafkaConn.send_fetch(conn, 100)

      assert {{:error, :offset_out_of_range, _}, conn} = KafkaConn.await(conn)
      assert conn.fetch_offset == 0
    end

    test "a connection closed by the listener is an error", ctx do
      {:ok, conn} = KafkaConn.connect("127.0.0.1", ctx.port, ctx.topic)
      {:ok, conn} = KafkaConn.send_produce(conn, [record("a")])
      :gen_tcp.shutdown(conn.socket, :read)
      assert {:error, _reason} = KafkaConn.await(conn)
    end

    test "a connection refused is an error" do
      {:ok, holder} = :gen_tcp.listen(0, [])
      {:ok, free} = :inet.port(holder)
      :gen_tcp.close(holder)
      assert {:error, :econnrefused} = KafkaConn.connect("127.0.0.1", free, "t")
    end
  end
end
