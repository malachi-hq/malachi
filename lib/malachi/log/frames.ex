defmodule Malachi.Log.Frames do
  @moduledoc """
  The two frame formats a segment file can hold, behind one interface for the store's scans and reads.

    * `:record` - one frame per record (`Malachi.Log.Record`), one CRC per record.
    * `:batch` - one frame per batch (`Malachi.Log.BatchFrame`), one CRC per batch, compressed or not.

  A segment holds one format, decided when it is registered in the control plane and never mixed inside
  it. A file says which one it holds through the magic of its first frame (`detect/1`), so a reader that
  walks a directory, the scrub or the chaos checker, reads each file correctly without being told.

  Every scan works on a frame's summary: where it starts in the offsets, how many records it holds, what
  they weigh in the record frame (the logical size every replica comparison uses), and the CRC of its
  logical content with the length it covers. The CRCs chain with `:erlang.crc32_combine/3` into the segment's
  logical hash, without inflating a batch or decoding a record: for a record segment the logical content is
  the record payloads, for a batch segment the inflated entries.
  """

  alias Malachi.BatchCodec
  alias Malachi.Log.BatchFrame
  alias Malachi.Log.Record

  @record_magic 0x4D51
  @batch_magic 0x4D42
  @shared_magic_byte 0x4D
  # magic, length and CRC of a record frame; magic, base offset, CRC and length of a batch frame
  @record_header 10
  @batch_header 18

  @typedoc "How a segment's records are framed on disk."
  @type format :: :record | :batch

  @typedoc "What a scan knows about one valid frame."
  @type summary :: %{
          base_offset: non_neg_integer(),
          count: pos_integer(),
          logical_bytes: non_neg_integer(),
          crc: non_neg_integer(),
          crc_size: non_neg_integer()
        }

  @doc "The formats, the default first."
  @spec formats() :: [format()]
  def formats, do: [:record, :batch]

  @doc "The format whose magic opens `bytes`, or `nil` when it opens with neither (empty, blank or damaged)."
  @spec detect(binary()) :: format() | nil
  def detect(<<@record_magic::16, _rest::binary>>), do: :record
  def detect(<<@batch_magic::16, _rest::binary>>), do: :batch
  def detect(_bytes), do: nil

  @doc """
  The summary of the frame at the front of `binary`, checked against its CRC, or where the scan stops:
  `:incomplete`, `:blank` or `{:error, reason}` (see `Malachi.Log.Record` and `Malachi.Log.BatchFrame`).
  """
  @spec summarize_one(format() | nil, binary()) ::
          {:ok, summary(), pos_integer(), binary()} | :incomplete | :blank | {:error, term()}
  # A file with no format holds no frame (`Malachi.Storage.ElixirStore` leaves it undecided): either format reads
  # its zeros as blank and any written byte without a magic as damage, so it is read as the record format reads it.
  def summarize_one(nil, binary), do: summarize_one(:record, binary)
  def summarize_one(:record, binary), do: Record.summarize_one(binary)

  def summarize_one(:batch, binary) do
    case BatchFrame.split(binary) do
      {:ok, header, size, rest} -> {:ok, batch_summary(header), size, rest}
      other -> other
    end
  end

  @doc """
  Every record of every complete, valid frame at the front of `binary`, with its offset, and how many bytes
  those frames take. Stops at the first frame that is incomplete, blank or wrong, like
  `Malachi.Log.Record.decode_all/1`. A batch whose entries cannot be read stops the run there too: its bytes
  passed the CRC, so this is a payload the writer and this reader disagree about, and the scrub reports it.
  """
  @spec decode_all(format() | nil, binary()) :: {[Record.t()], non_neg_integer()}
  def decode_all(nil, binary), do: decode_all(:record, binary)

  def decode_all(:record, binary) do
    {records_with_positions, consumed} = Record.decode_all(binary)
    {Enum.map(records_with_positions, &elem(&1, 0)), consumed}
  end

  def decode_all(:batch, binary), do: decode_batches(binary, 0, [])

  @doc """
  The records of the batch frame at the front of `binary`, as entries `{record, tombstone}`, when it is a
  valid frame. Used to cut a batch: the prefix that stays is re-encoded from these.
  """
  @spec batch_entries(binary()) ::
          {:ok, BatchFrame.header(), [BatchCodec.plain()]} | {:error, term()} | :incomplete | :blank
  def batch_entries(binary) do
    with {:ok, header, _size, _rest} <- BatchFrame.split(binary),
         {:ok, entries} <- BatchFrame.entries(header) do
      {:ok, header, entries}
    end
  end

  @doc """
  How many bytes the frame starting at `bytes` claims from its header, in either format, or `0` when `bytes`
  does not start a believable frame.

  `written`, when given, is how many of `bytes` were actually written, the rest being the unwritten zeros of
  a preallocated segment. A frame whose write stopped inside its own header (a byte of the magic both
  formats begin with, or a header cut short) claims at least its header, which puts the zeros inside it:
  that is a torn write, not damage. Past the header, see `Malachi.Log.BatchFrame.claimed_size/3`.
  """
  @spec claimed_size(binary(), non_neg_integer() | nil) :: non_neg_integer()
  def claimed_size(bytes, written \\ nil)

  def claimed_size(<<@shared_magic_byte, _rest::binary>>, 1), do: 2

  def claimed_size(<<@record_magic::16, _rest::binary>>, written) when is_integer(written) and written < @record_header,
    do: @record_header

  def claimed_size(<<@batch_magic::16, _rest::binary>>, written) when is_integer(written) and written < @batch_header,
    do: @batch_header

  def claimed_size(<<@record_magic::16, _rest::binary>> = bytes, _written), do: Record.claimed_size(bytes)

  def claimed_size(<<@batch_magic::16, _rest::binary>> = bytes, written),
    do: BatchFrame.claimed_size(bytes, written || byte_size(bytes))

  def claimed_size(_bytes, _written), do: 0

  @doc """
  The offset of the first record of the frame at the front of `bytes`, read from its header without checking
  anything, or `nil` when `bytes` opens with neither magic. For a report that names where a file says it
  starts: it vouches for nothing.
  """
  @spec first_offset(binary()) :: non_neg_integer() | nil
  def first_offset(<<@record_magic::16, _length::32, _crc::32, offset::64, _rest::binary>>), do: offset
  def first_offset(<<@batch_magic::16, offset::64, _rest::binary>>), do: offset
  def first_offset(_bytes), do: nil

  @doc "A segment's logical hash after `summary`: the CRC of its logical content so far, chained."
  @spec chain(non_neg_integer(), summary()) :: non_neg_integer()
  def chain(hash, %{crc: crc, crc_size: crc_size}), do: :erlang.crc32_combine(hash, crc, crc_size)

  @doc "The logical hash of an empty segment."
  @spec empty_hash() :: non_neg_integer()
  def empty_hash, do: :erlang.crc32(<<>>)

  defp batch_summary(header) do
    %{
      base_offset: header.base_offset,
      count: header.count,
      logical_bytes: header.logical_bytes,
      crc: header.entries_crc,
      crc_size: header.inflated_size
    }
  end

  defp decode_batches(binary, consumed, acc) do
    with {:ok, header, size, rest} <- BatchFrame.split(binary),
         {:ok, records} <- BatchFrame.records(header) do
      decode_batches(rest, consumed + size, [records | acc])
    else
      _incomplete_blank_or_error -> {acc |> Enum.reverse() |> List.flatten(), consumed}
    end
  end
end
