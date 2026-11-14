defmodule Malachi.Test.SegmentFilesHelper do
  @moduledoc """
  The segment data files a test looks at, found the way production finds them.

  Tests reach into a log directory to corrupt, truncate, measure or delete a segment file. Listing with
  `Path.wildcard("*.log")` would be a second spelling of what a segment file is, so a change to the naming
  rule could leave the tests checking files production no longer reads. This delegates to
  `Malachi.Log.SegmentFiles` instead.
  """

  alias Malachi.Log.SegmentFiles

  @doc "The segment data files in `directory`, in offset order; `[]` when the directory does not exist."
  @spec log_files(Path.t()) :: [Path.t()]
  def log_files(directory) do
    {:ok, paths} = SegmentFiles.log_paths(directory)
    paths
  end
end
