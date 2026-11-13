defmodule Malachi.Console.StreamHubTest do
  use ExUnit.Case, async: true

  alias Malachi.Console.Reads
  alias Malachi.Console.Sampler
  alias Malachi.Console.StreamHub

  defp overview(system, topics \\ %{}), do: %{"system" => system, "topics" => topics}

  # A hub that reads whatever the test last put in the Agent, ticking only when the test says so (a huge
  # interval) unless it asks for a fast one.
  defp start_hub(opts \\ []) do
    {:ok, source} = Agent.start_link(fn -> {:ok, overview(%{"run_queue" => 0})} end)
    read = fn -> Agent.get(source, & &1) end
    name = :"hub_#{System.unique_integer([:positive])}"

    hub_opts = [
      name: name,
      read: read,
      interval_ms: Keyword.get(opts, :interval_ms, 3_600_000),
      ring_size: Keyword.get(opts, :ring_size, 300)
    ]

    start_supervised!({StreamHub, hub_opts}, id: name)
    %{hub: name, source: source}
  end

  defp set(source, value), do: Agent.update(source, fn _ -> value end)
  defp tick(hub), do: send(Process.whereis(hub), :tick)

  defp next_event do
    assert_receive {:console_stream_event, event}, 1_000
    event
  end

  describe "delta/2" do
    test "names the series that changed, the topics that changed or appeared, and those that went away" do
      old = overview(%{"a" => 1, "b" => 2}, %{"t1" => %{"name" => "t1", "bytes" => 1}, "gone" => %{"name" => "gone"}})
      new = overview(%{"a" => 1, "b" => 3}, %{"t1" => %{"name" => "t1", "bytes" => 2}, "t2" => %{"name" => "t2"}})

      assert StreamHub.delta(old, new) == %{
               "system" => %{"b" => 3},
               "topics" => %{"changed" => [%{"name" => "t1", "bytes" => 2}, %{"name" => "t2"}], "removed" => ["gone"]}
             }

      assert StreamHub.delta(new, new) == :unchanged
    end
  end

  test "a client with no id starts from a snapshot as of the current sequence" do
    %{hub: hub} = start_hub()
    assert [%{event: "snapshot", id: id, data: data}] = StreamHub.subscribe(nil, hub)
    assert [_epoch, "0"] = String.split(id, ".")
    assert data == %{"system" => %{"run_queue" => 0}, "topics" => [], "available" => true}
  end

  test "each tick that changed something is one numbered delta to every subscriber, and a quiet one is none" do
    %{hub: hub, source: source} = start_hub()
    [%{id: start}] = StreamHub.subscribe(nil, hub)
    [epoch, "0"] = String.split(start, ".")

    set(source, {:ok, overview(%{"run_queue" => 4})})
    tick(hub)
    assert %{event: "overview", id: id, data: %{"system" => %{"run_queue" => 4}}} = next_event()
    assert id == "#{epoch}.1"

    tick(hub)
    refute_receive {:console_stream_event, _}, 100
  end

  test "a client that resumes inside the ring gets every event after its id, nothing skipped or repeated" do
    %{hub: hub, source: source} = start_hub()
    [%{id: start}] = StreamHub.subscribe(nil, hub)

    ids =
      for n <- 1..3 do
        set(source, {:ok, overview(%{"run_queue" => n})})
        tick(hub)
        next_event().id
      end

    assert Enum.map(StreamHub.subscribe(start, hub), & &1.id) == ids
    assert Enum.map(StreamHub.subscribe(Enum.at(ids, 0), hub), & &1.id) == Enum.drop(ids, 1)
    # current as of the last event: nothing to replay
    assert StreamHub.subscribe(List.last(ids), hub) == []
  end

  test "an id older than the ring is a gap that counts what was lost, then a snapshot" do
    %{hub: hub, source: source} = start_hub(ring_size: 2)
    [%{id: start}] = StreamHub.subscribe(nil, hub)

    for n <- 1..5 do
      set(source, {:ok, overview(%{"run_queue" => n})})
      tick(hub)
      next_event()
    end

    # the ring holds events 4 and 5; the client saw 0, so 1, 2 and 3 are lost
    assert [%{event: "gap", data: gap}, %{event: "snapshot", data: %{"system" => %{"run_queue" => 5}}}] =
             StreamHub.subscribe(start, hub)

    assert %{"type" => "gap", "from" => ^start, "dropped" => 3, "reason" => "expired"} = gap
  end

  test "an id from another hub, from the future, or not an id at all is a gap of unknown size" do
    %{hub: hub} = start_hub()
    [%{id: id}] = StreamHub.subscribe(nil, hub)
    [epoch, _] = String.split(id, ".")

    for other <- ["otherepoch.0", "#{epoch}.99", "#{epoch}.-1", "#{epoch}.x", "garbage"] do
      assert [%{event: "gap", data: %{"dropped" => nil, "reason" => "unknown", "from" => ^other}}, %{event: "snapshot"}] =
               StreamHub.subscribe(other, hub),
             other
    end
  end

  test "a sample that fails is one error event, and the next that works resumes the deltas" do
    %{hub: hub, source: source} = start_hub()
    StreamHub.subscribe(nil, hub)

    set(source, {:error, :down})
    tick(hub)
    assert %{event: "error", data: %{"type" => "errors.http.unavailable"}} = next_event()
    tick(hub)
    refute_receive {:console_stream_event, _}, 100
    assert [%{data: %{"available" => false}}] = StreamHub.subscribe(nil, hub)

    set(source, {:ok, overview(%{"run_queue" => 7})})
    tick(hub)
    assert %{event: "overview", data: %{"system" => %{"run_queue" => 7}}} = next_event()
  end

  test "it samples once per tick however many subscribe, and not at all with none" do
    %{hub: hub, source: source} = start_hub(interval_ms: 20)
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "stream-hub-#{inspect(ref)}",
      [:malachi, :console, :stream, :sample],
      fn _event, measurements, _meta, _ ->
        send(parent, {ref, measurements.subscribers})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("stream-hub-#{inspect(ref)}") end)

    subscribers =
      for _n <- 1..5 do
        Task.async(fn ->
          StreamHub.subscribe(nil, hub)
          receive do: (:stop -> :ok)
        end)
      end

    Process.sleep(150)
    samples = collect(ref)
    # every sample was taken once for all of them, however many there were
    assert length(samples) in 1..10
    assert Enum.max(samples) <= 5

    for task <- subscribers, do: send(task.pid, :stop)
    Enum.each(subscribers, &Task.await/1)
    Process.sleep(60)
    collect(ref)
    set(source, {:ok, overview(%{"run_queue" => 1})})
    Process.sleep(100)
    assert collect(ref) == []
  end

  defp collect(ref, acc \\ []) do
    receive do
      {^ref, subscribers} -> collect(ref, [subscribers | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a hub that was idle samples before answering, so a resume sees what changed meanwhile" do
    %{hub: hub, source: source} = start_hub()

    task = Task.async(fn -> StreamHub.subscribe(nil, hub) end)
    [%{id: id}] = Task.await(task)
    # its only subscriber is gone; the hub goes idle
    Process.sleep(50)

    set(source, {:ok, overview(%{"run_queue" => 42})})
    assert [%{event: "overview", data: %{"system" => %{"run_queue" => 42}}}] = StreamHub.subscribe(id, hub)
  end

  describe "read_overview/0" do
    setup do
      Sampler.clear()
      on_exit(fn -> Sampler.clear() end)
    end

    test "carries every served series and this node's topics" do
      assert {:ok, %{"system" => system, "topics" => topics}} = StreamHub.read_overview()
      assert Map.keys(system) |> Enum.sort() == Reads.history_series()
      assert is_map(topics)
    end

    test "is an error when the metadata cannot be read" do
      :ok = :sys.suspend(Malachi.LogBroker)

      try do
        assert {:error, :metadata_unavailable} = StreamHub.read_overview()
      after
        :sys.resume(Malachi.LogBroker)
      end
    end
  end

  test "a ring size setting that is not a positive integer falls back to the default" do
    Application.put_env(:malachi, :console_stream_ring_size, 0)
    on_exit(fn -> Application.delete_env(:malachi, :console_stream_ring_size) end)
    name = :"hub_default_#{System.unique_integer([:positive])}"
    start_supervised!({StreamHub, name: name, read: fn -> {:ok, overview(%{})} end, interval_ms: 3_600_000}, id: name)
    assert :sys.get_state(name).ring_size == 300
  end
end
