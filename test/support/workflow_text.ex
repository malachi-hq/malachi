defmodule Malachi.Test.WorkflowText do
  @moduledoc """
  Reads a GitHub Actions workflow file, for the tests that pin its shape: as text (`jobs/1`), for properties
  visible in it, and parsed (`yaml_jobs/1`, `steps/1`), for what depends on the YAML structure: which job a step
  belongs to, whether it can fail the run, and the matrix entries it runs for.
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

  @typedoc "One step of a workflow, with what decides whether it runs and whether its failure fails the run."
  @type step :: %{
          job: String.t(),
          name: String.t() | nil,
          uses: String.t() | nil,
          with: map(),
          run: String.t(),
          conditions: [String.t()],
          continue_on_error: [term()],
          matrix: [map()]
        }

  @doc """
  Each job's settings parsed as YAML, paired with its id, in the order the file declares them. Read with yamerl,
  which keeps a mapping's keys in the order written (YamlElixir reverses them).
  """
  @spec yaml_jobs(String.t()) :: [{String.t(), map()}]
  def yaml_jobs(text) do
    [document] = :yamerl_constr.string(String.to_charlist(text), [:str_node_as_binary])
    {"jobs", jobs} = List.keyfind(document, "jobs", 0)

    for {id, settings} <- jobs, do: {id, Map.new(settings)}
  end

  @doc """
  Every step of every job. `conditions` holds the job's and the step's `if`, `continue_on_error` every
  `continue-on-error` of the job or the step that is set to anything but false, and `matrix` the entries the job
  runs for (see `matrix_entries/1`).
  """
  @spec steps(String.t()) :: [step()]
  def steps(text) do
    for {id, job} <- yaml_jobs(text),
        step <- Map.get(job, "steps", []),
        step = Map.new(step) do
      %{
        job: id,
        name: step["name"],
        uses: step["uses"],
        with: Map.new(step["with"] || []),
        run: step["run"] || "",
        conditions: Enum.reject([job["if"], step["if"]], &is_nil/1),
        continue_on_error:
          Enum.filter([job["continue-on-error"], step["continue-on-error"]], &(&1 not in [nil, false])),
        matrix: matrix_entries(job["strategy"])
      }
    end
  end

  @doc """
  The entries a job runs for, from its `strategy` as yamerl reads it: every combination of its axes, plus its
  `include` entries, or one empty entry when it has no matrix. An axis given as an expression
  (`${{ fromJSON(...) }}`) is only known when the workflow runs, so it counts as one entry holding the expression.
  An `exclude` is not read, so a matrix with one raises instead of counting an entry that never runs.
  """
  @spec matrix_entries(list() | nil) :: [map()]
  def matrix_entries(nil), do: [%{}]

  def matrix_entries(strategy) do
    matrix = Map.new(Map.new(strategy)["matrix"] || [])
    if Map.has_key?(matrix, "exclude"), do: raise(ArgumentError, "a matrix exclude is not read")
    {include, axes} = Map.pop(matrix, "include", [])

    combinations =
      Enum.reduce(axes, [%{}], fn {key, values}, acc ->
        for entry <- acc, value <- axis_values(values), do: Map.put(entry, key, value)
      end)

    combinations = if axes == %{} and include != [], do: [], else: combinations
    combinations ++ Enum.map(include, &Map.new/1)
  end

  defp axis_values(values) when is_list(values), do: values
  defp axis_values(expression) when is_binary(expression), do: [expression]
end
