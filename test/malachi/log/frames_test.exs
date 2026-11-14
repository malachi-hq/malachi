defmodule Malachi.Log.FramesTest do
  use ExUnit.Case, async: true

  alias Malachi.BatchCodec
  alias Malachi.Log.BatchFrame
  alias Malachi.Log.Frames
  alias Malachi.Log.Record

  defp record_frame(value, offset), do: Record.encode(%{Record.new(value, timestamp: 1) | offset: offset})

  defp batch_frame(values, base) do
    values |> Enum.map(&{Record.new(&1, timestamp: 1), false}) |> BatchCodec.build(:zstd) |> BatchFrame.encode(base)
  end

  test "formats and detection" do
    assert Frames.formats() == [:record, :batch]
    assert Frames.detect(record_frame("a", 0)) == :record
    assert Frames.detect(batch_frame(["a"], 0)) == :batch
    assert Frames.detect(<<>>) == nil
    assert Frames.detect(<<0, 0, 1>>) == nil
  end

  test "a summary is the same shape in either format, and chains into one hash" do
    {:ok, r, rsize, <<>>} = Frames.summarize_one(:record, record_frame("a", 5))
    assert %{base_offset: 5, count: 1, logical_bytes: ^rsize} = r

    {:ok, b, _size, <<>>} = Frames.summarize_one(:batch, batch_frame(~w(a b), 9))
    assert %{base_offset: 9, count: 2} = b
    assert b.logical_bytes == Enum.sum(for v <- ~w(a b), do: Record.encoded_size(Record.new(v, timestamp: 1)))

    assert Frames.summarize_one(:batch, <<>>) == :incomplete
    assert Frames.summarize_one(:record, :binary.copy(<<0>>, 20)) == :blank
    assert Frames.chain(Frames.empty_hash(), b) == b.crc
  end

  test "decode_all reads every whole frame and stops at the first that is not one" do
    two = batch_frame(~w(a b), 0) <> batch_frame(~w(c), 2)
    {records, consumed} = Frames.decode_all(:batch, two <> <<0x4D>>)
    assert Enum.map(records, &{&1.offset, &1.value}) == [{0, "a"}, {1, "b"}, {2, "c"}]
    assert consumed == byte_size(two)

    {records, consumed} = Frames.decode_all(:record, record_frame("x", 3) <> <<1, 2>>)
    assert [%Record{offset: 3, value: "x"}] = records
    assert consumed == byte_size(record_frame("x", 3))
  end

  test "a batch whose entries disagree with its header stops a read there" do
    {:ok, header, _size, <<>>} = BatchFrame.split(batch_frame(~w(a), 0))
    # Re-frame the same payload with a header that claims another logical size, with a valid CRC.
    bad = %BatchCodec.Validated{
      codec: header.codec,
      count: header.count,
      inflated_size: header.inflated_size,
      payload: header.payload,
      first_timestamp: header.first_timestamp,
      max_timestamp: header.max_timestamp,
      logical_bytes: header.logical_bytes + 1,
      entries_crc: header.entries_crc
    }

    frame = BatchFrame.encode(bad, 0)
    assert Frames.decode_all(:batch, frame) == {[], 0}
    assert Frames.batch_entries(frame) == {:error, :bad_entries}
    assert {:ok, _header, [{%Record{value: "a"}, false}]} = Frames.batch_entries(batch_frame(~w(a), 0))
    assert Frames.batch_entries(<<>>) == :incomplete
  end

  test "claimed sizes, for whole frames and for writes cut in their header" do
    record = record_frame("a", 0)
    batch = batch_frame(~w(a), 0)

    assert Frames.claimed_size(record) == byte_size(record)
    assert Frames.claimed_size(batch) == byte_size(batch)
    assert Frames.claimed_size(batch, byte_size(batch)) == byte_size(batch)
    assert Frames.claimed_size(<<0x4D, 0, 0>>, 1) == 2
    assert Frames.claimed_size(record, 4) == 10
    assert Frames.claimed_size(batch, 9) == 18
    assert Frames.claimed_size(<<1, 2, 3>>) == 0
  end

  test "first_offset reads either header without checking it" do
    assert Frames.first_offset(record_frame("a", 42)) == 42
    assert Frames.first_offset(batch_frame(~w(a), 7)) == 7
    assert Frames.first_offset(<<>>) == nil
  end
end
