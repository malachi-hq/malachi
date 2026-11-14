defmodule Malachi.Cluster.CompressedCopiesTest do
  # Three replicas of a sealed batch segment whose records are stored zstd-compressed, so the bytes on each
  # disk are far below what the records weigh. That is what the replicas hold once #204 ships the primary's
  # batch bytes; here each copy is written with the same validated batches directly, which yields the same
  # files. Every comparison of copies must use logical numbers: a scrub and a self-healing pass that read the
  # stored bytes against the sealed size would call every copy lost and start a heal storm.
  use ExUnit.Case, async: true

  alias Malachi.BatchCodec
  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Cluster.Retention
  alias Malachi.Cluster.Scrubber
  alias Malachi.Cluster.SelfHealing
  alias Malachi.Log.Record
  alias Malachi.Log.SegmentFiles
  alias Malachi.Metadata
  alias Malachi.Storage.ElixirStore
  alias Malachi.Storage.Layout
  alias Malachi.Test.TmpDir

  defp start_replica do
    name = :"compressed_#{System.unique_integer([:positive])}"
    directory = TmpDir.path("malachi_compressed")
    on_exit(fn -> File.rm_rf!(directory) end)
    start_supervised!({ReplicationServer, [name: name, directory: directory]}, id: name)
    {{name, node()}, directory}
  end

  # JSON-like events: compressible the way real payloads are (#192).
  defp batches do
    for b <- 0..3 do
      for i <- 0..49 do
        n = b * 50 + i

        value =
          ~s({"event":"page_view","user_id":#{rem(n, 7)},"path":"/products/#{rem(n, 11)}","ts":#{1_700_000_000 + n}})

        {Record.new(value, key: "user-#{rem(n, 7)}", timestamp: 1_700_000_000_000 + n), false}
      end
    end
  end

  defp write_copy(directory, segment_id, batches) do
    {:ok, store} =
      ElixirStore.open(Layout.segment_directory(directory, segment_id), SegmentFiles.id(0), format: :batch)

    store =
      Enum.reduce(batches, store, fn batch, store ->
        {:ok, store, _first, _last} = ElixirStore.append_encoded(store, BatchCodec.build(batch, :zstd))
        store
      end)

    {:ok, store} = ElixirStore.seal(store)
    :ok = ElixirStore.close(store)
  end

  setup do
    replicas = for _ <- 1..3, do: start_replica()
    refs = Enum.map(replicas, &elem(&1, 0))

    {metadata, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "events", 2})
    segment_id = {root, 0}
    {metadata, :ok} = Metadata.apply(metadata, Metadata.register_command(root, segment_id, refs, 0, :batch), 1)

    batches = batches()
    for {_ref, dir} <- replicas, do: write_copy(dir, segment_id, batches)

    # The seal's sizes come from the fence on the primary, as on the produce path.
    {:ok, end_offset, sizes} = ReplicationServer.seal(hd(refs), segment_id, 0)
    for ref <- tl(refs), do: assert({:ok, ^end_offset, ^sizes} = ReplicationServer.seal(ref, segment_id, 0))

    segment = Metadata.get_segment(metadata, segment_id)
    {metadata, :ok} = Metadata.apply(metadata, Metadata.seal_command(segment, end_offset, sizes, 0))

    %{replicas: replicas, refs: refs, metadata: metadata, segment_id: segment_id, sizes: sizes, records: 200}
  end

  test "the stored bytes are well below the logical bytes, on every copy", ctx do
    %{logical: logical, stored: stored} = ctx.sizes
    assert stored * 3 < logical

    for {_ref, dir} <- ctx.replicas do
      on_disk =
        dir
        |> Layout.segment_directory(ctx.segment_id)
        |> SegmentFiles.log_paths()
        |> elem(1)
        |> Enum.map(&File.stat!(&1).size)
        |> Enum.sum()

      assert on_disk == stored
    end

    sealed = Metadata.get_segment(ctx.metadata, ctx.segment_id)
    assert %{byte_size: ^logical, stored_bytes: ^stored, length: 200} = sealed
  end

  test "a self-healing pass reports no lost copy and starts no backfill", ctx do
    for ref <- ctx.refs, do: assert(ReplicationServer.stored_bytes(ref, ctx.segment_id) == ctx.sizes.logical)

    result = SelfHealing.heal_sealed(ctx.metadata, ctx.refs, 3)
    assert result.applied == []
    assert result.repaired == []
    assert result.failed == []
  end

  test "a scrub on every node verifies its copy and reports no short copy", ctx do
    for {ref, dir} <- ctx.replicas do
      scrubber =
        start_supervised!(
          {Scrubber,
           metadata_source: fn -> ctx.metadata end,
           local_ref: ref,
           directory: dir,
           apply_command: fn _command -> flunk("the scrub tried to change the control plane") end,
           on_result: fn _result -> :ok end,
           interval: 60_000},
          id: {:scrubber, System.unique_integer([:positive])}
        )

      assert %{verified: [segment_id], damaged: [], repaired: [], unrepairable: []} = Scrubber.scrub_now(scrubber)
      assert segment_id == ctx.segment_id
    end
  end

  test "a copy cut short after it sealed is short to the probe and the scrub, despite its manifest", ctx do
    [_a, {b, b_dir} | _] = ctx.replicas
    [path] = b_dir |> Layout.segment_directory(ctx.segment_id) |> SegmentFiles.log_paths() |> elem(1)
    intact = File.read!(path)
    File.write!(path, binary_part(intact, 0, div(byte_size(intact), 2)))

    # The manifest still describes the whole file, and is no longer believed: the size changed.
    assert File.exists?(SegmentFiles.path(Path.dirname(path), SegmentFiles.id(0), :manifest))
    assert ReplicationServer.stored_bytes(b, ctx.segment_id) < ctx.sizes.logical

    scrubber =
      start_supervised!(
        {Scrubber,
         metadata_source: fn -> ctx.metadata end,
         local_ref: b,
         directory: b_dir,
         apply_command: fn _command -> :ok end,
         on_result: fn _result -> :ok end,
         interval: 60_000},
        id: {:scrubber, System.unique_integer([:positive])}
      )

    ExUnit.CaptureLog.capture_log(fn ->
      assert %{damaged: [{segment_id, _verdict}]} = Scrubber.scrub_now(scrubber)
      assert segment_id == ctx.segment_id
    end)
  end

  test "a restarted follower without a manifest is scanned once, then answers from the manifest the scan left",
       ctx do
    [_a, {{b_name, _node} = b, b_dir} | _] = ctx.replicas
    segment_dir = Layout.segment_directory(b_dir, ctx.segment_id)
    manifest = SegmentFiles.path(segment_dir, SegmentFiles.id(0), :manifest)
    [log_path] = segment_dir |> SegmentFiles.log_paths() |> elem(1)

    # A follower's store is never sealed by a roll, so it has no manifest; and after a restart its log is not
    # open, so the probe takes the directory path.
    File.rm!(manifest)
    :ok = stop_supervised(b_name)
    start_supervised!({ReplicationServer, [name: b_name, directory: b_dir]}, id: {b_name, :restarted})

    assert ReplicationServer.stored_bytes(b, ctx.segment_id) == ctx.sizes.logical
    assert File.exists?(manifest)

    # The next probe is a stat: bytes changed in place, at the same size, are not read (the scrub, which always
    # scans, is what catches them).
    intact = File.read!(log_path)
    File.write!(log_path, <<0x4D, 0x42>> <> :binary.copy(<<0xAB>>, byte_size(intact) - 2))
    assert ReplicationServer.stored_bytes(b, ctx.segment_id) == ctx.sizes.logical

    # A size change is not believed: the copy is measured again, and found short.
    File.write!(log_path, binary_part(intact, 0, div(byte_size(intact), 2)))
    assert ReplicationServer.stored_bytes(b, ctx.segment_id) < ctx.sizes.logical
  end

  test "retention by size counts the stored bytes, not the logical ones", ctx do
    %{logical: logical, stored: stored} = ctx.sizes
    between = div(logical + stored, 2)

    assert Retention.expired(ctx.metadata, 0, %{max_age_ms: nil, max_bytes: between}) == []
    assert Retention.expired(ctx.metadata, 0, %{max_age_ms: nil, max_bytes: stored - 1}) == [ctx.segment_id]
  end
end
