defmodule Malachi.Cluster.ReplicationServerBatchFormatTest do
  # The segment format travels with the write (#202): the primary creates the segment with the format it
  # was given, the push carries it to the followers, a catch-up copies it, and no copy is ever created in
  # the other format. The data directory's marker rises before the first byte of a batch segment.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.Catchup
  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Log.Frames
  alias Malachi.Log.Record
  alias Malachi.Log.SegmentFiles
  alias Malachi.Storage.FormatMarker
  alias Malachi.Storage.Layout
  alias Malachi.Test.SegmentFilesHelper
  alias Malachi.Test.TmpDir
  alias OpenTelemetry.Ctx

  @segment {{"events", 0}, 0}

  defp start_at(opts \\ []) do
    name = :"repl_batch_#{System.unique_integer([:positive])}"
    directory = TmpDir.path("malachi_repl_batch")
    on_exit(fn -> File.rm_rf!(directory) end)
    start_supervised!({ReplicationServer, [name: name, directory: directory] ++ opts}, id: name)
    {name, directory}
  end

  defp records(values), do: for(value <- values, do: Record.new(value, key: value))

  defp formats_on_disk(directory) do
    directory
    |> Layout.segment_directory(@segment)
    |> SegmentFilesHelper.log_files()
    |> Enum.map(&Frames.detect(File.read!(&1)))
  end

  defp read_values(ref, offset \\ 0) do
    case ReplicationServer.read(ref, @segment, offset, 100) do
      {:ok, records} -> Enum.map(records, & &1.value)
      :eof -> []
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "a batch segment is batch on the primary and on every follower the push reached" do
    [{p, pd}, {f1, f1d}, {f2, f2d}] = [start_at(), start_at(), start_at()]
    replica_set = [p, f1, f2]

    assert {:ok, 1} = ReplicationServer.replicate(p, @segment, replica_set, 0, records(~w(a b)), :batch)
    assert {:ok, 2} = ReplicationServer.replicate(p, @segment, replica_set, 0, records(~w(c)), :batch)

    for {ref, dir} <- [{p, pd}, {f1, f1d}, {f2, f2d}] do
      assert eventually(fn -> read_values(ref) == ~w(a b c) end)
      assert formats_on_disk(dir) == [:batch]
    end
  end

  test "a record segment pushes the shape every release applies, and stays record" do
    [{p, pd}, {f, fd}] = [start_at(), start_at()]
    assert {:ok, 0} = ReplicationServer.replicate(p, @segment, [p, f], 0, records(~w(a)))
    assert eventually(fn -> read_values(f) == ~w(a) end)
    assert formats_on_disk(pd) == [:record]
    assert formats_on_disk(fd) == [:record]
  end

  test "the asynchronous produce and the group-commit append carry the format too" do
    {p, pd} = start_at()
    :ok = ReplicationServer.replicate_async(p, @segment, [p], 0, records(~w(a)), self(), :t, :batch)
    assert_receive {:replicate_result, :t, {:ok, 0}}, 2_000
    assert formats_on_disk(pd) == [:batch]

    {q, qd} = start_at()
    assert {:ok, 0} = ReplicationServer.append(q, @segment, [q], 0, records(~w(a)), :batch)
    assert ReplicationServer.flush(q) == :ok
    assert formats_on_disk(qd) == [:batch]
  end

  test "a write in the other format than the copy holds fails the copy, never mixing formats" do
    {p, pd} = start_at()
    assert {:ok, 0} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a)), :batch)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:storage, {:format_mismatch, :batch, :record}}} =
               ReplicationServer.replicate(p, @segment, [p], 0, records(~w(b)), :record)
    end)

    assert formats_on_disk(pd) == [:batch]
  end

  test "a restarted server reads the format from the files, and a later write in it goes on", %{} do
    {p, pd} = start_at()
    assert {:ok, 1} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a b)), :batch)
    :ok = stop_supervised(p)

    start_supervised!({ReplicationServer, [name: p, directory: pd]}, id: {p, :again})
    assert read_values(p) == ~w(a b)
    assert {:ok, 2} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(c)), :batch)
    assert formats_on_disk(pd) == [:batch]
  end

  test "a catch-up copies a batch segment as a batch segment" do
    [{source, _sd}, {target, td}] = [start_at(), start_at()]
    assert {:ok, 2} = ReplicationServer.replicate(source, @segment, [source], 0, records(~w(a b c)), :batch)

    assert {:ok, 3} = Catchup.run(target, source, @segment, 0, 3, format: :batch)
    assert read_values(target) == ~w(a b c)
    assert formats_on_disk(td) == [:batch]
  end

  test "the data directory's marker rises before the first batch byte, and only for a batch segment" do
    marker_dir = TmpDir.path("malachi_marker")
    File.mkdir_p!(marker_dir)
    on_exit(fn -> File.rm_rf!(marker_dir) end)
    :ok = FormatMarker.enforce(marker_dir)

    {p, _pd} = start_at(format_marker_dir: marker_dir)
    assert {:ok, 0} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a)))
    assert {:ok, {:ok, %{format: 1}}} = FormatMarker.read(marker_dir)

    other = {{"events", 1}, 0}
    assert {:ok, 0} = ReplicationServer.replicate(p, other, [p], 0, records(~w(a)), :batch)
    assert {:ok, {:ok, %{format: 2}}} = FormatMarker.read(marker_dir)
  end

  test "a marker that cannot rise refuses the batch segment instead of writing it" do
    # No marker at all: the startup gate never ran on this directory, so nothing may be raised there.
    marker_dir = TmpDir.path("malachi_marker_absent")
    File.mkdir_p!(marker_dir)
    on_exit(fn -> File.rm_rf!(marker_dir) end)

    {p, pd} = start_at(format_marker_dir: marker_dir)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:storage, {:format_marker, :no_marker}}} =
               ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a)), :batch)
    end)

    assert formats_on_disk(pd) == []
  end

  test "a probe or a read that reaches a segment before its first write leaves the format to that write" do
    # What the node-fault and storage drills hit: the frontend's recovery probes a segment, opening its log
    # with no file and no format, and the first produce then writes a batch segment into it.
    {p, pd} = start_at()
    assert ReplicationServer.durable_end(p, @segment, 0) == 0
    assert ReplicationServer.read(p, @segment, 0, 10) == :eof

    assert {:ok, 1} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a b)), :batch)
    assert formats_on_disk(pd) == [:batch]

    # Decided now: a write in the other format fails the copy.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:storage, {:format_mismatch, :batch, :record}}} =
               ReplicationServer.replicate(p, @segment, [p], 0, records(~w(c)), :record)
    end)
  end

  test "a follower that missed a batch push catches up as batch, from the push's own trigger" do
    [{p, _pd}, {f, fd}] = [start_at(), start_at()]

    # The follower is not in the set for the first batch, so it holds nothing when the second arrives.
    assert {:ok, 1} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a b)), :batch)
    :ok = ReplicationServer.replicate_async(p, @segment, [p, f], 0, records(~w(c)), self(), :late, :batch)

    assert eventually(fn -> read_values(f) == ~w(a b c) end)
    assert formats_on_disk(fd) == [:batch]
  end

  describe "a segment whose newest file holds no frame yet" do
    # What a crash leaves when it lands between creating (and preallocating) a segment's file and its first
    # fsync. A read or a probe that reaches it first must not decide its format.
    defp blank_file!(directory, segment, base_offset, size) do
      dir = Layout.segment_directory(directory, segment)
      File.mkdir_p!(dir)
      File.write!(SegmentFiles.log_path(dir, base_offset), :binary.copy(<<0>>, size))
    end

    test "alone: a probe first, then the batch write decides, and nothing is latched" do
      {p, pd} = start_at()
      :ok = stop_supervised(p)
      blank_file!(pd, @segment, 0, 4096)
      start_supervised!({ReplicationServer, [name: p, directory: pd]}, id: {p, :restarted})

      assert ReplicationServer.durable_end(p, @segment, 0) == 0
      assert {:ok, 1} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a b)), :batch)
      assert read_values(p) == ~w(a b)
      assert formats_on_disk(pd) == [:batch]
    end

    test "after batch files: the log keeps their format, and reads of them still work" do
      {p, pd} = start_at()
      assert {:ok, 1} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(a b)), :batch)
      :ok = stop_supervised(p)
      blank_file!(pd, @segment, 2, 4096)
      start_supervised!({ReplicationServer, [name: p, directory: pd]}, id: {p, :restarted})

      assert read_values(p) == ~w(a b)
      assert {:ok, 2} = ReplicationServer.replicate(p, @segment, [p], 0, records(~w(c)), :batch)
      # A read answers one file at a time: the first holds a and b, the one written after the restart c.
      assert read_values(p) == ~w(a b)
      assert read_values(p, 2) == ~w(c)
      assert formats_on_disk(pd) == [:batch, :batch]
    end
  end

  describe "the shapes that cross nodes" do
    # The test process stands in for the node on the other side, so the exact tuple it receives is what a node
    # on another release would receive. A record segment's must be the shape every release before the batch
    # format sends and answers; only a batch segment's carries its format.
    defp stand_in do
      name = :"stand_in_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      {name, node()}
    end

    test "a record push keeps the seven-element shape, a batch push names its format" do
      {p, _pd} = start_at()
      follower = stand_in()

      :ok = ReplicationServer.replicate_async(p, @segment, [{p, node()}, follower], 0, records(~w(a)), self(), :r)
      assert_receive {:"$gen_cast", {:replica_append, @segment, 0, 0, [_], _committed, _source}}, 2_000

      other = {{"events", 1}, 0}
      :ok = ReplicationServer.replicate_async(p, other, [{p, node()}, follower], 0, records(~w(a)), self(), :b, :batch)
      assert_receive {:"$gen_cast", {:replica_append, ^other, 0, 0, [_], _committed, _source, :batch}}, 2_000
    end

    test "requests to a primary keep their shape for a record segment and name the format for a batch one" do
      primary = stand_in()

      :ok = ReplicationServer.replicate_async(primary, @segment, [primary], 0, records(~w(a)), self(), :t)
      assert_receive {:"$gen_cast", {:replicate_async, @segment, [_], 0, [_], {_pid, :t}, _ctx}}

      :ok = ReplicationServer.replicate_async(primary, @segment, [primary], 0, records(~w(a)), self(), :t, :batch)
      assert_receive {:"$gen_cast", {:replicate_async, @segment, [_], 0, [_], :batch, {_pid, :t}, _ctx}}

      for {format, call} <- [
            {:record, fn -> ReplicationServer.replicate(primary, @segment, [primary], 0, records(~w(a))) end},
            {:batch, fn -> ReplicationServer.replicate(primary, @segment, [primary], 0, records(~w(a)), :batch) end}
          ] do
        task = Task.async(call)
        assert_receive {:"$gen_call", from, request}
        GenServer.reply(from, {:ok, 0})
        assert Task.await(task) == {:ok, 0}

        case format do
          :record -> assert {:replicate, @segment, [_], 0, [_], _ctx} = request
          :batch -> assert {:replicate, @segment, [_], 0, [_], :batch, _ctx} = request
        end
      end

      for {format, call, shape} <- [
            {:record, fn -> ReplicationServer.append(primary, @segment, [primary], 0, records(~w(a))) end, 5},
            {:batch, fn -> ReplicationServer.append(primary, @segment, [primary], 0, records(~w(a)), :batch) end, 6},
            {:record, fn -> ReplicationServer.follow(primary, @segment, 0, records(~w(a))) end, 4},
            {:batch, fn -> ReplicationServer.follow(primary, @segment, 0, records(~w(a)), :batch) end, 5}
          ] do
        task = Task.async(call)
        assert_receive {:"$gen_call", from, request}
        GenServer.reply(from, {:ok, 0})
        Task.await(task)
        assert tuple_size(request) == shape, "#{format}: #{inspect(request)}"
        if format == :batch, do: assert(:batch in Tuple.to_list(request))
      end
    end

    test "a server takes a record segment's requests in the shape an older node sends them" do
      {p, pd} = start_at()
      ctx = Ctx.get_current()

      assert GenServer.call(p, {:replicate, @segment, [{p, node()}], 0, records(~w(a)), ctx}) == {:ok, 0}
      assert GenServer.call(p, {:append, @segment, [{p, node()}], 0, records(~w(b))}) == {:ok, 1}
      :ok = GenServer.cast(p, {:replicate_async, @segment, [{p, node()}], 0, records(~w(c)), {self(), :old}, ctx})
      assert_receive {:replicate_result, :old, {:ok, 2}}, 2_000
      assert ReplicationServer.flush(p) == :ok

      other = {{"events", 1}, 0}
      assert GenServer.call(p, {:follow, other, 0, records(~w(x))}) == {:ok, 0}
      assert formats_on_disk(pd) == [:record]
    end
  end
end
