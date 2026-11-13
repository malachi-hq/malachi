defmodule Malachi.Cluster.SetRangeStartsUpgradeMultinodeTest do
  @moduledoc """
  The rolling upgrade of the manual purge (#198), over real `ra` on peer nodes running the production
  metadata machine.

  `{:set_range_starts, topic, starts}` is introduced at machine version 9 so that a group whose members
  run different code never moves a range's logical start on some replicas and refuses it on others: a
  member that refused it would serve purged records again. A member pinned to 8 plays the previous
  release: while it is in the group the effective version stays at 8, and every member refuses the purge
  the same way. Lifting the pin finalizes the upgrade, the purge applies everywhere, and a full restart
  replays the log to the same state on every member.
  """
  use ExUnit.Case, async: false

  @moduletag :multinode
  @moduletag timeout: 180_000

  import Malachi.Test.MetadataUpgradeGroup

  alias Malachi.Cluster.MachineVersion
  alias Malachi.Metadata
  alias Malachi.Test.MetadataUpgradeGroup
  alias Malachi.Test.RaPeers

  @introduced 9
  @older @introduced - 1
  @root {"events", 0}

  setup_all do
    RaPeers.ensure_distribution()
  end

  test "this build implements the version the purge needs" do
    assert MachineVersion.code_version() >= @introduced
  end

  test "a member on the previous release holds the purge back on every member, and finalizing applies it" do
    group = MetadataUpgradeGroup.start([nil, nil, @older], "purge_upgrade")
    assert {:ok, {:ok, @root}} = command(group, {:create_topic, "events", 4})
    barrier(group)
    await_effective(group, @older)

    refused = command(group, {:set_range_starts, "events", %{@root => 3}})
    barrier(group)

    assert refused == {:ok, {:error, {:unsupported_command, {:set_range_starts, 3}, @introduced, @older}}}
    for state <- states(group), do: assert(Metadata.logical_start(state.ranges[@root]) == 0)
    assert_identical(group)

    restart(group, 2, nil)
    barrier(group)
    await_effective(group, MachineVersion.code_version())

    assert {:ok, {:ok, %{@root => {0, 3}}}} = command(group, {:set_range_starts, "events", %{@root => 3}})
    barrier(group)
    for state <- states(group), do: assert(Metadata.logical_start(state.ranges[@root]) == 3)
    assert_identical(group)

    # Every member goes down before any comes back: the whole log, refusal and purge, replays.
    before = hd(states(group))
    restart_all(group)
    marker = barrier(group)

    assert_identical(group)
    assert Map.delete(hd(states(group)).ranges, {marker, 0}) == before.ranges
  end
end
