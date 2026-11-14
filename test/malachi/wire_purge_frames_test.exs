defmodule Malachi.WirePurgeFramesTest do
  @moduledoc """
  The manual purge api key (35, #198) against frozen bytes. A shipped frame is frozen, so a difference
  here is a wire break, not an expectation to regenerate. #308 broke it once, on purpose: the request
  carries the data subject request it answers as two trailing strings, `<<0, 0>>` when it answers none.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.Wire

  @topic "events"

  @frames [
    {{:before, 1_700_000_000_000}, "01000000066576656e7473000000018bcfe568000000"},
    {{:position, <<1, 2, 3>>}, "01000000066576656e74730101000000030102030000"},
    {{:group, "billing"}, "01000000066576656e747302010000000762696c6c696e670000"}
  ]

  test "the key is 35" do
    assert Wire.purge_topic_key() == 35
  end

  for {point, hex} <- @frames do
    test "request #{inspect(point)} encodes to its frozen bytes and decodes back" do
      bytes = Base.decode16!(unquote(hex), case: :lower)
      assert Wire.encode_purge_topic_req(@topic, unquote(Macro.escape(point))) == bytes
      assert Wire.decode_purge_topic_req(bytes) == {@topic, unquote(Macro.escape(point)), nil, nil}
    end
  end

  test "a request with a data subject request carries its id and reason after the point, in frozen bytes" do
    bytes =
      Base.decode16!(
        "01000000066576656e7473020100000007" <> "62696c6c696e67" <> "01000000054453522d31" <> "0100000003776879",
        case: :lower
      )

    assert Wire.encode_purge_topic_req(@topic, {:group, "billing"}, "DSR-1", "why") == bytes
    assert Wire.decode_purge_topic_req(bytes) == {@topic, {:group, "billing"}, "DSR-1", "why"}
  end

  test "one request field without the other is a well-formed frame; Purge is what refuses it" do
    only_id = Wire.encode_purge_topic_req(@topic, {:before, 0}, "DSR-1", nil)
    assert Wire.decode_purge_topic_req(only_id) == {@topic, {:before, 0}, "DSR-1", nil}
  end

  property "every point, with or without a request, decodes back to what was encoded" do
    point =
      one_of([
        map(integer(0..0x7FFFFFFFFFFFFFFF), &{:before, &1}),
        map(binary(), &{:position, &1}),
        map(string(:printable), &{:group, &1})
      ])

    check all(
            topic <- string(:alphanumeric, min_length: 1),
            point <- point,
            request_id <- one_of([constant(nil), string(:ascii)]),
            reason <- one_of([constant(nil), string(:printable)])
          ) do
      bytes = Wire.encode_purge_topic_req(topic, point, request_id, reason)
      assert Wire.decode_purge_topic_req(bytes) == {topic, point, request_id, reason}
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

    group = <<2::8, 1::8, 1::32, "g">>

    # an unknown kind, and a time cut short: no clause takes them
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> <<9::8>>) end
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> <<0::8, 1::32>>) end
    # a nil token and a nil group
    assert_raise MatchError, fn -> Wire.decode_purge_topic_req(topic <> <<1::8, 0::8, 0::8, 0::8>>) end
    assert_raise MatchError, fn -> Wire.decode_purge_topic_req(topic <> <<2::8, 0::8, 0::8, 0::8>>) end
    # a frame from before #308 (no request fields), one with the reason missing, and trailing bytes
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> group) end
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> group <> <<0::8>>) end
    assert_raise MatchError, fn -> Wire.decode_purge_topic_req(topic <> group <> <<0::8, 0::8, 0::8>>) end
    # a request field whose length runs past the frame
    assert_raise FunctionClauseError, fn -> Wire.decode_purge_topic_req(topic <> group <> <<1::8, 9::32, "DSR">>) end
  end
end
