defmodule Malachi.AdminCallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Malachi.AdminCall

  doctest Malachi.AdminCall

  describe "call/1" do
    test "returns what the function returns" do
      assert AdminCall.call(fn -> {:ok, 1} end) == {:ok, 1}
      assert AdminCall.call(fn -> {:error, :nope} end) == {:error, :nope}
    end

    test "turns a call timeout into {:error, :timeout}" do
      assert AdminCall.call(fn -> exit({:timeout, {GenServer, :call, []}}) end) == {:error, :timeout}
    end

    test "turns any other exit into {:error, {:broker_unavailable, reason}}" do
      assert AdminCall.call(fn -> exit(:noproc) end) == {:error, {:broker_unavailable, :noproc}}
    end
  end

  describe "check_topic/1" do
    test "accepts a name the control plane accepts and refuses anything else" do
      assert AdminCall.check_topic("events") == :ok
      assert AdminCall.check_topic("Orders_v2.eu-1") == :ok
      assert AdminCall.check_topic("") == {:error, :invalid_topic}
      assert AdminCall.check_topic(nil) == {:error, :invalid_topic}
      assert AdminCall.check_topic(:events) == {:error, :invalid_topic}
    end

    test "refuses what would forge a log line or escape a directory" do
      for bad <- ["a\nb", "a b", "a/b", "..", ".", "t%{actor}", "caf\u00e9", <<0>>, "a\u202Eb"] do
        assert AdminCall.check_topic(bad) == {:error, :invalid_topic}, "accepted #{inspect(bad)}"
      end
    end

    test "accepts up to 255 bytes and refuses 256" do
      assert AdminCall.check_topic(String.duplicate("a", 255)) == :ok
      assert AdminCall.check_topic(String.duplicate("a", 256)) == {:error, :invalid_topic}
    end
  end

  describe "log/3" do
    test "logs the I18n line for :ok and {:ok, _}, nothing for a refusal" do
      bindings = [topic: "t", policy: "p", actor: "a"]

      assert capture_log(fn -> AdminCall.log(:ok, :topic_policy_bound, bindings) end) =~ "t"
      assert capture_log(fn -> AdminCall.log({:ok, %{}}, :topic_policy_bound, bindings) end) =~ "t"
      assert capture_log(fn -> AdminCall.log({:error, :x}, :topic_policy_bound, bindings) end) == ""
    end
  end

  describe "audit/6" do
    test "records success for :ok and {:ok, _} and failure with the rendered reason" do
      assert :ok = AdminCall.audit(:topic_policy_bound, "tester", "bind_topic_policy", :ok, %{topic: "t"})
      assert :ok = AdminCall.audit(:topic_policy_bound, "tester", "bind_topic_policy", {:ok, 1}, %{topic: "t"})

      assert :ok =
               AdminCall.audit(:topic_policy_bound, "tester", "bind_topic_policy", {:error, :x}, %{}, fn :x ->
                 "rendered"
               end)
    end
  end

  describe "reason_string/1" do
    test "renders the shared refusals" do
      assert AdminCall.reason_string(:timeout) =~ "timeout: "
      assert AdminCall.reason_string({:unsupported_command, {:x, 1}, 9, 8}) =~ "unsupported_command: "
      assert AdminCall.reason_string({:broker_unavailable, :noproc}) == "{:broker_unavailable, :noproc}"
    end
  end
end
