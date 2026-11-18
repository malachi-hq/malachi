defmodule Malachi.RenderMjsTest do
  # site/checks/render.mjs draws the blog's chart images (#373): it parses, and its pure functions behave
  # (test/scripts/render_mjs.test.mjs). Drawing itself needs the browser and runs locally only.
  use ExUnit.Case, async: true

  @script Path.expand("../../site/checks/render.mjs", __DIR__)
  @unit_tests Path.expand("render_mjs.test.mjs", __DIR__)

  setup_all do
    # A missing runtime fails loudly instead of skipping: a skipped client test reads as a passing one.
    %{node: System.find_executable("node") || flunk("node is required to test render.mjs; install Node 22+")}
  end

  test "render.mjs parses", %{node: node} do
    assert {_output, 0} = System.cmd(node, ["--check", @script], stderr_to_stdout: true)
  end

  test "its pure functions pass their unit tests", %{node: node} do
    {output, status} = System.cmd(node, ["--test", @unit_tests], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ ~r/# fail 0/
  end

  test "a usage error exits non-zero before any browser is needed", %{node: node} do
    {output, status} = System.cmd(node, [@script, "nonsense"], stderr_to_stdout: true)
    assert status == 1
    assert output =~ "usage: node site/checks/render.mjs"
  end
end
