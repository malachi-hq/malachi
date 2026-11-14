defmodule Malachi.BatchCodec do
  @moduledoc """
  The payload of a batch of records, shared by the wire (`Malachi.Wire.Batch`) and the disk
  (`Malachi.Log.BatchFrame`): one encoding of a record in the whole product, so the bytes a producer sends
  can be stored, replicated and pushed to a consumer as they are.

  The payload is the entries, one after the other, compressed with a codec or not:

      plain:       <<flags::8, record>>
      positioned:  <<source_index::16, offset::64, flags::8, record>>

  A record is `Malachi.Wire.encode_record/1` (no offset: a stored batch carries its base offset beside the
  payload, a consume batch carries each position in the entry). Flag bit 0 marks a tombstone (#206); the
  other bits are reserved, and an entry that sets one is malformed, so a flag added later fails loudly on a
  reader that does not know it.

  ## Inflating within a bound

  Bytes that come from a client, or from a disk that may have rotted, can claim to inflate to anything.
  `decode/6` and `validate/5` refuse, before any work, an `inflated_size` above the cap they are given, and
  a zstd frame that declares a content size other than `inflated_size`. They then inflate in steps of at
  most 128 KiB (what OTP's `:zstd` stream produces per call) and stop as soon as the output passes
  `inflated_size`, so a frame that lies about its size, or declares none, costs at most `inflated_size` plus
  one step in memory. A zstd payload shorter than the smallest whole frame (9 bytes) is refused unread: OTP
  reads a frame header out of fewer bytes than it has, and would answer from memory it never wrote. Last,
  exactly `count` entries must fill exactly `inflated_size` bytes. Everything that fails is an error tuple,
  never a raise. Nothing in the product inflates a batch any other way.

  ## A validated batch

  `validate/5` is the only way to obtain a `t:Malachi.BatchCodec.Validated.t/0` from bytes, and `build/2` the
  only way to make one from records. The store appends nothing else (`c:Malachi.Storage.SegmentStore.append_encoded/2`):
  the record count that decides every later offset, the timestamps and the logical size all come from
  entries that were actually read, never from a header the sender wrote.
  """

  alias Malachi.Log.Record
  alias Malachi.Wire

  @codecs [none: 0, zstd: 1]

  # magic number (4), frame header descriptor (1), window descriptor or content size (1), block header (3)
  @min_zstd_frame 9

  # The frame of nothing, as `:zstd.compress/1` writes it on OTP 29: OTP 28 raises on an empty input.
  @empty_zstd_frame <<40, 181, 47, 253, 32, 0, 1, 0, 0>>

  @typedoc "How a payload is encoded: as is, or compressed with zstd."
  @type codec :: :none | :zstd

  @typedoc "Plain entries (a produce, a stored batch) or entries behind their positions (a consume)."
  @type layout :: :plain | :positioned

  @typedoc "A plain entry: the record and whether it is a tombstone."
  @type plain :: {Record.t(), boolean()}

  @typedoc "A positioned entry: its position in the range's history, the record, and whether it is a tombstone."
  @type positioned :: {Wire.position(), Record.t(), boolean()}

  @typedoc "Why a payload was refused."
  @type error ::
          :batch_too_large
          | :batch_size_mismatch
          | :batch_count_mismatch
          | :malformed_batch
          | {:unknown_codec, non_neg_integer()}

  defmodule Validated do
    @moduledoc """
    A batch whose entries were read: what the store may append.

    `payload` is the bytes as they will be stored (compressed with `codec`, or not). Every other field was
    computed from the entries themselves:

      * `count`, `inflated_size`: how many entries, and how many bytes they inflate to;
      * `first_timestamp`, `max_timestamp`: of the first entry, and the largest of all;
      * `logical_bytes`: what the records weigh in the record frame (`Malachi.Log.Record.encoded_size/1`),
        the measure every replica comparison uses whatever the format;
      * `entries_crc`: `:erlang.crc32/1` of the inflated entries, which chains into a segment's logical hash.

    Build one with `Malachi.BatchCodec.validate/5` or `Malachi.BatchCodec.build/2`, never by hand.
    """

    @enforce_keys [
      :codec,
      :count,
      :inflated_size,
      :payload,
      :first_timestamp,
      :max_timestamp,
      :logical_bytes,
      :entries_crc
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            codec: Malachi.BatchCodec.codec(),
            count: pos_integer(),
            inflated_size: non_neg_integer(),
            payload: binary(),
            first_timestamp: non_neg_integer(),
            max_timestamp: non_neg_integer(),
            logical_bytes: non_neg_integer(),
            entries_crc: non_neg_integer()
          }
  end

  @doc """
  The most one batch may inflate to (`MALACHI_MAX_INFLATED_BATCH_BYTES`, 16 MiB by default): the bound on a
  batch a client sends, a page the server returns, and a batch frame on disk alike, so the bytes a producer
  sent always fit in one stored frame.
  """
  @spec max_inflated_bytes() :: pos_integer()
  def max_inflated_bytes, do: Application.get_env(:malachi, :max_inflated_batch_bytes, 16_777_216)

  @doc "The codecs, in code order."
  @spec codecs() :: [codec()]
  def codecs, do: Keyword.keys(@codecs)

  @doc "The code of `codec`."
  @spec codec_code(codec()) :: non_neg_integer()
  def codec_code(codec), do: Keyword.fetch!(@codecs, codec)

  @doc "The codec of a code, or `{:error, {:unknown_codec, code}}`."
  @spec codec(non_neg_integer()) :: {:ok, codec()} | {:error, {:unknown_codec, non_neg_integer()}}
  def codec(code) do
    case Enum.find(@codecs, fn {_codec, value} -> value == code end) do
      {codec, _code} -> {:ok, codec}
      nil -> {:error, {:unknown_codec, code}}
    end
  end

  @doc """
  `entries` encoded and compressed with `codec`: `{payload, inflated_size}`. The caller frames it (a wire
  header, or a disk frame).
  """
  @spec encode([plain()] | [positioned()], codec(), layout()) :: {binary(), non_neg_integer()}
  def encode(entries, codec, layout \\ :plain) do
    inflated = entries |> Enum.map(&encode_entry(&1, layout)) |> IO.iodata_to_binary()
    {compress(inflated, codec), byte_size(inflated)}
  end

  @doc """
  A validated batch of `entries`, compressed with `codec`. The server's own records need no reading back:
  they are encoded here, so every field is computed from them directly.

  `entries` must not be empty: a batch with no records stamps no offset and is never stored.
  """
  @spec build([plain(), ...], codec()) :: Validated.t()
  def build([_ | _] = entries, codec) do
    inflated = entries |> Enum.map(&encode_entry(&1, :plain)) |> IO.iodata_to_binary()
    validated(codec, compress(inflated, codec), inflated, entries)
  end

  @doc """
  Reads a payload received or stored with its header fields, within `cap` (see the moduledoc), and answers
  the validated batch with its entries. A payload with no entries is refused as `:malformed_batch`: a batch
  that holds no record has no place in a log.
  """
  @spec validate(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, Validated.t(), [plain()]} | {:error, error()}
  def validate(code, count, inflated_size, payload, cap) do
    with {:ok, codec} <- codec(code),
         :ok <- nonempty(count),
         :ok <- within(inflated_size, cap),
         {:ok, inflated} <- inflate(codec, payload, inflated_size),
         {:ok, entries} <- entries(inflated, count, :plain) do
      {:ok, validated(codec, payload, inflated, entries), entries}
    end
  end

  @doc "The entries of a payload, read within `cap` (see the moduledoc)."
  @spec decode(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary(), non_neg_integer(), layout()) ::
          {:ok, [plain()] | [positioned()]} | {:error, error()}
  def decode(code, count, inflated_size, payload, cap, layout \\ :plain) do
    with {:ok, codec} <- codec(code),
         :ok <- within(inflated_size, cap),
         {:ok, inflated} <- inflate(codec, payload, inflated_size) do
      entries(inflated, count, layout)
    end
  end

  defp validated(codec, payload, inflated, entries) do
    {count, first, max, logical} =
      Enum.reduce(entries, {0, nil, 0, 0}, fn {%Record{timestamp: ts} = record, _tombstone}, {n, first, max, bytes} ->
        {n + 1, first || ts, Kernel.max(max, ts), bytes + Record.encoded_size(record)}
      end)

    %Validated{
      codec: codec,
      count: count,
      inflated_size: byte_size(inflated),
      payload: payload,
      first_timestamp: first,
      max_timestamp: max,
      logical_bytes: logical,
      entries_crc: :erlang.crc32(inflated)
    }
  end

  defp nonempty(0), do: {:error, :malformed_batch}
  defp nonempty(_count), do: :ok

  defp within(inflated_size, cap) when inflated_size <= cap, do: :ok
  defp within(_inflated_size, _cap), do: {:error, :batch_too_large}

  defp compress(inflated, :none), do: inflated
  defp compress(<<>>, :zstd), do: @empty_zstd_frame
  defp compress(inflated, :zstd), do: inflated |> :zstd.compress() |> IO.iodata_to_binary()

  defp inflate(:none, payload, inflated_size) when byte_size(payload) == inflated_size, do: {:ok, payload}
  defp inflate(:none, _payload, _inflated_size), do: {:error, :batch_size_mismatch}

  defp inflate(:zstd, payload, _inflated_size) when byte_size(payload) < @min_zstd_frame,
    do: {:error, :malformed_batch}

  defp inflate(:zstd, payload, inflated_size) do
    with :ok <- declared_size(payload, inflated_size) do
      {:ok, context} = :zstd.context(:decompress)
      inflate_stream(context, payload, inflated_size, [], 0)
    end
  rescue
    # OTP's :zstd raises on bytes that are not a zstd frame, or a corrupt one
    ErlangError -> {:error, :malformed_batch}
  end

  # A frame that states its content size must state the batch's; one that states none is held to it by
  # the bounded inflation below.
  defp declared_size(payload, inflated_size) do
    case :zstd.get_frame_header(payload) do
      {:ok, %{frameContentSize: size}} when is_integer(size) and size != inflated_size -> {:error, :batch_size_mismatch}
      {:ok, _header} -> :ok
      {:error, _reason} -> {:error, :malformed_batch}
    end
  end

  # Each call inflates at most one block (128 KiB), so the output is checked against `inflated_size` before
  # the next one: inflating past it stops at once, at a cost of one block beyond the declaration. OTP answers
  # with three elements while input remains, at a full output block or at a frame's end (where the output
  # can be empty), and every call takes input or raises, so the loop ends within the payload's length.
  defp inflate_stream(context, input, inflated_size, acc, size) do
    case :zstd.stream(context, input) do
      {:continue, rest, output} ->
        produced = IO.iodata_length(output)
        size = size + produced

        if size > inflated_size,
          do: {:error, :batch_size_mismatch},
          else: inflate_stream(context, rest, inflated_size, [acc, output], size)

      {_continue_or_done, output} ->
        finish(size + IO.iodata_length(output), inflated_size, [acc, output])
    end
  end

  defp finish(size, inflated_size, acc) when size == inflated_size, do: {:ok, IO.iodata_to_binary(acc)}
  defp finish(_size, _inflated_size, _acc), do: {:error, :batch_size_mismatch}

  defp entries(inflated, count, layout) do
    case take_entries(inflated, count, layout, []) do
      {entries, <<>>} -> {:ok, entries}
      {_entries, _rest} -> {:error, :batch_count_mismatch}
    end
  rescue
    # a record cut short or a count past the payload: the record decoders match their input exactly
    _malformed in [MatchError, FunctionClauseError, CaseClauseError] -> {:error, :malformed_batch}
  end

  defp take_entries(rest, 0, _layout, acc), do: {Enum.reverse(acc), rest}

  defp take_entries(<<flags::8, rest::binary>>, n, :plain, acc) do
    {record, tombstone, rest} = take_flagged(flags, rest)
    take_entries(rest, n - 1, :plain, [{record, tombstone} | acc])
  end

  defp take_entries(<<source::16, offset::64, flags::8, rest::binary>>, n, :positioned, acc) do
    {record, tombstone, rest} = take_flagged(flags, rest)
    take_entries(rest, n - 1, :positioned, [{{source, offset}, record, tombstone} | acc])
  end

  # Only bit 0 is defined; a reserved bit makes the match fail, which `entries/3` answers as malformed.
  defp take_flagged(flags, rest) when flags in [0, 1] do
    {record, rest} = Wire.decode_record(rest)
    {record, flags == 1, rest}
  end

  defp encode_entry({%Record{} = record, tombstone}, :plain), do: flagged(record, tombstone)

  defp encode_entry({{source, offset}, %Record{} = record, tombstone}, :positioned),
    do: <<source::16, offset::64, flagged(record, tombstone)::binary>>

  defp flagged(record, tombstone) when is_boolean(tombstone),
    do: <<if(tombstone, do: 1, else: 0)::8, Wire.encode_record(record)::binary>>
end
