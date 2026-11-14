defmodule Malachi.Wire.Batch do
  @moduledoc """
  A batch of records on the stream keys (`Malachi.Wire`, keys 24 to 34): the unit a producer appends and
  a consumer is pushed.

      <<codec::8, count::32, inflated_size::32, size::32, payload::binary-size(size)>>

  `payload` is the entries, one after the other, compressed with `codec` or not; `inflated_size` is their
  size once inflated, and `count` how many there are. Every entry is a record (`Malachi.Wire.encode_record/1`)
  behind a flags byte. A produce batch holds plain entries; a consume batch holds positioned ones, each
  also behind the position its record has in its range:

      plain:       <<flags::8, record>>
      positioned:  <<source_index::16, offset::64, flags::8, record>>

  A record's position is raw, `{source_index, offset}`, not the opaque token a page's `next` is
  (`Malachi.Position`): it is transport, what a reader acks with and counts by, and a client must not hand
  it to an application as a place to resume from.

  Flag bit 0 marks a tombstone (#206), the delete marker log compaction keeps, so a producer can append one
  and a consumer is told of one. The other bits are reserved: a batch that sets one is refused as
  malformed, so a flag added later fails loudly on a reader that does not know it.

  ## Reading a batch from a client

  A batch comes from an untrusted client, and a compressed one can inflate to far more than it weighs on
  the wire. `decode/2` reads it through `Malachi.BatchCodec`, which refuses a batch above the cap it is
  given (`:max_inflated_bytes`, kept apart from the frame size limit, which counts bytes as received)
  before any work, and inflates within that bound (see its moduledoc). Everything that fails is an error
  tuple, never a raise.
  """

  alias Malachi.BatchCodec

  @typedoc "How a batch's payload is encoded: as is, or compressed with zstd."
  @type codec :: BatchCodec.codec()

  @typedoc "Plain records (a produce) or records behind their positions (a consume)."
  @type layout :: BatchCodec.layout()

  @typedoc "A record of a produce batch, and whether it is a tombstone."
  @type plain :: BatchCodec.plain()

  @typedoc "A record of a consume batch: its position in the range's history, the record, and whether it is a tombstone."
  @type positioned :: BatchCodec.positioned()

  @typedoc "Why a batch was refused."
  @type error :: BatchCodec.error()

  @doc "The codecs, in code order."
  @spec codecs() :: [codec()]
  defdelegate codecs, to: BatchCodec

  @doc "The wire code of `codec`."
  @spec codec_code(codec()) :: non_neg_integer()
  defdelegate codec_code(codec), to: BatchCodec

  @doc "The codec of a wire code. Raises on an unknown one, like every `Malachi.Wire` decoder."
  @spec codec_of(non_neg_integer()) :: codec()
  def codec_of(code) do
    case BatchCodec.codec(code) do
      {:ok, codec} -> codec
      {:error, _unknown} -> raise ArgumentError, "unknown codec #{code}"
    end
  end

  @doc "A batch of `entries` (plain, or positioned: see the moduledoc), with its payload encoded by `codec`."
  @spec encode([plain()] | [positioned()], codec(), layout()) :: binary()
  def encode(entries, codec, layout \\ :plain) do
    {payload, inflated_size} = BatchCodec.encode(entries, codec, layout)

    <<codec_code(codec)::8, length(entries)::32, inflated_size::32, byte_size(payload)::32, payload::binary>>
  end

  @doc """
  Splits one batch off the front of `binary`: its header and what follows it. Raises on a batch whose
  header or payload is cut short, the way a `Malachi.Wire` payload decoder does on a malformed frame.
  """
  @spec split(binary()) ::
          {%{codec: codec(), count: non_neg_integer(), inflated_size: non_neg_integer(), size: non_neg_integer()},
           binary()}
  def split(<<code::8, count::32, inflated::32, size::32, _payload::binary-size(size), rest::binary>>),
    do: {%{codec: codec_of(code), count: count, inflated_size: inflated, size: size}, rest}

  @doc """
  The records of one whole batch, inflated within `max_inflated_bytes` (see the moduledoc). Options:

    * `:max_inflated_bytes` (required): the most the batch may inflate to.
    * `:layout`: `:plain` (default) or `:positioned`.
  """
  @spec decode(binary(), keyword()) :: {:ok, [plain()] | [positioned()]} | {:error, error()}
  def decode(batch, opts) do
    cap = Keyword.fetch!(opts, :max_inflated_bytes)
    layout = Keyword.get(opts, :layout, :plain)

    case batch do
      <<code::8, count::32, inflated::32, size::32, payload::binary-size(size)>> ->
        BatchCodec.decode(code, count, inflated, payload, cap, layout)

      _malformed ->
        {:error, :malformed_batch}
    end
  end

  @doc """
  One whole produce batch, read within `max_inflated_bytes`, as a `t:Malachi.BatchCodec.Validated.t/0` the store
  can append as it is, with its entries. Same refusals as `decode/2`, and a batch with no record is malformed.
  """
  @spec validate(binary(), non_neg_integer()) ::
          {:ok, BatchCodec.Validated.t(), [plain()]} | {:error, error()}
  def validate(batch, max_inflated_bytes) do
    case batch do
      <<code::8, count::32, inflated::32, size::32, payload::binary-size(size)>> ->
        BatchCodec.validate(code, count, inflated, payload, max_inflated_bytes)

      _malformed ->
        {:error, :malformed_batch}
    end
  end
end
