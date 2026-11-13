defmodule Malachi.KafkaSpike.RecordBatch do
  @moduledoc """
  Kafka's RecordBatch (magic v2), decoded from a Produce request and encoded into a Fetch response.

  `kafka_protocol` has a batch codec (`kpro_batch`), but it is a client's: it decodes a null key, value or
  header value as an empty binary, cannot encode a null key, numbers the records of a batch it encodes from
  offset 0, and asserts the CRC by a match that crashes the caller. A server has to tell a tombstone from an
  empty value and refuse a corrupt batch with an error code, so the spike decodes and encodes the batch here
  and keeps from the library only its varint decoder and the CRC32C NIF it depends on (`crc32cer`). Its
  varint encoder stops at 35 bits, so a timestamp delta beyond about 199 days (two records of one batch
  produced that far apart, which a quiet topic fetched later does hold) cannot be encoded with it: the
  encoder here takes the full 64 bits Kafka's varlong does.

  Layout of one batch (all integers big-endian, the CRC32C covering everything from `attributes` on):

      base_offset int64 | batch_length int32 | partition_leader_epoch int32 | magic int8 | crc uint32 |
      attributes int16 | last_offset_delta int32 | base_timestamp int64 | max_timestamp int64 |
      producer_id int64 | producer_epoch int16 | base_sequence int32 | record_count int32 | records

  and of one record (varints are zigzag): `length varint | attributes int8 | timestamp_delta varlong |
  offset_delta varint | key_length varint | key | value_length varint | value | header_count varint |
  headers`, a length of -1 meaning null.
  """
  import Bitwise

  @compression_mask 0x07
  @transactional_bit 0x10
  @control_bit 0x20

  @typedoc "One record as a Kafka client sees it."
  @type kafka_record :: %{
          offset: integer(),
          timestamp: integer(),
          key: binary() | nil,
          value: binary() | nil,
          headers: [{binary(), binary() | nil}]
        }

  @typedoc "One decoded batch: its producer fields (idempotence) and its records."
  @type batch :: %{
          base_offset: integer(),
          producer_id: integer(),
          producer_epoch: integer(),
          base_sequence: integer(),
          records: [kafka_record()]
        }

  @typedoc "Why a batch was refused."
  @type refusal :: :corrupt_batch | :unsupported_magic | :compressed_batch | :transactional_batch | :control_batch

  @doc """
  The batches of a Produce request's record set, or the reason to refuse it: `:corrupt_batch` for a
  truncated batch, a CRC mismatch or a record that does not parse, `:unsupported_magic` for a message set
  older than v2, `:compressed_batch` for a compressed one (decompression is #168's), and
  `:transactional_batch` or `:control_batch` for the transactions this gateway does not support.
  """
  @spec decode(binary()) :: {:ok, [batch()]} | {:error, refusal()}
  def decode(bin), do: decode(bin, [])

  defp decode(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode(<<base_offset::64-signed, length::32-signed, body::binary-size(length), rest::binary>>, acc)
       when length >= 0 do
    case decode_batch(base_offset, body) do
      {:ok, batch} -> decode(rest, [batch | acc])
      {:error, _reason} = error -> error
    end
  end

  defp decode(_truncated, _acc), do: {:error, :corrupt_batch}

  defp decode_batch(base_offset, <<_epoch::32-signed, 2::8, crc::32, checked::binary>>) do
    with :ok <- check_crc(crc, checked) do
      decode_checked(base_offset, checked)
    end
  end

  defp decode_batch(_base_offset, <<_epoch::32-signed, _magic::8-signed, _rest::binary>>),
    do: {:error, :unsupported_magic}

  defp decode_batch(_base_offset, _short), do: {:error, :corrupt_batch}

  defp check_crc(crc, checked), do: if(:crc32cer.nif(checked) == crc, do: :ok, else: {:error, :corrupt_batch})

  defp decode_checked(
         base_offset,
         <<attributes::16-signed, _last_offset_delta::32-signed, base_timestamp::64-signed, _max_timestamp::64-signed,
           producer_id::64-signed, producer_epoch::16-signed, base_sequence::32-signed, count::32-signed,
           records::binary>>
       ) do
    with :ok <- check_attributes(attributes),
         {:ok, records} <- decode_records(count, records, base_offset, base_timestamp) do
      {:ok,
       %{
         base_offset: base_offset,
         producer_id: producer_id,
         producer_epoch: producer_epoch,
         base_sequence: base_sequence,
         records: records
       }}
    end
  end

  defp decode_checked(_base_offset, _short), do: {:error, :corrupt_batch}

  defp check_attributes(attributes) do
    cond do
      (attributes &&& @compression_mask) != 0 -> {:error, :compressed_batch}
      (attributes &&& @control_bit) != 0 -> {:error, :control_batch}
      (attributes &&& @transactional_bit) != 0 -> {:error, :transactional_batch}
      true -> :ok
    end
  end

  # A record that does not parse fails the whole batch. The varint decoder of `kafka_protocol` raises on a
  # truncated varint, and a short binary fails a match: both are the same corrupt batch to a client.
  defp decode_records(count, bin, base_offset, base_timestamp) when count >= 0 do
    {records, rest} =
      Enum.map_reduce(List.duplicate(nil, count), bin, fn nil, bin ->
        decode_record(bin, base_offset, base_timestamp)
      end)

    if rest == <<>>, do: {:ok, records}, else: {:error, :corrupt_batch}
  rescue
    _error in [MatchError, FunctionClauseError, ArgumentError, CaseClauseError, ErlangError] ->
      {:error, :corrupt_batch}
  end

  defp decode_records(_count, _bin, _base_offset, _base_timestamp), do: {:error, :corrupt_batch}

  defp decode_record(bin, base_offset, base_timestamp) do
    {length, bin} = varint(bin)
    <<record::binary-size(length), rest::binary>> = bin
    <<_attributes::8, record::binary>> = record
    {timestamp_delta, record} = varint(record)
    {offset_delta, record} = varint(record)
    {key, record} = nullable_bytes(record)
    {value, record} = nullable_bytes(record)
    {header_count, record} = varint(record)

    {headers, <<>>} =
      Enum.map_reduce(List.duplicate(nil, max(header_count, 0)), record, fn nil, record ->
        {key_length, record} = varint(record)
        <<header_key::binary-size(key_length), record::binary>> = record
        {header_value, record} = nullable_bytes(record)
        {{header_key, header_value}, record}
      end)

    record = %{
      offset: base_offset + offset_delta,
      timestamp: base_timestamp + timestamp_delta,
      key: key,
      value: value,
      headers: headers
    }

    {record, rest}
  end

  defp varint(bin), do: :kpro_varint.decode(bin)

  defp nullable_bytes(bin) do
    case varint(bin) do
      {-1, rest} ->
        {nil, rest}

      {length, rest} when length >= 0 ->
        <<bytes::binary-size(length), rest::binary>> = rest
        {:binary.copy(bytes), rest}
    end
  end

  @doc """
  The record set of a Fetch response for `records`, in offset order: one uncompressed batch per run of
  consecutive offsets, since a batch numbers its records by delta from its base offset and a Malachi range
  may hold gaps between them. Empty for no records.
  """
  @spec encode([kafka_record()]) :: iodata()
  def encode(records) do
    records
    |> Enum.chunk_while([], &chunk_consecutive/2, &chunk_after/1)
    |> Enum.map(&encode_batch/1)
  end

  defp chunk_consecutive(record, []), do: {:cont, [record]}

  defp chunk_consecutive(%{offset: offset} = record, [%{offset: previous} | _rest] = run) when offset == previous + 1,
    do: {:cont, [record | run]}

  defp chunk_consecutive(record, run), do: {:cont, Enum.reverse(run), [record]}

  defp chunk_after([]), do: {:cont, []}
  defp chunk_after(run), do: {:cont, Enum.reverse(run), []}

  defp encode_batch([first | _rest] = records) do
    base_offset = first.offset
    base_timestamp = first.timestamp
    max_timestamp = records |> Enum.map(& &1.timestamp) |> Enum.max()
    last_offset_delta = List.last(records).offset - base_offset
    encoded = Enum.map(records, &encode_record(&1, base_offset, base_timestamp))

    checked =
      IO.iodata_to_binary([
        <<0::16, last_offset_delta::32-signed, base_timestamp::64-signed, max_timestamp::64-signed, -1::64-signed,
          -1::16-signed, -1::32-signed, length(records)::32-signed>>
        | encoded
      ])

    crc = :crc32cer.nif(checked)
    # partition_leader_epoch -1: the spike's Metadata announces no leader epoch either (see Handler)
    body = <<-1::32-signed, 2::8, crc::32, checked::binary>>
    <<base_offset::64-signed, byte_size(body)::32-signed, body::binary>>
  end

  defp encode_record(record, base_offset, base_timestamp) do
    body = [
      <<0::8>>,
      varint_bytes(record.timestamp - base_timestamp),
      varint_bytes(record.offset - base_offset),
      encode_nullable(record.key),
      encode_nullable(record.value),
      varint_bytes(length(record.headers)),
      Enum.map(record.headers, fn {key, value} ->
        [varint_bytes(byte_size(key)), key, encode_nullable(value)]
      end)
    ]

    [varint_bytes(IO.iodata_length(body)), body]
  end

  defp encode_nullable(nil), do: varint_bytes(-1)
  defp encode_nullable(bytes), do: [varint_bytes(byte_size(bytes)), bytes]

  # Kafka's varlong: a signed 64-bit integer, zigzag encoded, seven bits a byte, low bits first.
  defp varint_bytes(int) when int >= -0x8000000000000000 and int <= 0x7FFFFFFFFFFFFFFF,
    do: unsigned_varint(bxor(int <<< 1, int >>> 63) &&& 0xFFFFFFFFFFFFFFFF)

  defp unsigned_varint(int) when int < 128, do: <<int>>
  defp unsigned_varint(int), do: <<1::1, int &&& 127::7, unsigned_varint(int >>> 7)::binary>>
end
