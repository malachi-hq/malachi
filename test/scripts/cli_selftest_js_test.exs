defmodule CliSelftestJsTest do
  # The Node CLIs' cases against brokers of their own (scripts/lib/cli.selftest.js, group_member.selftest.js),
  # for what the server cannot be made to do from a test: go down and come back, refuse, or not be there.
  # CliJsTest runs the CLIs against the test server.
  #
  # Async, and apart from CliJsTest so the partitions of the suite place them apart (#390): each selftest runs
  # its brokers in its own Node process, on ports of its own, and touches nothing of the running application.
  use ExUnit.Case, async: true

  @lib Path.expand("../../scripts/lib", __DIR__)
  @selftests [{"cli.selftest.js", "passed 10 cli cases"}, {"group_member.selftest.js", "passed 23 group member cases"}]

  setup_all do
    # A missing runtime fails loudly instead of skipping: a skipped client test reads as a passing one.
    %{node: System.find_executable("node") || flunk("node is required; install Node 22.15+ (zstd in zlib)")}
  end

  for {selftest, passed} <- @selftests do
    # the cli cases wait out a cluster that does not answer, several times over
    @tag timeout: 180_000
    test "the #{selftest} cases against brokers of their own", ctx do
      assert {output, 0} = System.cmd(ctx.node, [Path.join(@lib, unquote(selftest))], stderr_to_stdout: true)
      assert output =~ unquote(passed)
    end
  end
end
