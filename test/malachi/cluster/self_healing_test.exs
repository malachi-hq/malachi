defmodule Malachi.Cluster.SelfHealingTest do
  use ExUnit.Case, async: true

  alias Malachi.Test.SegmentFilesHelper

  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Cluster.SelfHealing
  alias Malachi.Log.Record
  alias Malachi.Metadata
  alias Malachi.Storage.Layout
  alias Malachi.Test.FaultySegmentStore
  alias Malachi.Test.TmpDir

  defp start_broker do
    {ref, _directory, _id} = start_broker_with_directory()
    ref
  end

  defp start_broker_with_directory do
    directory = TmpDir.path("malachi_heal")
    on_exit(fn -> File.rm_rf!(directory) end)
    id = {:repl, System.unique_integer([:positive])}
    {start_supervised!({ReplicationServer, directory: directory}, id: id), directory, id}
  end

  defp records(values), do: for(value <- values, do: Record.new(value, key: value))

  # A pid that has already exited: probing it exits, which the integrity pass reads as unreachable.
  defp dead_broker do
    pid = spawn(fn -> :ok end)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    pid
  end

  defp read_values(ref, segment_id) do
    case ReplicationServer.read(ref, segment_id, 0, 100) do
      {:ok, records} -> Enum.map(records, & &1.value)
      :eof -> []
    end
  end

  # Builds metadata with one sealed segment over `replica_set`, and seeds `source` with its data.
  defp sealed_segment(replica_set, source, values) do
    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
    segment_id = {root, 0}
    {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, replica_set, 0})
    {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, length(values), 0, 0})
    {:ok, _last} = ReplicationServer.replicate(source, segment_id, [source], 0, records(values))
    {metadata, segment_id}
  end

  test "backfills the new replica of an under-replicated sealed segment and returns the command" do
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])

    # c has left; the live set is a, b, d
    result = SelfHealing.heal_sealed(metadata, [a, b, d], 3)

    assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
    assert result.failed == []
    assert Enum.sort(new_set) == Enum.sort([a, b, d])

    # the freshly placed replica d now holds the segment's data
    assert read_values(d, segment_id) == ["x", "y", "z"]

    # applying the command makes the segment fully replicated again
    {healed, :ok} = Metadata.apply(metadata, {:set_segment_replicas, segment_id, new_set})
    assert SelfHealing.heal_sealed(healed, [a, b, d], 3).applied == []
  end

  test "a backfill cut short resumes where the new replica's copy ends instead of starting over" do
    # A pass fsyncs the first batch on d, then its next follow fails (d restarting, or a call that timed
    # out). Placement is deterministic, so the next pass picks d again; starting over at the segment's
    # base would be refused as out of sync on every pass, and the segment would never heal.
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])
    {:ok, 0} = ReplicationServer.follow(d, segment_id, 0, records(["x"]))

    result = SelfHealing.heal_sealed(metadata, [a, b, d], 3)

    assert result.failed == []
    assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
    assert d in new_set
    assert read_values(d, segment_id) == ["x", "y", "z"]
  end

  test "a new replica that already holds the whole segment is added without copying it again" do
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])
    {:ok, 2} = ReplicationServer.follow(d, segment_id, 0, records(["x", "y", "z"]))

    result = SelfHealing.heal_sealed(metadata, [a, b, d], 3)

    assert result.failed == []
    assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
    assert d in new_set
    assert read_values(d, segment_id) == ["x", "y", "z"]
  end

  test "a new replica that is not running fails the segment and adds nothing" do
    # Covers the probe's unreachable answer. The same outcome came from `follow/4` before the backfill
    # probed where the copy ends, so this pins the outcome rather than the probe.
    [a, b, c] = [start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])
    gone = {:no_such_replication_server, :"nonexistent@127.0.0.1"}

    result = SelfHealing.heal_sealed(metadata, [a, b, gone], 3)

    assert result.applied == []
    assert result.failed == [{segment_id, {:target, :unreachable}}]
  end

  test "a new replica whose copy failed in storage is reported with the storage reason, not as unreachable" do
    # A disk failure on a broker that answers is not a broker that is down: the reason is what the
    # operator reads in the heal warning. The copy is latched failed by an earlier pass, so the probe
    # of where it ends meets the failure first. Before that probe existed `follow/4` reported the same
    # reason, so this does not tell the probe from no probe: it guards the probe against folding a
    # storage failure into :unreachable, which is what the integrity pass's own probe does.
    [a, b, c] = [start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])

    dir_d = TmpDir.path("malachi_heal")
    on_exit(fn -> File.rm_rf!(dir_d) end)
    on_exit(fn -> FaultySegmentStore.clear(dir_d) end)
    FaultySegmentStore.fail(dir_d, :open, {:error, :eio})
    FaultySegmentStore.fail(dir_d, :recover, {:error, :eio})

    d =
      start_supervised!({ReplicationServer, directory: dir_d, store: FaultySegmentStore},
        id: {:repl, System.unique_integer([:positive])}
      )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:storage, _latched}} = ReplicationServer.follow(d, segment_id, 0, records(["x"]))

      result = SelfHealing.heal_sealed(metadata, [a, b, d], 3)

      assert result.applied == []
      assert [{^segment_id, {:target, {:storage, _reason}}}] = result.failed
    end)
  end

  test "a new replica holding more than the seal is added without a copy and left to be settled" do
    # An old primary that wrote a batch its quorum never acknowledged comes back one record past the
    # seal. The integrity pass settles it down to the sealed length once it is in the set.
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])
    {:ok, 3} = ReplicationServer.follow(d, segment_id, 0, records(["x", "y", "z", "w"]))

    result = SelfHealing.heal_sealed(metadata, [a, b, d], 3)

    assert result.failed == []
    assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
    assert d in new_set
  end

  test "a FENCED sealed segment still heals: the fence never blocks repair" do
    # `follow/4` is deliberately outside the fence, because re-replicating sealed segments is this
    # module's whole job. The bound is structural rather than a permission: a follow requires
    # `expected_first` to equal the target's current end, and its `to` comes from the sealed extent, so
    # a repair cannot hand out an offset above the sealed edge.
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])

    # Every holder fenced, the way the produce roll and failover both leave a closed segment.
    for replica <- [a, b, c] do
      assert {:ok, _end, _bytes} = ReplicationServer.seal(replica, segment_id, 0)
    end

    result = SelfHealing.heal_sealed(metadata, [a, b, d], 3)

    assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
    assert result.failed == []
    assert d in new_set
    assert read_values(d, segment_id) == ["x", "y", "z"]
  end

  test "the integrity probe fires for a segment sealed with the fence's byte size" do
    # Before the fence, a produce-path seal recorded the FRONTEND's byte tally, which
    # `adopt_active_segment/2` resets to zero, so `bytes < segment.byte_size` never fired for those
    # segments and a short copy went unnoticed. The fence answers `bytes_on_disk`, the same measure
    # `stored_bytes/3` reports, so the two sides finally compare like with like.
    {a, _dir_a, _id_a} = start_broker_with_directory()
    {b, dir_b, id_b} = start_broker_with_directory()

    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
    segment_id = {root, 0}
    {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b], 0})

    for replica <- [a, b] do
      {:ok, _last} = ReplicationServer.follow(replica, segment_id, 0, records(["x", "y", "z"]))
    end

    # The seal's numbers come from the fence, not from a tally beside it.
    {:ok, end_offset, byte_size} = ReplicationServer.seal(a, segment_id, 0)
    {:ok, ^end_offset, ^byte_size} = ReplicationServer.seal(b, segment_id, 0)
    seal = Metadata.seal_command(%{id: segment_id, start_offset: 0}, end_offset, byte_size, 0)
    {metadata, :ok} = Metadata.apply(metadata, seal)

    assert byte_size > 0

    # b loses its files while down and comes back short; the probe compares its stored bytes against
    # the fence's number and finally sees the shortfall.
    b = restart_broker_over(dir_b, id_b, fn -> File.rm_rf!(Layout.segment_directory(dir_b, segment_id)) end)
    metadata = rewrite_replicas(metadata, segment_id, [a, b])

    assert ReplicationServer.stored_bytes(b, segment_id) < byte_size

    result = SelfHealing.heal_sealed(metadata, [a, b], 2)
    assert result.repaired == [{segment_id, b}]
    assert read_values(b, segment_id) == ["x", "y", "z"]
  end

  test "re-replication is rack-aware when :spread is forwarded" do
    [a1, a2, b1, b2] = [start_broker(), start_broker(), start_broker(), start_broker()]
    dead = start_broker()
    attrs = %{a1 => %{"rack" => "a"}, a2 => %{"rack" => "a"}, b1 => %{"rack" => "b"}, b2 => %{"rack" => "b"}}

    # segment on [a1, dead]; dead has left, so it is under-replicated for rf 2
    {metadata, segment_id} = sealed_segment([a1, dead], a1, ["x", "y"])

    result = SelfHealing.heal_sealed(metadata, [a1, a2, b1, b2], 2, spread: {"rack", attrs})

    assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
    # with spread over two racks and rf 2, the healed set must span both racks (not concentrate in one)
    assert new_set |> Enum.map(&attrs[&1]["rack"]) |> Enum.sort() == ["a", "b"]
  end

  test "reports a segment whose every replica is dead as failed" do
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y"])

    # none of a, b, c is live, only d, which has no copy
    result = SelfHealing.heal_sealed(metadata, [d], 3)

    assert result.applied == []
    assert result.failed == [{segment_id, :no_live_source}]
    assert read_values(d, segment_id) == []
  end

  test "does nothing when every sealed segment is fully replicated" do
    [a, b, c] = [start_broker(), start_broker(), start_broker()]
    {metadata, segment_id} = sealed_segment([a, b, c], a, ["x"])

    result = SelfHealing.heal_sealed(metadata, [a, b, c], 3)

    assert %{applied: [], failed: [], repaired: []} = result

    # `sealed_segment/3` records a byte size of 0 while seeding real records on `a`, so the one copy
    # that holds anything reads as running past its segment's recorded size. That is the integrity
    # probe's other answer doing its job on a fixture that lies about the size, not a repair: nothing
    # is copied from this list, it is handed to `Malachi.Cluster.SealedOverrun` to settle.
    assert result.unsettled == [{segment_id, a}]
  end

  # Builds metadata with one sealed segment held by ALL of `replica_set` (each replica appended
  # durably via follow/4), sealed with the REAL byte size, the shape the physical integrity pass
  # probes against. Returns {metadata, segment_id, byte_size}.
  defp sealed_segment_everywhere(replica_set, values) do
    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
    segment_id = {root, 0}
    {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, replica_set, 0})

    for replica <- replica_set do
      {:ok, _last} = ReplicationServer.follow(replica, segment_id, 0, records(values))
    end

    byte_size = ReplicationServer.stored_bytes(hd(replica_set), segment_id)
    {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, length(values), byte_size, 0})
    {metadata, segment_id, byte_size}
  end

  # The chaos shape: the replica loses its file(s) while down and comes back over the damaged
  # directory. Restarting matters: a live server still holds the deleted file's descriptor (unix
  # keeps the data reachable through it), so loss only materializes at reopen.
  defp restart_broker_over(directory, id, damage_fun) do
    :ok = stop_supervised(id)
    damage_fun.()
    new_id = {:repl, System.unique_integer([:positive])}
    start_supervised!({ReplicationServer, directory: directory}, id: new_id)
  end

  test "re-backfills a live replica whose sealed copy was deleted (silent under-replication)" do
    {a, _dir_a, _id_a} = start_broker_with_directory()
    {b, _dir_b, _id_b} = start_broker_with_directory()
    {c, dir_c, id_c} = start_broker_with_directory()

    {metadata, segment_id, byte_size} = sealed_segment_everywhere([a, b, c], ["x", "y", "z"])

    c = restart_broker_over(dir_c, id_c, fn -> File.rm_rf!(Path.join(dir_c, "events-r0-s0")) end)
    metadata = rewrite_replicas(metadata, segment_id, [a, b, c])

    result = SelfHealing.heal_sealed(metadata, [a, b, c], 3)

    # no metadata change (the replica set is intact); the lost copy is rebuilt in place
    assert result == %{applied: [], failed: [], repaired: [{segment_id, c}], unsettled: []}
    assert ReplicationServer.stored_bytes(c, segment_id) == byte_size
    assert read_values(c, segment_id) == ["x", "y", "z"]

    # a second pass finds nothing to do
    assert SelfHealing.heal_sealed(metadata, [a, b, c], 3) ==
             %{applied: [], failed: [], repaired: [], unsettled: []}
  end

  test "repairs a truncated sealed copy from its truncation point, not by recopying" do
    {a, _dir_a, _id_a} = start_broker_with_directory()
    {b, _dir_b, _id_b} = start_broker_with_directory()
    {c, dir_c, id_c} = start_broker_with_directory()

    {metadata, segment_id, byte_size} = sealed_segment_everywhere([a, b, c], ["x", "y", "z"])

    # keep the first frame plus a partial second one: recovery must clamp to the last valid frame
    first_record = Record.new("x", key: "x")
    first_frame_bytes = byte_size(Record.encode(%Record{first_record | offset: 0}))
    [log_file] = SegmentFilesHelper.log_files(Path.join(dir_c, "events-r0-s0"))

    c =
      restart_broker_over(dir_c, id_c, fn ->
        truncated = binary_part(File.read!(log_file), 0, first_frame_bytes + 3)
        File.write!(log_file, truncated)
      end)

    metadata = rewrite_replicas(metadata, segment_id, [a, b, c])

    result = SelfHealing.heal_sealed(metadata, [a, b, c], 3)

    assert result == %{applied: [], failed: [], repaired: [{segment_id, c}], unsettled: []}
    assert ReplicationServer.stored_bytes(c, segment_id) == byte_size
    assert read_values(c, segment_id) == ["x", "y", "z"]
  end

  test "an unreachable replica is skipped by the integrity probe, never repaired on unknown state" do
    [a, b] = [start_broker(), start_broker()]

    # Waited for, not merely spawned. A pid that has not finished exiting yet is a plain process that
    # answers no call, so the probe would block for its full timeout and then exit with :timeout
    # instead of the :noproc this test is about: the same assertion, reached by a different path, two
    # seconds later, at random.
    dead = spawn(fn -> :ok end)
    reference = Process.monitor(dead)
    assert_receive {:DOWN, ^reference, :process, ^dead, _reason}

    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
    segment_id = {root, 0}
    {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, dead], 0})

    for replica <- [a, b] do
      {:ok, _last} = ReplicationServer.follow(replica, segment_id, 0, records(["x"]))
    end

    byte_size = ReplicationServer.stored_bytes(a, segment_id)
    {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 1, byte_size, 0})

    # the caller believes all three are live; the dead pid does not answer the probe and is skipped
    assert SelfHealing.heal_sealed(metadata, [a, b, dead], 3) ==
             %{applied: [], failed: [], repaired: [], unsettled: []}
  end

  # Replaces the sealed segment's replica set so the restarted replica's NEW ref takes the dead
  # ref's place, the same adjustment the control plane sees when a node rejoins under its name.
  defp rewrite_replicas(metadata, segment_id, replica_set) do
    {metadata, :ok} = Metadata.apply(metadata, {:set_segment_replicas, segment_id, replica_set})
    metadata
  end

  test "a replica whose copy failed in storage is skipped by the integrity probe, like one that does not answer" do
    {a, _dir_a, _id_a} = start_broker_with_directory()
    {b, _dir_b, _id_b} = start_broker_with_directory()
    {c, dir_c, id_c} = start_broker_with_directory()
    {metadata, segment_id, _byte_size} = sealed_segment_everywhere([a, b, c], ["x", "y", "z"])
    [log_file] = SegmentFilesHelper.log_files(Path.join(dir_c, "events-r0-s0"))

    # c comes back over a copy cut short, on a store whose recovery fails: short, so the probe wants to
    # repair it; unable to say where it ends, so a repair has nothing to start from. It must be skipped,
    # never "repaired" on a state nobody could read.
    :ok = stop_supervised(id_c)
    File.write!(log_file, binary_part(File.read!(log_file), 0, 3))
    on_exit(fn -> FaultySegmentStore.clear(dir_c) end)
    FaultySegmentStore.fail(dir_c, :recover, {:error, :eio})

    c =
      start_supervised!({ReplicationServer, directory: dir_c, store: FaultySegmentStore},
        id: {:repl, System.unique_integer([:positive])}
      )

    metadata = rewrite_replicas(metadata, segment_id, [a, b, c])

    ExUnit.CaptureLog.capture_log(fn ->
      assert SelfHealing.heal_sealed(metadata, [a, b, c], 3) ==
               %{applied: [], failed: [], repaired: [], unsettled: []}
    end)
  end

  describe "the integrity pass's sources" do
    test "leaves a segment with an unread latch out of the integrity repair" do
      [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "integrity-sources", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
      {:ok, _last} = ReplicationServer.replicate(a, segment_id, [a], 0, records(["x", "y", "z"]))

      # Sealed at the bytes a actually holds, so b and c, which hold nothing, are below the recorded size and need
      # repair. c has a latched copy, which sends the segment to the integrity probe.
      bytes = ReplicationServer.stored_bytes(a, segment_id)
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 3, bytes, 0})

      # a's latch was not read, so it is no source: the short copies have nothing to be repaired from.
      result =
        SelfHealing.heal_sealed(metadata, [a, b, c], 3,
          failed: MapSet.new([{segment_id, c}]),
          unknown_replicas: MapSet.new([{segment_id, a}])
        )

      assert result.repaired == []
      assert read_values(b, segment_id) == []
    end
  end

  describe "a membership backfill with an unread latch" do
    test "names the live source whose latch was not read, instead of saying no replica is live" do
      [a, d] = [start_broker(), start_broker()]
      b = dead_broker()
      c = dead_broker()
      {metadata, segment_id} = sealed_segment([a, b, c], a, ["x", "y", "z"])

      # a is the only live replica that holds the segment, and its latch was not read, so there is no usable source.
      result = SelfHealing.heal_sealed(metadata, [a, d], 3, unknown_replicas: MapSet.new([{segment_id, a}]))

      assert result.applied == []
      assert [{^segment_id, {:unread_latch_source, [^a]}}] = result.failed
    end
  end

  # A broker whose store can be made to fail, for latching a copy from the outside.
  defp start_faulty_broker do
    directory = TmpDir.path("malachi_heal_faulty")
    on_exit(fn -> FaultySegmentStore.clear(directory) end)
    id = {:repl, System.unique_integer([:positive])}
    {start_supervised!({ReplicationServer, directory: directory, store: FaultySegmentStore}, id: id), directory}
  end

  defp latch!(ref, directory, segment, base) do
    FaultySegmentStore.fail(Layout.segment_directory(directory, segment), :sync, {:error, :eio})

    ExUnit.CaptureLog.capture_log(fn ->
      assert ReplicationServer.replicate(ref, segment, [ref], base, records(["doomed"])) == {:error, {:storage, :eio}}
    end)
  end

  describe "a replica that latches after it was listed" do
    test "is not used as the source of a repair, and its error is not read as a size" do
      [a, c] = [start_broker(), start_broker()]
      {b, b_directory} = start_faulty_broker()
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "latched-probe", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
      {:ok, _last} = ReplicationServer.replicate(c, segment_id, [c], 0, records(["x", "y"]))
      bytes = ReplicationServer.stored_bytes(c, segment_id)
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, bytes, 0})

      # b latches on its own store, so the byte probe gets an error where a size was expected. a is empty, so it is
      # the copy to repair; the only usable source is c. An error read as a size would make b the first source.
      # b holds the same two records as c, so its bytes reach the recorded size; then it latches on a third.
      {:ok, _last} = ReplicationServer.replicate(b, segment_id, [b], 0, records(["x", "y"]))
      latch!(b, b_directory, segment_id, 2)
      result = SelfHealing.heal_sealed(metadata, [a, b, c], 3)

      assert {segment_id, a} in result.repaired
      assert read_values(a, segment_id) == ["x", "y"]
    end
  end

  describe "a membership backfill" do
    test "is not made from a replica whose latch was not read" do
      [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
      {metadata, segment_id} = sealed_segment([b, a, c], a, ["x", "y", "z"])
      {:ok, _last} = ReplicationServer.replicate(b, segment_id, [b], 0, records(["x", "y", "z"]))

      # c is not live, so the segment is under-replicated, and its copies on a and b are the only sources. Neither
      # latch could be read this tick, so the pass has no source and waits for a later tick.
      result =
        SelfHealing.heal_sealed(metadata, [a, b, d], 3,
          unknown_replicas: MapSet.new([{segment_id, a}, {segment_id, b}])
        )

      assert result.applied == []
      assert [{^segment_id, _reason}] = result.failed
      assert read_values(d, segment_id) == []
    end
  end

  describe "a sealed copy that failed in storage (:failed)" do
    test "is replaced on a spare broker, backfilled from a healthy copy, and left out of the new set" do
      [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
      {metadata, segment_id} = sealed_segment([b, a, c], a, ["x", "y", "z"])

      # Every broker is live: b is not gone, its copy of this one segment is.
      result = SelfHealing.heal_sealed(metadata, [a, b, c, d], 3, failed: MapSet.new([{segment_id, b}]))

      assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
      assert result.failed == []
      assert Enum.sort(new_set) == Enum.sort([a, c, d])
      assert read_values(d, segment_id) == ["x", "y", "z"]
    end

    test "with no spare broker it stays, behind the healthy replicas, and the segment is reported" do
      # Pure: nothing is backfilled when there is nowhere to put a copy, so atoms stand in for brokers.
      {metadata, segment_id} = sealed_metadata([:b, :a, :c])

      result = SelfHealing.heal_sealed(metadata, [:a, :b, :c], 3, failed: MapSet.new([{segment_id, :b}]))

      assert [{:set_segment_replicas, ^segment_id, new_set}] = result.applied
      assert Enum.sort(Enum.take(new_set, 2)) == [:a, :c]
      assert List.last(new_set) == :b
      assert result.failed == [{segment_id, {:no_spare_broker, [:b]}}]

      # Already at the tail, the next pass changes nothing and still reports it.
      {moved, :ok} = Metadata.apply(metadata, {:set_segment_replicas, segment_id, new_set})
      again = SelfHealing.heal_sealed(moved, [:a, :b, :c], 3, failed: MapSet.new([{segment_id, :b}]))
      assert again.applied == []
      assert again.failed == [{segment_id, {:no_spare_broker, [:b]}}]
    end

    test "a segment whose only live broker holds the failed copy has no source" do
      {metadata, segment_id} = sealed_metadata([:a])

      result = SelfHealing.heal_sealed(metadata, [:a], 1, failed: MapSet.new([{segment_id, :a}]))

      assert result == %{applied: [], failed: [{segment_id, :no_live_source}], repaired: [], unsettled: []}
    end

    # A latched copy must not hide a short copy on another replica from the integrity pass, and the latched
    # replica itself is not repaired, and its bytes are left untouched.
    test "a short copy is repaired from an intact peer even when another replica of the segment is latched" do
      [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})

      {:ok, _} = ReplicationServer.follow(a, segment_id, 0, records(["x", "y"]))
      {:ok, _} = ReplicationServer.follow(b, segment_id, 0, records(["x"]))
      {:ok, _} = ReplicationServer.follow(c, segment_id, 0, records(["x"]))
      byte_size = ReplicationServer.stored_bytes(a, segment_id)
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, byte_size, 0})

      result = SelfHealing.heal_sealed(metadata, [a, b, c], 3, failed: MapSet.new([{segment_id, c}]))

      assert result.repaired == [{segment_id, b}]
      assert read_values(b, segment_id) == ["x", "y"]
      assert read_values(c, segment_id) == ["x"]
    end

    # When the latch state of a segment could not be read this tick, the integrity pass leaves it alone rather
    # than probe a copy that may be latched. The next tick, with the state readable, repairs it.
    test "a segment whose latch state is unknown this tick is left out of the integrity pass" do
      [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
      {:ok, _} = ReplicationServer.follow(a, segment_id, 0, records(["x", "y"]))
      {:ok, _} = ReplicationServer.follow(b, segment_id, 0, records(["x"]))
      {:ok, _} = ReplicationServer.follow(c, segment_id, 0, records(["x", "y"]))
      byte_size = ReplicationServer.stored_bytes(a, segment_id)
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, byte_size, 0})

      skipped = SelfHealing.heal_sealed(metadata, [a, b, c], 3, unknown_replicas: MapSet.new([{segment_id, a}]))
      assert skipped.repaired == []
      assert read_values(b, segment_id) == ["x"]

      repaired = SelfHealing.heal_sealed(metadata, [a, b, c], 3)
      assert {segment_id, b} in repaired.repaired
      assert read_values(b, segment_id) == ["x", "y"]
    end

    # A replica that does not answer may still be intact, so the reason must not claim there is no intact copy.
    test "a short copy whose only intact peers do not answer is reported as unreachable sources" do
      [a, b, c] = [dead_broker(), dead_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
      {:ok, _} = ReplicationServer.follow(c, segment_id, 0, records(["x"]))
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, 1_000, 0})

      result = SelfHealing.heal_sealed(metadata, [a, b, c], 3)

      assert result.failed == [{segment_id, {:unreachable_sources, [a, b]}}]
    end

    test "a short copy with every replica answering and none intact is reported as no intact copy" do
      [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
      for replica <- [a, b, c], do: {:ok, _} = ReplicationServer.follow(replica, segment_id, 0, records(["x"]))
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, 1_000, 0})

      result = SelfHealing.heal_sealed(metadata, [a, b, c], 3)

      assert result.failed == [{segment_id, :no_intact_copy}]
    end

    # The latched replica is excluded from the probes, so it can never be the unreachable one.
    test "a latched replica is not reported among the unreachable sources" do
      # b is latched and dead: without the latch exclusion it would be probed, found unreachable, and listed.
      [a, b, c] = [dead_broker(), dead_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
      {:ok, _} = ReplicationServer.follow(c, segment_id, 0, records(["x"]))
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, 1_000, 0})

      result = SelfHealing.heal_sealed(metadata, [a, b, c], 3, failed: MapSet.new([{segment_id, b}]))

      assert {segment_id, {:unreachable_sources, [a]}} in result.failed
    end

    test "a failed copy of a broker outside the set, of an active segment or of an unknown one changes nothing" do
      {metadata, segment_id} = sealed_metadata([:a, :b, :c])
      {active, active_id} = active_metadata([:a, :b, :c])

      failed = MapSet.new([{segment_id, :d}, {{:unknown, 0}, :a}])
      assert SelfHealing.heal_sealed(metadata, [:a, :b, :c, :d], 3, failed: failed).applied == []

      failed_active = MapSet.new([{active_id, :a}])
      assert SelfHealing.heal_sealed(active, [:a, :b, :c, :d], 3, failed: failed_active).applied == []
    end
  end

  defp sealed_metadata(replica_set) do
    {metadata, segment_id} = active_metadata(replica_set)
    {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 3, 0, 0})
    {metadata, segment_id}
  end

  defp active_metadata(replica_set) do
    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
    segment_id = {root, 0}
    {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, replica_set, 0})
    {metadata, segment_id}
  end

  test "ignores active (unsealed) segments: those heal on the write path" do
    [a, b, c, d] = [start_broker(), start_broker(), start_broker(), start_broker()]
    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 4})
    segment_id = {root, 0}
    # active segment (no seal), under-replicated once c leaves
    {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, [a, b, c], 0})
    {:ok, _last} = ReplicationServer.replicate(a, segment_id, [a], 0, records(["x"]))

    assert SelfHealing.heal_sealed(metadata, [a, b, d], 3) == %{applied: [], failed: [], repaired: [], unsettled: []}
  end

  describe "the batched integrity probe" do
    # A replica on an older build, which does not know `stored_bytes_of/4`: it answers that call as the
    # catch-all of `Malachi.UnexpectedMessage` does and forwards everything else to a real replication server.
    defmodule OldReplica do
      @moduledoc false
      use GenServer

      def start_link(real), do: GenServer.start_link(__MODULE__, real)

      @impl true
      def init(real), do: {:ok, real}

      @impl true
      def handle_call({:stored_bytes_of, _segment_ids, _budget_ms}, _from, real),
        do: {:reply, {:error, :unknown_call}, real}

      def handle_call(message, _from, real), do: {:reply, GenServer.call(real, message, :infinity), real}

      @impl true
      def handle_cast(message, real) do
        GenServer.cast(real, message)
        {:noreply, real}
      end

      @impl true
      def handle_info(message, real) do
        send(real, message)
        {:noreply, real}
      end
    end

    # `count` sealed segments over `replica_set`, each written to `holders` only: a replica outside `holders`
    # holds nothing of it, which the probe measures as 0 bytes, a lost copy.
    defp sealed_segments(replica_set, holders, count) do
      {segment_ids, metadata} =
        Enum.map_reduce(1..count, Metadata.new(), fn i, metadata ->
          {metadata, {:ok, root}} = Metadata.apply(metadata, {:create_topic, "probe-#{i}", 1})
          segment_id = {root, 0}
          {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, replica_set, 0})
          for replica <- holders, do: {:ok, 1} = ReplicationServer.follow(replica, segment_id, 0, records(["x", "y"]))
          bytes = ReplicationServer.stored_bytes(hd(holders), segment_id)
          {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, bytes, 0})
          {segment_id, metadata}
        end)

      {metadata, segment_ids}
    end

    # Runs `fun` with every call `pids` receive traced, and answers its result and the `{pid, tag}` of each call.
    defp traced_calls(pids, fun) do
      for pid <- pids, do: 1 = :erlang.trace(pid, true, [:receive])
      result = fun.()

      for pid <- pids do
        :erlang.trace(pid, false, [:receive])
        ref = :erlang.trace_delivered(pid)
        assert_receive {:trace_delivered, ^pid, ^ref}
      end

      {result, collect_calls([])}
    end

    defp collect_calls(acc) do
      receive do
        {:trace, pid, :receive, {:"$gen_call", _from, message}} -> collect_calls([{pid, call_tag(message)} | acc])
        {:trace, _pid, :receive, _other} -> collect_calls(acc)
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp call_tag(message) when is_tuple(message), do: elem(message, 0)
    defp call_tag(message), do: message

    defp count(calls, pid, tag), do: Enum.count(calls, &(&1 == {pid, tag}))

    # Answers the real batched call, reporting each one to the test process.
    defp recording_probe(test) do
      fn replica, segment_ids ->
        send(test, {:asked, replica, segment_ids})
        ReplicationServer.stored_bytes_of(replica, segment_ids)
      end
    end

    defp asked do
      receive do
        {:asked, replica, segment_ids} -> [{replica, segment_ids} | asked()]
      after
        0 -> []
      end
    end

    test "asks each replica once per chunk, never once per segment" do
      replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, _segment_ids} = sealed_segments(replicas, replicas, 5)

      {result, calls} = traced_calls(replicas, fn -> SelfHealing.heal_sealed(metadata, replicas, 3, probe_chunk: 2) end)

      assert result == %{applied: [], failed: [], repaired: [], unsettled: []}
      # 5 segments in chunks of 2 is 3 calls per replica, where the per-segment probe made 5.
      for replica <- [a, b, c] do
        assert count(calls, replica, :stored_bytes_of) == 3
        assert count(calls, replica, :stored_bytes) == 0
      end

      # With the default chunk, one call per replica for the whole pass.
      {_result, calls} = traced_calls(replicas, fn -> SelfHealing.heal_sealed(metadata, replicas, 3) end)
      for replica <- [a, b, c], do: assert(count(calls, replica, :stored_bytes_of) == 1)
    end

    test "a replica too old for the batched call is asked one segment at a time, and its lost copies are repaired" do
      [a, b, real] = [start_broker(), start_broker(), start_broker()]
      {:ok, old} = OldReplica.start_link(real)
      on_exit(fn -> if Process.alive?(old), do: Process.exit(old, :kill) end)
      replicas = [a, b, old]
      {metadata, segment_ids} = sealed_segments(replicas, [a, b], 2)

      {result, calls} = traced_calls([a, b, old], fn -> SelfHealing.heal_sealed(metadata, replicas, 3) end)

      assert result.failed == []
      assert Enum.sort(result.repaired) == Enum.sort(for(id <- segment_ids, do: {id, old}))
      for segment_id <- segment_ids, do: assert(read_values(real, segment_id) == ["x", "y"])

      assert count(calls, old, :stored_bytes_of) == 1
      assert count(calls, old, :stored_bytes) == 2
      for replica <- [a, b], do: assert(count(calls, replica, :stored_bytes) == 0)
    end

    test "a replica that does not answer costs the pass one timeout, not one per segment" do
      [a, b] = [start_broker(), start_broker()]
      silent = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(silent, :kill) end)
      replicas = [a, b, silent]
      {metadata, _segment_ids} = sealed_segments(replicas, [a, b], 6)

      started = System.monotonic_time(:millisecond)

      {result, calls} =
        traced_calls([silent], fn -> SelfHealing.heal_sealed(metadata, replicas, 3, probe_chunk: 2) end)

      elapsed = System.monotonic_time(:millisecond) - started

      # The silent replica is skipped, never repaired, and its two other chunks are never sent.
      assert result == %{applied: [], failed: [], repaired: [], unsettled: []}
      assert count(calls, silent, :stored_bytes_of) == 1
      assert elapsed < 4_000, "the pass took #{elapsed} ms: more than one probe timeout for the silent replica"
    end

    # An older replica answers the batched call `{:error, :unknown_call}` and then `reply` to each per-segment
    # call, or exits after the first one when `reply` is `:exit`.
    defp old_replica(reply) do
      spawn(fn -> old_replica_loop(reply) end)
    end

    defp old_replica_loop(reply) do
      receive do
        {:"$gen_call", from, {:stored_bytes_of, _segment_ids, _budget_ms}} ->
          GenServer.reply(from, {:error, :unknown_call})
          old_replica_loop(reply)

        {:"$gen_call", _from, {:stored_bytes, _segment_id}} when reply == :exit ->
          exit(:shutdown)

        {:"$gen_call", from, {:stored_bytes, _segment_id}} ->
          GenServer.reply(from, reply)
          old_replica_loop(reply)
      end
    end

    test "an older replica whose per-segment answer is an error, or that exits, is unreachable and never repaired" do
      for reply <- [{:error, {:storage, :eio}}, :exit] do
        [a, b] = [start_broker(), start_broker()]
        old = old_replica(reply)
        on_exit(fn -> Process.exit(old, :kill) end)
        replicas = [a, b, old]
        {metadata, _segment_ids} = sealed_segments(replicas, [a, b], 2)

        assert SelfHealing.heal_sealed(metadata, replicas, 3) ==
                 %{applied: [], failed: [], repaired: [], unsettled: []}
      end
    end

    test "a chunk that fails leaves the rest of that replica unasked and unreachable" do
      replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, segment_ids} = sealed_segments(replicas, [a, b], 3)
      test = self()

      probe = fn
        ^c, segment_ids ->
          send(test, {:asked, c, segment_ids})
          {:error, :timeout}

        replica, segment_ids ->
          ReplicationServer.stored_bytes_of(replica, segment_ids)
      end

      result = SelfHealing.heal_sealed(metadata, replicas, 3, probe_chunk: 1, stored_bytes_of: probe)

      # c holds nothing, so a measurement would repair it; an unknown answer never does.
      assert result == %{applied: [], failed: [], repaired: [], unsettled: []}
      assert [{^c, [_one]}] = asked()
      for segment_id <- segment_ids, do: assert(read_values(c, segment_id) == [])
    end

    # A chunk that fails takes the later chunks of its replica with it, so the order is shuffled on every pass:
    # one copy that is always too slow to measure must not hide the same segments from every pass.
    test "a copy that always times out does not hide the same segments on every pass" do
      replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, [stuck | others]} = sealed_segments(replicas, replicas, 4)
      test = self()

      probe = fn
        ^c, segment_ids ->
          if stuck in segment_ids do
            {:error, :unreachable}
          else
            send(test, {:measured, segment_ids})
            ReplicationServer.stored_bytes_of(c, segment_ids)
          end

        replica, segment_ids ->
          ReplicationServer.stored_bytes_of(replica, segment_ids)
      end

      # With a fixed order, a segment queued behind the stuck one would never be measured. Shuffled, each is
      # behind it on half the passes, so 40 passes all miss one with probability 3 x 2^-40.
      for _pass <- 1..40, do: SelfHealing.heal_sealed(metadata, replicas, 3, probe_chunk: 1, stored_bytes_of: probe)

      measured = for {:measured, ids} <- drain_messages(), id <- ids, uniq: true, do: id
      assert Enum.sort(measured) == Enum.sort(others)
    end

    # The answers of the chunks a replica did answer survive a later chunk that fails.
    test "a chunk that fails keeps what the earlier chunks of its replica measured" do
      replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, segment_ids} = sealed_segments(replicas, [a, b], 2)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      probe = fn
        ^c, ids ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 -> ReplicationServer.stored_bytes_of(c, ids)
            _later -> {:error, :unreachable}
          end

        replica, ids ->
          ReplicationServer.stored_bytes_of(replica, ids)
      end

      result = SelfHealing.heal_sealed(metadata, replicas, 3, probe_chunk: 1, stored_bytes_of: probe)

      # c holds neither copy. The first chunk measured one of them as empty, and it is repaired; the second
      # chunk failed, so the other one is unknown this pass and left alone.
      assert [{repaired, ^c}] = result.repaired
      assert repaired in segment_ids
      assert result.failed == []
      assert read_values(c, repaired) == ["x", "y"]
      assert read_values(c, hd(segment_ids -- [repaired])) == []
    end

    test "a replica too old for the batched call is asked about every chunk one segment at a time" do
      [a, b, real] = [start_broker(), start_broker(), start_broker()]
      {:ok, old} = OldReplica.start_link(real)
      on_exit(fn -> if Process.alive?(old), do: Process.exit(old, :kill) end)
      replicas = [a, b, old]
      {metadata, segment_ids} = sealed_segments(replicas, [a, b], 2)

      {result, calls} =
        traced_calls([old], fn -> SelfHealing.heal_sealed(metadata, replicas, 3, probe_chunk: 1) end)

      # Two chunks: the first answers unknown_call, and BOTH segments are then asked one at a time.
      assert Enum.sort(result.repaired) == Enum.sort(for(id <- segment_ids, do: {id, old}))
      assert count(calls, old, :stored_bytes_of) == 1
      assert count(calls, old, :stored_bytes) == 2
    end

    defp drain_messages do
      receive do
        message -> [message | drain_messages()]
      after
        0 -> []
      end
    end

    test "a segment the answer leaves out, or could not measure, is unreachable and never repaired" do
      for answer_for_c <- [
            fn _segment_ids -> {:ok, %{}, []} end,
            fn segment_ids -> {:ok, Map.new(segment_ids, &{&1, {:error, {:storage, :eio}}}), []} end,
            fn segment_ids -> {:ok, Map.new(segment_ids, &{&1, -1}), []} end,
            # Hands every id back unmeasured: asked again it would never end, so it is given up for this pass.
            fn segment_ids -> {:ok, %{}, segment_ids} end,
            fn _segment_ids -> :garbage end
          ] do
        replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
        {metadata, [segment_id]} = sealed_segments(replicas, [a, b], 1)

        probe = fn
          ^c, segment_ids -> answer_for_c.(segment_ids)
          replica, segment_ids -> ReplicationServer.stored_bytes_of(replica, segment_ids)
        end

        assert SelfHealing.heal_sealed(metadata, replicas, 3, stored_bytes_of: probe) ==
                 %{applied: [], failed: [], repaired: [], unsettled: []}

        assert read_values(c, segment_id) == []
      end
    end

    # A replica whose budget runs out before the end of a chunk hands the rest back, and the pass asks again for it
    # at once: every copy is still measured on the pass, and the short ones repaired.
    test "the ids a spent budget hands back are asked again on the same pass" do
      replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, segment_ids} = sealed_segments(replicas, [a, b], 3)
      test = self()

      # c measures one id per call, as a server with no budget left would.
      probe = fn
        ^c, [first | rest] ->
          send(test, {:asked, c, [first | rest]})
          {:ok, %{first => ReplicationServer.stored_bytes(c, first)}, rest}

        replica, ids ->
          ReplicationServer.stored_bytes_of(replica, ids)
      end

      result = SelfHealing.heal_sealed(metadata, replicas, 3, stored_bytes_of: probe)

      assert Enum.sort(result.repaired) == Enum.sort(for(id <- segment_ids, do: {id, c}))
      assert result.failed == []
      assert length(asked()) == 3
    end

    test "a latched copy is left out of the batch" do
      replicas = [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, [latched, healthy]} = sealed_segments(replicas, replicas, 2)

      SelfHealing.heal_sealed(metadata, replicas, 3,
        failed: MapSet.new([{latched, c}]),
        stored_bytes_of: recording_probe(self())
      )

      asked = asked()
      assert [{^c, [^healthy]}] = Enum.filter(asked, &(elem(&1, 0) == c))
      for replica <- [a, b], do: assert([{^replica, _ids}] = Enum.filter(asked, &(elem(&1, 0) == replica)))
      for {replica, ids} <- asked, replica != c, do: assert(Enum.sort(ids) == Enum.sort([latched, healthy]))
    end

    test "a pass with no healthy sealed segment asks nobody" do
      [a, b, c] = [start_broker(), start_broker(), start_broker()]
      {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "active-only", 1})
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, {root, 0}, [a, b, c], 0})

      SelfHealing.heal_sealed(metadata, [a, b, c], 3, stored_bytes_of: recording_probe(self()))

      assert asked() == []
    end

    # The batched probe changes how many calls are made, never what is measured or decided: the same cluster,
    # asked in batches or one segment at a time, comes out of the pass the same way.
    test "the batched probe and the per-segment fallback reach the same result" do
      batched = equivalence_fixture() |> run_pass([]) |> by_position()

      per_segment =
        equivalence_fixture()
        |> run_pass(stored_bytes_of: fn _replica, _segment_ids -> {:error, :unknown_call} end)
        |> by_position()

      assert batched.repaired != []
      assert batched == per_segment
    end

    # Four segments over three replicas, each lost on a different replica, or on none for the last.
    defp equivalence_fixture do
      replicas = [start_broker(), start_broker(), start_broker()]

      {segment_ids, metadata} =
        Enum.map_reduce(0..3, Metadata.new(), fn i, metadata ->
          holders = List.delete_at(replicas, i)
          {metadata, [segment_id]} = sealed_segments_into(metadata, replicas, holders, "eq-#{i}")
          {segment_id, metadata}
        end)

      {metadata, replicas, segment_ids}
    end

    defp sealed_segments_into(metadata, replica_set, holders, topic) do
      {metadata, {:ok, root}} = Metadata.apply(metadata, {:create_topic, topic, 1})
      segment_id = {root, 0}
      {metadata, :ok} = Metadata.apply(metadata, {:register_segment, root, segment_id, replica_set, 0})
      for replica <- holders, do: {:ok, 1} = ReplicationServer.follow(replica, segment_id, 0, records(["x", "y"]))
      bytes = ReplicationServer.stored_bytes(hd(holders), segment_id)
      {metadata, :ok} = Metadata.apply(metadata, {:seal_segment, segment_id, 2, bytes, 0})
      {metadata, [segment_id]}
    end

    defp run_pass({metadata, replicas, _segment_ids}, opts) do
      {SelfHealing.heal_sealed(metadata, replicas, 3, opts), replicas}
    end

    # Each fixture has its own servers, so the results are compared with each replica named by its position.
    defp by_position({result, replicas}) do
      position = replicas |> Enum.with_index() |> Map.new()
      rename = fn {segment_id, replica} -> {segment_id, Map.get(position, replica, replica)} end
      %{result | repaired: Enum.sort(Enum.map(result.repaired, rename)), unsettled: Enum.map(result.unsettled, rename)}
    end
  end
end
