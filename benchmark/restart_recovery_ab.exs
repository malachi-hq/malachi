# What does a broker restart cost while it learns where its active ranges end? (issue #283)
#
# A restarted broker asks each active range's primary for its durable end before it serves anyone. On the
# baseline that probe reopens every active segment for appending, which writes its preallocation again
# (`MALACHI_SEGMENT_PREALLOC_BYTES`, 64MB by default), one range after another on the broker's own loop. The
# branch learns the end without the zero write and asks the primaries off the loop, 32 at a time, in a
# pass the boot waits for at most two probe bounds.
#
# Two versions of one module cannot be loaded into one BEAM, so the arms interleave by RUN:
# `restart_recovery_ab.sh` builds the baseline tree and the branch tree, then launches one sample per arm
# per repetition in an order shuffled per repetition. Two of the three arms are the baseline run twice
# under different labels, the A-A control, and the verdict rule is the one in `support/paired_stats.exs`,
# fixed before any number exists.
#
# Cases (one sample = one fresh data directory):
#   * restart        - N topics of one record each, then `@restarts` clean restarts of the replication
#                      server and the broker. One latency per restart: from `BrokerServer.start_link/2` to
#                      the answer of its first call (`metadata/1`, queued behind the boot reconcile).
#   * first_produce  - after one restart, one produce to each of the N topics: the cost the branch moves
#                      from the probe to the first write of each segment.
#   * burst          - the shape #275's drills caught: one producer appends to a segment without pause
#                      while N new segments open on the same replication server. One latency per append
#                      of that producer while the burst runs. On the branch each new segment makes its
#                      room in bounded steps on its flushes; the baseline writes each segment's whole
#                      preallocation on that server's loop when it opens.
#
# Knobs: AB_RANGES (N, default 10), AB_PREALLOC (bytes, default 67108864), AB_CASE (restart, first_produce
# or burst), AB_DIR (the scratch directory: a named volume or the
# container's overlay).
#
# Modes (normally driven by restart_recovery_ab.sh, not by hand):
#   AB_MODE=sample  AB_CASE=restart AB_DIR=/scratch  elixir --name ab@127.0.0.1 -S mix run benchmark/restart_recovery_ab.exs
#   AB_MODE=analyze AB_RESULTS=dir AB_OUT=file AB_EXPECTED="restart-n10-p0-volume ..." \
#     mix run --no-start benchmark/restart_recovery_ab.exs

Code.require_file("support/ab_run.exs", __DIR__)

defmodule RestartRecoveryAB do
  alias Malachi.Bench.ABRun
  alias Malachi.Bench.PairedStats
  alias Malachi.BrokerServer
  alias Malachi.Cluster.MetadataServer
  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Log.Record

  @restarts 5

  @doc "One repetition of `kase`, printed as a single marked JSON line."
  def sample("burst", directory, ranges, prealloc) do
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    preflight_disk!(directory, ranges, prealloc)
    log_dir = Path.join(directory, "log")
    name = :"burst_ab_repl_#{System.unique_integer([:positive])}"
    ref = {name, node()}

    {:ok, _repl} = ReplicationServer.start_link(directory: log_dir, name: name, prealloc_bytes: prealloc)

    record = [Record.new("v", key: "k")]
    {:ok, _} = ReplicationServer.replicate(ref, "steady", [ref], 0, record)

    burst =
      Task.async(fn ->
        for i <- 1..ranges, do: {:ok, _} = ReplicationServer.replicate(ref, "burst_#{i}", [ref], 0, record)
      end)

    latencies = steady_appends(ref, burst, record, [])
    :ok = GenServer.stop(name)
    File.rm_rf!(directory)
    ABRun.emit(Map.merge(PairedStats.summarize(latencies), %{ranges: ranges, prealloc: prealloc, n: length(latencies)}))
  end

  def sample(kase, directory, ranges, prealloc) do
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    preflight_disk!(directory, ranges, prealloc)

    cluster = :"restart_ab_#{System.unique_integer([:positive])}"
    replication = :"restart_ab_repl_#{System.unique_integer([:positive])}"
    log_dir = Path.join(directory, "log")

    repl_opts = [directory: log_dir, name: replication, prealloc_bytes: prealloc]
    broker_opts = [brokers: [{replication, node()}], replication_factor: 1, metadata_cluster: cluster]

    {:ok, _repl} = ReplicationServer.start_link(repl_opts)
    {:ok, broker} = BrokerServer.start_link("unused", broker_opts)

    topics = for i <- 1..ranges, do: "restart_ab_#{i}"

    for topic <- topics do
      {:ok, _root} = BrokerServer.create_topic(broker, topic, 4)
      {:ok, _placements} = BrokerServer.produce(broker, topic, [Record.new("v", key: "k")])
    end

    # A clean stop closes every segment, which trims its preallocated tail: what a restart reopens.
    stop_both(broker, replication)

    latencies =
      case kase do
        "restart" -> Enum.map(1..@restarts, fn _ -> timed_restart(repl_opts, broker_opts, replication) end)
        "first_produce" -> first_produces(repl_opts, broker_opts, replication, topics)
      end

    MetadataServer.delete(cluster)
    File.rm_rf!(directory)
    ABRun.emit(Map.merge(PairedStats.summarize(latencies), %{ranges: ranges, prealloc: prealloc, n: length(latencies)}))
  end

  defp timed_restart(repl_opts, broker_opts, replication) do
    {:ok, _repl} = ReplicationServer.start_link(repl_opts)
    started = System.monotonic_time(:microsecond)
    {:ok, broker} = BrokerServer.start_link("unused", broker_opts)
    _ = BrokerServer.metadata(broker)
    elapsed = System.monotonic_time(:microsecond) - started
    stop_both(broker, replication)
    elapsed
  end

  defp first_produces(repl_opts, broker_opts, replication, topics) do
    {:ok, _repl} = ReplicationServer.start_link(repl_opts)
    {:ok, broker} = BrokerServer.start_link("unused", broker_opts)
    _ = BrokerServer.metadata(broker)

    latencies =
      for topic <- topics do
        started = System.monotonic_time(:microsecond)
        {:ok, _placements} = BrokerServer.produce(broker, topic, [Record.new("w", key: "k")])
        System.monotonic_time(:microsecond) - started
      end

    stop_both(broker, replication)
    latencies
  end

  # Appends to the steady segment one batch at a time, as long as the burst runs, timing each.
  defp steady_appends(ref, burst, record, acc) do
    started = System.monotonic_time(:microsecond)
    {:ok, _} = ReplicationServer.replicate(ref, "steady", [ref], 0, record)
    acc = [System.monotonic_time(:microsecond) - started | acc]

    case Task.yield(burst, 0) do
      nil -> steady_appends(ref, burst, record, acc)
      {:ok, _done} -> Enum.reverse(acc)
    end
  end

  defp stop_both(broker, replication) do
    :ok = BrokerServer.stop(broker)
    :ok = GenServer.stop(replication)
  end

  # Every active segment is preallocated at once while the setup writes, and the baseline writes them all
  # again on each restart: a run that cannot hold twice that much stops here, before it fills the volume.
  defp preflight_disk!(directory, ranges, prealloc) do
    needed = 2 * ranges * prealloc
    {output, 0} = System.cmd("df", ["-Pk", directory])
    [_header, line | _] = String.split(output, "\n", trim: true)
    available = line |> String.split() |> Enum.at(3) |> String.to_integer() |> Kernel.*(1024)

    if available < needed,
      do: raise("#{directory} has #{available} bytes free, the run needs #{needed} (2 x #{ranges} x #{prealloc})")
  end

  @doc "Reads the samples under `results` and judges them (see `Malachi.Bench.ABRun.analyze/5`)."
  def analyze(results, out, expected) do
    # One case per grid cell, named by the driver after what it varies (`restart-n100-p67108864-volume`), so
    # every cell is judged on its own: a cost that only exists at 64MB must not be averaged away by the 0MB cells.
    cells = results |> File.ls!() |> Enum.filter(&File.dir?(Path.join(results, &1))) |> Enum.sort()
    ABRun.analyze(results, out, expected, Enum.map(cells, &{&1, &1, fn output -> parse(output) end}))
  end

  defp parse(output) do
    decoded = ABRun.marked(output)
    %{p50: decoded["p50"], p99: decoded["p99"]}
  end
end

case System.get_env("AB_MODE") do
  "sample" ->
    RestartRecoveryAB.sample(
      System.get_env("AB_CASE", "restart"),
      System.get_env("AB_DIR") || Path.join(System.tmp_dir!(), "restart_recovery_ab"),
      String.to_integer(System.get_env("AB_RANGES", "10")),
      String.to_integer(System.get_env("AB_PREALLOC", "67108864"))
    )

  "analyze" ->
    # The cells the run was asked for, space separated; restart_recovery_ab.sh passes every cell it ran.
    expected = System.get_env("AB_EXPECTED", "") |> String.split()
    RestartRecoveryAB.analyze(System.fetch_env!("AB_RESULTS"), System.get_env("AB_OUT"), expected)

  other ->
    raise ArgumentError, "AB_MODE must be sample or analyze, got: #{inspect(other)}"
end
