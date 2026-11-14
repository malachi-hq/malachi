# What the legal hold (#307) costs on the two paths it touches, against the code before it, in one process:
#
#   * `apply_hot`: `Malachi.Metadata.apply/3` on the commands a produce issues (register a segment, seal it,
#     commit an offset). The hold's gate sits beside the migration fence every command passes, so this is
#     the hot path the hold could slow down even on a cluster that never holds anything.
#   * `sweep`: one retention sweep's decision over 100 topics of 1000 sealed segments each, one topic held:
#     `Malachi.Cluster.Retention.plan/5` (treatment) against the `expired/5` it replaced (baseline).
#
# Method, fixed here before any number exists, so a result cannot shape how it is read:
#
#   * Both arms are compiled into this process the same way, from source, under other module names: the
#     baseline (`Baseline.Metadata`, `Baseline.Retention`) from `BASELINE_SRC`, a directory holding the two
#     files at the base ref, and the treatment (`Treatment.Metadata`, `Treatment.Retention`) from this
#     tree's `lib/`. Comparing a module compiled by `mix` against one compiled from a string would measure
#     the two compile paths as well as the change:
#
#       git show origin/main:lib/malachi/metadata.ex > "$BASELINE_SRC/metadata.ex"
#       git show origin/main:lib/malachi/cluster/retention.ex > "$BASELINE_SRC/retention.ex"
#
#   * Arms, SHUFFLED every repetition: `control_a1` and `control_a2` (the baseline twice: their difference is
#     this harness's noise floor, measured rather than assumed) and `treatment` (the code under test).
#   * `apply_hot`: each repetition times `LEGAL_HOLD_AB_OPS` (default 2000) produce sequences in samples of
#     100, against a state already holding 1000 sealed segments, and reports the per-sample p50 and p99.
#   * `sweep`: each repetition times `LEGAL_HOLD_AB_SWEEPS` (default 5) sweeps and reports their p50 and p99.
#   * `LEGAL_HOLD_AB_REPS` repetitions per arm (default 7, at least 5), after one discarded warm-up repetition.
#   * The verdict rule is `Malachi.Bench.PairedStats.verdict/3`: a difference is a SIGNAL only when it exceeds
#     the A-A control's AND its bootstrapped 95% interval excludes zero. No difference is a valid result.
#   * Linux only (Docker on a dev machine, cpuset pinned), like every number this repository publishes.
#
#   BASELINE_SRC=/baseline LEGAL_HOLD_AB_OUT=/out/legal-hold-ab.json mix run --no-start benchmark/legal_hold_ab.exs

Code.require_file("support/paired_stats.exs", __DIR__)

defmodule LegalHoldAB do
  alias Malachi.Bench.PairedStats

  @arms [:control_a1, :control_a2, :treatment]

  def run do
    baseline = System.fetch_env!("BASELINE_SRC")
    lib = Path.expand("../lib/malachi", __DIR__)
    load!("Baseline", Path.join(baseline, "metadata.ex"), Path.join(baseline, "retention.ex"))
    load!("Treatment", Path.join(lib, "metadata.ex"), Path.join(lib, "cluster/retention.ex"))
    reps = max(5, env_int("LEGAL_HOLD_AB_REPS", 7))
    ops = env_int("LEGAL_HOLD_AB_OPS", 2000)
    sweeps = env_int("LEGAL_HOLD_AB_SWEEPS", 5)

    cases = [
      measure("apply_hot", fn arm -> apply_hot(arm, ops) end, reps),
      measure("sweep", fn arm -> sweep(arm, sweeps) end, reps)
    ]

    result = %{
      cases: cases,
      outcome: PairedStats.outcome(cases, ["apply_hot", "sweep"]),
      system: %{otp: System.otp_release(), elixir: System.version(), schedulers: System.schedulers_online()}
    }

    json = Jason.encode!(result, pretty: true)
    if out = System.get_env("LEGAL_HOLD_AB_OUT"), do: File.write!(out, json)
    IO.puts(json)
  end

  # --- both arms, compiled from source the same way under their own names ---

  defp load!(prefix, metadata_path, retention_path) do
    metadata =
      metadata_path
      |> File.read!()
      |> String.replace("defmodule Malachi.Metadata do", "defmodule #{prefix}.Metadata do", global: false)

    retention =
      retention_path
      |> File.read!()
      |> String.replace("defmodule Malachi.Cluster.Retention do", "defmodule #{prefix}.Retention do", global: false)
      |> String.replace("alias Malachi.Metadata\n", "alias #{prefix}.Metadata, as: Metadata\n", global: false)

    Code.compiler_options(ignore_module_conflict: true, docs: false)
    Code.compile_string(metadata, "#{prefix}/metadata.ex")
    Code.compile_string(retention, "#{prefix}/retention.ex")
  end

  defp metadata_module(:treatment), do: Treatment.Metadata
  defp metadata_module(_control), do: Baseline.Metadata

  # The decision each arm makes per sweep: the treatment's one-pass plan, the baseline's expiry list.
  defp decide(:treatment, metadata, policy), do: Treatment.Retention.plan(metadata, 10_000, policy)
  defp decide(_control, metadata, policy), do: Baseline.Retention.expired(metadata, 10_000, policy)

  # --- cases ---

  # A topic whose root range holds `count` sealed one-offset segments, built with the arm's own module.
  defp topic_with_sealed(module, state, topic, count) do
    {state, {:ok, root}} = module.apply(state, {:create_topic, topic, 4})

    Enum.reduce(0..(count - 1), state, fn offset, state ->
      {state, :ok} = module.apply(state, {:register_segment, root, {root, offset}, [:b1], offset}, offset)
      {state, :ok} = module.apply(state, {:seal_segment, {root, offset}, 1, 100, offset})
      state
    end)
  end

  defp apply_hot(arm, ops) do
    module = metadata_module(arm)
    state = topic_with_sealed(module, module.new(), "events", 1000)
    root = {"events", 0}

    {_state, samples} =
      Enum.reduce(Enum.chunk_every(1000..(1000 + ops - 1), 100), {state, []}, fn chunk, {state, samples} ->
        started = :erlang.monotonic_time(:nanosecond)

        state =
          Enum.reduce(chunk, state, fn offset, state ->
            {state, :ok} = module.apply(state, {:register_segment, root, {root, offset}, [:b1], offset}, offset)
            {state, :ok} = module.apply(state, {:seal_segment, {root, offset}, 1, 100, offset})
            {state, :ok} = module.apply(state, {:commit_offset, "g", "events", %{root => {offset, offset + 1}}})
            state
          end)

        {state, [(:erlang.monotonic_time(:nanosecond) - started) / 1000 | samples]}
      end)

    PairedStats.summarize(samples)
  end

  defp sweep(arm, sweeps) do
    metadata_module = metadata_module(arm)

    metadata =
      Enum.reduce(0..99, metadata_module.new(), fn i, state ->
        topic_with_sealed(metadata_module, state, "topic-#{i}", 1000)
      end)

    # One held topic, on the arm that knows holds; the baseline has no hold to skip.
    metadata =
      if arm == :treatment do
        {held, :ok} = Treatment.Metadata.apply(metadata, {:set_topic_hold, "topic-0", %{reason: "r", actor: "a"}}, 1)
        held
      else
        metadata
      end

    policy = %{max_age_ms: 500}

    samples =
      for _ <- 1..sweeps do
        started = :erlang.monotonic_time(:nanosecond)

        decide(arm, metadata, policy)

        (:erlang.monotonic_time(:nanosecond) - started) / 1000
      end

    PairedStats.summarize(samples)
  end

  # --- harness ---

  defp measure(name, fun, reps) do
    _warmup = Enum.each(@arms, fun)

    samples =
      Enum.reduce(1..reps, Map.new(@arms, &{&1, []}), fn _rep, samples ->
        @arms
        |> Enum.shuffle()
        |> Enum.reduce(samples, fn arm, samples ->
          :erlang.garbage_collect()
          Map.update!(samples, arm, &[fun.(arm) | &1])
        end)
      end)

    %{
      case: name,
      sufficient: Enum.all?(@arms, &(length(samples[&1]) >= 5)),
      summary: Map.new(@arms, &{&1, PairedStats.summary(samples[&1])}),
      comparisons: [
        PairedStats.verdict({"#{name}: treatment vs baseline", :treatment, :control_a1}, samples),
        PairedStats.verdict({"#{name}: A-A control", :control_a2, :control_a1}, samples)
      ]
    }
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end

LegalHoldAB.run()
