defmodule Malachi.Log.SegmentFilesTest do
  use ExUnit.Case, async: true

  alias Malachi.Log.SegmentFiles

  @moduletag :tmp_dir

  describe "id/1 and path/3" do
    test "the id is the base offset zero padded to 20 digits" do
      assert SegmentFiles.id(0) == "00000000000000000000"
      assert SegmentFiles.id(42) == "00000000000000000042"
      assert SegmentFiles.id(18_446_744_073_709_551_615) == "18446744073709551615"
    end

    test "every kind has its own extension next to the data file" do
      id = SegmentFiles.id(7)

      assert SegmentFiles.path("/d", id, :log) == "/d/#{id}.log"
      assert SegmentFiles.path("/d", id, :index) == "/d/#{id}.idx"
      assert SegmentFiles.path("/d", id, :seal_marker) == "/d/#{id}.sealed"
      assert SegmentFiles.path("/d", id, :manifest) == "/d/#{id}.manifest"
      assert SegmentFiles.path("/d", id, :manifest_cache) == "/d/#{id}.manifest.tmp"
      assert SegmentFiles.path("/d", id, :rewrite) == "/d/#{id}.log.rewrite"
      assert SegmentFiles.log_path("/d", 7) == "/d/#{id}.log"
    end

    test "the data file is removed last" do
      assert List.last(SegmentFiles.removal_order()) == :log

      assert Enum.sort(SegmentFiles.removal_order()) ==
               Enum.sort([:log, :index, :seal_marker, :manifest, :manifest_cache, :rewrite])
    end
  end

  describe "base_offset/1" do
    test "reads the offset of a data file name, with or without a directory" do
      assert SegmentFiles.base_offset("00000000000000000042.log") == {:ok, 42}
      assert SegmentFiles.base_offset("/some/dir/00000000000000000042.log") == {:ok, 42}
    end

    test "refuses every name that is not exactly 20 digits and .log" do
      for name <- [
            "42.log",
            "000000000000000000042.log",
            "0000000000000000004x.log",
            "00000000000000000042.idx",
            "00000000000000000042.log.rewrite",
            ".00000000000000000042.log",
            "foo.log",
            "00000000000000000042.LOG",
            ""
          ] do
        assert SegmentFiles.base_offset(name) == :error, name
      end
    end
  end

  describe "list/1 and log_paths/1" do
    test "lists the data files in offset order and ignores everything else", %{tmp_dir: dir} do
      for name <- [
            SegmentFiles.id(20) <> ".log",
            SegmentFiles.id(3) <> ".log",
            SegmentFiles.id(3) <> ".idx",
            SegmentFiles.id(3) <> ".log.rewrite",
            "foo.log",
            ".hidden.log",
            "SEALED"
          ] do
        File.write!(Path.join(dir, name), "")
      end

      assert SegmentFiles.list(dir) == {:ok, [3, 20]}
      assert SegmentFiles.log_paths(dir) == {:ok, [SegmentFiles.log_path(dir, 3), SegmentFiles.log_path(dir, 20)]}
    end

    test "a directory that does not exist, or a file in its place, holds no segments", %{tmp_dir: dir} do
      assert SegmentFiles.list(Path.join(dir, "absent")) == {:ok, []}

      file = Path.join(dir, "a-file")
      File.write!(file, "")
      assert SegmentFiles.list(Path.join(file, "below")) == {:ok, []}
    end

    @tag :unix_permissions
    test "a directory that cannot be read is an error, never an empty list", %{tmp_dir: dir} do
      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      File.write!(SegmentFiles.log_path(locked, 0), "")
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      case File.ls(locked) do
        {:error, reason} -> assert SegmentFiles.list(locked) == {:error, reason}
        # Running as root reads it anyway; the property under test cannot be produced.
        {:ok, _names} -> :ok
      end
    end
  end
end
