defmodule Malachi.Console.ReadsTest do
  use ExUnit.Case, async: false

  alias Malachi.BrokerServer
  alias Malachi.Cluster.MachineVersion
  alias Malachi.Cluster.Membership
  alias Malachi.Console.Access
  alias Malachi.Console.Fanout
  alias Malachi.Console.Reads
  alias Malachi.Console.Sampler
  alias Malachi.Console.Samples
  alias Malachi.Consumer.GroupCoordinator
  alias Malachi.Log.Record
  alias Malachi.Metadata
  alias Malachi.Test.AccessHelper
  alias Malachi.Test.SamplerHelper
  alias Malachi.Test.TmpDir

  test "a node describes itself: uptime, release, format marker and machine versions" do
    info = Reads.node_info()
    assert is_integer(info.uptime_seconds) and info.uptime_seconds >= 0
    assert info.version == :malachi |> Application.spec(:vsn) |> List.to_string()
    assert info.format.state in ["present", "absent", "none", "invalid", "unreadable"]
    assert info.machine_versions == Reads.machine_versions()
  end

  test "every member this node hosts is named by its machine, sorted, and none is stuck" do
    versions = Reads.machine_versions()
    assert versions == Enum.sort_by(versions, &{&1.machine, &1.member})

    for version <- versions do
      assert version.machine in ~w(metadata ring lease policy cluster_flags user lockout acl)
      assert version.supported == MachineVersion.version()
      assert version.stuck == version.effective > version.supported
    end

    assert Reads.machine_versions(:no_such_ra_system) == []

    # the test node runs the replicated stores
    assert Enum.any?(versions, &(&1.machine == "user" and &1.member == "users"))
  end

  describe "the format marker" do
    setup do
      original = Application.get_env(:malachi, :log_data_dir)
      on_exit(fn -> Application.put_env(:malachi, :log_data_dir, original) end)
      dir = TmpDir.path("reads_marker")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "each state a data directory can be in", %{dir: dir} do
      Application.put_env(:malachi, :log_data_dir, nil)
      assert Reads.node_info().format == %{state: "none"}

      Application.put_env(:malachi, :log_data_dir, dir)
      assert Reads.node_info().format == %{state: "absent"}

      File.write!(Path.join(dir, "malachi.format"), "format=2\nwritten_by=0.23.0\nrequires=0.13.0\n")
      assert Reads.node_info().format == %{state: "present", format: 2, written_by: "0.23.0", requires: "0.13.0"}

      File.write!(Path.join(dir, "malachi.format"), "not a marker")
      assert Reads.node_info().format == %{state: "invalid"}

      File.rm!(Path.join(dir, "malachi.format"))
      File.mkdir_p!(Path.join(dir, "malachi.format"))
      assert Reads.node_info().format == %{state: "unreadable"}
    end
  end

  describe "copy health" do
    setup do
      Sampler.clear()
      Application.put_env(:malachi, :console_sample_ms, 600_000)

      on_exit(fn ->
        Application.delete_env(:malachi, :console_sample_ms)
        Sampler.clear()
      end)
    end

    test "the failed and damaged copies this node holds, from their samples" do
      SamplerHelper.seed!(:metadata, Metadata.new())
      SamplerHelper.seed!(:failed, MapSet.new([:seg]))
      SamplerHelper.seed!(:damaged, [:other])

      health = Reads.copy_health()
      assert health.failed == [:seg]
      assert health.damaged in [[:other], :not_scrubbed]
    end

    test "the copies of a topic produced on this node are asked of its replication server, and none failed" do
      topic = "reads_health_#{System.unique_integer([:positive])}"
      {:ok, _root} = BrokerServer.create_topic(Malachi.LogBroker, topic, 4)
      {:ok, _placements} = BrokerServer.produce(Malachi.LogBroker, topic, [Record.new("v", key: "k")])

      assert {:ok, %{value: failed}} = Samples.failed()
      assert MapSet.size(failed) == 0
      assert Reads.copy_health().failed == []
    end

    test "a failure latch that could not be read again is unknown, though an older list is kept" do
      Application.put_env(:malachi, :console_sample_ms, 50)
      {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "stale_health", 4})
      ref = {:no_such_replication_server, node()}
      {state, :ok} = Metadata.apply(state, {:register_segment, root, {root, 0}, [ref], 0})
      SamplerHelper.seed!(:metadata, state)
      SamplerHelper.seed!(:failed, MapSet.new())
      Process.sleep(60)
      SamplerHelper.seed!(:metadata, state)

      # the latch read now fails (its server does not exist): the empty list from before is not current
      assert Reads.copy_health().failed == :unknown
    end

    test "a failure latch that cannot be read is unknown, not empty" do
      # with no sample yet and a metadata whose replica on this node does not answer
      {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "health", 4})
      ref = {:no_such_replication_server, node()}
      {state, :ok} = Metadata.apply(state, {:register_segment, root, {root, 0}, [ref], 0})
      SamplerHelper.seed!(:metadata, state)

      assert Reads.copy_health().failed == :unknown
    end
  end

  describe "groups" do
    setup do
      Sampler.clear()
      on_exit(fn -> Sampler.clear() end)
    end

    test "the groups the node-wide coordinator holds" do
      topic = "reads_groups_#{System.unique_integer([:positive])}"
      {:ok, _root} = BrokerServer.create_topic(Malachi.LogBroker, topic, 4)
      {:ok, _} = GroupCoordinator.join_group(Malachi.LogGroupCoordinator, "reads-group", topic, "m")
      on_exit(fn -> GroupCoordinator.leave(Malachi.LogGroupCoordinator, "reads-group", topic, "m") end)

      assert %{groups: groups, unanswered: 0} = Reads.groups()
      assert Enum.any?(groups, &match?(%{group: "reads-group", topic: ^topic, members: [%{member: "m"}]}, &1))
    end

    test "a slow coordinator answers through the fan-out with its last sample, not as an unanswered node" do
      Application.put_env(:malachi, :console_sample_ms, 50)
      on_exit(fn -> Application.delete_env(:malachi, :console_sample_ms) end)
      held = [%{group: "held", topic: "t", generation: 1, members: []}]
      SamplerHelper.seed!({:group_coordinator, Malachi.LogGroupCoordinator}, held)
      Process.sleep(60)
      :ok = :sys.suspend(Malachi.LogGroupCoordinator)

      try do
        result = Fanout.call(:groups, [], nodes: [node()])
        assert result.unanswered == []
        assert [{_node, %{groups: groups, unanswered: 0}}] = result.answers
        assert Enum.any?(groups, &(&1.group == "held"))
      after
        :sys.resume(Malachi.LogGroupCoordinator)
      end
    end

    test "a coordinator that does not answer is counted, not waited for" do
      :ok = :sys.suspend(Malachi.LogGroupCoordinator)

      try do
        assert %{unanswered: unanswered} = Reads.groups()
        assert unanswered >= 1
      after
        :sys.resume(Malachi.LogGroupCoordinator)
      end
    end
  end

  test "sessions are named by their digest and the node that holds them, never by their token" do
    token = AccessHelper.account!("reads_session", [], :viewer)
    digest = Access.session_digest(token)

    assert [session] = Enum.filter(Reads.sessions(), &(&1.session == digest))
    assert %{username: "reads_session", node: node_name} = session
    assert node_name == Atom.to_string(node())
    refute Map.has_key?(session, :token_prefix)
    refute inspect(session) =~ token
  end

  test "the nodes a fan-out asks come from the membership's sample, not a call into the gossip loop per request" do
    Sampler.clear()
    Application.put_env(:malachi, :console_sample_ms, 60_000)

    on_exit(fn ->
      Application.delete_env(:malachi, :console_sample_ms)
      Sampler.clear()
    end)

    view = %Membership{
      self: {Malachi.LogMembership, node()},
      members: %{
        {Malachi.LogMembership, node()} => %{status: :alive, incarnation: 1, attributes: %{}},
        {Malachi.LogMembership, :sampled@h} => %{status: :alive, incarnation: 1, attributes: %{}},
        {Malachi.LogMembership, :dead@h} => %{status: :dead, incarnation: 1, attributes: %{}}
      }
    }

    # the test node runs a membership; its real view does not know :sampled@h, the sample does
    assert Process.whereis(Malachi.LogMembership)
    SamplerHelper.seed!(:membership, view)
    assert Enum.sort(Fanout.alive_nodes()) == Enum.sort([node(), :sampled@h])
  end

  test "a membership that could not be read leaves this node alone, and the fan-out says it is partial" do
    Sampler.clear()
    Application.put_env(:malachi, :console_sample_ms, 60_000)

    on_exit(fn ->
      Application.delete_env(:malachi, :console_sample_ms)
      Sampler.clear()
    end)

    # a first read that fails leaves no sample, and none is tried again within the interval
    assert Sampler.fetch(:membership, fn -> {:error, :down} end, interval_ms: 0) == {:error, :unavailable}

    assert Fanout.nodes_to_ask() == {[node()], true}
    result = Fanout.call(:node_info, [])
    assert result.membership_unavailable
    assert Fanout.partial?(result)
    assert Fanout.members(result)["membership"] == "unavailable"
  end
end
