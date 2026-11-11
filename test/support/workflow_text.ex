defmodule Malachi.Test.WorkflowText do
  @moduledoc """
  Reads a GitHub Actions workflow file as text, for the tests that pin its shape. The repository has no YAML
  parser among its test dependencies, and the properties those tests hold are visible in the text.
  """

  @workflows Path.expand("../../.github/workflows", __DIR__)

  @doc "The path of a workflow file, by its basename."
  @spec path(String.t()) :: String.t()
  def path(file), do: Path.join(@workflows, file)

  @doc "Every workflow file."
  @spec files() :: [String.t()]
  def files, do: Path.wildcard(Path.join(@workflows, "*.yml"))

  @doc """
  Each job's text, keyed by its id: from `  <id>:` at two spaces to the next job or the end of the file. A comment
  written above a job is split off on its own, has no job id, and is dropped.
  """
  @spec jobs(String.t()) :: %{String.t() => String.t()}
  def jobs(text) do
    [_, body] = String.split(text, ~r/^jobs:\n/m, parts: 2)

    for job <- Regex.split(~r/^(?=  [a-z][a-z0-9_-]*:\n)/m, body, trim: true),
        [id] <- [Regex.run(~r/\A  ([a-z][a-z0-9_-]*):/, job, capture: :all_but_first)],
        into: %{},
        do: {id, job}
  end
end
