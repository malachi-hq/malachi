# Judges the samples of benchmark/loop_stall_ab.sh (issue #283, Part 2) by the rule every paired A/B here uses
# (`support/paired_stats.exs` through `support/ab_run.exs`): the latency of node 1's `GET /ready` while node 3
# is frozen, one repetition's samples reduced to their p50 and p99.
#
# The probe starts sampling, the driver freezes node 3 fifteen seconds later and keeps it frozen for forty, and
# the driver sees the probe start within a second of it, so the frozen window is taken as 17s to 54s from the
# probe's start: two seconds of margin on each side. The healthy window (1s to 14s) is printed beside it, as
# what the loop costs when nothing is wrong.
#
#   AB_RESULTS=dir AB_OUT=file mix run --no-start benchmark/loop_stall_ab.exs

Code.require_file("support/ab_run.exs", __DIR__)

defmodule LoopStallAB do
  alias Malachi.Bench.ABRun
  alias Malachi.Bench.PairedStats

  @marker "READY_PROBE "
  @frozen 17_000..54_000
  @healthy 1_000..14_000

  def analyze(results, out) do
    report_windows(results)
    ABRun.analyze(results, out, ["stall"], [{"stall", "stall", &parse/1}])
  end

  defp parse(output), do: output |> window(@frozen) |> PairedStats.summarize()

  defp window(output, range) do
    line = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, @marker))
    unless line, do: raise("a sample without a #{String.trim(@marker)} line:\n#{output}")
    %{"samples" => samples} = line |> String.replace_prefix(@marker, "") |> Jason.decode!()
    for [offset, latency_us, _status] <- samples, offset in range, do: latency_us
  end

  # The longest single wait in each window, per sample: the number an operator would see as a stall.
  defp report_windows(results) do
    IO.puts("\n  longest wait per sample (healthy window | frozen window):")

    for path <- results |> Path.join("stall/*.out") |> Path.wildcard() |> Enum.sort(),
        not String.contains?(Path.basename(path), "warm") do
      output = File.read!(path)
      healthy = output |> window(@healthy) |> Enum.max(fn -> 0 end)
      frozen = output |> window(@frozen) |> Enum.max(fn -> 0 end)
      IO.puts("    #{String.pad_trailing(Path.basename(path), 18)} #{div(healthy, 1000)}ms | #{div(frozen, 1000)}ms")
    end
  end
end

LoopStallAB.analyze(System.fetch_env!("AB_RESULTS"), System.get_env("AB_OUT"))
