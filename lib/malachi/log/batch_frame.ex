defmodule Malachi.Log.BatchFrame do
  @moduledoc """
  The on-disk frame of a batch of records: one header, one payload, one CRC for the whole batch.

      <<magic::16, base_offset::64, crc32::32, body_length::32, body::binary-size(body_length)>>

  where `body` is:

      <<version::8, attributes::16, codec::8, count::32, first_timestamp::64, max_timestamp::64,
        inflated_size::32, logical_bytes::64, entries_crc::32, size::32, payload::binary-size(size)>>

  `payload` is a `Malachi.BatchCodec` payload of plain entries, compressed with `codec` or not: the same
  bytes a producer sends on the wire, so a batch can be stored, replicated and served as it came. The record
  at position `i` of the batch has offset `base_offset + i`.

  ## What the CRC covers

  `crc32` is `:erlang.crc32/1` of `body`, everything after `body_length`, and of nothing before it. The
  base offset is deliberately outside it: the primary stamps a batch's offset as it appends (`stamp/2`)
  without touching the checksum, so a batch built once can be written anywhere. A flipped bit in the base
  offset is therefore invisible to the CRC; the store catches it instead, because every batch must start
  where the previous one ended (the first one where the segment starts), and recovery and verify check
  that. `body_length` is outside it too, so it is checked against `size`, which the CRC covers: the two
  must agree (`body_length` is exactly the fixed fields plus `size`), and once the bytes holding `size`
  are on disk a disagreement is damage. That matters for a frame in the middle of a segment: a flipped
  length that claims more bytes than the file holds would otherwise read as a write cut short, and recovery
  would discard every valid frame after it as a torn tail.

  `logical_bytes` and `entries_crc` are what the records weigh in the record frame
  (`Malachi.Log.Record.encoded_size/1`) and the CRC of the inflated entries
  (`t:Malachi.BatchCodec.Validated.t/0`). They are in the header so that recovery, verify and a manifest
  rebuild know a segment's logical size and hash without inflating a single batch.

  ## Versions and attributes

  `version` is 1. `attributes` is reserved and zero: a later version (the Kafka gateway, #168) can carry what
  it needs there or in a new version without changing how version 1 reads. A frame with another version or
  a non-zero attribute is refused rather than guessed at, so a reader that does not know a change fails
  loudly.

  ## Where a scan stops

  As for `Malachi.Log.Record`, a scan hits one of four things: a valid frame; `:incomplete`, the bytes run
  out inside a frame; `:blank`, the header is all zeros (unwritten preallocated space); or
  `{:error, reason}`, a frame that is there and wrong. The magic is `0x4D42`, never zero and never the
  record frame's `0x4D51`.

  A frame never claims more than `max_frame_size/1`: the largest payload a batch within
  `max_stored_inflated/0` can compress to, plus the fixed fields. A header that claims more
  is damage (`:batch_too_large`), not a write that was cut short, so recovery classifies it as rot rather
  than discarding everything after it as a torn tail.
  """

  import Bitwise

  alias Malachi.BatchCodec
  alias Malachi.BatchCodec.Validated
  alias Malachi.Log.Record

  @magic 0x4D42
  @version 1
  # magic(2) + base_offset(8) + crc32(4) + body_length(4)
  @header_size 18
  # version(1) + attributes(2) + codec(1) + count(4) + first_timestamp(8) + max_timestamp(8) + inflated_size(4)
  # + logical_bytes(8) + entries_crc(4) + size(4)
  @fixed_body_size 44
  # See max_stored_inflated/0.
  @max_stored_inflated 268_435_456
  # Where `size` starts in the body: every fixed field before it.
  @size_at 40

  @typedoc "A frame's header fields, its payload, and where it sits in the offsets."
  @type header :: %{
          base_offset: non_neg_integer(),
          count: pos_integer(),
          codec: BatchCodec.codec(),
          first_timestamp: non_neg_integer(),
          max_timestamp: non_neg_integer(),
          inflated_size: non_neg_integer(),
          logical_bytes: non_neg_integer(),
          entries_crc: non_neg_integer(),
          payload: binary()
        }

  @typedoc "Why a frame is refused."
  @type error ::
          :bad_magic
          | :bad_crc
          | :bad_length
          | :batch_too_large
          | :unknown_version
          | :bad_attributes
          | {:unknown_codec, non_neg_integer()}

  @doc "The bytes before the body: magic, base offset, CRC and body length."
  @spec header_size() :: pos_integer()
  def header_size, do: @header_size

  @doc "The magic number that opens every batch frame."
  @spec magic() :: non_neg_integer()
  def magic, do: @magic

  @doc """
  The most one stored batch may inflate to: 256 MiB, fixed, whatever `MALACHI_MAX_INFLATED_BATCH_BYTES` says
  today. A frame is judged by this ceiling, never by the setting, because the setting can be lowered after
  larger batches were written, and judging old bytes by a new setting would call them damage on every replica
  at once. The setting itself is refused above it at boot (`config/runtime.exs`), so every batch the node
  accepts fits.
  """
  @spec max_stored_inflated() :: pos_integer()
  def max_stored_inflated, do: @max_stored_inflated

  @doc """
  The largest frame a batch within `max_inflated` can need: zstd's worst case for that many bytes (its
  `ZSTD_COMPRESSBOUND`), plus the fixed fields. A codec `:none` payload is `max_inflated` itself, which is
  below it.
  """
  @spec max_frame_size(pos_integer()) :: pos_integer()
  def max_frame_size(max_inflated \\ @max_stored_inflated) do
    @header_size + @fixed_body_size + compress_bound(max_inflated)
  end

  defp compress_bound(n) when n < 131_072, do: n + (n >>> 8) + ((131_072 - n) >>> 11)
  defp compress_bound(n), do: n + (n >>> 8)

  @doc """
  The frame of `validated` with `base_offset` stamped. The CRC is computed here, once, over the body; a later
  `stamp/2` moves the frame to another offset without computing it again.
  """
  @spec encode(Validated.t(), non_neg_integer()) :: binary()
  def encode(%Validated{} = validated, base_offset) do
    body =
      <<@version::8, 0::16, BatchCodec.codec_code(validated.codec)::8, validated.count::32,
        validated.first_timestamp::64, validated.max_timestamp::64, validated.inflated_size::32,
        validated.logical_bytes::64, validated.entries_crc::32, byte_size(validated.payload)::32,
        validated.payload::binary>>

    <<@magic::16, base_offset::64, :erlang.crc32(body)::32, byte_size(body)::32, body::binary>>
  end

  @doc "`frame` with its base offset replaced by `base_offset`. The CRC does not cover it, so it stays valid."
  @spec stamp(binary(), non_neg_integer()) :: binary()
  def stamp(<<@magic::16, _old::64, rest::binary>>, base_offset), do: <<@magic::16, base_offset::64, rest::binary>>

  @doc """
  Checks the frame at the front of `binary`, framing and CRC, without inflating its payload. Returns
  `{:ok, header, frame_size, rest}`, `:incomplete`, `:blank` or `{:error, reason}`: see the moduledoc.
  `max_frame` is the largest frame accepted (`max_frame_size/1`).
  """
  @spec split(binary(), pos_integer()) ::
          {:ok, header(), pos_integer(), binary()} | :incomplete | :blank | {:error, error()}
  def split(binary, max_frame \\ max_frame_size())

  def split(<<@magic::16, _base::64, _crc::32, body_length::32, _rest::binary>>, max_frame)
      when @header_size + body_length > max_frame,
      do: {:error, :batch_too_large}

  def split(<<@magic::16, _base::64, _crc::32, body_length::32, _rest::binary>>, _max_frame)
      when body_length < @fixed_body_size,
      do: {:error, :bad_length}

  # `size` sits at a fixed place in the body, so once those bytes are on disk the length can be checked
  # against it before the body is whole: a length that disagrees is damage, never a write to wait for.
  def split(
        <<@magic::16, _base::64, _crc::32, body_length::32, _head::binary-size(@size_at), size::32, _rest::binary>>,
        _max_frame
      )
      when body_length != @fixed_body_size + size,
      do: {:error, :bad_length}

  def split(
        <<@magic::16, base::64, crc::32, body_length::32, body::binary-size(body_length), rest::binary>>,
        _max_frame
      ) do
    if :erlang.crc32(body) == crc do
      with {:ok, header} <- body_fields(body, base), do: {:ok, header, @header_size + body_length, rest}
    else
      {:error, :bad_crc}
    end
  end

  def split(<<@magic::16, _base::64, _crc::32, _body_length::32, _partial::binary>>, _max_frame), do: :incomplete

  # Unwritten space, not a damaged frame: the whole header has to be zero, for the reason
  # `Malachi.Log.Record` gives (a zero magic followed by written bytes is damage on the magic).
  def split(<<0::size(@header_size)-unit(8), _rest::binary>>, _max_frame), do: :blank

  def split(<<0, rest::binary>> = binary, _max_frame) when byte_size(binary) < @header_size do
    if all_zero?(rest), do: :blank, else: {:error, :bad_magic}
  end

  def split(<<0::16, _rest::binary>>, _max_frame), do: {:error, :bad_magic}
  def split(<<@magic::16, _partial::binary>>, _max_frame), do: :incomplete
  def split(binary, _max_frame) when byte_size(binary) < 2, do: :incomplete
  def split(_binary, _max_frame), do: {:error, :bad_magic}

  @doc """
  How many bytes the frame starting at `bytes` claims, from its header alone, or `0` when `bytes` does not
  start a believable frame: another magic, a header cut short, or a length past `max_frame`. Recovery uses
  it to tell a write that was cut inside a frame from damage.

  `written` is how many of `bytes` were actually written (the rest being the unwritten zeros of a
  preallocated segment). When it reaches past the frame's `size` field, that field was written, and a
  length that disagrees with it is damage, so the claim is `0`. Before that point the field may still be
  zeros, and the length is all there is to go on.
  """
  @spec claimed_size(binary(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def claimed_size(bytes, written \\ 0, max_frame \\ max_frame_size())

  def claimed_size(
        <<@magic::16, _base::64, _crc::32, body_length::32, _head::binary-size(@size_at), size::32, _rest::binary>>,
        written,
        _max_frame
      )
      when written >= @header_size + @fixed_body_size and body_length != @fixed_body_size + size,
      do: 0

  def claimed_size(<<@magic::16, _base::64, _crc::32, body_length::32, _rest::binary>>, _written, max_frame)
      when body_length >= @fixed_body_size and @header_size + body_length <= max_frame,
      do: @header_size + body_length

  def claimed_size(_bytes, _written, _max_frame), do: 0

  @doc """
  The entries of a checked frame, each record with its offset, inflated within `max_inflated`
  (`Malachi.BatchCodec`), and checked against the header: the count must match and the entries must hash to
  `entries_crc`.
  """
  @spec entries(header(), pos_integer()) :: {:ok, [BatchCodec.plain()]} | {:error, BatchCodec.error() | :bad_entries}
  def entries(header, max_inflated \\ @max_stored_inflated) do
    code = BatchCodec.codec_code(header.codec)

    with {:ok, validated, entries} <-
           BatchCodec.validate(code, header.count, header.inflated_size, header.payload, max_inflated),
         :ok <- agrees(validated, header) do
      {:ok, entries |> Enum.with_index(header.base_offset) |> Enum.map(&with_offset/1)}
    end
  end

  @doc "The records of a checked frame, with their offsets. See `entries/2`."
  @spec records(header(), pos_integer()) :: {:ok, [Record.t()]} | {:error, BatchCodec.error() | :bad_entries}
  def records(header, max_inflated \\ @max_stored_inflated) do
    with {:ok, entries} <- entries(header, max_inflated), do: {:ok, Enum.map(entries, &elem(&1, 0))}
  end

  @doc "The end offset (exclusive) of a checked frame."
  @spec end_offset(header()) :: non_neg_integer()
  def end_offset(%{base_offset: base, count: count}), do: base + count

  defp with_offset({{%Record{} = record, tombstone}, offset}), do: {%{record | offset: offset}, tombstone}

  # The header was written from the entries (`Malachi.BatchCodec.Validated`), and the CRC says it was not
  # changed since; entries that read back otherwise mean the writer and this reader disagree about the
  # payload, which no honest frame produces.
  defp agrees(%Validated{} = v, header) do
    if v.first_timestamp == header.first_timestamp and v.max_timestamp == header.max_timestamp and
         v.logical_bytes == header.logical_bytes and v.entries_crc == header.entries_crc,
       do: :ok,
       else: {:error, :bad_entries}
  end

  defp body_fields(
         <<version::8, attributes::16, code::8, count::32, first::64, max::64, inflated::32, logical::64,
           entries_crc::32, size::32, payload::binary>>,
         base
       ) do
    cond do
      version != @version ->
        {:error, :unknown_version}

      attributes != 0 ->
        {:error, :bad_attributes}

      byte_size(payload) != size ->
        {:error, :bad_length}

      count == 0 ->
        {:error, :bad_length}

      true ->
        with_codec(code, %{
          base_offset: base,
          count: count,
          first_timestamp: first,
          max_timestamp: max,
          inflated_size: inflated,
          logical_bytes: logical,
          entries_crc: entries_crc,
          payload: payload
        })
    end
  end

  defp with_codec(code, fields) do
    case BatchCodec.codec(code) do
      {:ok, codec} -> {:ok, Map.put(fields, :codec, codec)}
      {:error, {:unknown_codec, _code}} = error -> error
    end
  end

  defp all_zero?(binary), do: binary == :binary.copy(<<0>>, byte_size(binary))
end
