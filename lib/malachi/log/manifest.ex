defmodule Malachi.Log.Manifest do
  @moduledoc """
  What a sealed segment file holds, written once when it seals: `<id>.manifest`, beside its data file.

      <<"MLMF", manifest_version::8, format::8, record_count::64, logical_bytes::64, logical_hash::32,
        stored_bytes::64, crc32::32>>

    * `format` - how the records are framed (`t:Malachi.Log.Frames.format/0`).
    * `record_count`, `logical_bytes`, `logical_hash` - the logical numbers every replica comparison uses
      (`c:Malachi.Storage.SegmentStore.logical_bytes/1`), so a sealed file answers them without a scan.
    * `stored_bytes` - the size of the data file when the manifest was written.
    * `crc32` - `:erlang.crc32/1` of every byte before it.

  ## When it is believed

  A manifest describes a file that should never change again, and it is believed only while that is
  visibly true: the data file's size must still be `stored_bytes` (`trusted/2`). A file cut short after it
  sealed (a truncation, a lost tail) no longer matches, so its numbers come from a scan instead, and the
  copy is seen as short rather than vouched for by a description of what it used to hold. The scrub goes
  further and always scans, then compares: a manifest that disagrees with its file is reported as damage
  (`:bad_manifest`) and rewritten locally, like a damaged index, because it is derived from the file.

  A missing manifest is not damage: a file sealed before manifests existed, or one whose manifest was lost,
  is scanned, and the scrub writes it again.

  ## Versions

  `manifest_version` is 1. A later version (re-blocking, #209, would add a generation) is a new layout read
  beside this one; an unknown version is refused as `:bad_manifest` rather than guessed at.
  """

  alias Malachi.Storage.Directory

  @magic "MLMF"
  @version 1
  @format_codes [record: 0, batch: 1]

  @enforce_keys [:format, :record_count, :logical_bytes, :logical_hash, :stored_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format: Malachi.Log.Frames.format(),
          record_count: non_neg_integer(),
          logical_bytes: non_neg_integer(),
          logical_hash: non_neg_integer(),
          stored_bytes: non_neg_integer()
        }

  @doc "The manifest's bytes."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = manifest) do
    body =
      <<@magic::binary, @version::8, Keyword.fetch!(@format_codes, manifest.format)::8, manifest.record_count::64,
        manifest.logical_bytes::64, manifest.logical_hash::32, manifest.stored_bytes::64>>

    <<body::binary, :erlang.crc32(body)::32>>
  end

  @doc "A manifest read back from its bytes, or `{:error, :bad_manifest}` for anything else."
  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_manifest}
  def decode(<<body::binary-size(34), crc::32>>) do
    with true <- :erlang.crc32(body) == crc,
         <<@magic, @version::8, code::8, records::64, logical::64, hash::32, stored::64>> <- body,
         {format, _code} <- Enum.find(@format_codes, fn {_format, value} -> value == code end) do
      {:ok,
       %__MODULE__{
         format: format,
         record_count: records,
         logical_bytes: logical,
         logical_hash: hash,
         stored_bytes: stored
       }}
    else
      _bad -> {:error, :bad_manifest}
    end
  end

  def decode(_binary), do: {:error, :bad_manifest}

  @doc """
  Writes `manifest` to `path` durably: the content fsynced, then the directory, so the entry that makes it
  exist survives a power failure too.
  """
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(path, %__MODULE__{} = manifest) do
    with :ok <- File.write(path, encode(manifest), [:sync]) do
      Directory.sync(Path.dirname(path))
    end
  end

  @doc "The manifest at `path`: `{:error, :enoent}` when there is none, `{:error, :bad_manifest}` when it is not one."
  @spec read(Path.t()) :: {:ok, t()} | {:error, :enoent | :bad_manifest | File.posix()}
  def read(path) do
    with {:ok, binary} <- File.read(path), do: decode(binary)
  end

  @doc """
  The manifest at `manifest_path`, when it still describes the data file at `log_path`: same size as when it
  was written. `:untrusted` when it is missing, damaged, or the file has changed size since.
  """
  @spec trusted(Path.t(), Path.t()) :: {:ok, t()} | :untrusted
  def trusted(manifest_path, log_path) do
    with {:ok, %__MODULE__{stored_bytes: stored} = manifest} <- read(manifest_path),
         {:ok, %{size: ^stored}} <- File.stat(log_path) do
      {:ok, manifest}
    else
      _missing_damaged_or_changed -> :untrusted
    end
  end
end
