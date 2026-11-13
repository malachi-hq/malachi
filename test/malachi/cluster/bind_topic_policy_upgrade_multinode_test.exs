defmodule Malachi.Cluster.BindTopicPolicyUpgradeMultinodeTest do
  @moduledoc """
  The rolling upgrade of the first command that binds a topic to a policy, over real `ra` on peer nodes
  running the production metadata machine.

  `{:bind_topic_policy, topic, name}` is introduced at machine version 4 so that a group whose members
  run different code never applies it on some replicas and refuses it on others. A member pinned to 3
  plays the previous release: while it is in the group, or while the operator holds the pin, the
  effective version stays at 3 and every member refuses the binding the same way. Lifting the pin with a
  rolling restart finalizes the upgrade, the binding applies everywhere, and a full restart replays the
  log to the same state on every member.
  """
  use ExUnit.Case, async: false

  @moduletag :multinode
  @moduletag timeout: 180_000

  import Malachi.Test.MetadataUpgradeGroup

  alias Malachi.Cluster.MachineVersion
  alias Malachi.Metadata
  alias Malachi.Test.MetadataUpgradeGroup
  alias Malachi.Test.RaPeers

  @introduced 4
  @older @introduced - 1

  setup_all do
    RaPeers.ensure_distribution()
  end

  test "this build implements the version the binding needs" do
    assert MachineVersion.code_version() >= @introduced
  end

  test "a member on the previous release holds the binding back on every member, and finalizing applies it" do
    group = MetadataUpgradeGroup.start([nil, nil, @older], "bind_upgrade")
    assert {:ok, {:ok, _root}} = command(group, {:create_topic, "events", 4})
    barrier(group)
    await_effective(group, @older)

    refused = command(group, {:bind_topic_policy, "events", "durable"})
    barrier(group)

    assert refused == {:ok, {:error, {:unsupported_command, {:bind_topic_policy, 3}, @introduced, @older}}}
    for state <- states(group), do: assert(Metadata.topic_policy_name(state, "events") == nil)
    assert_identical(group)

    # Finalize: the last member comes back on the new code, the leader re-asks its peers, and the group
    # reaches the version with no election needed.
    # With no pin left the group reaches this build's version, which is the introducing one or a later
    # release's: the command applies either way.
    restart(group, 2, nil)
    barrier(group)
    await_effective(group, MachineVersion.code_version())

    assert {:ok, :ok} = command(group, {:bind_topic_policy, "events", "durable"})
    barrier(group)
    for state <- states(group), do: assert(Metadata.topic_policy_name(state, "events") == "durable")
    assert_identical(group)

    # Every member goes down before any comes back: the whole log, refusal and binding, replays.
    before = hd(states(group))
    restart_all(group)
    marker = barrier(group)

    assert_identical(group)
    assert Map.delete(hd(states(group)).topics, marker) == before.topics
  end
end
