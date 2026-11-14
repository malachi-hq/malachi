defmodule Malachi.MetadataLegalHoldTest do
  # The legal hold in the control plane (#307): `{:set_topic_hold, topic, request}` places or releases a hold,
  # and while one is in place the commands that would remove the topic's data are refused.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.MetadataMachine
  alias Malachi.Metadata

  @at 1_700_000_000_000
  @request %{reason: "case 2026-114", actor: "admin"}

  defp topic(state \\ Metadata.new(), name \\ "events") do
    {state, {:ok, root}} = Metadata.apply(state, {:create_topic, name, 2})
    {state, root}
  end

  defp hold(state, topic \\ "events", request \\ @request),
    do: Metadata.apply(state, {:set_topic_hold, topic, request}, @at)

  defp release(state, topic \\ "events"), do: Metadata.apply(state, {:set_topic_hold, topic, nil}, @at)

  # A topic with one sealed segment in its root range, the shape every refusal below needs.
  defp with_sealed_segment do
    {state, root} = topic()
    {state, :ok} = Metadata.apply(state, Metadata.register_command(root, {root, 0}, [:a], 0, :record), @at)
    {state, :ok} = Metadata.apply(state, {:seal_segment, {root, 0}, 10, 100, @at})
    {state, root, {root, 0}}
  end

  describe "placing a hold" do
    test "stores the reason, the actor and the time the log entry carries" do
      {state, _root} = topic()
      assert {state, :ok} = hold(state)
      assert Metadata.legal_hold(state, "events") == %{reason: "case 2026-114", actor: "admin", since_ms: @at}
    end

    test "is refused for an unknown topic" do
      assert {_state, {:error, :no_such_topic}} = hold(Metadata.new(), "nope")
    end

    test "is refused on a topic already held, which keeps its first hold" do
      {state, _root} = topic()
      {state, :ok} = hold(state)
      assert {^state, {:error, :already_held}} = hold(state, "events", %{reason: "another", actor: "other"})
      assert Metadata.legal_hold(state, "events").reason == "case 2026-114"
    end

    test "is refused without a timestamp from the log entry, so no replica stores a time it made up" do
      {state, _root} = topic()
      assert {^state, {:error, :invalid_hold}} = Metadata.apply(state, {:set_topic_hold, "events", @request})
    end

    test "is refused for a request of any other shape" do
      {state, _root} = topic()

      for request <- [%{reason: "r"}, %{reason: "r", actor: "a", extra: 1}, "r", %{reason: :r, actor: "a"}] do
        assert {^state, {:error, :invalid_hold}} = hold(state, "events", request)
      end
    end

    test "is refused for a reason or an actor that could forge a line in the audit trail" do
      {state, _root} = topic()

      line_separator = <<0xE2, 0x80, 0xA8>>
      right_to_left_override = <<0xE2, 0x80, 0xAE>>

      for bad <- [
            "",
            String.duplicate("a", 1025),
            <<0xFF, 0xFE>>,
            "a\nb",
            "a\rb",
            "a\tb",
            "a" <> line_separator <> "b",
            "a" <> right_to_left_override <> "b",
            <<?a, 0, ?b>>
          ] do
        assert {^state, {:error, :invalid_hold}} = hold(state, "events", %{reason: bad, actor: "admin"}), inspect(bad)
        assert {^state, {:error, :invalid_hold}} = hold(state, "events", %{reason: "r", actor: bad}), inspect(bad)
      end

      assert {_state, :ok} = hold(state, "events", %{reason: String.duplicate("é", 512), actor: "admin"})
    end

    test "is allowed on a sealed topic" do
      {state, _root} = topic()
      {state, :ok} = Metadata.apply(state, {:seal_topic, "events"})
      assert {_state, :ok} = hold(state)
    end

    test "is fenced like any other command while the topic migrates" do
      {state, _root} = topic()
      {state, :ok} = Metadata.apply(state, {:begin_migration, "events"})
      assert {^state, {:error, :migrating}} = hold(state)
    end

    test "is routed to the topic it names" do
      assert Metadata.command_target_topic({:set_topic_hold, "events", nil}) == "events"
    end
  end

  describe "releasing a hold" do
    test "returns the topic to exactly the shape it had before the hold" do
      {state, _root} = topic()
      before = Metadata.get_topic(state, "events")
      {state, :ok} = hold(state)
      assert {state, :ok} = release(state)
      assert Metadata.get_topic(state, "events") == before
      assert Metadata.legal_hold(state, "events") == nil
    end

    test "is refused on a topic that is not held" do
      {state, _root} = topic()
      assert {^state, {:error, :not_held}} = release(state)
    end

    test "is refused for an unknown topic" do
      assert {_state, {:error, :no_such_topic}} = release(Metadata.new(), "nope")
    end
  end

  describe "while a topic is held" do
    test "deleting it is refused, and allowed again once released" do
      {state, _root} = topic()
      {held, :ok} = hold(state)
      assert {^held, {:error, :legal_hold}} = Metadata.apply(held, {:delete_topic, "events"})

      {released, :ok} = release(held)
      assert {state, :ok} = Metadata.apply(released, {:delete_topic, "events"})
      assert Metadata.get_topic(state, "events") == nil
    end

    test "deleting one of its sealed segments is refused, which stops a sweep planned before the hold" do
      {state, _root, segment} = with_sealed_segment()
      {held, :ok} = hold(state)
      assert {^held, {:error, :legal_hold}} = Metadata.apply(held, {:delete_segment, segment})

      {released, :ok} = release(held)
      assert {_state, :ok} = Metadata.apply(released, {:delete_segment, segment})
    end

    test "moving its logical start is refused" do
      {state, root, _segment} = with_sealed_segment()
      {held, :ok} = hold(state)
      assert {^held, {:error, :legal_hold}} = Metadata.apply(held, {:set_range_starts, "events", %{root => 5}})

      {released, :ok} = release(held)
      assert {_state, {:ok, %{^root => {0, 5}}}} = Metadata.apply(released, {:set_range_starts, "events", %{root => 5}})
    end

    test "writing to it goes on: a hold keeps data, it does not stop the topic" do
      {state, root, _segment} = with_sealed_segment()
      {held, :ok} = hold(state)
      assert {held, :ok} = Metadata.apply(held, Metadata.register_command(root, {root, 1}, [:a], 10, :record), @at)
      assert {held, :ok} = Metadata.apply(held, {:seal_segment, {root, 1}, 5, 50, @at})
      assert {_held, {:ok, _left, _right}} = Metadata.apply(held, {:split_range, root})
    end

    test "another topic is untouched by it" do
      {state, _root} = topic()
      {state, _other_root} = topic(state, "other")
      {state, :ok} = hold(state)
      assert {state, :ok} = Metadata.apply(state, {:delete_topic, "other"})
      assert Metadata.get_topic(state, "events") != nil
    end

    test "an unknown segment is still answered as unknown, not as held" do
      {state, _root} = topic()
      {held, :ok} = hold(state)
      assert {^held, {:error, :no_such_segment}} = Metadata.apply(held, {:delete_segment, {:nope, 0}})
    end
  end

  describe "through the replicated machine" do
    defp meta(effective), do: %{machine_version: effective, index: 1, term: 1, system_time: @at}

    test "a member below version 11 refuses the command with the state unchanged" do
      {state, _root} = topic()

      assert {^state, {:error, {:unsupported_command, {:set_topic_hold, 3}, 11, 10}}} =
               MetadataMachine.apply(meta(10), {:set_topic_hold, "events", @request}, state)
    end

    test "at version 11 the hold takes the timestamp of the log entry" do
      {state, _root} = topic()
      {state, :ok} = MetadataMachine.apply(meta(11), {:set_topic_hold, "events", @request}, state)
      assert Metadata.legal_hold(state, "events").since_ms == @at
    end
  end

  describe "valid_hold_text?/1" do
    test "rejects anything that is not a binary" do
      refute Metadata.valid_hold_text?(nil)
      refute Metadata.valid_hold_text?(:atom)
      refute Metadata.valid_hold_text?(123)
    end

    test "accepts exactly 1024 bytes and refuses 1025" do
      assert Metadata.valid_hold_text?(String.duplicate("a", 1024))
      refute Metadata.valid_hold_text?(String.duplicate("a", 1025))
    end
  end
end
