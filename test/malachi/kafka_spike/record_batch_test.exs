defmodule Malachi.KafkaSpike.RecordBatchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Malachi.KafkaSpike.RecordBatch

  defp record(offset, fields \\ %{}),
    do: Map.merge(%{offset: offset, timestamp: 1_700_000_000_000 + offset, key: "k", value: "v", headers: []}, fields)

  defp encode(records), do: IO.iodata_to_binary(RecordBatch.encode(records))

  defp records_of({:ok, batches}), do: Enum.flat_map(batches, & &1.records)

  # A batch with its attributes replaced (and its CRC fixed, so only the attributes are wrong).
  defp with_attributes(<<head::binary-size(17), _crc::32, _attributes::16, rest::binary>>, attributes) do
    checked = <<attributes::16, rest::binary>>
    <<head::binary, :crc32cer.nif(checked)::32, checked::binary>>
  end

  describe "decode/1" do
    test "an empty record set is no batches" do
      assert RecordBatch.decode(<<>>) == {:ok, []}
    end

    test "reads several batches in a row" do
      bin = encode([record(0)]) <> encode([record(1), record(2)])
      assert {:ok, [%{records: [_]}, %{records: [_, _]}]} = RecordBatch.decode(bin)
    end

    test "reads the producer fields an idempotent producer sets" do
      assert {:ok, [%{producer_id: -1, producer_epoch: -1, base_sequence: -1, base_offset: 0}]} =
               RecordBatch.decode(encode([record(0)]))
    end

    test "reads what kafka_protocol's own encoder writes, timestamps and headers included" do
      {_size, iodata} =
        :kpro_batch.encode(
          2,
          [%{key: "a", value: "1", ts: 10, headers: [{"h", "x"}]}, %{key: "b", value: "2", ts: 12}],
          :no_compression
        )

      assert [%{offset: 0, key: "a", value: "1", timestamp: 10, headers: [{"h", "x"}]}, %{offset: 1, timestamp: 12}] =
               records_of(RecordBatch.decode(IO.iodata_to_binary(iodata)))
    end

    test "a truncated batch is corrupt" do
      bin = encode([record(0)])
      assert RecordBatch.decode(binary_part(bin, 0, byte_size(bin) - 1)) == {:error, :corrupt_batch}
      assert RecordBatch.decode(<<0::64, 5::32, 1, 2>>) == {:error, :corrupt_batch}
      assert RecordBatch.decode(<<0::64, -1::32-signed>>) == {:error, :corrupt_batch}
    end

    test "a CRC that does not match is corrupt" do
      <<head::binary-size(17), crc::32, rest::binary>> = encode([record(0)])
      assert RecordBatch.decode(<<head::binary, bxor(crc, 0xFF)::32, rest::binary>>) == {:error, :corrupt_batch}
    end

    test "a record count that disagrees with the records is corrupt" do
      <<head::binary-size(17), _crc::32, fixed::binary-size(36), _count::32, records::binary>> = encode([record(0)])

      for count <- [0, 2, -3] do
        checked = <<fixed::binary, count::32-signed, records::binary>>

        assert RecordBatch.decode(<<head::binary, :crc32cer.nif(checked)::32, checked::binary>>) ==
                 {:error, :corrupt_batch}
      end
    end

    test "a batch too short for its header is corrupt" do
      checked = <<0::16>>
      body = <<0::32, 2, :crc32cer.nif(checked)::32, checked::binary>>
      assert RecordBatch.decode(<<0::64, byte_size(body)::32, body::binary>>) == {:error, :corrupt_batch}
      assert RecordBatch.decode(<<0::64, 3::32, 0, 0, 0>>) == {:error, :corrupt_batch}
    end

    test "a message set older than v2 is refused" do
      {_size, iodata} = :kpro_batch.encode(1, [%{key: "k", value: "v", ts: 1}], :no_compression)
      assert RecordBatch.decode(IO.iodata_to_binary(iodata)) == {:error, :unsupported_magic}
    end

    test "a compressed batch is refused, whatever the codec" do
      for codec <- [:gzip, :snappy, :lz4, :zstd] do
        {_size, iodata} = :kpro_batch.encode(2, [%{key: "k", value: "v"}], codec)
        assert RecordBatch.decode(IO.iodata_to_binary(iodata)) == {:error, :compressed_batch}, "#{codec}"
      end
    end

    test "a transactional or a control batch is refused" do
      bin = encode([record(0)])
      assert RecordBatch.decode(with_attributes(bin, 0x10)) == {:error, :transactional_batch}
      assert RecordBatch.decode(with_attributes(bin, 0x30)) == {:error, :control_batch}
    end

    test "a record that does not parse is corrupt" do
      <<head::binary-size(17), _crc::32, fixed::binary-size(40), _records::binary>> = encode([record(0)])

      for garbage <- [<<0xFF>>, <<20, 0, 0>>, <<2, 0, 0>>] do
        checked = fixed <> garbage

        bin =
          <<head::binary-size(8), byte_size(checked) + 9::32, binary_part(head, 12, 5)::binary,
            :crc32cer.nif(checked)::32, checked::binary>>

        assert RecordBatch.decode(bin) == {:error, :corrupt_batch}, inspect(garbage)
      end
    end
  end

  describe "encode/1" do
    test "no records is no batches" do
      assert RecordBatch.encode([]) == []
    end

    test "one batch per run of consecutive offsets, each at its own base offset" do
      batches = RecordBatch.encode([record(3), record(4), record(7), record(9), record(10)])
      assert length(batches) == 3

      assert [[3, 4], [7], [9, 10]] =
               Enum.map(batches, fn batch -> batch |> RecordBatch.decode() |> records_of() |> Enum.map(& &1.offset) end)
    end

    test "kafka_protocol reads what it writes, offsets and nulls included" do
      records = [record(5, %{key: nil, headers: [{"h", "v"}]}), record(6, %{value: nil})]
      [{meta, messages}] = :kpro_batch.decode(encode(records))

      assert meta.is_transaction == false
      assert Enum.map(messages, &elem(&1, 1)) == [5, 6]
    end

    test "a timestamp delta past 35 bits, which kafka_protocol's varint encoder cannot write" do
      year_ms = 365 * 24 * 3_600 * 1_000
      records = [record(0, %{timestamp: 0}), record(1, %{timestamp: 2 * year_ms}), record(2, %{timestamp: 1 <<< 62})]

      assert_raise FunctionClauseError, fn -> :kpro_varint.encode(2 * year_ms) end
      assert records_of(RecordBatch.decode(encode(records))) == records
    end

    test "kafka_protocol's decoder reads the varints written, negative and past 35 bits included" do
      for delta <- [0, 1, -1, 63, -64, 64, 300, -300, 1 <<< 20, -(1 <<< 33), 1 <<< 40, (1 <<< 62) - 1] do
        base = 1 <<< 61

        [{_meta, [_first, second]}] =
          :kpro_batch.decode(encode([record(0, %{timestamp: base}), record(1, %{timestamp: base + delta})]))

        assert elem(second, 5) == base + delta, "delta #{delta}"
      end
    end

    property "decode/1 inverts encode/1" do
      nullable = one_of([constant(nil), binary()])

      check all(
              start <- integer(0..1_000_000),
              fields <-
                list_of(
                  fixed_map(%{
                    timestamp: integer(0..(1 <<< 50)),
                    key: nullable,
                    value: nullable,
                    headers: list_of(tuple({binary(), nullable}), max_length: 3)
                  }),
                  min_length: 1,
                  max_length: 20
                )
            ) do
        records = fields |> Enum.with_index(start) |> Enum.map(fn {map, offset} -> Map.put(map, :offset, offset) end)
        assert records_of(RecordBatch.decode(encode(records))) == records
      end
    end
  end
end
