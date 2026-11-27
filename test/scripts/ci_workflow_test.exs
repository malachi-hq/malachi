defmodule Malachi.CiWorkflowTest do
  # The shape of .github/workflows/ci.yml that a green run cannot show (#390). Code Quality used to run `mix check`
  # behind continue-on-error: the whole suite a second time, and four failing tools nobody saw. The Node wrappers
  # failed under the runner's own Node, which a job without setup-node picks. And CI Summary, the one check a
  # ruleset requires and release.yml reads, listed Code Quality in its needs without ever reading its result. Each
  # property is checked on the real file and on a copy tampered to break it, so a check that always passes fails
  # here.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  @ci File.read!(WorkflowText.path("ci.yml"))
  @summary "CI Summary"

  # The text of `ci` with `from` replaced by `to` inside the job `job` only, asserting the job holds `from`.
  defp in_job(ci, job, from, to) do
    body = Map.fetch!(WorkflowText.jobs(ci), job)
    assert body =~ from, "the #{job} job no longer holds #{inspect(from)}"
    String.replace(ci, body, String.replace(body, from, to, global: false), global: false)
  end

  # Steps that may fail without failing the run.
  defp hiding_steps(ci),
    do: for(step <- WorkflowText.steps(ci), step.continue_on_error != [], do: {step.job, step.name})

  # Steps that run ex_check, whatever else they run.
  defp mix_check_steps(ci),
    do: for(step <- WorkflowText.steps(ci), step.run =~ ~r/\bmix check\b/, do: {step.job, step.name})

  # The blocking, unconditional steps of Code Quality that run Hex's advisory audit.
  defp hex_audit_steps(ci) do
    for step <- WorkflowText.steps(ci),
        step.job == "quality",
        String.trim(step.run) == "mix hex.audit",
        step.conditions == [] and step.continue_on_error == [],
        do: step.name
  end

  # The jobs that run the suite (`mix coveralls.json`) without setting up the Node the Node wrappers are tested
  # under, with the version they set up, if any.
  defp suite_jobs_off_node(ci) do
    steps = WorkflowText.steps(ci)

    for job <- steps |> Enum.filter(&(&1.run =~ "mix coveralls.json")) |> Enum.map(& &1.job) |> Enum.uniq(),
        versions =
          for(
            s <- steps,
            s.job == job,
            String.starts_with?(s.uses || "", "actions/setup-node@"),
            do: s.with["node-version"]
          ),
        versions != ["22"],
        do: {job, versions}
  end

  # Every job CI Summary does not wait for, or waits for without failing when it did not succeed.
  defp unchecked_jobs(ci) do
    jobs = WorkflowText.yaml_jobs(ci)
    {summary_id, summary} = Enum.find(jobs, fn {_id, job} -> job["name"] == @summary end)
    needs = List.wrap(summary["needs"])
    script = Enum.map_join(summary["steps"], "\n", &(Map.new(&1)["run"] || ""))

    for {id, _job} <- jobs, id != summary_id do
      check =
        Regex.run(
          ~r/#{Regex.escape(~s/if [ "${{ needs.#{id}.result }}" != "success" ]; then/)}\n(.*?)\n\s*fi\n/s,
          script
        )

      cond do
        id not in needs -> {id, :not_needed}
        check == nil -> {id, :not_checked}
        # the branch must fail the step: a check that echoes and goes on, or exits 0, passes every result
        not Regex.match?(~r/^\s*exit 1\s*$/m, Enum.at(check, 1)) -> {id, :does_not_fail}
        true -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # The workflow's top-level env.
  defp workflow_env(ci) do
    [document] = :yamerl_constr.string(String.to_charlist(ci), [:str_node_as_binary])
    {"env", env} = List.keyfind(document, "env", 0)
    Map.new(env)
  end

  # What keeps the partitions and TEST_PARTITIONS in step: the matrix lists 1 to TEST_PARTITIONS, and the suite step
  # runs its own partition of that many, exporting its coverage under its own name.
  defp partition_problems(ci) do
    partitions = workflow_env(ci)["TEST_PARTITIONS"]
    {_id, test} = List.keyfind(WorkflowText.yaml_jobs(ci), "test", 0)
    entries = WorkflowText.matrix_entries(test["strategy"])
    body = Map.fetch!(WorkflowText.jobs(ci), "test")
    suite = Enum.find(WorkflowText.steps(ci), &(&1.job == "test" and &1.run =~ "mix coveralls.json"))

    [
      {:not_a_count, not (is_integer(partitions) and partitions > 0)},
      {:matrix_mismatch, is_integer(partitions) and entries != for(k <- 1..partitions//1, do: %{"partition" => k})},
      {:no_suite_step, suite == nil},
      {:not_partitioned, suite != nil and not String.contains?(suite.run, ~s/--partitions "$TEST_PARTITIONS"/)},
      {:not_exported,
       suite != nil and not String.contains?(suite.run, ~s/--export-coverage "partition-$MIX_TEST_PARTITION"/)},
      {:partition_unset, not String.contains?(body, "MIX_TEST_PARTITION: ${{ matrix.partition }}")}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # What makes the coverage job's number the suite's and its threshold binding: it waits for the partitions,
  # counts their exports, merges them, and fails below the threshold, in steps that block.
  defp coverage_problems(ci) do
    {_id, coverage} = List.keyfind(WorkflowText.yaml_jobs(ci), "coverage", 0)

    steps =
      for step <- WorkflowText.steps(ci),
          step.job == "coverage",
          step.conditions == [] and step.continue_on_error == [],
          do: step.run

    merge = Enum.find(steps, &(&1 =~ "mix coveralls.multiple"))

    [
      {:not_after_test, List.wrap(coverage["needs"]) != ["test"]},
      {:no_count_check,
       not Enum.any?(steps, &(&1 =~ ~s/if [ "$found" -ne "$TEST_PARTITIONS" ]; then/ and &1 =~ ~r/^\s*exit 1$/m))},
      {:no_merge, merge == nil},
      {:no_threshold, merge != nil and not (merge =~ "--type local")},
      {:no_report, merge != nil and not (merge =~ "--type json")},
      {:not_imported, merge != nil and not (merge =~ "--import-cover cover/partitions")},
      {:runs_tests, merge != nil and not (merge =~ "--exclude test")}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # Download steps, in any workflow, that read artifacts from another run: the way a pull request's artifact could
  # reach a job with more privileges than the pull request's own run.
  defp cross_run_downloads do
    for file <- WorkflowText.files(),
        step <- WorkflowText.steps(File.read!(file)),
        String.starts_with?(step.uses || "", "actions/download-artifact@"),
        Map.has_key?(step.with, "run-id") or Map.has_key?(step.with, "github-token"),
        do: {Path.basename(file), step.job}
  end

  # Workflows triggered by the completion of this one, which would run with the base repository's privileges on
  # whatever a pull request's run left behind.
  defp ci_followers do
    for file <- WorkflowText.files(),
        [document] = :yamerl_constr.file(String.to_charlist(file), [:str_node_as_binary]),
        {"on", on} <- [List.keyfind(document, "on", 0)],
        is_list(on),
        {"workflow_run", settings} <- on,
        "CI" in List.wrap(Map.new(settings)["workflows"]),
        do: Path.basename(file)
  end

  describe "no failure is hidden" do
    test "no step may fail without failing the run" do
      assert hiding_steps(@ci) == []

      tampered =
        in_job(
          @ci,
          "quality",
          "run: mix credo --strict\n",
          "run: mix credo --strict\n        continue-on-error: true\n"
        )

      assert hiding_steps(tampered) == [{"quality", "🔎 Run Credo (static analysis)"}]

      tampered =
        in_job(
          @ci,
          "dialyzer",
          "    runs-on: ubuntu-latest\n",
          "    runs-on: ubuntu-latest\n    continue-on-error: true\n"
        )

      assert hiding_steps(tampered) != []
    end

    test "CI Summary waits for every other job and fails when any of them did not succeed" do
      assert unchecked_jobs(@ci) == []

      tampered = in_job(@ci, "summary", ~s/if [ "${{ needs.quality.result }}" != "success" ]; then/, "if false; then")
      assert unchecked_jobs(tampered) == [{"quality", :not_checked}]

      tampered = in_job(@ci, "summary", "needs: [test, coverage, docker, quality,", "needs: [test, coverage, docker,")
      assert unchecked_jobs(tampered) == [{"quality", :not_needed}]

      quality_fails = ~s/echo "❌ Code quality checks failed!"\n            exit 1\n/

      for passes <- ["true", "exit 0"] do
        tampered =
          in_job(@ci, "summary", quality_fails, ~s/echo "❌ Code quality checks failed!"\n            #{passes}\n/)

        assert unchecked_jobs(tampered) == [{"quality", :does_not_fail}], passes
      end
    end

    test "the required check keeps its name, which rulesets and release.yml's verify-ci look for" do
      assert {"summary", _} = Enum.find(WorkflowText.yaml_jobs(@ci), fn {_id, job} -> job["name"] == @summary end)
      assert File.read!(WorkflowText.path("release.yml")) =~ "'#{@summary}'"
    end
  end

  describe "Code Quality" do
    test "runs no ex_check, whose tools all run elsewhere" do
      assert mix_check_steps(@ci) == []

      tampered =
        in_job(@ci, "quality", "run: mix hex.audit\n", "run: |\n          mix hex.audit\n          mix check\n")

      assert mix_check_steps(tampered) == [{"quality", "🔐 Audit Hex advisories"}]
    end

    test "audits Hex advisories in a step that blocks" do
      assert hex_audit_steps(@ci) == ["🔐 Audit Hex advisories"]

      tampered = in_job(@ci, "quality", "run: mix hex.audit\n", "run: mix hex.audit\n        continue-on-error: true\n")
      assert hex_audit_steps(tampered) == []

      tampered =
        in_job(@ci, "quality", "run: mix hex.audit\n", "run: mix hex.audit\n        if: github.event_name == 'push'\n")

      assert hex_audit_steps(tampered) == []
    end
  end

  describe "the Node the suite runs under" do
    test "every job that runs the suite sets up Node 22, which the Node wrappers are tested under" do
      assert suite_jobs_off_node(@ci) == []

      tampered = in_job(@ci, "test", "node-version: '22'", "node-version: '24'")
      assert suite_jobs_off_node(tampered) == [{"test", ["24"]}]

      tampered = in_job(@ci, "test", "uses: actions/setup-node@", "uses: actions/setup-python@")
      assert suite_jobs_off_node(tampered) == [{"test", []}]
    end
  end

  describe "the partitions and the merged coverage" do
    test "the matrix and the suite step agree on the number of partitions" do
      assert partition_problems(@ci) == []

      # Built from the file's own count, so changing the count touches ci.yml alone.
      n = workflow_env(@ci)["TEST_PARTITIONS"]
      matrix = "partition: [#{Enum.join(1..n, ", ")}]"
      count = "  TEST_PARTITIONS: #{n}\n"
      assert @ci =~ matrix and @ci =~ count

      assert partition_problems(String.replace(@ci, matrix, "partition: [#{Enum.join(1..(n - 1)//1, ", ")}]")) == [
               :matrix_mismatch
             ]

      assert partition_problems(String.replace(@ci, count, "  TEST_PARTITIONS: #{n + 1}\n")) == [:matrix_mismatch]
      assert partition_problems(String.replace(@ci, count, "  TEST_PARTITIONS: four\n")) == [:not_a_count]

      assert partition_problems(String.replace(@ci, count, "  TEST_PARTITIONS: 0\n")) == [
               :not_a_count,
               :matrix_mismatch
             ]

      assert partition_problems(in_job(@ci, "test", ~s/--partitions "$TEST_PARTITIONS" /, "")) == [:not_partitioned]

      assert partition_problems(in_job(@ci, "test", ~s/ --export-coverage "partition-$MIX_TEST_PARTITION"/, "")) == [
               :not_exported
             ]

      assert partition_problems(
               in_job(@ci, "test", "MIX_TEST_PARTITION: ${{ matrix.partition }}", "MIX_TEST_PARTITION: 1")
             ) ==
               [:partition_unset]
    end

    test "the coverage job merges every partition's export and fails below the threshold" do
      assert coverage_problems(@ci) == []

      assert coverage_problems(in_job(@ci, "coverage", "    needs: test\n", "")) == [:not_after_test]
      assert coverage_problems(in_job(@ci, "coverage", " --type local", "")) == [:no_threshold]
      assert coverage_problems(in_job(@ci, "coverage", " --exclude test", "")) == [:runs_tests]

      assert coverage_problems(in_job(@ci, "coverage", ~s/[ "$found" -ne "$TEST_PARTITIONS" ]/, "false")) == [
               :no_count_check
             ]

      hidden = in_job(@ci, "coverage", "--exclude test\n", "--exclude test\n        continue-on-error: true\n")
      assert coverage_problems(hidden) == [:no_merge]
    end

    test "a partition's export outlives a re-run of the failed jobs a few days later" do
      [upload] =
        for step <- WorkflowText.steps(@ci), step.job == "test", (step.uses || "") =~ "upload-artifact", do: step

      assert upload.with["retention-days"] >= 7
    end

    test "the threshold is coveralls.json's minimum_coverage, 85, and mix.exs sets none ExCoveralls would ignore" do
      assert File.read!(Path.expand("../../coveralls.json", __DIR__))
             |> Jason.decode!()
             |> get_in(["coverage_options", "minimum_coverage"]) == 85

      assert Mix.Project.config()[:test_coverage] == [tool: ExCoveralls]
    end

    test "no workflow reads another run's artifacts or runs after this one, where a pull request's coverage could reach" do
      assert cross_run_downloads() == []
      assert ci_followers() == []
    end
  end
end
