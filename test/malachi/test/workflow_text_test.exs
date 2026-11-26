defmodule Malachi.Test.WorkflowTextTest do
  # The workflow reader the tests that pin ci.yml's shape read through (test/scripts/ci_workflow_test.exs and
  # the gate test of dependency_updates_skill_test.exs): which job a step belongs to, whether it can fail the run,
  # and the matrix entries it runs for. A wrong answer here would let those tests pass on a workflow they exist to
  # refuse.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  defp strategy(matrix_yaml) do
    [document] =
      :yamerl_constr.string(String.to_charlist("strategy:\n  matrix:\n" <> matrix_yaml), [:str_node_as_binary])

    {"strategy", strategy} = List.keyfind(document, "strategy", 0)
    strategy
  end

  describe "matrix_entries/1" do
    test "a job without a strategy runs once, with no matrix values" do
      assert WorkflowText.matrix_entries(nil) == [%{}]
    end

    test "axes run every combination of their values" do
      entries = WorkflowText.matrix_entries(strategy("    os: [a, b]\n    otp: [1, 2]\n"))

      assert Enum.sort(entries) ==
               Enum.sort([
                 %{"os" => "a", "otp" => 1},
                 %{"os" => "a", "otp" => 2},
                 %{"os" => "b", "otp" => 1},
                 %{"os" => "b", "otp" => 2}
               ])
    end

    test "an include alone runs its entries and nothing else" do
      assert WorkflowText.matrix_entries(strategy("    include:\n      - lint: true\n        coverage: true\n")) ==
               [%{"lint" => true, "coverage" => true}]
    end

    test "an include beside axes adds its entries to their combinations" do
      assert WorkflowText.matrix_entries(strategy("    partition: [1, 2]\n    include:\n      - extra: true\n")) ==
               [%{"partition" => 1}, %{"partition" => 2}, %{"extra" => true}]
    end

    test "an axis given as an expression counts as one entry holding it" do
      assert WorkflowText.matrix_entries(strategy("    runner: ${{ fromJSON(needs.plan.outputs.runners) }}\n")) ==
               [%{"runner" => "${{ fromJSON(needs.plan.outputs.runners) }}"}]
    end

    test "an exclude is refused rather than counted as entries that run" do
      assert_raise ArgumentError, "a matrix exclude is not read", fn ->
        WorkflowText.matrix_entries(strategy("    partition: [1, 2]\n    exclude:\n      - partition: 2\n"))
      end
    end
  end

  describe "steps/1" do
    @workflow """
    name: example
    on: push
    jobs:
      first:
        runs-on: ubuntu-latest
        if: github.event_name == 'push'
        continue-on-error: false
        steps:
          - name: Setup
            uses: actions/setup-node@abc
            with:
              node-version: '22'
          - name: Run
            run: mix test
            if: matrix.lint
            continue-on-error: true
      second:
        runs-on: ubuntu-latest
        continue-on-error: true
        strategy:
          matrix:
            partition: [1, 2]
        steps:
          - run: echo hi
    """

    test "reads each step with its job, its action, its inputs and what decides whether it runs and fails the run" do
      assert [setup, run, echo] = WorkflowText.steps(@workflow)

      assert setup == %{
               job: "first",
               name: "Setup",
               uses: "actions/setup-node@abc",
               with: %{"node-version" => "22"},
               run: "",
               conditions: ["github.event_name == 'push'"],
               continue_on_error: [],
               matrix: [%{}]
             }

      assert %{job: "first", name: "Run", run: "mix test", continue_on_error: [true]} = run
      assert run.conditions == ["github.event_name == 'push'", "matrix.lint"]

      assert %{job: "second", name: nil, uses: nil, with: %{}, run: "echo hi", continue_on_error: [true]} = echo
      assert echo.matrix == [%{"partition" => 1}, %{"partition" => 2}]
    end

    test "yaml_jobs/1 keeps the jobs in the order the file declares them" do
      assert Enum.map(WorkflowText.yaml_jobs(@workflow), &elem(&1, 0)) == ["first", "second"]
    end
  end
end
