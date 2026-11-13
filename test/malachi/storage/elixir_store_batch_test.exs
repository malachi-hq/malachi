defmodule Malachi.Storage.ElixirStoreBatchTest do
  # The batch format through the store: what the record format's suite proves record by record, proven
  # again where one frame holds many records. The torn-versus-rot cases are enumerated at every byte,
  # because recovery is the one place a wrong answer silently drops acknowledged data or keeps garbage.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Bitwise

  alias Malachi.BatchCodec
  alias Malachi.Log.BatchFrame
  alias Malachi.Log.Frames
  alias Malachi.Log.Record
  alias Malachi.Log.SegmentFiles
  alias Malachi.Storage.ElixirStore
  alias Malachi.Test.TmpDir

  @moduletag :tmp_dir
  @id "segment-0"

  defp rec(value, ts \\ 1), do: Record.new(value, key: "k-" <> value, timestamp: ts)

  defp open(directory, opts \\ []), do: ElixirStore.open(directory, @id, Keyword.put_new(opts, :format, :batch))

  defp path(directory), do: SegmentFiles.path(directory, @id, :log)

  defp append_sync(store, records) do
    {:ok, store, first, last} = ElixirStore.append(store, records)
    {:ok, store} = ElixirStore.sync(store)
    {store, first, last}
  end

  defp encoded_append_sync(store, records, codec) do
    validated = records |> Enum.map(&{&1, false}) |> BatchCodec.build(codec)
    {:ok, store, first, last} = ElixirStore.append_encoded(store, validated)
    {:ok, store} = ElixirStore.sync(store)
    {store, first, last}
  end

  # Three batches of 3, 1 and 4 records (offsets 0..7), the middle one zstd.
  defp seed_batches(directory, opts \\ []) do
    {:ok, store} = open(directory, opts)
    {store, 0, 2} = append_sync(store, [rec("a"), rec("b"), rec("c")])
    {store, 3, 3} = encoded_append_sync(store, [rec("d")], :zstd)
    {store, 4, 7} = append_sync(store, [rec("e"), rec("f"), rec("g"), rec("h")])
    store
  end

  defp values(records), do: Enum.map(records, & &1.value)

  defp frame_starts(binary), do: frame_starts(binary, 0, [])

  defp frame_starts(binary, position, acc) do
    case BatchFrame.split(binary) do
      {:ok, _header, size, rest} -> frame_starts(rest, position + size, [position | acc])
      _other -> Enum.reverse(acc)
    end
  end

  describe "writing and reading" do
    test "batches append at consecutive offsets and read back from any offset", %{tmp_dir: dir} do
      store = seed_batches(dir)

      assert ElixirStore.next_offset(store) == 8
      assert ElixirStore.format(store) == :batch
      all = ~w(a b c d e f g h)

      for start <- 0..7 do
        assert {:ok, records} = ElixirStore.read(store, start, 100)
        assert values(records) == Enum.drop(all, start)
        assert Enum.map(records, & &1.offset) == Enum.to_list(start..7)
      end

      assert {:ok, [%Record{offset: 5, value: "f"}, %Record{offset: 6}]} = ElixirStore.read(store, 5, 2)
      assert ElixirStore.read(store, 8, 1) == :eof
    end

    test "one frame per append, holding every record of the call", %{tmp_dir: dir} do
      store = seed_batches(dir)
      :ok = ElixirStore.close(store)

      assert length(frame_starts(File.read!(path(dir)))) == 3
    end

    test "logical bytes are the record frame's, and the stored bytes are the file's", %{tmp_dir: dir} do
      store = seed_batches(dir)
      records = for v <- ~w(a b c d e f g h), do: rec(v)
      logical = records |> Enum.map(&Record.encoded_size/1) |> Enum.sum()

      assert ElixirStore.logical_bytes(store) == logical
      assert ElixirStore.stored_bytes(store) == File.stat!(path(dir)).size
    end

    test "a record segment refuses an encoded batch, and an unknown format is refused at open", %{tmp_dir: dir} do
      {:ok, store} = ElixirStore.open(dir, @id, format: :record)
      validated = BatchCodec.build([{rec("a"), false}], :none)

      assert ElixirStore.append_encoded(store, validated) == {:error, {:wrong_format, :record}}
      assert ElixirStore.open(Path.join(dir, "x"), @id, format: :avro) == {:error, {:unknown_format, :avro}}
    end

    test "a sealed segment refuses an encoded batch", %{tmp_dir: dir} do
      {:ok, store} = dir |> seed_batches() |> ElixirStore.seal()
      validated = BatchCodec.build([{rec("z"), false}], :zstd)
      assert ElixirStore.append_encoded(store, validated) == {:error, :sealed}
    end

    test "a batch above the inflate bound is refused, never written", %{tmp_dir: dir} do
      {:ok, store} = open(dir)
      validated = BatchCodec.build([{rec(String.duplicate("x", 2048)), false}], :zstd)
      previous = Application.get_env(:malachi, :max_inflated_batch_bytes)
      Application.put_env(:malachi, :max_inflated_batch_bytes, 1024)

      try do
        assert ElixirStore.append_encoded(store, validated) == {:error, :batch_too_large}
      after
        if previous,
          do: Application.put_env(:malachi, :max_inflated_batch_bytes, previous),
          else: Application.delete_env(:malachi, :max_inflated_batch_bytes)
      end
    end

    test "records past the inflate bound in one call are cut into several batches", %{tmp_dir: dir} do
      previous = Application.get_env(:malachi, :max_inflated_batch_bytes)
      Application.put_env(:malachi, :max_inflated_batch_bytes, 600)

      try do
        {:ok, store} = open(dir)
        records = for i <- 1..20, do: rec(String.duplicate("v", 60) <> "#{i}")
        {store, 0, 19} = append_sync(store, records)
        :ok = ElixirStore.close(store)

        binary = File.read!(path(dir))
        assert length(frame_starts(binary)) > 1

        {:ok, store} = ElixirStore.recover(dir, @id, format: :batch)
        assert {:ok, got} = ElixirStore.read(store, 0, 100)
        assert values(got) == values(records)
      after
        if previous,
          do: Application.put_env(:malachi, :max_inflated_batch_bytes, previous),
          else: Application.delete_env(:malachi, :max_inflated_batch_bytes)
      end
    end

    test "lowering the inflate setting after larger batches were written leaves them readable", %{tmp_dir: dir} do
      {:ok, store} = open(dir)
      big = for i <- 1..20, do: rec(String.duplicate("v", 100) <> "#{i}")
      {store, 0, 19} = append_sync(store, big)
      :ok = ElixirStore.close(store)

      previous = Application.get_env(:malachi, :max_inflated_batch_bytes)
      Application.put_env(:malachi, :max_inflated_batch_bytes, 256)

      try do
        assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch)
        assert ElixirStore.integrity(store) == :ok
        assert {:ok, got} = ElixirStore.read(store, 0, 100)
        assert values(got) == values(big)
        :ok = ElixirStore.close(store)
        assert {:ok, %{records: 20}} = ElixirStore.verify(dir, @id, [])
      after
        if previous,
          do: Application.put_env(:malachi, :max_inflated_batch_bytes, previous),
          else: Application.delete_env(:malachi, :max_inflated_batch_bytes)
      end
    end

    test "a read inside a frame larger than the read window still returns the records", %{tmp_dir: dir} do
      {:ok, store} = open(dir)
      big = for i <- 1..40, do: rec(:crypto.strong_rand_bytes(10_000) <> "#{i}")
      {store, 0, 39} = append_sync(store, big)

      assert {:ok, [%Record{offset: 37}, %Record{offset: 38}]} = ElixirStore.read(store, 37, 2)
    end
  end

  describe "recovery" do
    test "a cleanly written segment recovers every count, byte and hash it had", %{tmp_dir: dir} do
      store = seed_batches(dir)
      logical = ElixirStore.logical_bytes(store)
      hash = ElixirStore.logical_hash(store)
      :ok = ElixirStore.close(store)

      assert {:ok, recovered} = ElixirStore.recover(dir, @id, format: :batch)
      assert ElixirStore.next_offset(recovered) == 8
      assert ElixirStore.logical_bytes(recovered) == logical
      assert ElixirStore.logical_hash(recovered) == hash
      assert ElixirStore.integrity(recovered) == :ok
      assert {:ok, records} = ElixirStore.read(recovered, 0, 100)
      assert values(records) == ~w(a b c d e f g h)
    end

    test "the logical hash is the CRC of the inflated entries of every batch", %{tmp_dir: dir} do
      store = seed_batches(dir)
      batches = [[rec("a"), rec("b"), rec("c")], [rec("d")], [rec("e"), rec("f"), rec("g"), rec("h")]]
      {inflated, _size} = batches |> List.flatten() |> Enum.map(&{&1, false}) |> BatchCodec.encode(:none)

      assert ElixirStore.logical_hash(store) == :erlang.crc32(inflated)
    end

    test "the reader takes the format from the file, and refuses a file of the other format", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()

      assert {:ok, store} = ElixirStore.recover(dir, @id, [])
      assert ElixirStore.format(store) == :batch
      :ok = ElixirStore.close(store)

      assert ElixirStore.recover(dir, @id, format: :record) == {:error, {:format_mismatch, :batch, :record}}
    end

    test "an empty segment registered as batch stays batch across a restart", %{tmp_dir: dir} do
      {:ok, store} = open(dir)
      :ok = ElixirStore.close(store)

      {:ok, store} = ElixirStore.recover(dir, @id, format: :batch)
      {store, 0, 0} = append_sync(store, [rec("a")])
      :ok = ElixirStore.close(store)

      assert Frames.detect(File.read!(path(dir))) == :batch
    end

    test "every cut inside the last batch is torn: discarded, and the batches before it kept", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()
      intact = File.read!(path(dir))
      last_start = intact |> frame_starts() |> List.last()

      for cut <- (last_start + 1)..(byte_size(intact) - 1) do
        File.write!(path(dir), binary_part(intact, 0, cut))

        assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch), "cut #{cut}"
        assert ElixirStore.next_offset(store) == 4, "cut #{cut}"
        assert %{reason: :incomplete} = ElixirStore.integrity(store)
        :ok = ElixirStore.close(store)
        assert File.stat!(path(dir)).size == last_start, "cut #{cut}"
      end
    end

    test "every cut inside the last batch of a preallocated segment is torn too", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()
      intact = File.read!(path(dir))
      last_start = intact |> frame_starts() |> List.last()
      room = byte_size(intact) + 4096

      # A cut whose missing bytes are all zeros (the frame's last fields can be) completes the frame
      # exactly as written, which is a whole frame rather than a torn one.
      cuts =
        for cut <- (last_start + 1)..(byte_size(intact) - 1),
            binary_part(intact, cut, byte_size(intact) - cut) != :binary.copy(<<0>>, byte_size(intact) - cut),
            do: cut

      assert length(cuts) > byte_size(intact) - last_start - 8

      for cut <- cuts do
        torn = binary_part(intact, 0, cut)
        File.write!(path(dir), torn <> :binary.copy(<<0>>, room - cut))

        assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch, prealloc_bytes: room), "cut #{cut}"
        assert ElixirStore.next_offset(store) == 4, "cut #{cut}"
        assert %{reason: :incomplete} = ElixirStore.integrity(store), "cut #{cut}"
        {store, 4, 4} = append_sync(store, [rec("again")])
        :ok = ElixirStore.close(store)

        {:ok, again} = ElixirStore.recover(dir, @id, format: :batch)
        assert {:ok, records} = ElixirStore.read(again, 0, 100)
        assert values(records) == ~w(a b c d again), "cut #{cut}"
        :ok = ElixirStore.close(again)
      end
    end

    test "every bit flip in a batch's covered bytes is rot: preserved, never discarded", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()
      intact = File.read!(path(dir))
      [_first, second, third] = frame_starts(intact)

      # The middle batch, so valid batches follow the damage; every bit outside its base offset field.
      for bit <- ((second + 10) * 8)..(third * 8 - 1) do
        byte = div(bit, 8)
        <<head::binary-size(byte), b::8, tail::binary>> = intact
        File.write!(path(dir), <<head::binary, bxor(b, 1 <<< rem(bit, 8))::8, tail::binary>>)

        assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch), "bit #{bit}"
        assert ElixirStore.next_offset(store) == 3, "bit #{bit}"
        assert %{position: ^second} = ElixirStore.integrity(store)
        refute ElixirStore.integrity(store).reason == :incomplete, "bit #{bit}"
        assert ElixirStore.append(store, [rec("x")]) == {:error, :damaged_tail}
        :ok = ElixirStore.close(store)
        assert File.read!(path(dir)) |> byte_size() == byte_size(intact), "bit #{bit}"
      end
    end

    test "a base offset flipped outside the CRC is caught by contiguity, in recover and verify", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()
      intact = File.read!(path(dir))
      [_first, second, _third] = frame_starts(intact)

      for bit <- 0..63 do
        position = second + 2 + div(63 - bit, 8)
        <<head::binary-size(position), b::8, tail::binary>> = intact
        File.write!(path(dir), <<head::binary, bxor(b, 1 <<< rem(bit, 8))::8, tail::binary>>)

        assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch)
        assert %{reason: :bad_offset, position: ^second} = ElixirStore.integrity(store)
        :ok = ElixirStore.close(store)

        assert {:error, %{reason: :bad_offset, position: ^second}} = ElixirStore.verify(dir, @id, format: :batch)
      end
    end

    test "the first batch must start at the segment's base offset", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()

      assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch, base_offset: 1)
      assert %{reason: :bad_offset, position: 0} = ElixirStore.integrity(store)
      :ok = ElixirStore.close(store)
    end
  end

  describe "verify/3 and the index" do
    test "an intact batch segment verifies with its counts, logical numbers and format", %{tmp_dir: dir} do
      store = seed_batches(dir, index_interval: 1)
      logical = ElixirStore.logical_bytes(store)
      hash = ElixirStore.logical_hash(store)
      {:ok, store} = ElixirStore.seal(store)
      size = File.stat!(path(dir)).size
      :ok = ElixirStore.close(store)

      assert ElixirStore.verify(dir, @id, []) ==
               {:ok, %{records: 8, bytes: size, logical_bytes: logical, logical_hash: hash, format: :batch}}
    end

    test "index entries point at batch starts, and a stale one is caught", %{tmp_dir: dir} do
      store = seed_batches(dir, index_interval: 1)
      {:ok, store} = ElixirStore.seal(store)
      :ok = ElixirStore.close(store)
      index_path = SegmentFiles.path(dir, @id, :index)
      starts = frame_starts(File.read!(path(dir)))

      assert File.read!(index_path) ==
               for({offset, position} <- Enum.zip([0, 3, 4], starts), into: <<>>, do: <<offset::64, position::64>>)

      # An entry for a record inside a batch names an offset no frame starts with.
      File.write!(index_path, <<1::64, hd(starts)::64>>)
      assert {:error, %{reason: :bad_index}} = ElixirStore.verify(dir, @id, [])
      assert ElixirStore.rebuild_index(dir, @id, []) == :ok
      assert {:ok, %{records: 8}} = ElixirStore.verify(dir, @id, [])
    end

    test "a sealed segment reads back through open_read with its index", %{tmp_dir: dir} do
      store = seed_batches(dir, index_interval: 1)
      {:ok, store} = ElixirStore.seal(store)
      :ok = ElixirStore.close(store)

      assert {:ok, reader} = ElixirStore.open_read(dir, @id, record_count: 8)
      assert ElixirStore.format(reader) == :batch
      assert {:ok, [%Record{offset: 6, value: "g"}, %Record{offset: 7}]} = ElixirStore.read(reader, 6, 5)
      :ok = ElixirStore.close(reader)

      assert ElixirStore.open_read(dir, @id, record_count: 8, format: :record) ==
               {:error, {:format_mismatch, :batch, :record}}
    end
  end

  describe "truncate_to/2" do
    test "a cut at every offset keeps exactly the records below it, on disk and after a restart", %{tmp_dir: dir} do
      all = ~w(a b c d e f g h)

      for keep <- 0..8 do
        sub = Path.join(dir, "keep-#{keep}")
        store = seed_batches(sub)
        assert {:ok, store} = ElixirStore.truncate_to(store, keep)
        assert ElixirStore.next_offset(store) == keep

        expected_logical = all |> Enum.take(keep) |> Enum.map(&Record.encoded_size(rec(&1))) |> Enum.sum()
        assert ElixirStore.logical_bytes(store) == expected_logical
        hash = ElixirStore.logical_hash(store)

        if keep > 0 do
          assert {:ok, got} = ElixirStore.read(store, 0, 100)
          assert values(got) == Enum.take(all, keep)
        end

        {store, ^keep, ^keep} = append_sync(store, [rec("next")])
        :ok = ElixirStore.close(store)

        {:ok, again} = ElixirStore.recover(sub, @id, format: :batch)
        assert ElixirStore.integrity(again) == :ok
        assert {:ok, got} = ElixirStore.read(again, 0, 100)
        assert values(got) == Enum.take(all, keep) ++ ["next"], "keep #{keep}"
        :ok = ElixirStore.close(again)
        refute File.exists?(SegmentFiles.path(sub, @id, :rewrite))

        # The hash after the cut is that of the kept records alone.
        {:ok, fresh} = ElixirStore.open(Path.join(sub, "fresh"), @id, format: :batch)

        fresh =
          if keep > 0 do
            {fresh, 0, _} = append_sync(fresh, Enum.map(Enum.take(all, keep), &rec/1))
            fresh
          else
            fresh
          end

        # Batch boundaries do not enter the hash: the kept records hash the same however they were batched.
        assert ElixirStore.logical_hash(fresh) == hash
        :ok = ElixirStore.close(fresh)
      end
    end

    test "a cut inside a zstd batch keeps its codec", %{tmp_dir: dir} do
      {:ok, store} = open(dir)
      {store, 0, 3} = encoded_append_sync(store, [rec("a"), rec("b"), rec("c"), rec("d")], :zstd)
      {:ok, store} = ElixirStore.truncate_to(store, 2)
      :ok = ElixirStore.close(store)

      assert {:ok, %{codec: :zstd, count: 2}, _size, <<>>} = BatchFrame.split(File.read!(path(dir)))
    end

    test "a rewrite the process died in leaves the old segment, and the orphan is removed", %{tmp_dir: dir} do
      :ok = dir |> seed_batches() |> ElixirStore.close()
      intact = File.read!(path(dir))
      orphan = SegmentFiles.path(dir, @id, :rewrite)
      File.write!(orphan, binary_part(intact, 0, 30))

      assert {:ok, store} = ElixirStore.recover(dir, @id, format: :batch)
      refute File.exists?(orphan)
      assert ElixirStore.next_offset(store) == 8
      assert File.read!(path(dir)) == intact
      :ok = ElixirStore.close(store)
    end

    test "a rewrite that cannot create its file leaves the segment untouched", %{tmp_dir: dir} do
      store = seed_batches(dir)
      intact = File.read!(path(dir))
      # A directory where the temporary file would go makes the exclusive create fail.
      File.mkdir_p!(SegmentFiles.path(dir, @id, :rewrite))

      assert {:error, _reason} = ElixirStore.truncate_to(store, 1)
      assert File.read!(path(dir)) == intact
    end
  end

  property "append in any chunking, restart, and every offset reads back the same, either format" do
    check all(
            values <- list_of(string(:alphanumeric, max_length: 20), min_length: 1, max_length: 40),
            chunk <- integer(1..9),
            codec <- member_of([:none, :zstd]),
            format <- member_of([:record, :batch]),
            max_runs: 40
          ) do
      dir = TmpDir.path("batch_prop")
      File.rm_rf!(dir)
      records = Enum.map(values, &rec/1)
      {:ok, store} = ElixirStore.open(dir, @id, format: format, index_interval: 32)

      store =
        records
        |> Enum.chunk_every(chunk)
        |> Enum.reduce(store, fn part, acc ->
          if format == :batch and codec == :zstd do
            {acc, _, _} = encoded_append_sync(acc, part, :zstd)
            acc
          else
            {acc, _, _} = append_sync(acc, part)
            acc
          end
        end)

      logical = ElixirStore.logical_bytes(store)
      hash = ElixirStore.logical_hash(store)
      assert logical == records |> Enum.map(&Record.encoded_size/1) |> Enum.sum()
      :ok = ElixirStore.close(store)

      {:ok, store} = ElixirStore.recover(dir, @id, format: format, index_interval: 32)
      assert ElixirStore.logical_bytes(store) == logical
      assert ElixirStore.logical_hash(store) == hash
      n = length(records)

      for start <- 0..(n - 1) do
        {:ok, got} = ElixirStore.read(store, start, n)
        assert values(got) == Enum.drop(values, start)
      end

      :ok = ElixirStore.close(store)
      File.rm_rf!(dir)
    end
  end
end
