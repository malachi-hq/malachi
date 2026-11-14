defmodule Malachi.Purge.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.Purge.Request

  doctest Malachi.Purge.Request

  @reason "LGPD art. 18 request"

  defp new(id, reason \\ @reason), do: Request.new(id, reason)

  describe "id" do
    test "1 to 128 bytes of printable ASCII" do
      assert {:ok, %Request{id: "a"}} = new("a")
      assert {:ok, _} = new(String.duplicate("x", 128))
      # every printable ASCII byte, 0x21 to 0x7E
      assert {:ok, _} = new(List.to_string(Enum.to_list(0x21..0x7E)))
    end

    test "empty, longer than 128 bytes, or anything not printable ASCII is refused" do
      for bad <- ["", String.duplicate("x", 129), "DSR 1", "DSR\t1", "DSR\n1", <<0x7F>>, <<0x1F>>, "café", <<0xFF>>] do
        assert new(bad) == {:error, :invalid_request}, "accepted id #{inspect(bad)}"
      end
    end

    test "a non-binary is refused" do
      for bad <- [nil, 42, :dsr, ~c"DSR-1", %{}] do
        assert new(bad) == {:error, :invalid_request}
      end
    end
  end

  describe "reason" do
    test "1 to 512 bytes of UTF-8 text, multi-byte characters included" do
      assert {:ok, %Request{reason: "x"}} = new("DSR-1", "x")
      assert {:ok, _} = new("DSR-1", String.duplicate("x", 512))
      assert {:ok, _} = new("DSR-1", "pedido do titular, art. 18, inciso VI: eliminação")
      # 256 two-byte characters are exactly 512 bytes; one more byte is over
      assert {:ok, _} = new("DSR-1", String.duplicate("é", 256))
      assert new("DSR-1", String.duplicate("é", 256) <> "x") == {:error, :invalid_request}
    end

    test "empty or longer than 512 bytes is refused" do
      assert new("DSR-1", "") == {:error, :invalid_request}
      assert new("DSR-1", String.duplicate("x", 513)) == {:error, :invalid_request}
    end

    test "invalid UTF-8 is refused" do
      assert new("DSR-1", <<0xC3>>) == {:error, :invalid_request}
      assert new("DSR-1", "ok" <> <<0xFF, 0xFE>>) == {:error, :invalid_request}
    end

    test "control, format and separator characters are refused" do
      # \n \t NUL DEL, a C1 control, RLO, zero-width space, BOM, line and paragraph separators
      for codepoint <- [?\n, ?\r, ?\t, 0, 0x7F, 0x85, 0x202E, 0x200B, 0xFEFF, 0x2028, 0x2029] do
        assert new("DSR-1", "before" <> <<codepoint::utf8>> <> "after") == {:error, :invalid_request},
               "accepted U+#{Integer.to_string(codepoint, 16)}"
      end
    end

    test "a non-binary is refused" do
      assert new("DSR-1", nil) == {:error, :invalid_request}
      assert new("DSR-1", ~c"reason") == {:error, :invalid_request}
    end
  end

  test "limits/0 names the bounds" do
    assert Request.limits() == {128, 512}
  end

  test "safe_text?/1 is the rule the reason follows" do
    assert Request.safe_text?("billing")
    refute Request.safe_text?("bill\ning")
    refute Request.safe_text?(<<0xFF>>)
  end

  property "any pair of binaries is either accepted within the bounds or refused" do
    check all(id <- binary(max_length: 200), reason <- binary(max_length: 600), max_runs: 500) do
      case Request.new(id, reason) do
        {:ok, %Request{id: ^id, reason: ^reason}} ->
          assert byte_size(id) in 1..128
          assert for(<<b <- id>>, do: b) |> Enum.all?(&(&1 in 0x21..0x7E))
          assert byte_size(reason) in 1..512
          assert String.valid?(reason)
          refute reason =~ ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

        {:error, :invalid_request} ->
          assert byte_size(id) not in 1..128 or Enum.any?(for(<<b <- id>>, do: b), &(&1 not in 0x21..0x7E)) or
                   byte_size(reason) not in 1..512 or not String.valid?(reason) or
                   reason =~ ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
      end
    end
  end

  property "printable ids and plain text reasons are always accepted" do
    check all(
            id <- string(?!..?~, min_length: 1, max_length: 128),
            reason <- string(:alphanumeric, min_length: 1, max_length: 512),
            max_runs: 300
          ) do
      assert {:ok, %Request{id: ^id, reason: ^reason}} = Request.new(id, reason)
    end
  end
end
