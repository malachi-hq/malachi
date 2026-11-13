defmodule DockerSingleNodeRestartTest do
  # scripts/docker-single-node-restart.sh seeds one admin with a password it generates, and every check
  # connects as that admin from an rpc inside the node. #180: the password must reach the container by
  # name (`docker run -e NAME`) and the rpc must read it from the node's own environment, so it is never an
  # argument of the docker client, where every local user could read it. The drill runs for real with
  # Malachi.Test.DockerHarnessStubs first on the PATH; every rpc answers `true`, which brings the node up
  # and lets the first connecting check run before the drill fails on the answers it cannot use.
  use ExUnit.Case, async: true

  alias Malachi.Test.DockerHarnessStubs, as: Stubs

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/docker-single-node-restart.sh", __DIR__)

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    for tool <- ~w(bash openssl) do
      System.find_executable(tool) || flunk("#{tool} is required to test #{@script}")
    end

    :ok
  end

  setup %{tmp_dir: dir}, do: Stubs.install!(dir)

  test "the admin password reaches the node by name and never as a process argument", ctx do
    data = Path.join(Path.dirname(ctx.stubs), "data")

    {_output, _status} =
      System.cmd(System.find_executable("bash"), [@script, "malachi:stub"],
        env: Stubs.env(ctx, [{"DRILL_DIR", data}, {"DRILL_NAME", "drill-test"}, {"STUB_RPC_REPLY", "true"}]),
        stderr_to_stdout: true
      )

    env = Stubs.container_env(ctx)
    assert "drill_" <> hex = env["MALACHI_ADMIN_PASS"]
    assert hex =~ ~r/^[0-9a-f]{16}$/
    assert env["MALACHI_DEFAULT_USERS"] == "admin:#{env["MALACHI_ADMIN_PASS"]}:admin"

    argv = Stubs.argv(ctx)
    assert argv =~ "-e MALACHI_DEFAULT_USERS -e MALACHI_ADMIN_PASS "
    # A check that connects as the admin did run, reading the password inside the node.
    assert argv =~ ~s|pass: System.fetch_env!("MALACHI_ADMIN_PASS")|
    refute argv =~ env["MALACHI_ADMIN_PASS"]
  end
end
