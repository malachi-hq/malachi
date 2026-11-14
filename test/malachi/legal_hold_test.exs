defmodule Malachi.LegalHoldTest do
  # The broker and the audit log are the ones the application started: global state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.LegalHold
  alias Malachi.Log.Record
  alias Malachi.LogApi
  alias Malachi.Policies
  alias Malachi.Purge
  alias Malachi.Topics

  doctest Malachi.LegalHold

  setup do
    suffix = System.unique_integer([:positive])
    topic = "hold-test-#{suffix}"
    actor = "holder_#{suffix}"
    shard = DataPlaneRouter.shard_for(topic)
    :ok = LogApi.create_topic(shard, topic)
    {:ok, _placements} = BrokerServer.produce(shard, topic, [Record.new("v0", key: "k0")])
    %{topic: topic, actor: actor, shard: shard}
  end

  defp audited(actor, event_type) do
    _ = :sys.get_state(Malachi.AuditLog)
    actor |> Malachi.AuditLog.get_events_by_user() |> Enum.filter(&(&1.event_type == event_type))
  end

  # A write a broker applied is visible to its own reads at once; the hold is read back the same way.
  defp hold_of(topic) do
    {:ok, hold} = LegalHold.get(topic)
    hold
  end

  describe "set/3 and release/2" do
    test "a hold is placed, read back with its actor and reason, audited and logged", ctx do
      log = capture_log(fn -> assert LegalHold.set(ctx.topic, "case 2026-114", ctx.actor) == :ok end)

      assert log =~ ctx.topic
      assert log =~ "case 2026-114"
      assert %{reason: "case 2026-114", actor: actor, since_ms: since} = hold_of(ctx.topic)
      assert actor == ctx.actor
      assert is_integer(since) and since > 0

      assert [%{action: "set_topic_hold", status: :success, metadata: metadata}] =
               audited(ctx.actor, :topic_hold_set)

      assert metadata == %{topic: ctx.topic, reason: "case 2026-114"}
    end

    test "releasing returns the topic to not held, audited and logged", ctx do
      :ok = LegalHold.set(ctx.topic, "r", ctx.actor)
      log = capture_log(fn -> assert LegalHold.release(ctx.topic, ctx.actor) == :ok end)

      assert log =~ "released"
      assert hold_of(ctx.topic) == nil
      assert [%{status: :success, metadata: %{topic: topic}}] = audited(ctx.actor, :topic_hold_released)
      assert topic == ctx.topic
    end

    test "refusals are audited by their reason and change nothing", ctx do
      assert LegalHold.release(ctx.topic, ctx.actor) == {:error, :not_held}
      assert LegalHold.set("", "r", ctx.actor) == {:error, :invalid_topic}
      assert LegalHold.set(ctx.topic, "", ctx.actor) == {:error, :invalid_hold}
      assert LegalHold.set(ctx.topic, "line\nforged", ctx.actor) == {:error, :invalid_hold}
      assert LegalHold.set("hold-ghost-#{ctx.actor}", "r", ctx.actor) == {:error, :no_such_topic}

      :ok = LegalHold.set(ctx.topic, "first", ctx.actor)
      assert LegalHold.set(ctx.topic, "second", ctx.actor) == {:error, :already_held}
      assert hold_of(ctx.topic).reason == "first"

      failures = for event <- audited(ctx.actor, :topic_hold_set), event.status == :failure, do: event.metadata.reason
      assert Enum.any?(failures, &String.starts_with?(&1, "invalid_hold"))
      assert Enum.any?(failures, &String.starts_with?(&1, "already_held"))
      assert Enum.any?(failures, &(&1 == "no_such_topic"))

      assert [%{status: :failure, metadata: %{reason: "not_held: " <> _}}] = audited(ctx.actor, :topic_hold_released)
    end

    test "an actor that could forge an audit line is refused before anything is sent", ctx do
      assert LegalHold.set(ctx.topic, "r", "admin\nforged") == {:error, :invalid_hold}
      assert hold_of(ctx.topic) == nil
    end

    test "get/1 refuses a malformed topic and answers an unknown one as such" do
      assert LegalHold.get("") == {:error, :invalid_topic}
      assert LegalHold.get("hold-ghost-#{System.unique_integer([:positive])}") == {:error, :no_such_topic}
    end

    test "the topic's policy read-back reports the hold", ctx do
      assert {:ok, %{legal_hold: nil}} = Policies.topic_policy(ctx.topic)
      :ok = LegalHold.set(ctx.topic, "r", ctx.actor)
      assert {:ok, %{legal_hold: %{reason: "r"}}} = Policies.topic_policy(ctx.topic)
    end
  end

  describe "while a topic is held" do
    test "deleting it is refused and audited, and goes through once released", ctx do
      :ok = LegalHold.set(ctx.topic, "r", ctx.actor)

      assert Topics.delete(ctx.topic, ctx.actor) == {:error, :legal_hold}
      assert {:ok, _hold} = LegalHold.get(ctx.topic)

      assert [%{action: "delete_topic", status: :failure, metadata: %{reason: "legal_hold: " <> _}}] =
               audited(ctx.actor, :topic_deleted)

      :ok = LegalHold.release(ctx.topic, ctx.actor)
      log = capture_log(fn -> assert Topics.delete(ctx.topic, ctx.actor) == :ok end)
      assert log =~ "deleted"
      assert LegalHold.get(ctx.topic) == {:error, :no_such_topic}
      assert Enum.any?(audited(ctx.actor, :topic_deleted), &(&1.status == :success))
    end

    test "purging it is refused and audited, even a purge that would move nothing", ctx do
      :ok = LegalHold.set(ctx.topic, "r", ctx.actor)

      assert Purge.purge(ctx.topic, {:before, 0}, ctx.actor) == {:error, :legal_hold}

      assert Enum.any?(audited(ctx.actor, :topic_purged), fn event ->
               event.status == :failure and event.metadata.reason =~ "legal_hold"
             end)
    end

    test "writing to it goes on", ctx do
      :ok = LegalHold.set(ctx.topic, "r", ctx.actor)
      assert {:ok, _placements} = BrokerServer.produce(ctx.shard, ctx.topic, [Record.new("v1", key: "k1")])
    end
  end

  test "Topics.delete refuses a malformed topic" do
    assert Topics.delete("", "someone") == {:error, :invalid_topic}
  end
end
