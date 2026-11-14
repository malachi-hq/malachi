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
  alias Malachi.Purge.Request

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

  # The purge's own log lines. When another test turns the audit log's stdout output on, the audit entries
  # themselves are logged as `[AUDIT] {...}` lines, and the purge's flush writes them inside the capture;
  # they are the audit output, which holds the actor and the reason by design, so they are left out.
  defp purge_log(fun) do
    fun
    |> capture_log()
    |> String.split("\n")
    |> Enum.reject(&String.contains?(&1, "[AUDIT]"))
    |> Enum.join("\n")
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
      purge_log(fn ->
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
    log = purge_log(fn -> assert Purge.purge(ctx.topic, {:before, 0}, ctx.actor) == {:ok, %{}} end)
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
    assert Enum.any?(reasons, &String.starts_with?(&1, "invalid_purge_point: "))
    assert "no_such_topic" in reasons
    assert Enum.any?(reasons, &String.starts_with?(&1, "start_past_end: "))
  end

  test "a refused topic or point is audited by its size, never its bytes, and logs nothing", ctx do
    forged = "t\n%{actor}"
    huge_token = :binary.copy(<<0xAB>>, 1025)
    bad_group = "billing" <> <<0x2028::utf8>> <> "forged"

    log =
      purge_log(fn ->
        assert Purge.purge(forged, {:before, 0}, ctx.actor) == {:error, :invalid_topic}
        assert Purge.purge(String.duplicate("a", 256), {:before, 0}, ctx.actor) == {:error, :invalid_topic}
        assert Purge.purge(ctx.topic, {:position, huge_token}, ctx.actor) == {:error, :invalid_purge_point}
        assert Purge.purge(ctx.topic, {:position, ""}, ctx.actor) == {:error, :invalid_purge_point}
        assert Purge.purge(ctx.topic, {:group, bad_group}, ctx.actor) == {:error, :invalid_purge_point}
        assert Purge.purge(ctx.topic, {:group, String.duplicate("g", 256)}, ctx.actor) == {:error, :invalid_purge_point}
        assert Purge.purge(ctx.topic, :everything, ctx.actor) == {:error, :invalid_purge_point}
        assert Purge.purge(:not_a_topic, {:before, 0}, ctx.actor) == {:error, :invalid_topic}
      end)

    refute log =~ "forged"
    refute log =~ ctx.actor

    failures = Enum.filter(audited(ctx.actor), &(&1.event_type == :topic_purged))
    assert length(failures) == 8
    assert Enum.all?(failures, &(&1.status == :failure))

    metadata = Enum.map(failures, & &1.metadata)
    point_refusal = Purge.reason_string(:invalid_purge_point)
    assert %{topic: "<10 bytes>", point: "before:0", reason: "invalid_topic"} in metadata
    assert %{topic: "<256 bytes>", point: "before:0", reason: "invalid_topic"} in metadata
    assert %{topic: ctx.topic, point: "position:<1025 bytes>", reason: point_refusal} in metadata
    assert %{topic: ctx.topic, point: "position:<0 bytes>", reason: point_refusal} in metadata
    assert %{topic: ctx.topic, point: "group:<#{byte_size(bad_group)} bytes>", reason: point_refusal} in metadata
    assert %{topic: ctx.topic, point: "group:<256 bytes>", reason: point_refusal} in metadata
    assert %{topic: ctx.topic, point: "<unrecognized>", reason: point_refusal} in metadata
    assert %{topic: "<not a string>", point: "before:0", reason: "invalid_topic"} in metadata
    refute inspect(metadata) =~ "forged"
    refute Enum.any?(audited(ctx.actor), &(&1.event_type == :purge_request_recorded))
  end

  describe "with a data subject request" do
    setup ctx do
      {:ok, request} = Request.new("DSR-#{ctx.actor}", "LGPD art. 18 request")
      %{request: request}
    end

    defp requested(actor, request_id) do
      actor
      |> audited()
      |> Enum.filter(&(Map.get(&1.metadata, :request_id) == request_id))
      |> Enum.sort_by(& &1.event_type)
    end

    test "records the request, then the purge with the same id, and logs both", ctx do
      point = {:position, Position.encode(ctx.root, {0, 2})}

      log =
        purge_log(fn ->
          assert Purge.purge(ctx.topic, point, ctx.actor, ctx.request) == {:ok, %{ctx.root => {0, 2}}}
        end)

      assert log =~ "Purge request #{ctx.request.id} recorded by #{ctx.actor} for topic #{ctx.topic}"
      assert log =~ "for request #{ctx.request.id}: logical start moved on 1 range(s)"
      assert log =~ "logical purge"
      refute log =~ ctx.request.reason

      assert [recorded, planned, purged] = requested(ctx.actor, ctx.request.id)

      assert %{event_type: :purge_request_recorded, action: "record_purge_request", status: :success} = recorded

      assert recorded.metadata == %{
               topic: ctx.topic,
               point: Purge.describe_point(point),
               request_id: ctx.request.id,
               request_reason: ctx.request.reason
             }

      assert %{event_type: :topic_purge_planned, action: "plan_purge", status: :success} = planned
      assert planned.metadata.planned == %{inspect(ctx.root) => [0, 2]}
      assert planned.metadata.request_id == ctx.request.id

      assert %{event_type: :topic_purged, action: "purge_topic", status: :success} = purged
      assert purged.metadata.moves == %{inspect(ctx.root) => [0, 2]}
      refute Map.has_key?(purged.metadata, :request_reason)

      assert {["v2", "v3", "v4"], [%{cause: :purged}]} = values(ctx.shard, ctx.root)
    end

    test "takes the id and reason as a pair as well as a struct", ctx do
      assert {:ok, _} = Purge.purge(ctx.topic, {:before, 0}, ctx.actor, {ctx.request.id, ctx.request.reason})

      assert [%{event_type: :purge_request_recorded}, %{event_type: :topic_purged}] =
               requested(ctx.actor, ctx.request.id)
    end

    test "a request the broker refuses stays recorded, with the refusal under the same id", ctx do
      ghost = "purge-ghost-#{ctx.actor}"

      log =
        purge_log(fn ->
          assert Purge.purge(ghost, {:before, 0}, ctx.actor, ctx.request) == {:error, :no_such_topic}
        end)

      assert log =~ "Purge request #{ctx.request.id} recorded"
      refute log =~ "purged up to"

      assert [recorded, refused] = requested(ctx.actor, ctx.request.id)
      assert %{event_type: :purge_request_recorded, status: :success} = recorded
      assert %{event_type: :topic_purged, status: :failure} = refused
      assert refused.metadata.reason == "no_such_topic"
      assert refused.metadata.topic == ghost
    end

    test "a request that moves nothing is recorded and its purge audited as a success with no moves", ctx do
      log = purge_log(fn -> assert Purge.purge(ctx.topic, {:before, 0}, ctx.actor, ctx.request) == {:ok, %{}} end)

      assert log =~ "Purge request #{ctx.request.id} recorded"
      refute log =~ "purged up to"

      assert [_recorded, %{event_type: :topic_purged, status: :success} = purged] = requested(ctx.actor, ctx.request.id)
      assert purged.metadata.moves == %{}
    end

    test "running the same request again moves nothing and is audited again", ctx do
      point = {:position, Position.encode(ctx.root, {0, 3})}
      assert Purge.purge(ctx.topic, point, ctx.actor, ctx.request) == {:ok, %{ctx.root => {0, 3}}}
      assert Purge.purge(ctx.topic, point, ctx.actor, ctx.request) == {:ok, %{}}

      events = requested(ctx.actor, ctx.request.id)
      assert Enum.count(events, &(&1.event_type == :purge_request_recorded)) == 2
      assert Enum.count(events, &(&1.event_type == :topic_purged and &1.status == :success)) == 2
    end

    test "an invalid request is refused before the broker, recorded by sizes only", ctx do
      point = {:position, Position.encode(ctx.root, {0, 4})}

      for {request, sizes} <- [
            {{"DSR 1", "reason"}, {"<5 bytes>", "<6 bytes>"}},
            {{"DSR-1", "line\nbreak"}, {"<5 bytes>", "<10 bytes>"}},
            {{"DSR-1", nil}, {"<5 bytes>", "<none>"}},
            {{nil, "only a reason"}, {"<none>", "<13 bytes>"}},
            {{"DSR-1", String.duplicate("x", 513)}, {"<5 bytes>", "<513 bytes>"}},
            {%Request{id: "DSR\n1", reason: "built by hand"}, {"<5 bytes>", "<13 bytes>"}},
            {{42, "a number for an id"}, {"<not a string>", "<18 bytes>"}},
            {:not_a_request, {"<none>", "<none>"}}
          ] do
        log =
          purge_log(fn -> assert Purge.purge(ctx.topic, point, ctx.actor, request) == {:error, :invalid_request} end)

        refute log =~ "Purge request"
        refute log =~ "purged up to"

        {id_size, reason_size} = sizes

        assert Enum.any?(audited(ctx.actor), fn event ->
                 event.event_type == :topic_purged and event.status == :failure and
                   event.metadata.request_id == id_size and event.metadata.request_reason == reason_size and
                   String.starts_with?(event.metadata.reason, "invalid_request: ")
               end),
               "no sizes-only entry for #{inspect(request)}"
      end

      refute inspect(audited(ctx.actor)) =~ "line\\nbreak"
      refute Enum.any?(audited(ctx.actor), &(&1.event_type == :purge_request_recorded))
      # nothing reached the broker: every record is still readable
      assert {["v0", "v1", "v2", "v3", "v4"], []} = values(ctx.shard, ctx.root)
    end

    test "a valid request whose topic or point is refused is still recorded, the refusal under its id", ctx do
      log =
        purge_log(fn ->
          assert Purge.purge("a/b\n%{actor}", {:before, 0}, ctx.actor, ctx.request) == {:error, :invalid_topic}

          assert Purge.purge(ctx.topic, {:group, String.duplicate("g", 256)}, ctx.actor, ctx.request) ==
                   {:error, :invalid_purge_point}
        end)

      refute log =~ "Purge request"

      events = requested(ctx.actor, ctx.request.id)
      recorded = Enum.filter(events, &(&1.event_type == :purge_request_recorded))
      refused = Enum.filter(events, &(&1.event_type == :topic_purged))
      request = %{request_id: ctx.request.id, request_reason: ctx.request.reason}

      assert recorded |> Enum.map(& &1.metadata) |> Enum.sort() ==
               Enum.sort([
                 Map.merge(%{topic: "<12 bytes>", point: "before:0"}, request),
                 Map.merge(%{topic: ctx.topic, point: "group:<256 bytes>"}, request)
               ])

      assert Enum.all?(refused, &(&1.status == :failure))
      assert refused |> Enum.map(& &1.metadata.topic) |> Enum.sort() == Enum.sort(["<12 bytes>", ctx.topic])
      refute inspect(events) =~ "a/b"
    end

    test "the request is in the audit trail before the broker is asked", ctx do
      broker = DataPlaneRouter.shard_for(ctx.topic)
      :ok = :sys.suspend(broker)

      task =
        Task.async(fn ->
          Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 1})}, ctx.actor, ctx.request)
        end)

      recorded? = fn type -> Enum.any?(requested(ctx.actor, ctx.request.id), &(&1.event_type == type)) end

      try do
        # The broker cannot answer while suspended, so a recorded entry seen now was written before the
        # purge reached it, and no topic_purged entry can exist yet.
        assert wait_until(fn -> recorded?.(:purge_request_recorded) end)
        refute recorded?.(:topic_purged)
      after
        :ok = :sys.resume(broker)
      end

      assert Task.await(task) == {:ok, %{ctx.root => {0, 1}}}
      assert recorded?.(:topic_purged)
    end

    test "the request's entry is written durably before the broker is asked, and the log flushed after the purge's",
         ctx do
      audit = Process.whereis(Malachi.AuditLog)
      broker = DataPlaneRouter.shard_for(ctx.topic)
      point = {:position, Position.encode(ctx.root, {0, 1})}

      # Every message the audit log receives is traced, so the flush calls this purge's own process makes,
      # and their order against its entries, can be read off; the ETS table alone cannot show a flush.
      1 = :erlang.trace(audit, true, [:receive])
      :ok = :sys.suspend(broker)
      task = Task.async(fn -> Purge.purge(ctx.topic, point, ctx.actor, ctx.request) end)
      caller = task.pid

      try do
        try do
          # one durable call from the purge's own process, answered before the broker (suspended) is asked
          assert_receive {:trace, ^audit, :receive,
                          {:"$gen_call", {^caller, _tag}, {:log_event_durably, :purge_request_recorded, _, _, _, _}}},
                         2_000
        after
          :ok = :sys.resume(broker)
        end

        assert {:ok, _moves} = Task.await(task)

        # In order: the purge's own entry reaches the log before the flush it then asks for.
        assert next_trace(audit, caller) == :topic_purged
        assert next_trace(audit, caller) == :flush_now
      after
        :erlang.trace(audit, false, [:receive])
      end
    end

    test "a purge still queued when its caller gave up is dropped: no plan, no move", ctx do
      broker = DataPlaneRouter.shard_for(ctx.topic)
      point = {:position, Position.encode(ctx.root, {0, 3})}
      :ok = :sys.suspend(broker)

      result =
        try do
          # the broker cannot take the request within the caller's 4 s, so the caller is answered timeout
          Purge.purge(ctx.topic, point, ctx.actor, ctx.request)
        after
          :ok = :sys.resume(broker)
        end

      assert result == {:error, :timeout}
      # the broker now reaches the stale request and drops it: the start never moves
      _ = :sys.get_state(broker)
      assert {["v0", "v1", "v2", "v3", "v4"], []} = values(ctx.shard, ctx.root)

      events = requested(ctx.actor, ctx.request.id)
      refute Enum.any?(events, &(&1.event_type == :topic_purge_planned))

      assert [%{status: :failure, metadata: %{reason: "timeout: " <> _}}] =
               Enum.filter(events, &(&1.event_type == :topic_purged))
    end

    test "an invalid request with an invalid topic or point is refused as the request, every bad field by size",
         ctx do
      bad = {"DSR 1", "reason"}

      assert Purge.purge("a/b\n", {:before, 0}, ctx.actor, bad) == {:error, :invalid_request}
      assert Purge.purge(ctx.topic, {:group, "g\n%{actor}"}, ctx.actor, bad) == {:error, :invalid_request}

      refused =
        ctx.actor
        |> audited()
        |> Enum.filter(&(&1.event_type == :topic_purged and &1.status == :failure))
        |> Enum.map(& &1.metadata)

      assert %{topic: "<4 bytes>", point: "before:0", request_id: "<5 bytes>", request_reason: "<6 bytes>"} =
               Enum.find(refused, &(&1.topic == "<4 bytes>"))

      assert %{topic: _, point: "group:<10 bytes>", request_id: "<5 bytes>"} =
               Enum.find(refused, &(&1.point == "group:<10 bytes>"))

      assert Enum.all?(refused, &String.starts_with?(&1.reason, "invalid_request: "))
      refute inspect(refused) =~ "%{actor}"
      refute Enum.any?(audited(ctx.actor), &(&1.event_type == :purge_request_recorded))
    end

    test "a request whose entry the audit log cannot write is refused before the broker is asked", ctx do
      pid = Process.whereis(Malachi.AuditLog)
      point = {:position, Position.encode(ctx.root, {0, 3})}
      true = Process.unregister(Malachi.AuditLog)

      log =
        try do
          purge_log(fn ->
            assert Purge.purge(ctx.topic, point, ctx.actor, ctx.request) == {:error, :audit_unavailable}
          end)
        after
          true = Process.register(pid, Malachi.AuditLog)
        end

      assert log =~ "Request #{ctx.request.id} by #{ctx.actor} for topic #{ctx.topic} could not be written"
      refute log =~ "Purge request #{ctx.request.id} recorded"
      # nothing was sent: every record is still readable
      assert {["v0", "v1", "v2", "v3", "v4"], []} = values(ctx.shard, ctx.root)
      assert Purge.reason_string(:audit_unavailable) =~ "audit_unavailable: the audit log could not write"
    end

    test "a purge without a request records no request", ctx do
      assert {:ok, _} = Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 1})}, ctx.actor)

      events = audited(ctx.actor)
      refute Enum.any?(events, &(&1.event_type == :purge_request_recorded))
      assert [purged] = Enum.filter(events, &(&1.event_type == :topic_purged))
      refute Map.has_key?(purged.metadata, :request_id)
    end
  end

  test "every purge that moves a range records its plan before the command, the same moves it reports", ctx do
    point = {:position, Position.encode(ctx.root, {0, 2})}
    assert {:ok, moves} = Purge.purge(ctx.topic, point, ctx.actor)

    assert [planned] = Enum.filter(audited(ctx.actor), &(&1.event_type == :topic_purge_planned))
    assert %{action: "plan_purge", status: :success} = planned

    assert planned.metadata == %{
             topic: ctx.topic,
             point: Purge.describe_point(point),
             planned: %{inspect(ctx.root) => [0, 2]}
           }

    assert moves == %{ctx.root => {0, 2}}

    # a point that moves nothing has no plan
    assert Purge.purge(ctx.topic, {:before, 0}, ctx.actor) == {:ok, %{}}
    assert [_only_one] = Enum.filter(audited(ctx.actor), &(&1.event_type == :topic_purge_planned))
  end

  test "a purge refused after it was planned keeps its plan: what it set out to move is on record", ctx do
    {:ok, request} = Request.new("DSR-plan-#{ctx.actor}", "LGPD art. 18 request")
    point = {:position, Position.encode(ctx.root, {0, 99})}

    assert Purge.purge(ctx.topic, point, ctx.actor, request) == {:error, :start_past_end}

    events = Enum.filter(audited(ctx.actor), &(&1.metadata[:request_id] == request.id))
    assert [planned] = Enum.filter(events, &(&1.event_type == :topic_purge_planned))
    assert planned.metadata.planned == %{inspect(ctx.root) => [0, 99]}
    assert [%{status: :failure}] = Enum.filter(events, &(&1.event_type == :topic_purged))
  end

  test "a plan callback that raises is logged and does not stop the purge or the broker", ctx do
    shard = DataPlaneRouter.shard_for(ctx.topic)
    point = {:position, Position.encode(ctx.root, {0, 1})}

    log =
      capture_log(fn ->
        assert BrokerServer.purge(shard, ctx.topic, point, fn _plan -> raise "boom" end) == {:ok, %{ctx.root => {0, 1}}}
      end)

    assert log =~ "Recording the purge plan of topic #{ctx.topic} failed: boom; the purge goes on"

    point = {:position, Position.encode(ctx.root, {0, 2})}

    log =
      capture_log(fn ->
        assert BrokerServer.purge(shard, ctx.topic, point, fn _plan -> exit(:gone) end) == {:ok, %{ctx.root => {1, 2}}}
      end)

    assert log =~ "{:exit, :gone}"
    assert {["v2", "v3", "v4"], _skips} = values(ctx.shard, ctx.root)
  end

  test "an audit log that cannot flush does not take the purge down, and is reported", ctx do
    :ok = :sys.suspend(Malachi.AuditLog)

    log =
      try do
        capture_log(fn -> assert Purge.purge("a/b", {:before, 0}, ctx.actor) == {:error, :invalid_topic} end)
      after
        :ok = :sys.resume(Malachi.AuditLog)
      end

    assert log =~ "Could not flush the audit log for a purge"
    # the entry was queued, so it is written once the log answers again
    assert Enum.any?(audited(ctx.actor), &(&1.event_type == :topic_purged and &1.metadata.topic == "<3 bytes>"))
  end

  test "a group name with spaces is accepted: only control, format, line and paragraph separators are not", ctx do
    assert Purge.purge(ctx.topic, {:group, "billing team"}, ctx.actor) == {:ok, %{}}
    assert Purge.purge(ctx.topic, {:group, "billing\u00A0team"}, ctx.actor) == {:ok, %{}}
  end

  describe "telemetry" do
    setup do
      parent = self()
      id = "purge-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:malachi, :purge, :done],
        fn _event, measurements, metadata, _config ->
          send(parent, {:purge_done, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp purge_done(topic) do
      receive do
        {:purge_done, measurements, %{topic: ^topic} = metadata} -> {measurements, metadata}
      after
        2_000 -> flunk("no [:malachi, :purge, :done] for #{topic}")
      end
    end

    test "an applied purge reports the ranges moved and the offsets it stopped serving", ctx do
      {:ok, request} = Request.new("DSR-tel-#{ctx.actor}", "LGPD art. 18 request")
      assert {:ok, _} = Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 3})}, ctx.actor, request)

      assert {%{count: 1, ranges: 1, offsets: 3}, %{kind: :position, result: :applied, reason: nil, request: true}} =
               purge_done(ctx.topic)
    end

    test "a purge that moves nothing and a refused one are reported too, without a request", ctx do
      assert {:ok, %{}} = Purge.purge(ctx.topic, {:group, "nobody"}, ctx.actor)

      assert {%{count: 1, ranges: 0, offsets: 0}, %{kind: :group, result: :nothing, request: false}} =
               purge_done(ctx.topic)

      assert {:error, :invalid_purge_point} = Purge.purge(ctx.topic, {:before, -1}, ctx.actor)

      assert {%{ranges: 0, offsets: 0}, %{kind: :before, result: :refused, reason: :invalid_purge_point}} =
               purge_done(ctx.topic)

      assert {:error, :invalid_topic} = Purge.purge("a/b", :everything, ctx.actor)
      assert {_, %{kind: :other, result: :refused, reason: :invalid_topic}} = purge_done("<3 bytes>")
    end

    test "the reporter counts purges by outcome, kind and request, and the offsets purged", ctx do
      before = Malachi.Metrics.get_system_metrics().operations
      {:ok, _} = Purge.purge(ctx.topic, {:position, Position.encode(ctx.root, {0, 2})}, ctx.actor)
      after_ = Malachi.Metrics.get_system_metrics().operations

      count = fn ops ->
        Enum.find_value(ops.purges, fn {labels, n} ->
          labels == [result: "applied", kind: "position", request: "false"] && n
        end)
      end

      assert count.(after_) - count.(before) >= 1
      assert after_.purged_offsets - before.purged_offsets >= 2
      assert length(after_.purges) == 24
    end
  end

  test "the largest token and group name the check accepts get past it", ctx do
    # A 1024-byte token is not a position the topic issued, so the broker refuses it, but not as a bad point.
    assert Purge.purge(ctx.topic, {:position, :binary.copy(<<1>>, 1024)}, ctx.actor) == {:error, :invalid_position}
    assert Purge.purge(ctx.topic, {:group, String.duplicate("g", 255)}, ctx.actor) == {:ok, %{}}
  end

  # The next message the audit log received from this purge's process, or its topic_purged entry (the
  # plan arrives from the broker, so it is skipped), as :topic_purged or :flush_now, in arrival order.
  defp next_trace(audit, caller) do
    receive do
      {:trace, ^audit, :receive, {:"$gen_cast", {:log_event, :topic_purged, _, _, _, _}}} -> :topic_purged
      {:trace, ^audit, :receive, {:"$gen_call", {^caller, _tag}, :flush_now}} -> :flush_now
    after
      2_000 -> :none
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  test "reason_string/1 renders the purge's own refusals and falls back for the shared ones" do
    assert Purge.reason_string(:invalid_purge_point) =~ "invalid_purge_point: give exactly one point"
    assert Purge.reason_string(:invalid_purge_point) =~ "1 to 1024 bytes"
    assert Purge.reason_string(:invalid_purge_point) =~ "1 to 255 bytes"
    assert Purge.reason_string(:start_past_end) =~ "start_past_end: "
    assert Purge.reason_string(:invalid_request) =~ "invalid_request: give both a request id (1 to 128 bytes"
    assert Purge.reason_string(:invalid_request) =~ "1 to 512 bytes"
    assert Purge.reason_string({:unsupported_command, {:set_range_starts, 3}, 9, 8}) =~ "unsupported_command: "
    assert Purge.reason_string(:timeout) =~ "timeout: "
  end

  test "describe_point/1 names a point it does not recognize by inspecting it" do
    assert Purge.describe_point(:everything) == ":everything"
  end
end
