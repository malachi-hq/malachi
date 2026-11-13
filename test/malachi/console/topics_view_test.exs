defmodule Malachi.Console.TopicsViewTest do
  use ExUnit.Case, async: true

  alias Malachi.Console.TopicsView
  alias Malachi.Metadata

  @a {Malachi.LogReplication, :a@h}
  @b {Malachi.LogReplication, :b@h}
  @c {Malachi.LogReplication, :c@h}

  defp apply!(state, command) do
    {state, reply} = Metadata.apply(state, command)
    assert reply == :ok or elem(reply, 0) == :ok, "#{inspect(command)}: #{inspect(reply)}"
    state
  end

  # "orders": its root range sealed and split in two, the root's segment sealed on a and b, the left child
  # with an active segment on a, b and c.
  defp metadata do
    {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "orders", 4})

    state =
      state
      |> apply!({:register_segment, root, {root, 0}, [@a, @b], 0})
      |> apply!({:seal_segment, {root, 0}, 10, 100, 1_791_720_000_000})
      |> apply!({:split_range, root})

    {state, {:ok, _other}} = Metadata.apply(state, {:create_topic, "audit", 4})
    apply!(state, {:register_segment, {"orders", 1}, {{"orders", 1}, 0}, [@a, @b, @c], 10})
  end

  test "topics are summarized by name, with their counts" do
    assert [%{name: "audit"}, %{name: "orders"} = orders] = TopicsView.topics(metadata())

    assert %{
             "name" => "orders",
             "state" => "active",
             "ranges" => %{"active" => 2, "total" => 3},
             "segments" => %{"active" => 1, "total" => 2},
             "bytes" => 100,
             "groups" => []
           } = TopicsView.render_topic(orders)

    assert TopicsView.topic?(metadata(), "orders")
    refute TopicsView.topic?(metadata(), "missing")
  end

  test "ranges are listed in sequence order with the ranges they came from" do
    assert [root, left, right] = TopicsView.ranges(metadata(), "orders")

    assert TopicsView.render_range(root) == %{
             "range" => 0,
             "key_start" => 0,
             "key_end" => 16,
             "state" => "sealed",
             "parents" => []
           }

    assert %{seq: 1, parents: [0], state: :active, key_end: 8} = left
    assert %{seq: 2, parents: [0], key_start: 8} = right
    assert TopicsView.ranges(metadata(), "missing") == []
  end

  defp all_healthy(nodes),
    do: %{by_node: Map.new(nodes, &{&1, %{failed: [], damaged: []}}), unanswered: MapSet.new()}

  test "segments are in range then segment order, replicas by node name, and healthy copies say so" do
    [sealed, active] = TopicsView.segments(metadata(), "orders", [:a@h, :b@h, :c@h], 2)
    assert %{range: 0, segment: 0, state: :sealed, replicas: ["a@h", "b@h"], under_replicated: false} = sealed
    assert %{range: 1, segment: 0, state: :active, start_offset: 10} = active

    body = TopicsView.render_segment(sealed, all_healthy(["a@h", "b@h"]))

    assert %{
             "range" => 0,
             "segment" => 0,
             "state" => "sealed",
             "length" => 10,
             "byte_size" => 100,
             "sealed_at" => "2026-10-11T12:00:00.000Z",
             "primary" => "a@h",
             "replica_set" => ["a@h", "b@h"],
             "under_replicated" => false,
             "health" => %{"label" => "sealed", "severity" => "ok"}
           } = body

    assert body["copies"] == [
             %{"node" => "a@h", "conditions" => ["sealed"]},
             %{"node" => "b@h", "conditions" => ["sealed"]}
           ]

    assert TopicsView.render_segment(active, all_healthy(["a@h", "b@h", "c@h"]))["sealed_at"] == nil
  end

  test "a segment with fewer replicas on alive nodes than the factor asks is under replicated" do
    # c is gone: the active segment keeps two of three, the sealed one both of its two
    [sealed, active] = TopicsView.segments(metadata(), "orders", [:a@h, :b@h], 3)
    refute sealed.under_replicated
    refute active.under_replicated

    # with a, b and a fourth node alive, a factor of 3 is reachable, and the sealed segment's two fall short
    [sealed, active] = TopicsView.segments(metadata(), "orders", [:a@h, :b@h, :c@h, :d@h], 3)
    assert sealed.under_replicated
    refute active.under_replicated

    assert %{"under_replicated" => true, "health" => %{"label" => "sealed+under_replicated", "severity" => "error"}} =
             TopicsView.render_segment(sealed, all_healthy(["a@h", "b@h"]))
  end

  test "a single node's replicas are pids, named by the node, and count as live" do
    {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "solo", 4})
    state = apply!(state, {:register_segment, root, {root, 0}, [self()], 0})

    assert [%{replicas: [name], under_replicated: false}] = TopicsView.segments(state, "solo", [node()], 3)
    assert name == Atom.to_string(node())
  end

  test "each copy carries what its node said, and the segment the worst of it" do
    [sealed, _active] = TopicsView.segments(metadata(), "orders", [:a@h, :b@h, :c@h], 2)
    id = {{"orders", 0}, 0}

    health = %{
      by_node: %{"a@h" => %{failed: [id], damaged: :not_scrubbed}, "b@h" => %{failed: :unknown, damaged: [id]}},
      unanswered: MapSet.new()
    }

    body = TopicsView.render_segment(sealed, health)

    assert body["copies"] == [
             %{"node" => "a@h", "conditions" => ["sealed", "failed"]},
             %{"node" => "b@h", "conditions" => ["sealed", "unknown", "damaged"]}
           ]

    assert body["health"] == %{"label" => "sealed+failed+damaged+unknown", "severity" => "error"}
  end

  test "a copy whose node did not answer is unknown, a warning" do
    [sealed, _active] = TopicsView.segments(metadata(), "orders", [:a@h, :b@h], 2)
    health = TopicsView.health(%{answers: [{:a@h, %{failed: [], damaged: []}}], unanswered: [:b@h], unsupported: []})
    assert health.unanswered == MapSet.new(["b@h"])

    body = TopicsView.render_segment(sealed, health)
    assert Enum.at(body["copies"], 1) == %{"node" => "b@h", "conditions" => ["sealed", "unknown"]}
    assert body["health"] == %{"label" => "sealed+unknown", "severity" => "warning"}
  end

  test "a topic of 5000 segments is listed whole and in order" do
    {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "big", 4})

    state =
      Enum.reduce(0..4_999, state, fn seq, acc ->
        acc
        |> apply!({:register_segment, root, {root, seq}, [@a], seq * 10})
        |> apply!({:seal_segment, {root, seq}, 10, 100, 1_791_720_000_000})
      end)

    segments = TopicsView.segments(state, "big", [:a@h], 1)
    assert length(segments) == 5_000
    assert Enum.map(segments, & &1.segment) == Enum.to_list(0..4_999)
  end
end
