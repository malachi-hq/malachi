defmodule Malachi.Log.BatchFrameTest do
  # The frame is what recovery, verify and the scrubber trust about a stored batch, so every way it can be
  # damaged is enumerated here: every cut, every bit, every field that sits outside the CRC.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Malachi.BatchCodec
  alias Malachi.Log.BatchFrame
  alias Malachi.Log.Record

  @header 18

  defp record_gen do
    gen all(
          value <- binary(max_length: 48),
          key <- one_of([constant(nil), binary(max_length: 8)]),
          headers <- list_of({binary(max_length: 4), binary(max_length: 4)}, max_length: 2),
          timestamp <- integer(0..4_000_000_000_000)
        ) do
      %Record{value: value, key: key, headers: headers, timestamp: timestamp}
    end
  end

  defp entries_gen, do: list_of(tuple({record_gen(), boolean()}), min_length: 1, max_length: 12)

  defp frame(entries, codec, base), do: entries |> BatchCodec.build(codec) |> BatchFrame.encode(base)

  defp small_frame(codec \\ :zstd, base \\ 100) do
    frame([{Record.new("alpha", key: "k", timestamp: 1), false}, {Record.new("beta", timestamp: 2), true}], codec, base)
  end

  defp flip(binary, bit) do
    byte = div(bit, 8)
    <<head::binary-size(byte), b::8, tail::binary>> = binary
    <<head::binary, bxor(b, 1 <<< rem(bit, 8))::8, tail::binary>>
  end

  property "split then entries returns every record with its offset, for every codec" do
    check all(
            entries <- entries_gen(),
            codec <- member_of(BatchCodec.codecs()),
            base <- integer(0..1_000_000_000_000)
          ) do
      frame = frame(entries, codec, base)
      assert {:ok, header, size, "rest"} = BatchFrame.split(frame <> "rest")
      assert size == byte_size(frame)
      assert header.base_offset == base
      assert header.count == length(entries)
      assert BatchFrame.end_offset(header) == base + length(entries)

      expected = entries |> Enum.with_index(base) |> Enum.map(fn {{%Record{} = r, t}, o} -> {%{r | offset: o}, t} end)
      assert BatchFrame.entries(header) == {:ok, expected}
      assert BatchFrame.records(header) == {:ok, Enum.map(expected, &elem(&1, 0))}
    end
  end

  property "stamping a base offset never changes the CRC, and the stamped frame reads at the new offset" do
    check all(
            entries <- entries_gen(),
            codec <- member_of(BatchCodec.codecs()),
            from <- integer(0..1_000_000),
            to <- integer(0..1_000_000_000)
          ) do
      original = frame(entries, codec, from)
      stamped = BatchFrame.stamp(original, to)

      <<_::binary-size(10), tail::binary>> = original
      assert <<_::binary-size(10), ^tail::binary>> = stamped
      assert stamped == frame(entries, codec, to)
      assert {:ok, %{base_offset: ^to}, _size, <<>>} = BatchFrame.split(stamped)
    end
  end

  property "any single-bit flip in the CRC-covered region is caught" do
    check all(
            entries <- entries_gen(),
            codec <- member_of(BatchCodec.codecs()),
            seed <- integer(0..1_000_000)
          ) do
      frame = frame(entries, codec, 7)
      # From the CRC field to the end: everything but the magic and the base offset.
      covered_bits = (byte_size(frame) - 10) * 8
      bit = 80 + rem(seed, covered_bits)
      refute match?({:ok, _header, _size, _rest}, BatchFrame.split(flip(frame, bit)))
    end
  end

  test "every single-bit flip of a small frame outside the base offset is caught, each codec" do
    for codec <- BatchCodec.codecs() do
      frame = small_frame(codec)

      for bit <- 0..(byte_size(frame) * 8 - 1), bit not in 16..79 do
        refute match?({:ok, _header, _size, _rest}, BatchFrame.split(flip(frame, bit))), "#{codec} bit #{bit}"
      end
    end
  end

  test "a flip in the base offset is invisible to the frame: the store's contiguity check is what catches it" do
    frame = small_frame(:none, 100)
    assert {:ok, %{base_offset: other}, _size, <<>>} = BatchFrame.split(flip(frame, 16 + 63))
    assert other != 100
  end

  test "every cut of a frame reads as incomplete, never as damage or a frame" do
    for codec <- BatchCodec.codecs() do
      frame = small_frame(codec)

      for cut <- 0..(byte_size(frame) - 1) do
        assert BatchFrame.split(binary_part(frame, 0, cut)) == :incomplete, "#{codec} cut at #{cut}"
      end
    end
  end

  test "every cut followed by zeros claims the whole frame, so the zeros start inside it" do
    frame = small_frame()

    for cut <- @header..(byte_size(frame) - 1) do
      torn = binary_part(frame, 0, cut) <> :binary.copy(<<0>>, byte_size(frame))
      assert BatchFrame.claimed_size(torn) == byte_size(frame)
      refute match?({:ok, _header, _size, _rest}, BatchFrame.split(torn))
    end
  end

  test "zeros are blank space, but written bytes after a zero magic are damage" do
    assert BatchFrame.split(:binary.copy(<<0>>, 64)) == :blank
    assert BatchFrame.split(:binary.copy(<<0>>, 5)) == :blank
    assert BatchFrame.split(<<0>>) == :blank
    assert BatchFrame.split(<<0, 0, 0, 1>>) == {:error, :bad_magic}
    assert BatchFrame.split(<<0, 0>> <> :binary.copy(<<1>>, 30)) == {:error, :bad_magic}
    assert BatchFrame.split(<<0x4D51::16>> <> :binary.copy(<<1>>, 30)) == {:error, :bad_magic}
    assert BatchFrame.split(<<>>) == :incomplete
  end

  test "a length past the largest frame is damage, never a write to wait for" do
    huge = BatchFrame.max_frame_size(1024)
    header = <<BatchFrame.magic()::16, 0::64, 0::32, huge::32>>

    assert BatchFrame.split(header, huge) == {:error, :batch_too_large}
    assert BatchFrame.claimed_size(header, 0, huge) == 0
    assert BatchFrame.claimed_size(<<0x4D51::16, 0::64, 0::32, 64::32>>) == 0
    assert BatchFrame.claimed_size(<<BatchFrame.magic()::16, 0::64>>) == 0
  end

  test "a length that disagrees with the covered payload size is damage, even before the body is whole" do
    frame = small_frame()
    <<head::binary-size(14), length::32, tail::binary>> = frame

    for other <- [length + 1, length + 1000, length - 1] do
      mangled = <<head::binary, other::32, tail::binary>>
      assert BatchFrame.split(mangled) == {:error, :bad_length}
      # Its size field written, the length is known to be wrong: no claim recovery could call torn.
      assert BatchFrame.claimed_size(mangled, byte_size(mangled)) == 0
      # Without proof the size field was written, the length is all there is.
      assert BatchFrame.claimed_size(mangled, 18 + 43) == 18 + other
      # Cut to the bytes that hold `size`: still known to be damage, not a write to wait for.
      assert BatchFrame.split(binary_part(mangled, 0, 18 + 44)) == {:error, :bad_length}
    end
  end

  test "a length below the fixed fields is damage" do
    assert BatchFrame.split(<<BatchFrame.magic()::16, 0::64, 0::32, 10::32, 0::80>>) == {:error, :bad_length}
  end

  test "an unknown version, a set attribute, a wrong payload size, no records or an unknown codec are refused" do
    body = fn version, attrs, code, count, size_delta ->
      payload = "xyz"

      b =
        <<version::8, attrs::16, code::8, count::32, 0::64, 0::64, 3::32, 0::64, 0::32,
          byte_size(payload) + size_delta::32, payload::binary>>

      <<BatchFrame.magic()::16, 0::64, :erlang.crc32(b)::32, byte_size(b)::32, b::binary>>
    end

    assert BatchFrame.split(body.(2, 0, 0, 1, 0)) == {:error, :unknown_version}
    assert BatchFrame.split(body.(1, 1, 0, 1, 0)) == {:error, :bad_attributes}
    assert BatchFrame.split(body.(1, 0, 0, 1, 1)) == {:error, :bad_length}
    assert BatchFrame.split(body.(1, 0, 0, 0, 0)) == {:error, :bad_length}
    assert BatchFrame.split(body.(1, 0, 7, 1, 0)) == {:error, {:unknown_codec, 7}}
  end

  test "a header whose summary disagrees with its entries is refused when the entries are read" do
    {:ok, header, _size, <<>>} = BatchFrame.split(small_frame())

    assert BatchFrame.entries(%{header | logical_bytes: header.logical_bytes + 1}) == {:error, :bad_entries}
    assert BatchFrame.entries(%{header | entries_crc: header.entries_crc + 1}) == {:error, :bad_entries}
    assert BatchFrame.entries(%{header | max_timestamp: 99}) == {:error, :bad_entries}
    assert BatchFrame.entries(%{header | count: header.count + 1}) == {:error, :malformed_batch}
    assert BatchFrame.entries(header, header.inflated_size - 1) == {:error, :batch_too_large}
  end

  test "the largest frame fits the largest compressed batch" do
    assert BatchFrame.max_frame_size(16_777_216) > 16_777_216 + 62
    assert BatchFrame.max_frame_size(100) > 100 + 62
  end

  test "a stored frame is judged by a fixed ceiling, and the boot refuses a setting above it" do
    assert BatchFrame.max_stored_inflated() == 268_435_456
    assert BatchFrame.max_frame_size() == BatchFrame.max_frame_size(BatchFrame.max_stored_inflated())

    runtime = File.read!(Path.expand("../../../config/runtime.exs", __DIR__))
    assert runtime =~ "bytes when bytes <= 268_435_456 ->"
  end
end
