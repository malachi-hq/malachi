defmodule Malachi.Cluster.LegalHoldUpgradeMultinodeTest do
  @moduledoc """
  The rolling upgrade of the legal hold (#307), over real `ra` on peer nodes running the production metadata
  machine.

  `{:set_topic_hold, topic, request}` is introduced at machine version 11 so that a group whose members run
  different code never holds a topic on some replicas while the others go on deleting it. A member pinned
  to 10 plays the previous release: while it is in the group the effective version stays at 10 and every
  member refuses the hold the same way, so the topic can still be deleted on all of them. Lifting the pin
  with a rolling restart finalizes the upgrade, the hold applies everywhere, every member refuses the
  delete it now covers, and a full restart replays the log to the same state on every member.
  """
  use ExUnit.Case, async: false

  @moduletag :multinode
  @moduletag timeout: 180_000

  import Malachi.Test.MetadataUpgradeGroup

  alias Malachi.Cluster.MachineVersion
  alias Malachi.Metadata
  alias Malachi.Test.MetadataUpgradeGroup
  alias Malachi.Test.RaPeers

  @introduced 11
  @older @introduced - 1
  @request %{reason: "case 7", actor: "admin"}

  setup_all do
    RaPeers.ensure_distribution()
  end

  test "this build implements the version the hold needs" do
    assert MachineVersion.code_version() >= @introduced
  end

  test "a member on the previous release holds the hold back on every member, and finalizing applies it" do
    group = MetadataUpgradeGroup.start([nil, nil, @older], "hold_upgrade")
    assert {:ok, {:ok, _root}} = command(group, {:create_topic, "events", 4})
    barrier(group)
    await_effective(group, @older)

    refused = command(group, {:set_topic_hold, "events", @request})
    barrier(group)

    assert refused == {:ok, {:error, {:unsupported_command, {:set_topic_hold, 3}, @introduced, @older}}}
    for state <- states(group), do: assert(Metadata.legal_hold(state, "events") == nil)
    assert_identical(group)

    # Finalize: the last member comes back on the new code and the group reaches this build's version.
    restart(group, 2, nil)
    barrier(group)
    await_effective(group, MachineVersion.code_version())

    assert {:ok, :ok} = command(group, {:set_topic_hold, "events", @request})
    barrier(group)

    # Every member stamped the same time, the one the leader wrote into the log entry.
    holds = for state <- states(group), do: Metadata.legal_hold(state, "events")
    assert [%{reason: "case 7", actor: "admin", since_ms: since} | _] = holds
    assert is_integer(since)
    assert Enum.uniq(holds) == [hd(holds)]

    assert {:ok, {:error, :legal_hold}} = command(group, {:delete_topic, "events"})
    barrier(group)
    for state <- states(group), do: assert(Metadata.get_topic(state, "events") != nil)
    assert_identical(group)

    # Every member goes down before any comes back: the whole log, refusal, hold and refused delete, replays.
    before = hd(states(group))
    restart_all(group)
    marker = barrier(group)

    assert_identical(group)
    assert Map.delete(hd(states(group)).topics, marker) == before.topics
  end
end
