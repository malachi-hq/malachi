# What does one heal pass's sealed-copy integrity probe cost, before and after it was batched? (issue #241)
#
# `Malachi.Cluster.SelfHealing` probes every healthy sealed segment on every replica on every heal pass. Before
# #241 that was one `ReplicationServer.stored_bytes/3` call per segment per replica; after it, one
# `ReplicationServer.stored_bytes_of/4` call per replica per chunk of segments. This measures, at a fixed number
# of sealed segments over three replicas in one VM:
#
#   * the calls one pass makes, counted by tracing what the replication servers receive;
#   * the wall clock of one pass (the A/B verdict, p50 and p99 over the passes of a sample);
#   * in the sweep, how long one batched call holds a replication server for each chunk size, which is the
#     time the data plane serves nothing else and what the default `:probe_chunk` is chosen from.
#
# Every replica runs in the same VM, so a call crosses no network: the per-call saving between real nodes is a
# round trip larger than what this measures. Linux only (Malachi runs nowhere else), on a real filesystem.
#
# Modes (AB_MODE):
#   fixture  writes AB_N sealed segments on three replicas under AB_DIR/fixture-AB_N, once, with their metadata
#   sample   one A/B sample over that fixture: emits the pass wall clock and the calls per pass
#   sweep    branch tree only: the per-call hold time for each chunk in AB_CHUNKS (default 128 256 512 1024 all)
#   cold     branch tree only: AB_N batch copies of AB_SEGMENT_MB MiB with no manifest, measured with and without
#            the server's per-call budget (AB_CHUNKS default 1 2 4 8 16 32)
#   analyze  judges the samples under AB_RESULTS (see support/ab_run.exs)

Code.require_file("support/ab_run.exs", __DIR__)

defmodule IntegrityProbeAB do
  alias Malachi.Bench.ABRun
  alias Malachi.Bench.PairedStats
  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Cluster.SelfHealing
  alias Malachi.Log.Record
  alias Malachi.Metadata

  # Registered names, so the metadata written by the fixture names the same replicas in every sample.
  @replicas [:integrity_ab_r1, :integrity_ab_r2, :integrity_ab_r3]
  @passes 7

  def fixture(base, count) do
    directory = fixture_dir(base, count)

    if File.exists?(Path.join(directory, "metadata.bin")) do
      IO.puts("fixture #{directory} already written")
    else
      File.rm_rf!(directory)
      start_replicas(directory)
      records = [Record.new("x", key: "x"), Record.new("y", key: "y")]

      metadata =
        Enum.reduce(1..count, Metadata.new(), fn i, metadata ->
          {metadata, {:ok, root}} = Metadata.apply(metadata, {:create_topic, "probe-#{i}", 1})
          segment_id = {root, 0}
          {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, @replicas, 0})
          for replica <- @replicas, do: {:ok, 1} = ReplicationServer.follow(replica, segment_id, 0, records)
          bytes = ReplicationServer.stored_bytes(hd(@replicas), segment_id)
          {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, bytes, 0})
          metadata
        end)

      File.write!(Path.join(directory, "metadata.bin"), :erlang.term_to_binary(metadata))
      IO.puts("fixture #{directory}: #{count} sealed segments on #{length(@replicas)} replicas")
    end
  end

  # Fresh servers over the fixture on every sample: a sealed segment nobody has opened since the replica
  # started is the common case for the probe, and the one that measures from disk.
  def sample(base, count) do
    {metadata, live} = open_fixture(base, count)

    _warm = SelfHealing.heal_sealed(metadata, live, 3)
    {calls, result} = traced_pass(metadata, live)
    unless result.repaired == [] and result.failed == [], do: raise("the fixture is not healthy: #{inspect(result)}")

    walls =
      for _pass <- 1..@passes do
        started = System.monotonic_time(:microsecond)
        _result = SelfHealing.heal_sealed(metadata, live, 3)
        System.monotonic_time(:microsecond) - started
      end

    ABRun.emit(Map.merge(PairedStats.summarize(walls), %{segments: count, calls_per_pass: calls}))
  end

  def sweep(base, count, chunks) do
    {metadata, live} = open_fixture(base, count)
    _warm = SelfHealing.heal_sealed(metadata, live, 3)

    IO.puts("segments=#{count} replicas=#{length(live)} passes=#{@passes}")
    IO.puts("chunk\tcalls/pass\tpass_p50_ms\tcall_p50_ms\tcall_p99_ms\tcall_max_ms")

    for chunk <- chunks do
      size = if chunk == :all, do: count, else: chunk
      test = self()

      timed = fn replica, segment_ids ->
        started = System.monotonic_time(:microsecond)
        answer = ReplicationServer.stored_bytes_of(replica, segment_ids, 60_000)
        send(test, {:call_us, System.monotonic_time(:microsecond) - started})
        answer
      end

      walls =
        for _pass <- 1..@passes do
          started = System.monotonic_time(:microsecond)
          _result = SelfHealing.heal_sealed(metadata, live, 3, probe_chunk: size, stored_bytes_of: timed)
          System.monotonic_time(:microsecond) - started
        end

      calls = drain_call_times([]) |> Enum.sort()
      ms = fn us -> Float.round(us / 1000, 2) end

      IO.puts(
        Enum.join(
          [
            chunk,
            div(length(calls), @passes),
            ms.(PairedStats.summarize(walls).p50),
            ms.(pctl(calls, 50)),
            ms.(pctl(calls, 99)),
            ms.(List.last(calls))
          ],
          "\t"
        )
      )
    end
  end

  # The COLD case: batch-format copies with no manifest, which is what a follower holds right after a backfill
  # (its own store never seals it, so nothing has cached its logical size yet). Each one is then measured by a
  # scan of the whole file, once, inside the replication server. This measures `chunk` such copies with no budget
  # (one call holds the server for all of them) and with the server's default budget (the rest is handed back and
  # asked again), and how long a one-segment call queued behind them waits, which is what a replicate or follow
  # queued at that server would wait. Every manifest is removed first, so every copy is cold. The files were just
  # written, so they are in the page cache: this is the scan's CPU cost, a lower bound on a disk.
  def cold(base, count, segment_mb, chunks) do
    directory = Path.join(base, "cold-#{count}x#{segment_mb}")
    replica = hd(@replicas)
    segment_ids = for i <- 1..count, do: {{"cold-#{i}", 0}, 0}

    unless File.exists?(Path.join(directory, "written")) do
      File.rm_rf!(directory)
      {:ok, _apps} = Application.ensure_all_started(:telemetry)
      {:ok, pid} = ReplicationServer.start_link(name: replica, directory: Path.join(directory, "#{replica}"))
      value = :crypto.strong_rand_bytes(64 * 1024)
      per_batch = 16
      batches = div(segment_mb * 16, per_batch)

      for segment_id <- segment_ids, batch <- 0..(batches - 1) do
        records = for i <- 1..per_batch, do: Record.new(value, key: "k#{i}")
        {:ok, _last} = ReplicationServer.follow(replica, segment_id, batch * per_batch, records, :batch)
      end

      GenServer.stop(pid)
      File.write!(Path.join(directory, "written"), "")
    end

    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    {:ok, _pid} = ReplicationServer.start_link(name: replica, directory: Path.join(directory, "#{replica}"))

    IO.puts("cold: #{count} batch copies of #{segment_mb} MiB, no manifest, page cache warm")
    IO.puts("budget\tchunk\tcalls\tmax_call_ms\tper_copy_ms\tqueued_call_ms")

    # Without a budget (the call measures its whole chunk) and with the server's default one (the caller asks
    # again for what is handed back, as `Malachi.Cluster.SelfHealing` does).
    for {label, budget_ms} <- [{"none", 3_600_000}, {"default", 100}], chunk <- chunks do
      ids = Enum.take(segment_ids, chunk)
      drop_manifests(directory)

      # One segment outside the chunk, its size cached, asked while the chunk is being measured: what a replicate
      # or follow queued at the server waits.
      queued_id = List.last(segment_ids)
      {:ok, _cached, []} = ReplicationServer.stored_bytes_of(replica, [queued_id], :infinity, budget_ms)
      task = Task.async(fn -> ask_all(replica, ids, budget_ms, []) end)
      Process.sleep(5)
      queued_started = System.monotonic_time(:microsecond)
      _ = ReplicationServer.stored_bytes(replica, queued_id, :infinity)
      queued = System.monotonic_time(:microsecond) - queued_started
      calls = Task.await(task, :infinity)

      ms = fn us -> Float.round(us / 1000, 1) end
      total = Enum.sum(calls)
      IO.puts(Enum.join([label, chunk, length(calls), ms.(Enum.max(calls)), ms.(total / chunk), ms.(queued)], "\t"))
    end
  end

  # Asks for `ids` until every one is measured, and answers how long each call took.
  defp ask_all(_replica, [], _budget_ms, durations), do: Enum.reverse(durations)

  defp ask_all(replica, ids, budget_ms, durations) do
    started = System.monotonic_time(:microsecond)
    {:ok, measured, unmeasured} = ReplicationServer.stored_bytes_of(replica, ids, :infinity, budget_ms)
    elapsed = System.monotonic_time(:microsecond) - started

    if Enum.any?(measured, fn {_id, bytes} -> not is_integer(bytes) or bytes == 0 end) do
      raise "bad answer: #{inspect(measured)}"
    end

    ask_all(replica, unmeasured, budget_ms, [elapsed | durations])
  end

  defp drop_manifests(directory) do
    for path <- Path.wildcard(Path.join(directory, "**/*.manifest")), do: File.rm!(path)
  end

  def analyze(results, out, expected) do
    cases = for dir <- expected, do: {dir, dir, &parse/1}
    ABRun.analyze(results, out, expected, cases)
  end

  defp parse(output) do
    decoded = ABRun.marked(output)
    %{p50: decoded["p50"], p99: decoded["p99"]}
  end

  defp fixture_dir(base, count), do: Path.join(base, "fixture-#{count}")

  defp open_fixture(base, count) do
    directory = fixture_dir(base, count)
    metadata = directory |> Path.join("metadata.bin") |> File.read!() |> :erlang.binary_to_term()
    start_replicas(directory)
    {metadata, @replicas}
  end

  defp start_replicas(directory) do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    for replica <- @replicas do
      {:ok, _pid} = ReplicationServer.start_link(name: replica, directory: Path.join(directory, "#{replica}"))
    end
  end

  # One pass with every call the replicas receive traced: `{tag => count}`.
  defp traced_pass(metadata, live) do
    pids = Enum.map(live, &Process.whereis/1)
    for pid <- pids, do: 1 = :erlang.trace(pid, true, [:receive])
    result = SelfHealing.heal_sealed(metadata, live, 3)

    for pid <- pids do
      :erlang.trace(pid, false, [:receive])
      ref = :erlang.trace_delivered(pid)
      receive do: ({:trace_delivered, ^pid, ^ref} -> :ok)
    end

    {drain_calls(%{}), result}
  end

  defp drain_calls(acc) do
    receive do
      {:trace, _pid, :receive, {:"$gen_call", _from, message}} ->
        tag = if is_tuple(message), do: elem(message, 0), else: message
        drain_calls(Map.update(acc, tag, 1, &(&1 + 1)))

      {:trace, _pid, :receive, _other} ->
        drain_calls(acc)
    after
      0 -> acc
    end
  end

  defp drain_call_times(acc) do
    receive do
      {:call_us, us} -> drain_call_times([us | acc])
    after
      0 -> acc
    end
  end

  defp pctl([], _p), do: 0
  defp pctl(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, div(p * length(sorted), 100)))
end

base = System.get_env("AB_DIR") || Path.join(System.tmp_dir!(), "integrity_probe_ab")
count = String.to_integer(System.get_env("AB_N", "1000"))

case System.get_env("AB_MODE") do
  "fixture" ->
    IntegrityProbeAB.fixture(base, count)

  "sample" ->
    IntegrityProbeAB.sample(base, count)

  "sweep" ->
    chunks =
      System.get_env("AB_CHUNKS", "128 256 512 1024 all")
      |> String.split()
      |> Enum.map(fn
        "all" -> :all
        n -> String.to_integer(n)
      end)

    IntegrityProbeAB.sweep(base, count, chunks)

  "cold" ->
    chunks = System.get_env("AB_CHUNKS", "1 2 4 8 16 32") |> String.split() |> Enum.map(&String.to_integer/1)
    segment_mb = String.to_integer(System.get_env("AB_SEGMENT_MB", "64"))
    # One copy more than the largest chunk: the queued call asks about it, and it must be outside every chunk.
    IntegrityProbeAB.cold(base, max(count, Enum.max(chunks) + 1), segment_mb, chunks)

  "analyze" ->
    expected = System.get_env("AB_EXPECTED", "n1000 n10000") |> String.split()
    IntegrityProbeAB.analyze(System.fetch_env!("AB_RESULTS"), System.get_env("AB_OUT"), expected)

  other ->
    raise ArgumentError, "AB_MODE must be fixture, sample, sweep or analyze, got: #{inspect(other)}"
end
