defmodule Malachi.Test.NodeUnitTest do
  # The helper the Node unit test wrappers assert through (test/scripts/render_mjs_test.exs,
  # dashboard_js_test.exs): it must fail on a failing test, a missing file, a file that declares no test and a
  # count that does not match, and pass only when every expected test ran and passed.
  use ExUnit.Case, async: true

  alias Malachi.Test.NodeUnit

  @fixtures Path.expand("../../fixtures/node_unit", __DIR__)

  setup_all do
    # A missing runtime fails loudly instead of skipping: a skipped client test reads as a passing one.
    %{node: System.find_executable("node") || flunk("node is required to test the Node test helper; install Node 22+")}
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  test "passes when every expected test ran and passed", %{node: node} do
    assert NodeUnit.assert_pass(node, fixture("passing.test.mjs"), tests: 2) == :ok
  end

  test "fails on a failing test, with Node's output", %{node: node} do
    error =
      assert_raise ExUnit.AssertionError, fn -> NodeUnit.assert_pass(node, fixture("failing.test.mjs"), tests: 2) end

    assert error.message =~ "exited with status 1"
    assert error.message =~ "not ok 2 - fails"
  end

  test "fails when the file is missing", %{node: node} do
    error =
      assert_raise ExUnit.AssertionError, fn -> NodeUnit.assert_pass(node, fixture("absent.test.mjs"), tests: 1) end

    assert error.message =~ "exited with status 1"
  end

  test "fails on a file that declares no test, which Node reports as one passing test", %{node: node} do
    error =
      assert_raise ExUnit.AssertionError, fn -> NodeUnit.assert_pass(node, fixture("empty.test.mjs"), tests: 2) end

    assert error.message =~ "reported tests=1 pass=1 fail=0, expected 2 tests"
  end

  test "fails when fewer tests ran than the caller expects", %{node: node} do
    error =
      assert_raise ExUnit.AssertionError, fn -> NodeUnit.assert_pass(node, fixture("passing.test.mjs"), tests: 3) end

    assert error.message =~ "reported tests=2 pass=2 fail=0, expected 3 tests"
  end

  test "fails when more tests ran than the caller expects", %{node: node} do
    error =
      assert_raise ExUnit.AssertionError, fn -> NodeUnit.assert_pass(node, fixture("passing.test.mjs"), tests: 1) end

    assert error.message =~ "expected 1 tests"
  end

  @tag :tmp_dir
  test "fails on output without the TAP summary, whatever the exit status", %{tmp_dir: dir} do
    # A stand-in for node that exits 0 and prints the spec reporter's lines: what the earlier check could not
    # tell from a pass when the runner's Node picked that reporter.
    fake = Path.join(dir, "node")
    File.write!(fake, "#!/bin/sh\necho '✔ adds (1ms)'\necho 'ℹ tests 2'\n")
    File.chmod!(fake, 0o755)

    error =
      assert_raise ExUnit.AssertionError, fn -> NodeUnit.assert_pass(fake, fixture("passing.test.mjs"), tests: 2) end

    assert error.message =~ "reported tests=nil pass=nil fail=nil"
  end

  test "refuses a count that is not a positive integer", %{node: node} do
    assert_raise FunctionClauseError, fn -> NodeUnit.assert_pass(node, fixture("passing.test.mjs"), tests: 0) end
  end
end
