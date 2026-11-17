defmodule Malachi.Cluster.MachineVersioningMultinodeTest do
  @moduledoc """
  The eight production control-plane machines over real `ra` on three peers: each group reaches the
  current machine version on every member, applies its commands, refuses an unknown one with the
  versioned reply, and comes back from a full-cluster restart with the same state and the same
  effective version.

  Lease and ring are the two whose pure modules have no catch-all clause, so before versioning the
  `{:machine_version, 0, 1}` that `ra` applies on the first version bump would have raised inside
  `apply/3` on every replica, and again on every replay.
  """
  use ExUnit.Case, async: false

  @moduletag :multinode
  @moduletag timeout: 180_000

  alias Malachi.Auth.AclMachine
  alias Malachi.Auth.LockoutMachine
  alias Malachi.Auth.UserMachine
  alias Malachi.Cluster.ClusterFlagsMachine
  alias Malachi.Cluster.HashRing
  alias Malachi.Cluster.LeaseMachine
  alias Malachi.Cluster.MachineVersion
  alias Malachi.Cluster.MetadataMachine
  alias Malachi.Cluster.Policy
  alias Malachi.Cluster.PolicyMachine
  alias Malachi.Cluster.PolicyRegistry
  alias Malachi.Cluster.RaCluster
  alias Malachi.Cluster.RingMachine
  alias Malachi.Cluster.RingTopology
  alias Malachi.Test.RaPeers

  setup_all do
    RaPeers.ensure_distribution()
  end

  # {machine, a command it accepts before the restart, one after}
  defp stores do
    topology = %{RingTopology.new(HashRing.new(), %{}) | version: 1}

    [
      {MetadataMachine, {:create_topic, "before", 1}, {:create_topic, "after", 1}},
      {LeaseMachine, {:acquire_or_renew, :holder, 60_000}, {:acquire_or_renew, :holder, 60_000}},
      {RingMachine, {:init, topology}, {:advance, 1, 1, %{topology | version: 2}}},
      {UserMachine, {:put_user, "before", "hash", [:produce]}, {:put_user, "after", "hash", [:produce]}},
      {LockoutMachine, {:unlock_user, "before"}, {:unlock_user, "after"}},
      {AclMachine, {:grant, "before", :produce, {:literal, "t"}}, {:grant, "after", :produce, {:literal, "t"}}},
      {ClusterFlagsMachine, {:enable_flag, :before}, {:enable_flag, :after}},
      {PolicyMachine, {:define_policy, "before", %{spread_by: "rack"}}, {:define_policy, "after", %{}}}
    ]
  end

  defp command(cluster, nodes, command) do
    RaPeers.eventually(fn ->
      Enum.find_value(nodes, fn node ->
        case RaCluster.command({cluster, node}, command) do
          {:ok, reply} -> {:ok, reply}
          {:error, _unreachable} -> nil
        end
      end)
    end)
  end

  defp accepted?({:ok, {:error, _reason}}), do: false
  defp accepted?({:ok, _reply}), do: true
  defp accepted?(_unreachable), do: false

  defp await_converged(clusters, nodes, expected_version) do
    assert RaPeers.eventually(fn ->
             Enum.all?(clusters, fn cluster ->
               Enum.all?(nodes, &(RaPeers.effective(&1, cluster) == expected_version)) and
                 nodes |> Enum.map(&RaPeers.local_state(&1, cluster)) |> Enum.uniq() |> length() == 1
             end)
           end)
  end

  # A policy that sets `field` to a value its type accepts.
  defp setting(%{path: path, type: :bound} = field),
    do: put_in(%{}, Enum.map(path, &Access.key(&1, %{})), Map.get(field, :min, 1))

  defp setting(%{path: path, type: :attribute}), do: put_in(%{}, Enum.map(path, &Access.key(&1, %{})), "rack")

  # Every policy field this release introduces (#199 onwards), against a group caught mid rolling upgrade:
  # one member pinned a version below plays the member still on older code. A pinned member runs this
  # code, so this proves what every member decides from the replicated version, which is all an older
  # binary decides from too (`Malachi.Cluster.MachineVersion`).
  test "a policy field this release introduces is refused alike by every member until the pin is lifted" do
    current = MachineVersion.code_version()
    fields = for %{since: ^current} = field <- Policy.fields(), do: field
    assert fields != [], "this release introduces no policy field: retarget the test at the next one that does"

    pinned = RaPeers.start(current - 1)
    peers = [pinned | for(_ <- 1..2, do: RaPeers.start(nil))]
    {:ok, handles} = Agent.start(fn -> peers |> Enum.with_index() |> Map.new(fn {peer, index} -> {index, peer} end) end)

    on_exit(fn ->
      handles |> Agent.get(&Map.values/1) |> Enum.each(&RaPeers.stop/1)
      Agent.stop(handles)
    end)

    nodes = Enum.map(peers, & &1.node)
    cluster = :"mv_policy_field_#{System.unique_integer([:positive])}"
    {:ok, _member} = RaCluster.start(PolicyMachine, cluster, nodes)
    await_converged([cluster], nodes, current - 1)

    for %{name: name, since: since} = field <- fields do
      define = {:define_policy, "new-#{name}", setting(field)}

      assert {:ok, {:error, {:unsupported_policy_field, ^name, ^since, effective}}} = command(cluster, nodes, define)
      assert effective == current - 1
    end

    # Nothing stored, on any member: the refusal left every replica where it was.
    await_converged([cluster], nodes, current - 1)
    assert RaPeers.local_state(hd(nodes), cluster) == PolicyMachine.init(%{})

    # Lifting the pin is the end of the upgrade: the group moves up and the field is stored. Under a name of
    # its own, so the replay below can tell an entry refused before the upgrade from one stored after it.
    unpinned = RaPeers.restart(pinned, nil, [cluster])
    Agent.update(handles, &Map.put(&1, 0, unpinned))
    nodes = [unpinned.node | tl(nodes)]
    await_converged([cluster], nodes, current)

    for field <- fields do
      assert accepted?(command(cluster, nodes, {:define_policy, "after-#{field.name}", setting(field)}))
    end

    await_converged([cluster], nodes, current)
    stored = RaPeers.local_state(hd(nodes), cluster)

    # A replay applies every entry at the version it was applied at the first time: the refused ones are
    # refused again and the stored ones stored again, on every member.
    running = Agent.get(handles, fn by_index -> Enum.map(0..2, &Map.fetch!(by_index, &1)) end)
    Enum.each(running, &RaPeers.stop/1)

    nodes =
      for {peer, index} <- Enum.with_index(running) do
        back = RaPeers.restart(peer, nil, [cluster])
        Agent.update(handles, &Map.put(&1, index, back))
        back.node
      end

    await_converged([cluster], nodes, current)

    for node <- nodes do
      replayed = RaPeers.local_state(node, cluster)
      assert replayed == stored

      for %{name: name} <- fields do
        assert PolicyRegistry.get(replayed, "new-#{name}") == nil, "#{node} stored a define refused before the upgrade"
        assert PolicyRegistry.get(replayed, "after-#{name}") != nil
      end
    end
  end

  test "every control-plane machine reaches the current version, refuses unknown commands and survives a restart" do
    peers = for _ <- 1..3, do: RaPeers.start(nil)
    # Outlives the test process, so on_exit can still stop whatever handles the test replaced.
    {:ok, handles} = Agent.start(fn -> peers |> Enum.with_index() |> Map.new(fn {peer, index} -> {index, peer} end) end)

    on_exit(fn ->
      handles |> Agent.get(&Map.values/1) |> Enum.each(&RaPeers.stop/1)
      Agent.stop(handles)
    end)

    nodes = Enum.map(peers, & &1.node)

    groups =
      for {machine, before_command, after_command} <- stores() do
        cluster = :"mv_store_#{System.unique_integer([:positive])}"
        {:ok, _member} = RaCluster.start(machine, cluster, nodes)
        {cluster, before_command, after_command}
      end

    clusters = Enum.map(groups, &elem(&1, 0))

    # A group is born at version 0 and moves to the current one once its leader has heard every member
    # advertise it.
    current = MachineVersion.code_version()
    await_converged(clusters, nodes, current)

    for {cluster, before_command, _after} <- groups do
      assert accepted?(command(cluster, nodes, before_command)), "#{cluster} refused #{inspect(before_command)}"
      assert {:ok, {:error, {:unknown_command, {:bogus, 2}, ^current}}} = command(cluster, nodes, {:bogus, 1})
    end

    await_converged(clusters, nodes, current)

    before = Map.new(clusters, &{&1, RaPeers.local_state(hd(nodes), &1)})

    # Full-cluster restart: every member down before any comes back, so the logs replay from disk.
    Enum.each(peers, &RaPeers.stop/1)

    restarted =
      for {peer, index} <- Enum.with_index(peers) do
        restarted = RaPeers.restart(peer, nil, clusters)
        Agent.update(handles, &Map.put(&1, index, restarted))
        restarted
      end

    nodes = Enum.map(restarted, & &1.node)
    await_converged(clusters, nodes, current)

    for cluster <- clusters, do: assert(RaPeers.local_state(hd(nodes), cluster) == before[cluster])

    for {cluster, _before, after_command} <- groups do
      assert accepted?(command(cluster, nodes, after_command)), "#{cluster} refused #{inspect(after_command)}"
    end

    await_converged(clusters, nodes, current)
  end
end
