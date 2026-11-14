defmodule Mix.Tasks.Malachi.HoldTest do
  # The local-call case uses the broker the application started: global state.
  use ExUnit.Case, async: false

  alias Malachi.DataPlaneRouter
  alias Malachi.LogApi
  alias Mix.Tasks.Malachi.Hold, as: Task

  defp recording_call(result) do
    parent = self()

    fn module, fun, args ->
      send(parent, {:called, module, fun, args})
      result
    end
  end

  defp local_call, do: fn module, fun, args -> {:ok, apply(module, fun, args)} end

  describe "execute/3: parsing and dispatch" do
    test "set sends the reason with this node as the actor" do
      call = recording_call({:ok, :ok})
      assert {:ok, "t: legal hold placed"} = Task.execute(["set", "t"], [reason: "case 7"], call)
      assert_received {:called, Malachi.LegalHold, :set, ["t", "case 7", "cli@" <> _node]}
    end

    test "release and show dispatch to the hold service" do
      assert {:ok, "t: legal hold released"} = Task.execute(["release", "t"], [], recording_call({:ok, :ok}))
      assert_received {:called, Malachi.LegalHold, :release, ["t", "cli@" <> _node]}

      assert {:ok, "t: not held"} = Task.execute(["show", "t"], [], recording_call({:ok, {:ok, nil}}))
      assert_received {:called, Malachi.LegalHold, :get, ["t"]}

      hold = %{reason: "case 7", actor: "admin", since_ms: 1_700_000_000_000}
      assert {:ok, shown} = Task.execute(["show", "t"], [], recording_call({:ok, {:ok, hold}}))
      assert shown == "topic\tt\nheld\tsince 2023-11-14T22:13:20.000Z\nactor\tadmin\nreason\tcase 7"
    end

    test "set without a reason, or an unknown subcommand, is refused before anything is sent" do
      call = recording_call({:ok, :ok})
      assert {:error, "set takes --reason" <> _} = Task.execute(["set", "t"], [], call)
      assert {:error, "usage:" <> _} = Task.execute(["hold", "t"], [], call)
      assert {:error, "usage:" <> _} = Task.execute([], [], call)
      refute_received {:called, _, _, _}
    end

    test "a refusal is printed by its reason, an RPC failure as such" do
      assert {:error, "already_held: " <> _} =
               Task.execute(["set", "t"], [reason: "r"], recording_call({:ok, {:error, :already_held}}))

      assert {:error, "not_held: " <> _} =
               Task.execute(["release", "t"], [], recording_call({:ok, {:error, :not_held}}))

      assert {:error, "no_such_topic"} =
               Task.execute(["show", "t"], [], recording_call({:ok, {:error, :no_such_topic}}))

      assert {:error, message} = Task.execute(["show", "t"], [], recording_call({:error, :nodedown}))
      assert is_binary(message)
    end
  end

  test "end to end against the application's broker: set, show, release" do
    topic = "hold-task-#{System.unique_integer([:positive])}"
    :ok = LogApi.create_topic(DataPlaneRouter.shard_for(topic), topic)

    assert {:ok, _} = Task.execute(["set", topic], [reason: "case 7"], local_call())
    assert {:ok, shown} = Task.execute(["show", topic], [], local_call())
    assert shown =~ "reason\tcase 7"
    assert {:ok, _} = Task.execute(["release", topic], [], local_call())
    assert {:ok, "#{topic}: not held"} == Task.execute(["show", topic], [], local_call())
  end

  describe "run/1" do
    setup do
      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous) end)
      # The test VM is itself a named node, so the task can target it over real distribution.
      %{target: ["--node", Atom.to_string(node()), "--cookie", Atom.to_string(Node.get_cookie())]}
    end

    test "an unknown option is refused with the usage, before any node is contacted" do
      assert_raise Mix.Error, ~r/unknown option\(s\): --nod/, fn -> Task.run(["show", "t", "--nod", "x@y"]) end
    end

    test "prints the answer of a real node over RPC", %{target: target} do
      topic = "hold-run-#{System.unique_integer([:positive])}"
      :ok = LogApi.create_topic(DataPlaneRouter.shard_for(topic), topic)
      Task.run(["show", topic | target])
      assert_received {:mix_shell, :info, [message]}
      assert message == "#{topic}: not held"
    end

    test "prints a refusal and exits non-zero", %{target: target} do
      ghost = "hold-ghost-#{System.unique_integer([:positive])}"
      assert catch_exit(Task.run(["release", ghost | target])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, ["no_such_topic"]}
    end

    test "a node that cannot be reached is refused with the reason", %{target: [_flag, _node | cookie]} do
      nobody = "nobody_#{System.unique_integer([:positive])}@127.0.0.1"

      assert_raise Mix.Error, ~r/could not connect to #{nobody}/, fn ->
        Task.run(["show", "t", "--node", nobody | cookie])
      end
    end
  end
end
