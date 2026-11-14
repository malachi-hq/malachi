defmodule Malachi.WireHoldFramesTest do
  @moduledoc """
  The legal hold api keys (36 to 38, #307) against frozen bytes. A shipped frame is frozen, so a difference
  here is a wire break, not an expectation to regenerate.
  """
  use ExUnit.Case, async: true

  alias Malachi.Wire

  test "the keys are 36, 37 and 38" do
    assert {Wire.set_topic_hold_key(), Wire.release_topic_hold_key(), Wire.get_topic_hold_key()} == {36, 37, 38}
  end

  test "set_topic_hold carries the topic and the reason, in frozen bytes" do
    bytes = Base.decode16!("01000000066576656e74730100000006636173652037", case: :lower)
    assert Wire.encode_set_topic_hold_req("events", "case 7") == bytes
    assert Wire.decode_set_topic_hold_req(bytes) == {"events", "case 7"}
  end

  test "release_topic_hold and get_topic_hold carry the topic alone" do
    bytes = Base.decode16!("01000000066576656e7473", case: :lower)
    assert Wire.encode_topic_hold_topic_req("events") == bytes
    assert Wire.decode_topic_hold_topic_req(bytes) == "events"
  end

  test "get_topic_hold answers a not-held marker, or the hold, in frozen bytes" do
    assert Wire.encode_topic_hold_resp(nil) == <<0>>
    assert Wire.decode_topic_hold_resp(<<0>>) == nil

    hold = %{reason: "r", actor: "admin", since_ms: 1_700_000_000_000}
    bytes = Base.decode16!("01010000000172010000000561646d696e0000018bcfe56800", case: :lower)
    assert Wire.encode_topic_hold_resp(hold) == bytes
    assert Wire.decode_topic_hold_resp(bytes) == hold
  end

  test "a malformed request does not decode" do
    topic = <<1, 6::32, "events">>
    assert_raise FunctionClauseError, fn -> Wire.decode_set_topic_hold_req(topic) end
    assert_raise MatchError, fn -> Wire.decode_set_topic_hold_req(topic <> <<1, 1::32, "r", 0>>) end
    assert_raise MatchError, fn -> Wire.decode_topic_hold_topic_req(topic <> <<0>>) end
    assert_raise MatchError, fn -> Wire.decode_topic_hold_resp(<<1, 1, 1::32, "r", 1, 1::32, "a", 0::32>>) end
    assert_raise FunctionClauseError, fn -> Wire.decode_topic_hold_resp(<<2>>) end
  end
end
