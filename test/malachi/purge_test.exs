defmodule Malachi.PurgeTest do
  # The broker and the audit log are the ones the application started: global state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.Log.Record
  alias Malachi.LogApi
  alias Malachi.Position
  alias Malachi.Purge

  doctest Malachi.Purge

  setup do
    suffix = System.unique_integer([:positive])
    topic = "purge-test-#{suffix}"
    actor = "purger_#{suffix}"
    shard = DataPlaneRouter.shard_for(topic)
    :ok = LogApi.create_topic(shard, topic)
    records = for i <- 0..4, do: Record.new("v#{i}", key: "k#{i}")
    {:ok, _placements} = BrokerServer.produce(shard, topic, records)
    %{topic: topic, actor: actor, shard: shard, root: {topic, 0}}
  end

  defp audited(actor) do
    _ = :sys.get_state(Malachi.AuditLog)
    Malachi.AuditLog.get_events_by_user(actor)
  end

  defp values(shard, range_id) do
    {:ok, records, _cursor, skips} = BrokerServer.read_consume(shard, range_id, :start, 100)
    {Enum.map(records, & &1.value), skips}
  end

  test "a purge to a position clamps every reader, is audited with the starts, and logged", ctx do
    log =
      capture_log(fn ->
        assert Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 3})}, ctx.actor) ==
                 {:ok, %{ctx.root => {0, 3}}}
      end)

    assert log =~ ctx.topic
    assert log =~ "logical purge"

    assert {["v3", "v4"], [%{cause: :purged, offsets: 3}]} = values(ctx.shard, ctx.root)

    assert Enum.any?(audited(ctx.actor), fn event ->
             match?(%{event_type: :topic_purged, action: "purge_topic", status: :success}, event) and
               event.metadata.moves == %{inspect(ctx.root) => [0, 3]} and
               event.metadata.point =~ "position:"
           end)
  end

  test "a time before any seal moves nothing, still answers ok, is audited, and logs no purge line", ctx do
    log = capture_log(fn -> assert Purge.purge(ctx.topic, {:before, 0}, ctx.actor) == {:ok, %{}} end)
    refute log =~ "purged up to"

    assert Enum.any?(audited(ctx.actor), &match?(%{event_type: :topic_purged, status: :success}, &1))
    assert {["v0", "v1", "v2", "v3", "v4"], []} = values(ctx.shard, ctx.root)
  end

  test "a group that committed nothing purges nothing", ctx do
    assert Purge.purge(ctx.topic, {:group, "nobody"}, ctx.actor) == {:ok, %{}}
  end

  test "refusals are audited by their reason and change nothing", ctx do
    assert Purge.purge("", {:before, 0}, ctx.actor) == {:error, :invalid_topic}
    assert Purge.purge(ctx.topic, {:before, -5}, ctx.actor) == {:error, :invalid_purge_point}
    assert Purge.purge(ctx.topic, {:group, ""}, ctx.actor) == {:error, :invalid_purge_point}
    assert Purge.purge("purge-ghost-#{ctx.actor}", {:before, 0}, ctx.actor) == {:error, :no_such_topic}

    assert Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 99})}, ctx.actor) ==
             {:error, :start_past_end}

    {:ok, _} = Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 2})}, ctx.actor)
    # a position below the start moves nothing: the start never goes back
    assert Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 1})}, ctx.actor) == {:ok, %{}}

    failures = Enum.filter(audited(ctx.actor), &(&1.event_type == :topic_purged and &1.status == :failure))
    reasons = Enum.map(failures, & &1.metadata.reason)
    assert "invalid_topic" in reasons
    assert "invalid_purge_point" in reasons
    assert "no_such_topic" in reasons
    assert Enum.any?(reasons, &String.starts_with?(&1, "start_past_end: "))
  end

  test "reason_string/1 renders the purge's own refusals and falls back for the shared ones" do
    assert Purge.reason_string(:start_past_end) =~ "start_past_end: "
    assert Purge.reason_string({:unsupported_command, {:set_range_starts, 3}, 9, 8}) =~ "unsupported_command: "
    assert Purge.reason_string(:timeout) =~ "timeout: "
  end

  test "describe_point/1 names a point it does not recognize by inspecting it" do
    assert Purge.describe_point(:everything) == ":everything"
  end
end
