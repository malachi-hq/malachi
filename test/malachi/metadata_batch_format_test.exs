defmodule Malachi.MetadataBatchFormatTest do
  # The control plane's half of the batch storage format (#202): a segment's format is decided once, when it is
  # registered, and its seal records both its logical size (what replicas are compared by) and its stored size
  # (what retention counts). Record segments keep the shapes every older member applies.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.MachineVersion
  alias Malachi.Metadata

  defp topic do
    {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 2})
    {state, root}
  end

  defp registered(format) do
    {state, root} = topic()
    id = {root, 0}
    {state, :ok} = Metadata.apply(state, Metadata.register_command(root, id, [:a, :b], 0, format), 1_000)
    {state, root, id}
  end

  describe "registering" do
    test "a batch segment records its format; a record segment carries no format key" do
      {state, _root, id} = registered(:batch)
      segment = Metadata.get_segment(state, id)
      assert segment.format == :batch
      assert segment.stored_bytes == nil
      assert Metadata.segment_format(segment) == :batch

      {state, _root, id} = registered(:record)
      segment = Metadata.get_segment(state, id)
      refute Map.has_key?(segment, :format)
      refute Map.has_key?(segment, :stored_bytes)
      assert Metadata.segment_format(segment) == :record
    end

    test "the record shape is the five-element command, the batch shape the six-element one" do
      assert Metadata.register_command(:r, :s, [:a], 0, :record) == {:register_segment, :r, :s, [:a], 0}
      assert Metadata.register_command(:r, :s, [:a], 0, :batch) == {:register_segment, :r, :s, [:a], 0, :batch}
    end

    test "an unknown format is refused with the state unchanged" do
      {state, root} = topic()
      command = {:register_segment, root, {root, 0}, [:a], 0, :avro}
      assert Metadata.apply(state, command, 1) == {state, {:error, {:unknown_format, :avro}}}
    end

    test "a six-element register still checks the range like the five-element one" do
      {state, root} = topic()
      {state, :ok} = Metadata.apply(state, {:seal_topic, "events"})

      assert {_state, {:error, :sealed}} =
               Metadata.apply(state, Metadata.register_command(root, {root, 0}, [:a], 0, :batch), 1)
    end
  end

  describe "sealing" do
    test "a batch segment's seal records its logical and stored sizes" do
      {state, _root, id} = registered(:batch)
      segment = Metadata.get_segment(state, id)
      command = Metadata.seal_command(segment, 10, %{logical: 900, stored: 300}, 5)

      assert command == {:seal_segment, id, 10, 900, 300, 5}
      assert {state, :ok} = Metadata.apply(state, command)
      sealed = Metadata.get_segment(state, id)
      assert %{state: :sealed, length: 10, byte_size: 900, stored_bytes: 300, sealed_at: 5} = sealed
      assert Metadata.stored_bytes(sealed) == 300

      # An idempotent retry, then a conflicting length, behave as for a record segment.
      assert {^state, :ok} = Metadata.apply(state, command)
      assert {^state, {:error, {:already_sealed, 10}}} = Metadata.apply(state, {:seal_segment, id, 9, 1, 1, 6})
    end

    test "a record segment's seal keeps the five-element shape, whatever sizes it is given" do
      {state, _root, id} = registered(:record)
      segment = Metadata.get_segment(state, id)

      assert Metadata.seal_command(segment, 10, %{logical: 700, stored: 700}, 5) == {:seal_segment, id, 10, 700, 5}
      assert Metadata.seal_command(segment, 10, 700, 5) == {:seal_segment, id, 10, 700, 5}

      {state, :ok} = Metadata.apply(state, {:seal_segment, id, 10, 700, 5})
      sealed = Metadata.get_segment(state, id)
      refute Map.has_key?(sealed, :stored_bytes)
      assert Metadata.stored_bytes(sealed) == 700
    end

    test "a batch segment sealed with one number stores it as both sizes" do
      {_state, _root, id} = registered(:batch)
      segment = %{id: id, start_offset: 0, format: :batch}
      assert Metadata.seal_command(segment, 4, 77, 1) == {:seal_segment, id, 4, 77, 77, 1}
    end

    test "sizes helpers" do
      assert Metadata.logical_bytes(5) == 5
      assert Metadata.logical_bytes(%{logical: 7, stored: 2}) == 7
      assert Metadata.sizes?(0)
      assert Metadata.sizes?(%{logical: 1, stored: 1})
      refute Metadata.sizes?(-1)
      refute Metadata.sizes?(%{logical: 1})
      refute Metadata.sizes?(:x)
      assert Metadata.stored_bytes(%{byte_size: nil}) == 0
    end

    test "the sealed segment id is read from either seal shape" do
      assert Metadata.sealed_segment_id({:seal_segment, :s, 1, 2, 3}) == :s
      assert Metadata.sealed_segment_id({:seal_segment, :s, 1, 2, 2, 3}) == :s
      assert Metadata.sealed_segment_id({:delete_segment, :s}) == nil
    end
  end

  describe "the machine version gate" do
    @meta9 %{machine_version: 9, index: 1, term: 1, system_time: 0}
    @meta10 %{machine_version: 10, index: 1, term: 1, system_time: 0}

    defp gated(meta, state, command) do
      MachineVersion.apply(meta, command, state, Metadata.command_versions(), fn _meta, command, state ->
        Metadata.apply(state, command, 1)
      end)
    end

    test "below version 10 both batch shapes are refused with the state unchanged; at 10 they apply" do
      {state, root} = topic()
      register = Metadata.register_command(root, {root, 0}, [:a], 0, :batch)

      assert {^state, {:error, {:unsupported_command, {:register_segment, 6}, 10, 9}}} = gated(@meta9, state, register)

      assert {^state, {:error, {:unsupported_command, {:seal_segment, 6}, 10, 9}}} =
               gated(@meta9, state, {:seal_segment, {root, 0}, 1, 1, 1, 1})

      assert {_state, :ok} = gated(@meta10, state, register)
    end

    test "the record shapes stay applicable on an older version" do
      {state, root} = topic()
      assert {_state, :ok} = gated(@meta9, state, Metadata.register_command(root, {root, 0}, [:a], 0, :record))
    end

    test "the code version is 10" do
      assert MachineVersion.code_version() == 10
    end
  end

  describe "exporting a topic" do
    test "is format 10 only when it carries a batch segment, so record topics still split under a pin" do
      {state, _root, _id} = registered(:record)
      assert Metadata.export_topic(state, "events").export_format == 0

      {state, _root, _id} = registered(:batch)
      assert Metadata.export_topic(state, "events").export_format == 10
      assert Metadata.export_format() == 10
    end
  end

  describe "routing" do
    test "both new shapes route to the topic they belong to" do
      {state, root, id} = registered(:batch)
      assert Metadata.routed_range_topics(Metadata.register_command(root, {root, 1}, [:a], 0, :batch)) != []
      assert Metadata.routed_range_topics({:seal_segment, id, 1, 1, 1, 1}) != []
      # A migration fence applies to the six-element seal like the five-element one.
      {state, _} = Metadata.apply(state, {:begin_migration, "events"})
      assert {_state, {:error, :migrating}} = Metadata.apply(state, {:seal_segment, id, 1, 1, 1, 1})
    end
  end
end
