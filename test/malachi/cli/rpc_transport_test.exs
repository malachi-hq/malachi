defmodule Malachi.CLI.RpcTransportTest do
  # The operator tasks reach a node over Erlang distribution (#385). A node on TLS distribution can only be reached
  # from a VM started with -proto_dist inet_tls, which a task cannot switch to once it runs, so a task asked for TLS
  # (MALACHI_DIST_TLS=true) on a plaintext VM stops at once and says how to start it.
  use ExUnit.Case, async: true

  alias Malachi.CLI.Rpc

  @tls %{proto_dist: ["inet_tls"], optfile: "/dist/dist_tls.conf"}
  @plain %{proto_dist: [], optfile: nil}

  describe "check_transport/2" do
    test "TLS asked for on a VM started with TLS distribution and its options file passes" do
      assert Rpc.check_transport("true", @tls) == :ok
    end

    test "TLS asked for on a plaintext VM, or one with no options file, stops with how to start the task" do
      for facts <- [@plain, %{@tls | optfile: nil}, %{@tls | optfile: ""}, %{@plain | optfile: "/dist/x.conf"}] do
        assert {:error, message} = Rpc.check_transport("true", facts)
        assert message =~ "MALACHI_DIST_TLS=true"
        assert message =~ ~s(ELIXIR_ERL_OPTIONS="-proto_dist inet_tls -ssl_dist_optfile <options file>")
      end
    end

    test "with TLS not asked for, the VM is used as it is" do
      for tls <- [nil, "", "false"], facts <- [@tls, @plain], do: assert(Rpc.check_transport(tls, facts) == :ok)
    end
  end

  describe "connection_usage/0" do
    test "names the node, the cookie from the environment rather than a flag, and how to reach a TLS node" do
      usage = Rpc.connection_usage()
      assert usage =~ "--node (or $MALACHI_NODE, default malachi@127.0.0.1)"
      assert usage =~ "the cookie in $RELEASE_COOKIE"
      assert usage =~ "a flag shows in ps and in the shell history"
      assert usage =~ "MALACHI_DIST_TLS=true ELIXIR_ERL_OPTIONS="
      refute String.ends_with?(usage, "\n")
    end

    test "every task that connects to a node prints it, from this one place" do
      tasks = Path.wildcard(Path.expand("../../../lib/mix/tasks/*.ex", __DIR__))
      connecting = Enum.filter(tasks, &(File.read!(&1) =~ "Rpc.connect("))

      assert length(connecting) == 8

      for task <- connecting do
        text = File.read!(task)
        assert text =~ "Rpc.connection_usage()", "#{Path.basename(task)} does not print the shared usage"
        refute text =~ "connection: --node", "#{Path.basename(task)} keeps a copy of the usage"
      end
    end
  end
end
