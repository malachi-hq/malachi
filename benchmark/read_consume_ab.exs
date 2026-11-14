# What does the consume read cost once the read view carries the ranges' logical starts (#198)?
#
# The manual purge clamps every consume read at the higher of the first stored segment and the range's
# logical start, so building a `Malachi.Broker.ReadView` now also looks up each touched range's start, and
# every page compares two floors instead of one. Both are on the consume path of every reader, so this
# times reads through `Malachi.BrokerServer.read_consume/4` with the paired protocol of wake_view_ab.exs:
# arms interleaved by run in a shuffled order, an A-A control, and the fixed verdict rule of
# `support/paired_stats.exs`. No range is purged: the question is what the unpurged path pays.
#
# One sample builds a range of @segments[-1] sealed one-record segments by produces with a segment size of
# one record. For each retained count in @segments it times @rounds rounds, each paging the whole range
# from `:start` in pages of @page records.
#
# Modes (normally driven by read_consume_ab.sh, not by hand):
#   AB_MODE=sample AB_DIR=/scratch           mix run benchmark/read_consume_ab.exs
#   AB_MODE=analyze AB_RESULTS=dir AB_OUT=file mix run --no-start benchmark/read_consume_ab.exs

Code.require_file("support/ab_run.exs", __DIR__)

defmodule ReadConsumeAB do
  alias Malachi.Bench.ABRun
  alias Malachi.Bench.PairedStats
  alias Malachi.BrokerServer
  alias Malachi.Log.Record

  @segments [1, 100, 1000]
  @rounds 40
  @page 100

  @doc "One repetition, printed as a single marked JSON line."
  def sample(directory) do
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    one_record = Record.encoded_size(record(0))
    {:ok, server} = BrokerServer.start_link(directory, segment_max_bytes: one_record)
    {:ok, root} = BrokerServer.create_topic(server, "read_consume_ab", 1)

    {results, _retained} =
      Enum.map_reduce(@segments, 0, fn segments, retained ->
        retain(server, root, retained, segments)
        {{"s#{segments}", PairedStats.summarize(timed(server, root))}, segments}
      end)

    ABRun.emit(Map.new(results))
  end

  # Seals produces until `root` retains `segments` segments, each sealed by its own produce's roll.
  defp retain(server, root, retained, segments) do
    for n <- retained..(segments - 1)//1, do: {:ok, _} = BrokerServer.produce(server, "read_consume_ab", [record(n)])
    wait_sealed(server, root, segments, 500)
  end

  defp wait_sealed(server, root, segments, attempts) do
    sealed =
      server
      |> BrokerServer.metadata()
      |> Malachi.Metadata.segments_of_range(root)
      |> Enum.count(&(&1.state == :sealed))

    cond do
      sealed >= segments -> :ok
      attempts > 0 -> Process.sleep(10) && wait_sealed(server, root, segments, attempts - 1)
      true -> raise "#{segments} segments never sealed (#{sealed})"
    end
  end

  # The microseconds of each round, one round reading the whole range from the start.
  defp timed(server, root) do
    for _ <- 1..@rounds do
      started = System.monotonic_time(:microsecond)
      drain(server, root, :start)
      System.monotonic_time(:microsecond) - started
    end
  end

  defp drain(server, root, cursor) do
    case BrokerServer.read_consume(server, root, cursor, @page) do
      {:ok, [], _next, _skips} -> :ok
      {:ok, _records, next, _skips} -> drain(server, root, next)
    end
  end

  defp record(n), do: Record.new("v#{n}", key: "k")

  @doc "Reads the samples under `results` and judges them (see `Malachi.Bench.ABRun.analyze/5`)."
  def analyze(results, out) do
    names = for segments <- @segments, do: "s#{segments}"
    cases = for name <- names, do: {name, "read", &parse(&1, name)}
    ABRun.analyze(results, out, names, cases, %{rounds: @rounds, page: @page, segments: @segments})
  end

  defp parse(output, name) do
    %{"p50" => p50, "p99" => p99} = output |> ABRun.marked() |> Map.fetch!(name)
    %{p50: p50, p99: p99}
  end
end

case System.get_env("AB_MODE") do
  "sample" -> ReadConsumeAB.sample(System.fetch_env!("AB_DIR"))
  "analyze" -> ReadConsumeAB.analyze(System.fetch_env!("AB_RESULTS"), System.get_env("AB_OUT"))
  other -> raise ArgumentError, "AB_MODE must be sample or analyze, got: #{inspect(other)}"
end
