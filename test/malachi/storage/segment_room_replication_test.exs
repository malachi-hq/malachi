defmodule Malachi.Storage.SegmentRoomReplicationTest do
  # What #283 changed for the replication server: a new segment no longer writes its whole preallocation on
  # the loop every other segment of the node waits on. It makes a bounded step of room on its first flush,
  # and the next steps as its writes reach them. Sizes, not timings: a timing would measure the disk of
  # whatever runs the suite.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Log.Record

  @moduletag :tmp_dir
  # Larger than one step (4MB), so a segment that wrote the whole region is told apart from one that made
  # one step of room.
  @region 16 * 1024 * 1024
  @step 4 * 1024 * 1024

  defp start_replication(directory) do
    name = :"segment_room_repl_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReplicationServer, directory: Path.join(directory, "log"), name: name, prealloc_bytes: @region},
      id: name
    )

    {name, node()}
  end

  # Each test writes one segment, so its only file is the one (segment directories are named by an encoding
  # of the id, see `Malachi.Storage.Layout`).
  defp segment_file(directory) do
    [path] = Path.wildcard(Path.join([directory, "log", "*", "*.log"]))
    path
  end

  test "a new segment makes one step of room on its first write, never the whole region", %{tmp_dir: directory} do
    ref = start_replication(directory)
    {:ok, _last} = ReplicationServer.replicate(ref, "seg_stepped", [ref], 0, [Record.new("v", key: "k")])

    size = File.stat!(segment_file(directory)).size
    assert size > 0 and size <= @step + 4096, "the segment wrote #{size} bytes of room"
    assert ReplicationServer.end_offset(ref, "seg_stepped", 1_000) == 1
  end
end
