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
      cond do
        id not in needs -> {id, :not_needed}
        not String.contains?(script, ~s/if [ "${{ needs.#{id}.result }}" != "success" ]; then/) -> {id, :not_checked}
        true -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
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

      tampered = in_job(@ci, "summary", "needs: [test, docker, quality,", "needs: [test, docker,")
      assert unchecked_jobs(tampered) == [{"quality", :not_needed}]
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
end
