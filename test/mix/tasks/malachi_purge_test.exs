defmodule Mix.Tasks.Malachi.PurgeTest do
  # The local-call case uses the broker the application started: global state.
  use ExUnit.Case, async: false

  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.Log.Record
  alias Malachi.LogApi
  alias Malachi.Position
  alias Mix.Tasks.Malachi.Purge, as: Task

  defp recording_call(result) do
    parent = self()

    fn module, fun, args ->
      send(parent, {:called, module, fun, args})
      result
    end
  end

  defp local_call, do: fn module, fun, args -> {:ok, apply(module, fun, args)} end

  describe "execute/3: parsing and dispatch" do
    test "--before takes epoch ms or an ISO 8601 datetime" do
      call = recording_call({:ok, {:ok, %{}}})

      assert {:ok, "t: nothing to purge up to before:1700000000000"} =
               Task.execute(["t"], [before: "1700000000000"], call)

      assert_received {:called, Malachi.Purge, :purge, ["t", {:before, 1_700_000_000_000}, "cli@" <> _node]}

      assert {:ok, _message} = Task.execute(["t"], [before: "2023-11-14T22:13:20Z"], call)
      assert_received {:called, Malachi.Purge, :purge, ["t", {:before, 1_700_000_000_000}, _actor]}
    end

    test "--cursor takes a hex token and --group a name" do
      call = recording_call({:ok, {:ok, %{}}})

      assert {:ok, _} = Task.execute(["t"], [cursor: "0A0b"], call)
      assert_received {:called, Malachi.Purge, :purge, ["t", {:position, <<10, 11>>}, _actor]}

      assert {:ok, _} = Task.execute(["t"], [group: "billing"], call)
      assert_received {:called, Malachi.Purge, :purge, ["t", {:group, "billing"}, _actor]}
    end

    test "a malformed or missing point is refused before anything is sent" do
      call = recording_call({:ok, {:ok, %{}}})

      assert {:error, "--before takes" <> _} = Task.execute(["t"], [before: "yesterday"], call)
      assert {:error, "--before takes" <> _} = Task.execute(["t"], [before: "-5"], call)
      assert {:error, "--cursor takes" <> _} = Task.execute(["t"], [cursor: "xyz"], call)
      assert {:error, "--group takes" <> _} = Task.execute(["t"], [group: ""], call)
      assert {:error, "give exactly one" <> _} = Task.execute(["t"], [], call)
      assert {:error, "give exactly one" <> _} = Task.execute(["t"], [before: "1", group: "g"], call)
      assert {:error, "usage:" <> _} = Task.execute([], [before: "1"], call)
      refute_received {:called, _, _, _}
    end

    test "the moved starts are printed, a refusal by its reason, an RPC failure as such" do
      moves = %{{"t", 0} => {0, 4}, {"t", 1} => {2, 9}}
      assert {:ok, message} = Task.execute(["t"], [group: "g"], recording_call({:ok, {:ok, moves}}))
      assert message =~ "logical purge, not erasure"
      assert message =~ ~s({"t", 0}\t0 -> 4)
      assert message =~ ~s({"t", 1}\t2 -> 9)

      assert {:error, "cursor_in_ancestor: " <> _} =
               Task.execute(["t"], [group: "g"], recording_call({:ok, {:error, :cursor_in_ancestor}}))

      assert {:error, message} = Task.execute(["t"], [group: "g"], recording_call({:error, :nodedown}))
      assert is_binary(message)
    end
  end

  test "against the running application, a cursor purge moves the start" do
    topic = "purge-task-#{System.unique_integer([:positive])}"
    shard = DataPlaneRouter.shard_for(topic)
    :ok = LogApi.create_topic(shard, topic)
    {:ok, _} = BrokerServer.produce(shard, topic, for(i <- 0..2, do: Record.new("v#{i}", key: "k#{i}")))
    hex = Base.encode16(Position.encode({topic, 0}, {0, 2}))

    assert {:ok, message} = Task.execute([topic], [cursor: hex], local_call())
    assert message =~ "0 -> 2"
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
      assert_raise Mix.Error, ~r/unknown option\(s\): --nod/, fn -> Task.run(["t", "--nod", "x@y"]) end
    end

    test "prints the answer of a real node over RPC", %{target: target} do
      topic = "purge-run-#{System.unique_integer([:positive])}"
      :ok = LogApi.create_topic(DataPlaneRouter.shard_for(topic), topic)
      Task.run([topic, "--before", "0" | target])
      assert_received {:mix_shell, :info, [message]}
      assert message == "#{topic}: nothing to purge up to before:0"
    end

    test "prints a refusal and exits non-zero", %{target: target} do
      ghost = "purge-ghost-#{System.unique_integer([:positive])}"
      assert catch_exit(Task.run([ghost, "--before", "0" | target])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, ["no_such_topic"]}
    end

    test "a node that cannot be reached is refused with the reason", %{target: [_flag, _node | cookie]} do
      nobody = "nobody_#{System.unique_integer([:positive])}@127.0.0.1"

      assert_raise Mix.Error, ~r/could not connect to #{nobody}/, fn ->
        Task.run(["t", "--before", "0", "--node", nobody | cookie])
      end
    end
  end
end
