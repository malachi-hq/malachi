defmodule Malachi.AdminCallDurableTest do
  @moduledoc """
  `Malachi.AdminCall.audit_durably/6` against the application's audit log, which these tests take away and
  give back: not async, so no other test sees it missing.
  """
  use ExUnit.Case, async: false

  alias Malachi.AdminCall

  defp actor, do: "durable_#{System.unique_integer([:positive])}"

  test "answers :ok once the entry is in the trail, with no wait for a flush" do
    actor = actor()

    assert AdminCall.audit_durably(:purge_request_recorded, actor, "record_purge_request", :ok, %{request_id: "R"}) ==
             :ok

    # no :sys.get_state: the call has already handled the event
    assert [%{event_type: :purge_request_recorded, status: :success, metadata: %{request_id: "R"}}] =
             Malachi.AuditLog.get_events_by_user(actor)
  end

  test "a refusal is recorded as a failure with its rendered reason, like audit/6" do
    actor = actor()
    assert AdminCall.audit_durably(:topic_purged, actor, "purge_topic", {:error, :no_such_topic}, %{}) == :ok
    assert [%{status: :failure, metadata: %{reason: "no_such_topic"}}] = Malachi.AuditLog.get_events_by_user(actor)
  end

  test "an audit log that is not running is :audit_unavailable, where a cast would be dropped unseen" do
    pid = Process.whereis(Malachi.AuditLog)
    true = Process.unregister(Malachi.AuditLog)

    try do
      assert AdminCall.audit_durably(:purge_request_recorded, actor(), "r", :ok, %{}) == {:error, :audit_unavailable}
    after
      true = Process.register(pid, Malachi.AuditLog)
    end
  end

  test "an audit log that does not answer in time is :audit_unavailable" do
    :ok = :sys.suspend(Malachi.AuditLog)

    try do
      assert AdminCall.audit_durably(:purge_request_recorded, actor(), "r", :ok, %{}, 100) ==
               {:error, :audit_unavailable}
    after
      :ok = :sys.resume(Malachi.AuditLog)
    end
  end
end
