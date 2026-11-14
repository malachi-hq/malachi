defmodule Malachi.DashboardJsTest do
  # The dashboard's extracted scripts (#38): they parse, and their pure functions behave
  # (test/scripts/dashboard_js.test.cjs). Whether the page works under the strict policy in a browser is
  # site/checks/dashboard.mjs.
  use ExUnit.Case, async: true

  @dir Path.expand("../../priv/static/dashboard", __DIR__)
  @unit_tests Path.expand("dashboard_js.test.cjs", __DIR__)

  setup_all do
    # A missing runtime fails loudly instead of skipping: a skipped client test reads as a passing one.
    %{node: System.find_executable("node") || flunk("node is required to test the dashboard scripts; install Node 22+")}
  end

  for file <- ["app.js", "login.js"] do
    test "#{file} parses", %{node: node} do
      assert {_output, 0} = System.cmd(node, ["--check", Path.join(@dir, unquote(file))], stderr_to_stdout: true)
    end
  end

  test "the pure functions pass their unit tests", %{node: node} do
    {output, status} = System.cmd(node, ["--test", @unit_tests], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ ~r/# fail 0/
  end
end
