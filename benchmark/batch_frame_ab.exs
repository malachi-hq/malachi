# The batch frame against the record frame on the store's own write path (#202): per-flush latency and the
# bytes each format puts on disk, with realistic payloads. It is the uncompressed baseline #208 compares
# compression against, and it answers the one question #202 can answer alone: does one CRC per batch, and
# one frame per batch, cost or save anything per flush before any compression is involved?
#
# Method, fixed here before any number exists, so a result cannot shape how it is read:
#
#   * Arms, interleaved in one process on one filesystem and SHUFFLED every repetition (the reason is in
#     storage_viability.exs, PreallocAB.paired/3: a fixed or rotated order lets one arm inherit another's
#     writeback):
#       - `record`      `Malachi.Storage.ElixirStore`, format `:record`, `append/2` then `sync/1`;
#       - `batch_none`  format `:batch`, `append/2` then `sync/1`: one uncompressed batch per flush;
#       - `batch_zstd`  format `:batch`, `append_encoded/2` of a batch compressed with zstd BEFORE the timed
#                       region, then `sync/1`. Compressing belongs to the connection process (#186), so it is
#                       not the store's cost; this arm shows what the smaller flush saves the store.
#       - `control_a1`, `control_a2`: two identical `record` arms. Their difference is this harness's noise
#         floor, MEASURED rather than assumed.
#   * Cases: 1, 10, 100 and 1000 records per flush, `json` payloads of 256 bytes from
#     `Malachi.Loadtest.Payload` (#192), with a fixed seed so every arm writes the same values.
#   * Each repetition writes a fresh segment of `BATCH_AB_FLUSHES` flushes (default 200) and reports that
#     repetition's per-flush p50 and p99; `BATCH_AB_REPS` repetitions per arm (default 7, at least 5), after
#     one discarded warm-up repetition.
#   * The verdict rule is `Malachi.Bench.PairedStats.verdict/3`: a difference is a SIGNAL only when it exceeds
#     the A-A control's AND its bootstrapped 95% interval excludes zero. No difference is a valid result.
#   * Disk bytes are reported per record for each format: the stored size of the segment after the run,
#     which is the same every repetition, so it needs no statistics.
#   * Linux only, on a disk-backed directory: `Malachi.Bench.FlushRegime.prepare!/1` refuses tmpfs and ramfs,
#     where a sync costs nothing and the effect under test is invisible. No preallocation, the store default.
#
#   BENCH_DIR=/data BATCH_AB_OUT=/data/batch-frame-ab.json mix run --no-start benchmark/batch_frame_ab.exs

Code.require_file("support/paired_stats.exs", __DIR__)
Code.require_file("support/flush_regime.exs", __DIR__)

defmodule BatchFrameAB do
  alias Malachi.Bench.PairedStats
  alias Malachi.BatchCodec
  alias Malachi.Loadtest.Payload
  alias Malachi.Log.Record
  alias Malachi.Storage.ElixirStore

  @record_bytes 256
  @seed 202
  @warmup_reps 1
  @cases [1, 10, 100, 1000]
  @arms [:record, :batch_none, :batch_zstd, :control_a1, :control_a2]

  @comparisons [
    {"batch frame, uncompressed, vs record frame", :batch_none, :record},
    {"batch frame, zstd, vs record frame", :batch_zstd, :record},
    {"A-A control (identical arms)", :control_a2, :control_a1}
  ]

  def run(dir, reps, flushes) do
    for per_flush <- @cases do
      IO.puts("\n  case: #{per_flush} record(s) of #{@record_bytes}B json per flush, #{flushes} flushes")
      records = records(per_flush)
      encoded = BatchCodec.build(Enum.map(records, &{&1, false}), :zstd)

      for _ <- 1..@warmup_reps, arm <- @arms, do: measure(dir, arm, records, encoded, flushes)

      samples =
        1..reps
        |> Enum.reduce(Map.new(@arms, &{&1, []}), fn _rep, acc ->
          @arms
          |> Enum.shuffle()
          |> Enum.reduce(acc, fn arm, inner ->
            {latencies, _bytes} = measure(dir, arm, records, encoded, flushes)
            Map.update!(inner, arm, &[PairedStats.summarize(latencies) | &1])
          end)
        end)
        |> Map.new(fn {arm, values} -> {arm, Enum.reverse(values)} end)

      verdicts = Enum.map(@comparisons, &PairedStats.verdict(&1, samples))
      PairedStats.report(samples, verdicts)

      bytes =
        Map.new([:record, :batch_none, :batch_zstd], fn arm ->
          {_latencies, stored} = measure(dir, arm, records, encoded, flushes)
          {arm, Float.round(stored / (per_flush * flushes), 1)}
        end)

      IO.puts("    -- stored bytes per record --")
      for {arm, per_record} <- bytes, do: IO.puts("    #{PairedStats.pad(arm)} #{per_record}")

      %{
        records_per_flush: per_flush,
        record_bytes: @record_bytes,
        flushes_per_rep: flushes,
        arms: Map.new(samples, fn {arm, values} -> {arm, PairedStats.summary(values)} end),
        stored_bytes_per_record: bytes,
        comparisons: verdicts
      }
    end
  end

  defp records(count) do
    :json
    |> Payload.values(@seed, @record_bytes, count)
    |> Enum.with_index()
    |> Enum.map(fn {value, i} -> Record.new(value, key: "key-#{rem(i, 16)}", timestamp: 1_700_000_000_000 + i) end)
  end

  # One arm, one repetition: a fresh segment, then `flushes` append+sync cycles, each timed as the store's
  # durability barrier is (the append and the sync together, as an acknowledged produce waits for both).
  defp measure(dir, arm, records, encoded, flushes) do
    segment_dir = Path.join(dir, "#{arm}_#{System.unique_integer([:positive])}")
    {:ok, store} = ElixirStore.open(segment_dir, "s", format: format(arm), flush_count: 1_000_000_000)

    {latencies, store} =
      Enum.map_reduce(1..flushes, store, fn _flush, store ->
        started = System.monotonic_time(:microsecond)
        {:ok, store, _first, _last} = append(arm, store, records, encoded)
        {:ok, store} = ElixirStore.sync(store)
        {System.monotonic_time(:microsecond) - started, store}
      end)

    stored = ElixirStore.stored_bytes(store)
    :ok = ElixirStore.close(store)
    File.rm_rf!(segment_dir)
    {latencies, stored}
  end

  defp format(arm) when arm in [:batch_none, :batch_zstd], do: :batch
  defp format(_record_or_control), do: :record

  defp append(:batch_zstd, store, _records, encoded), do: ElixirStore.append_encoded(store, encoded)
  defp append(_arm, store, records, _encoded), do: ElixirStore.append(store, records)
end

reps = String.to_integer(System.get_env("BATCH_AB_REPS") || "7")
flushes = String.to_integer(System.get_env("BATCH_AB_FLUSHES") || "200")

# Validated before anything runs, so a bad value costs nothing.
if reps < 5, do: raise(ArgumentError, "BATCH_AB_REPS must be at least 5, got: #{reps}")
if flushes < 20, do: raise(ArgumentError, "BATCH_AB_FLUSHES must be at least 20, got: #{flushes}")

%{dir: base, filesystem: filesystem} = Malachi.Bench.FlushRegime.prepare!()
dir = Path.join(base, "malachi_batch_frame_ab")
File.rm_rf!(dir)
File.mkdir_p!(dir)

IO.puts("\n========== BATCH FRAME vs RECORD FRAME (issue #202) ==========")
IO.puts("  #{reps} shuffled repetitions per arm, on #{filesystem} under #{dir},")
IO.puts("  verdict: signal only when the delta beats the A-A control AND its 95% CI excludes zero.")

cases = BatchFrameAB.run(dir, reps, flushes)
File.rm_rf!(dir)

if out = System.get_env("BATCH_AB_OUT") do
  report = %{
    issue: 202,
    filesystem: filesystem,
    repetitions: reps,
    flushes_per_rep: flushes,
    otp: System.otp_release(),
    cases: cases
  }

  File.write!(out, Jason.encode!(report, pretty: true))
  IO.puts("\n  wrote #{out}")
end
