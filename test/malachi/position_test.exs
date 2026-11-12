defmodule Malachi.PositionTest do
  # The opaque position token (`Malachi.Position`): its exact bytes, what decoding refuses, and the order
  # two tokens compare in.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.Position

  @max_u16 0xFFFF
  @max_u32 0xFFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  test "a token is version 1, the topic's crc32, the issuer, the source and the offset, big-endian" do
    token = Position.encode({"orders", 3}, {1, 42})

    assert token == <<1, :erlang.crc32("orders")::32, 3::32, 1::16, 42::64>>
    assert byte_size(token) == 19
    assert Position.tag("orders") == :erlang.crc32("orders")
  end

  test "a token decodes to what it was encoded from, at every bound" do
    for issuer <- [0, @max_u32], index <- [0, @max_u16], offset <- [0, @max_u64] do
      token = Position.encode({"t", issuer}, {index, offset})
      assert Position.decode(token) == {:ok, %{tag: :erlang.crc32("t"), issuer: issuer, at: {index, offset}}}
    end
  end

  test "a value that does not fit its field is not encoded rather than cut short" do
    for {issuer, at} <- [{@max_u32 + 1, {0, 0}}, {0, {@max_u16 + 1, 0}}, {0, {0, @max_u64 + 1}}, {-1, {0, 0}}] do
      assert_raise FunctionClauseError, fn -> Position.encode({"t", issuer}, at) end
    end
  end

  test "every truncation and every extension of a token is refused" do
    token = Position.encode({"orders", 7}, {2, 9})

    for size <- 0..18 do
      assert Position.decode(binary_part(token, 0, size)) == {:error, :invalid_position}
    end

    for extra <- [<<0>>, <<0, 0>>, :binary.copy(<<255>>, 46)] do
      assert Position.decode(token <> extra) == {:error, :invalid_position}
    end
  end

  test "an unknown version, a token past the wire's 64 bytes and a value that is no binary are refused" do
    <<1, rest::binary>> = Position.encode({"orders", 7}, {2, 9})

    for version <- [0, 2, 255], do: assert(Position.decode(<<version, rest::binary>>) == {:error, :invalid_position})
    assert Position.decode(:binary.copy(<<1>>, 65)) == {:error, :invalid_position}
    assert Position.decode({2, 9}) == {:error, :invalid_position}
    assert Position.decode(nil) == {:error, :invalid_position}
  end

  test "resolve names the issuer within the topic, and refuses another topic's token or a broken one" do
    token = Position.encode({"orders", 7}, {2, 9})

    assert Position.resolve(token, "orders") == {:ok, {"orders", 7}, {2, 9}}
    assert Position.resolve(token, "payments") == {:error, :invalid_position}
    assert Position.resolve(binary_part(token, 0, 18), "orders") == {:error, :invalid_position}
  end

  describe "compare/2" do
    property "two tokens of one issuer compare as their positions do" do
      check all(
              issuer <- StreamData.integer(0..@max_u32),
              a <- position(),
              b <- position()
            ) do
        expected =
          cond do
            a < b -> :lt
            a > b -> :gt
            true -> :eq
          end

        assert Position.compare(Position.encode({"t", issuer}, a), Position.encode({"t", issuer}, b)) == expected
      end
    end

    test "tokens of different issuers, of different topics, or broken ones are incomparable" do
      token = Position.encode({"orders", 1}, {0, 5})

      assert Position.compare(token, Position.encode({"orders", 2}, {0, 5})) == :incomparable
      assert Position.compare(token, Position.encode({"payments", 1}, {0, 5})) == :incomparable
      assert Position.compare(token, binary_part(token, 0, 18)) == :incomparable
      assert Position.compare(token <> <<0>>, token) == :incomparable
      <<1, rest::binary>> = token
      assert Position.compare(<<2, rest::binary>>, <<2, rest::binary>>) == :incomparable
    end

    test "the end of one source and the start of the next name the same record and still compare :lt" do
      # documented in the moduledoc: a position is no record number, so the two are not :eq
      assert Position.compare(Position.encode({"t", 4}, {0, 10}), Position.encode({"t", 4}, {1, 0})) == :lt
    end
  end

  defp position do
    StreamData.tuple(
      {StreamData.integer(0..@max_u16), StreamData.one_of([StreamData.integer(0..@max_u64), StreamData.integer(0..3)])}
    )
  end
end
