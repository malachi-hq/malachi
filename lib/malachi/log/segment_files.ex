defmodule Malachi.Log.SegmentFiles do
  @moduledoc """
  The one place that knows how a segment's files are named on disk.

  A log directory holds, per segment, a data file (`<id>.log`) and its sidecars: the sparse index
  (`<id>.idx`), the per-file seal marker (`<id>.sealed`), the manifest (`<id>.manifest`) and, only while a
  truncation rewrites the file, `<id>.log.rewrite`. The id is the segment's base offset, zero padded to
  20 digits, so names sort in offset order.

  Every reader that lists or builds these names goes through here: the log, the replication server, the
  chaos checker and the tests. A second spelling of the rule is how one of them ends up counting a file the
  others do not see, and a count that disagrees between replicas is what starts a heal.

  Listing is strict. Only names that are exactly `<20 digits>.log` are segments; anything else in the
  directory (a dotfile, a temporary file, a stray `foo.log`) is ignored rather than parsed, so a foreign
  file can neither crash a listing nor be taken for data.
  """

  @id_width 20
  @log_name ~r/\A(\d{20})\.log\z/

  @typedoc "What a path is for."
  @type kind :: :log | :index | :seal_marker | :manifest | :rewrite

  @doc "The id of the segment that starts at `base_offset`: the offset, zero padded to #{@id_width} digits."
  @spec id(non_neg_integer()) :: String.t()
  def id(base_offset) when is_integer(base_offset) and base_offset >= 0 do
    base_offset |> Integer.to_string() |> String.pad_leading(@id_width, "0")
  end

  @doc "The path of the segment `id`'s file of `kind` in `directory`."
  @spec path(Path.t(), String.t(), kind()) :: Path.t()
  def path(directory, id, kind) when is_binary(id), do: Path.join(directory, id <> extension(kind))

  @doc "The data file of the segment that starts at `base_offset`."
  @spec log_path(Path.t(), non_neg_integer()) :: Path.t()
  def log_path(directory, base_offset), do: path(directory, id(base_offset), :log)

  @doc """
  The files a segment owns, in the order they are removed: sidecars first, the data file last.

  The order matters. `list/1` finds a segment through its `.log` and nothing else, so removing that first
  and then failing on a sidecar would hide the segment from every later pass while its leftovers stay.
  """
  @spec removal_order() :: [kind()]
  def removal_order, do: [:rewrite, :manifest, :seal_marker, :index, :log]

  @doc "The base offset named by a data file name, or `:error` for any other name."
  @spec base_offset(String.t()) :: {:ok, non_neg_integer()} | :error
  def base_offset(name) when is_binary(name) do
    case Regex.run(@log_name, Path.basename(name)) do
      [_, digits] -> {:ok, String.to_integer(digits)}
      nil -> :error
    end
  end

  @doc """
  The base offsets of the segment data files in `directory`, sorted.

  A directory that does not exist (or whose parent is a file) holds no segments, so `{:ok, []}`. One that
  cannot be listed is an error, never an empty list: `File.ls/1` is used rather than a wildcard, which
  answers `[]` for a directory it cannot read.
  """
  @spec list(Path.t()) :: {:ok, [non_neg_integer()]} | {:error, File.posix()}
  def list(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        {:ok, names |> Enum.flat_map(&offset_list/1) |> Enum.sort()}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The paths of the segment data files in `directory`, in offset order. Same errors as `list/1`."
  @spec log_paths(Path.t()) :: {:ok, [Path.t()]} | {:error, File.posix()}
  def log_paths(directory) do
    with {:ok, offsets} <- list(directory) do
      {:ok, Enum.map(offsets, &log_path(directory, &1))}
    end
  end

  defp offset_list(name) do
    case base_offset(name) do
      {:ok, offset} -> [offset]
      :error -> []
    end
  end

  defp extension(:log), do: ".log"
  defp extension(:index), do: ".idx"
  defp extension(:seal_marker), do: ".sealed"
  defp extension(:manifest), do: ".manifest"
  defp extension(:rewrite), do: ".log.rewrite"
end
