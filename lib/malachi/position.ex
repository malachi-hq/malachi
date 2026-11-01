defmodule Malachi.Position do
  @moduledoc """
  A position as a client holds it: an opaque token naming where a read of one range resumes. NorthGuard
  carries offsets on its broker pushes and read acks, and hands applications an opaque position they can
  compare and resume from, never compute (meetup transcript, 862 to 872, 1018 to 1023, 1065 to 1075):
  there is no arithmetic on a position, so the server is free to change what one holds.

  The broker mints a token for each position it hands out: the `next` of a page, the `position` an
  `open_consume` answers (`Malachi.Wire`, keys 29 and 31), and it reads one back as the start of a read or
  a group's checkpoint (`commit_offsets`, 34). Inside the server a position stays the
  `{source_index, offset}` pair of the range's history (`Malachi.Broker.consume_start/3`), and the control
  plane stores it so.

  Version 1 is 19 bytes, big-endian:

      <<1::8, topic_tag::32, issuer_seq::32, source_index::16, offset::64>>

  `topic_tag` is `:erlang.crc32/1` of the topic name, `issuer_seq` the sequence number of the range whose
  read minted it (the issuer), and `{source_index, offset}` the position in the issuer's history.
  `decode/1` is a plain binary match: it builds no term from the bytes and makes no atom, and anything
  that is not exactly a version 1 token (shorter, longer, another version) is `{:error, :invalid_position}`.

  A token minted on one range can be used on another of its topic only when that one's history extends the
  issuer's and its keyspace slice lies inside the issuer's (`Malachi.Broker.position_lineage/4`): a split's
  child, or a merge back into exactly the issuer's block, goes on from the issuer's position.

  Two tokens compare (`compare/2`) when they share their version, topic tag and issuer: then their order is
  the order of their `{source_index, offset}` pairs, which is the order of their bytes. Any other pair is
  `:incomparable`. A position is where the next record is read from, and the end of one source and the
  start of the next name the same next record: `{i, end_of_i}` and `{i + 1, 0}` compare `:lt` although a
  read from either delivers the same record first.
  """

  @version 1

  @typedoc "An opaque position token, as the wire carries it."
  @type t :: binary()

  @typedoc "A position in a range's history: the index of a source and an offset in it."
  @type at :: {non_neg_integer(), non_neg_integer()}

  @typedoc "What a token holds: the topic's tag, the issuer's sequence number and the position."
  @type decoded :: %{tag: non_neg_integer(), issuer: non_neg_integer(), at: at()}

  @doc "The token for `at`, a position in the history of `issuer`, the range whose read hands it out."
  @spec encode({String.t(), non_neg_integer()}, at()) :: t()
  def encode({topic, issuer_seq}, {index, offset})
      when is_binary(topic) and issuer_seq in 0..0xFFFF_FFFF and index in 0..0xFFFF and
             offset in 0..0xFFFF_FFFF_FFFF_FFFF do
    <<@version::8, tag(topic)::32, issuer_seq::32, index::16, offset::64>>
  end

  @doc "The tag of `topic` a token carries: `:erlang.crc32/1` of its name."
  @spec tag(String.t()) :: non_neg_integer()
  def tag(topic) when is_binary(topic), do: :erlang.crc32(topic)

  @doc "What a version 1 token holds, or `{:error, :invalid_position}` for anything else."
  @spec decode(term()) :: {:ok, decoded()} | {:error, :invalid_position}
  def decode(<<@version::8, tag::32, issuer::32, index::16, offset::64>>),
    do: {:ok, %{tag: tag, issuer: issuer, at: {index, offset}}}

  def decode(_other), do: {:error, :invalid_position}

  @doc """
  A token used on `topic`: its issuer's range id and the position, or `{:error, :invalid_position}` for one
  that does not decode or that another topic's read minted.
  """
  @spec resolve(term(), String.t()) ::
          {:ok, {String.t(), non_neg_integer()}, at()} | {:error, :invalid_position}
  def resolve(token, topic) when is_binary(topic) do
    expected = tag(topic)

    case decode(token) do
      {:ok, %{tag: ^expected, issuer: issuer, at: at}} -> {:ok, {topic, issuer}, at}
      _other -> {:error, :invalid_position}
    end
  end

  @doc """
  The order of two tokens: `:lt`, `:eq` or `:gt` when they share their version, topic tag and issuer, else
  `:incomparable` (a token that does not decode included). See the moduledoc for two tokens that name the
  same next record and still compare `:lt`.
  """
  @spec compare(term(), term()) :: :lt | :eq | :gt | :incomparable
  def compare(
        <<@version::8, prefix::binary-size(8), a::binary-size(10)>>,
        <<@version::8, prefix::binary-size(8), b::binary-size(10)>>
      ) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  def compare(_a, _b), do: :incomparable
end
