defmodule Malachi.Log.ManifestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Malachi.Log.Manifest
  alias Malachi.Log.Record
  alias Malachi.Log.SegmentFiles
  alias Malachi.Storage.ElixirStore

  @moduletag :tmp_dir

  defp manifest(overrides \\ []) do
    struct!(
      Manifest,
      Keyword.merge(
        [format: :batch, record_count: 12, logical_bytes: 900, logical_hash: 0xDEADBEEF, stored_bytes: 400],
        overrides
      )
    )
  end

  property "encode then decode returns the same manifest" do
    check all(
            format <- member_of([:record, :batch]),
            records <- integer(0..1_000_000),
            logical <- integer(0..1_000_000_000),
            hash <- integer(0..0xFFFFFFFF),
            stored <- integer(0..1_000_000_000)
          ) do
      m =
        manifest(
          format: format,
          record_count: records,
          logical_bytes: logical,
          logical_hash: hash,
          stored_bytes: stored
        )

      assert Manifest.decode(Manifest.encode(m)) == {:ok, m}
    end
  end

  test "every single-bit flip, every cut, and anything else is refused" do
    binary = Manifest.encode(manifest())

    for bit <- 0..(byte_size(binary) * 8 - 1) do
      byte = div(bit, 8)
      <<head::binary-size(byte), b::8, tail::binary>> = binary
      assert Manifest.decode(<<head::binary, bxor(b, 1 <<< rem(bit, 8))::8, tail::binary>>) == {:error, :bad_manifest}
    end

    for cut <- 0..(byte_size(binary) - 1),
        do: assert(Manifest.decode(binary_part(binary, 0, cut)) == {:error, :bad_manifest})

    assert Manifest.decode(binary <> <<0>>) == {:error, :bad_manifest}
  end

  test "an unknown version or format is refused even with a valid CRC" do
    <<"MLMF", _version::8, rest::binary-size(29), _crc::32>> = Manifest.encode(manifest())
    body = <<"MLMF", 2::8, rest::binary>>
    assert Manifest.decode(<<body::binary, :erlang.crc32(body)::32>>) == {:error, :bad_manifest}

    <<"MLMF", 1::8, _format::8, rest::binary-size(28), _crc::32>> = Manifest.encode(manifest())
    body = <<"MLMF", 1::8, 7::8, rest::binary>>
    assert Manifest.decode(<<body::binary, :erlang.crc32(body)::32>>) == {:error, :bad_manifest}
  end

  test "trusted only while the data file keeps the size it had", %{tmp_dir: dir} do
    log = Path.join(dir, "x.log")
    path = Path.join(dir, "x.manifest")
    File.write!(log, :binary.copy(<<1>>, 400))
    :ok = Manifest.write(path, manifest())

    assert Manifest.trusted(path, log) == {:ok, manifest()}

    File.write!(log, :binary.copy(<<1>>, 200))
    assert Manifest.trusted(path, log) == :untrusted

    File.rm!(log)
    assert Manifest.trusted(path, log) == :untrusted
    assert Manifest.trusted(Path.join(dir, "absent.manifest"), log) == :untrusted
    assert Manifest.read(Path.join(dir, "absent.manifest")) == {:error, :enoent}
  end

  describe "through the store" do
    test "sealing writes a manifest of what the file holds, in either format", %{tmp_dir: dir} do
      for format <- [:record, :batch] do
        sub = Path.join(dir, Atom.to_string(format))
        {:ok, store} = ElixirStore.open(sub, "s", format: format)
        records = for v <- ~w(a b c), do: Record.new(v, timestamp: 1)
        {:ok, store, 0, 2} = ElixirStore.append(store, records)
        {:ok, store} = ElixirStore.seal(store)
        :ok = ElixirStore.close(store)

        assert {:ok, m} = Manifest.read(SegmentFiles.path(sub, "s", :manifest))
        assert m.format == format
        assert m.record_count == 3
        assert m.logical_bytes == records |> Enum.map(&Record.encoded_size/1) |> Enum.sum()
        assert m.stored_bytes == File.stat!(SegmentFiles.path(sub, "s", :log)).size
        assert {:ok, %{logical_hash: hash}} = ElixirStore.verify(sub, "s", [])
        assert m.logical_hash == hash
      end
    end

    test "a manifest that disagrees with its file is damage the index rebuild repairs", %{tmp_dir: dir} do
      {:ok, store} = ElixirStore.open(dir, "s", format: :batch)
      {:ok, store, _, _} = ElixirStore.append(store, [Record.new("a"), Record.new("b")])
      {:ok, store} = ElixirStore.seal(store)
      :ok = ElixirStore.close(store)
      path = SegmentFiles.path(dir, "s", :manifest)
      {:ok, good} = Manifest.read(path)

      :ok = Manifest.write(path, %{good | record_count: 1})
      assert {:error, %{reason: :bad_manifest, detail: :mismatch}} = ElixirStore.verify(dir, "s", [])

      File.write!(path, "garbage")
      assert {:error, %{reason: :bad_manifest, detail: :bad_manifest}} = ElixirStore.verify(dir, "s", [])

      assert ElixirStore.rebuild_index(dir, "s", []) == :ok
      assert Manifest.read(path) == {:ok, good}
      assert {:ok, _counts} = ElixirStore.verify(dir, "s", [])
    end

    test "a missing manifest is not damage, and a rebuild of a sealed segment writes it", %{tmp_dir: dir} do
      {:ok, store} = ElixirStore.open(dir, "s", format: :batch)
      {:ok, store, _, _} = ElixirStore.append(store, [Record.new("a")])
      {:ok, store} = ElixirStore.seal(store)
      :ok = ElixirStore.close(store)
      path = SegmentFiles.path(dir, "s", :manifest)
      {:ok, good} = Manifest.read(path)
      File.rm!(path)

      assert {:ok, _counts} = ElixirStore.verify(dir, "s", [])
      assert ElixirStore.rebuild_index(dir, "s", []) == :ok
      assert Manifest.read(path) == {:ok, good}
    end

    test "an active segment gets no manifest from a rebuild", %{tmp_dir: dir} do
      {:ok, store} = ElixirStore.open(dir, "s", format: :batch)
      {:ok, store, _, _} = ElixirStore.append(store, [Record.new("a")])
      {:ok, store} = ElixirStore.sync(store)
      :ok = ElixirStore.close(store)

      assert ElixirStore.rebuild_index(dir, "s", []) == :ok
      refute File.exists?(SegmentFiles.path(dir, "s", :manifest))
    end

    test "a truncation of a sealed segment rewrites its manifest", %{tmp_dir: dir} do
      {:ok, store} = ElixirStore.open(dir, "s", format: :batch)
      {:ok, store, _, _} = ElixirStore.append(store, for(v <- ~w(a b c d), do: Record.new(v, timestamp: 1)))
      {:ok, store} = ElixirStore.seal(store)
      {:ok, store} = ElixirStore.truncate_to(store, 2)
      :ok = ElixirStore.close(store)

      assert {:ok, %{record_count: 2} = m} = Manifest.read(SegmentFiles.path(dir, "s", :manifest))
      assert m.stored_bytes == File.stat!(SegmentFiles.path(dir, "s", :log)).size
      assert {:ok, %{records: 2}} = ElixirStore.verify(dir, "s", [])
    end
  end
end
