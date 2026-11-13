defmodule Malachi.BatchCodecTest do
  # The bounds of reading a payload are covered byte for byte by `Malachi.Wire.BatchTest`, which goes through
  # this module. What is new here is the validated batch: every field the store will trust must come from the
  # entries, and `build/2` and `validate/5` must agree on it.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.BatchCodec
  alias Malachi.BatchCodec.Validated
  alias Malachi.Log.Record
  alias Malachi.Wire.Batch

  @cap 16_777_216

  defp record_gen do
    gen all(
          value <- binary(max_length: 64),
          key <- one_of([constant(nil), binary(max_length: 16)]),
          headers <- list_of({binary(max_length: 8), binary(max_length: 8)}, max_length: 3),
          timestamp <- integer(0..4_000_000_000_000)
        ) do
      %Record{value: value, key: key, headers: headers, timestamp: timestamp}
    end
  end

  defp entries_gen, do: list_of(tuple({record_gen(), boolean()}), min_length: 1, max_length: 20)

  property "validate/5 reads back what build/2 wrote, with the same fields, for every codec" do
    check all(entries <- entries_gen(), codec <- member_of(BatchCodec.codecs())) do
      %Validated{} = built = BatchCodec.build(entries, codec)

      assert {:ok, ^built, ^entries} =
               BatchCodec.validate(
                 BatchCodec.codec_code(codec),
                 built.count,
                 built.inflated_size,
                 built.payload,
                 @cap
               )
    end
  end

  property "every field is the entries' own" do
    check all(entries <- entries_gen(), codec <- member_of(BatchCodec.codecs())) do
      built = BatchCodec.build(entries, codec)
      records = Enum.map(entries, &elem(&1, 0))
      {inflated, inflated_size} = BatchCodec.encode(entries, :none)

      assert built.codec == codec
      assert built.count == length(entries)
      assert built.inflated_size == inflated_size
      assert built.first_timestamp == hd(records).timestamp
      assert built.max_timestamp == records |> Enum.map(& &1.timestamp) |> Enum.max()
      assert built.logical_bytes == records |> Enum.map(&Record.encoded_size/1) |> Enum.sum()
      assert built.entries_crc == :erlang.crc32(inflated)
    end
  end

  test "the count that decides offsets comes from the entries, never from the header" do
    entries = [{Record.new("a", timestamp: 1), false}, {Record.new("b", timestamp: 2), false}]
    built = BatchCodec.build(entries, :none)
    code = BatchCodec.codec_code(:none)

    # A sender that claims one record more, or one less, than the payload holds is refused outright.
    assert BatchCodec.validate(code, 3, built.inflated_size, built.payload, @cap) == {:error, :malformed_batch}
    assert BatchCodec.validate(code, 1, built.inflated_size, built.payload, @cap) == {:error, :batch_count_mismatch}
  end

  test "a batch with no record is never valid" do
    {payload, 0} = BatchCodec.encode([], :zstd)
    assert BatchCodec.validate(BatchCodec.codec_code(:zstd), 0, 0, payload, @cap) == {:error, :malformed_batch}
    assert BatchCodec.validate(BatchCodec.codec_code(:none), 0, 0, <<>>, @cap) == {:error, :malformed_batch}
  end

  test "an unknown codec and a size above the cap are refused before any inflating" do
    built = BatchCodec.build([{Record.new("a"), false}], :none)

    assert BatchCodec.validate(9, 1, built.inflated_size, built.payload, @cap) == {:error, {:unknown_codec, 9}}

    assert BatchCodec.validate(0, 1, built.inflated_size, built.payload, built.inflated_size - 1) ==
             {:error, :batch_too_large}
  end

  test "build/2 refuses an empty list" do
    assert_raise FunctionClauseError, fn -> BatchCodec.build(Enum.drop([{Record.new("a"), false}], 1), :none) end
  end

  test "codec/1 answers every known code and refuses the rest" do
    for codec <- BatchCodec.codecs(), do: assert(BatchCodec.codec(BatchCodec.codec_code(codec)) == {:ok, codec})
    assert BatchCodec.codec(255) == {:error, {:unknown_codec, 255}}
  end

  test "segment hashes chain from batch crcs without inflating again" do
    first = [{Record.new("a", timestamp: 1), false}]
    second = [{Record.new("b", timestamp: 2), true}, {Record.new("c", timestamp: 3), false}]
    a = BatchCodec.build(first, :zstd)
    b = BatchCodec.build(second, :zstd)
    {whole, _size} = BatchCodec.encode(first ++ second, :none)

    assert :erlang.crc32_combine(a.entries_crc, b.entries_crc, b.inflated_size) == :erlang.crc32(whole)
  end

  test "Wire.Batch.validate/2 hands the store the producer's batch as it came, or refuses it" do
    entries = [{Record.new("a", timestamp: 5), false}]
    wire = Batch.encode(entries, :zstd)
    built = BatchCodec.build(entries, :zstd)

    assert {:ok, ^built, ^entries} = Batch.validate(wire, @cap)
    assert Batch.validate(binary_part(wire, 0, byte_size(wire) - 1), @cap) == {:error, :malformed_batch}
  end
end
