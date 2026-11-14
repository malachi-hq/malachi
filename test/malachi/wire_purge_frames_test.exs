defmodule Malachi.WirePurgeFramesTest do
  @moduledoc """
  The manual purge api key (35, #198) against frozen bytes. A shipped frame is frozen, so a difference
  here is a wire break, not an expectation to regenerate.
  """
  use ExUnit.Case, async: true

  alias Malachi.Wire

  @topic "events"

  @frames [
    {{:before, 1_700_000_000_000}, "01000000066576656e7473000000018bcfe56800"},
    {{:position, <<1, 2, 3>>}, "01000000066576656e7473010100000003010203"},
    {{:group, "billing"}, "01000000066576656e747302010000000762696c6c696e67"}
  ]

  test "the key is 35" do
    assert Wire.purge_topic_key() == 35
  end

  for {point, hex} <- @frames do
    test "request #{inspect(point)} encodes to its frozen bytes and decodes back" do
      bytes = Base.decode16!(unquote(hex), case: :lower)
      assert Wire.encode_purge_topic_req(@topic, unquote(Macro.escape(point))) == bytes
      assert Wire.decode_purge_topic_req(bytes) == {@topic, unquote(Macro.escape(point))}
    end
  end

  test "the response lists each range's start before and after, in frozen bytes" do
    rows = [{0, 0, 7}, {2, 3, 10}]

    bytes =
      Base.decode16!(
        "000000020000000000000000000000000000000000000007000000020000000000000003000000000000000a",
        case: :lower
      )

    assert Wire.encode_purge_topic_resp(rows) == bytes
    assert Wire.decode_purge_topic_resp(bytes) == rows
    assert Wire.encode_purge_topic_resp([]) == <<0::32>>
    assert Wire.decode_purge_topic_resp(<<0::32>>) == []
  end

  test "a malformed request does not decode" do
    topic = <<1, 6::32, "events">>

    # an unknown kind, and a time with trailing bytes: no clause takes them
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> <<9::8>>) end
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> <<0::8, 1::64, 0::8>>) end
    # a nil token, a nil group, and trailing bytes after a group
    assert_raise MatchError, fn -> Wire.decode_purge_topic_req(topic <> <<1::8, 0::8>>) end
    assert_raise MatchError, fn -> Wire.decode_purge_topic_req(topic <> <<2::8, 0::8>>) end
    assert_raise MatchError, fn -> Wire.decode_purge_topic_req(topic <> <<2::8, 1::8, 1::32, "g", 0::8>>) end
  end
end
