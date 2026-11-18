defmodule Malachi.Release.Measurements do
  @moduledoc """
  Finds the published measurement of a release's code (issue #373).

  `benchmark/published/*.json` are rewritten by Publish results after merges to main, so the file as it is at a
  release's tag holds an older version's numbers: the run that measured the released code lands after the tag.
  That run's `meta.git_ref` is the commit it measured, usually the merge that started the release (`tag^`),
  and its `meta.malachi_version` is still the previous release's, since the bump had not been committed yet.
  Neither the file at the tag nor the version it carries says which numbers belong to a release.

  So a measurement belongs to a release when the commit it measured holds the same code as the tag. Two trees
  hold the same code when they differ in nothing but the published results, the changelog and the blog (which
  the release and later merges write), and in `mix.exs` only in its `@version` line (which the bump changes).

  The search walks one file's history after the release's tag, oldest first, and takes the first run whose
  measured commit holds the release's code. It does not stop at the next release: two releases close together
  can publish the first one's measurement after the second one's tag (v0.28.1's landed after v0.28.2's). The
  first match is usually the first results commit after the tag, so a release's own post reads a few commits;
  an old release reads every results commit since it, still only one file's history.
  """

  @published "benchmark/published"
  @ignored ["benchmark/published", "CHANGELOG.md", "site/blog"]
  @tag ~r/\Av\d+\.\d+\.\d+\z/

  @typedoc "A published measurement: its decoded JSON and the results commit that published it."
  @type t :: %{data: map(), published_by: String.t(), git_ref: String.t()}

  @doc "The release tags of the repository at `repo`, oldest first by version."
  @spec tags(Path.t()) :: [String.t()]
  def tags(repo) do
    repo
    |> git!(["tag", "--list", "v*", "--sort=v:refname"])
    |> String.split("\n", trim: true)
    |> Enum.filter(&Regex.match?(@tag, &1))
  end

  @doc """
  The measurement in `benchmark/published/<file>` of the code released as `tag`, or `:none` when no published
  run measured that code.
  """
  @spec find(Path.t(), String.t(), String.t()) :: {:ok, t()} | :none
  def find(repo, file, tag) do
    path = "#{@published}/#{file}"

    repo
    |> git!(["log", "--reverse", "--format=%H", "#{tag}..HEAD", "--", path])
    |> String.split("\n", trim: true)
    |> Enum.find_value(:none, fn commit ->
      with {:ok, data} <- published(repo, commit, path),
           ref when is_binary(ref) <- get_in(data, ["meta", "git_ref"]),
           true <- same_code?(repo, ref, tag) do
        {:ok, %{data: data, published_by: commit, git_ref: ref}}
      else
        _ -> nil
      end
    end)
  end

  defp published(repo, commit, path) do
    case git(repo, ["show", "#{commit}:#{path}"]) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, %{} = data} -> {:ok, data}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  Whether the commit `ref` holds the same code as `tag`: the same tree but for the published results, the
  changelog, the blog, and `mix.exs`'s `@version` line. A `ref` that names no commit here holds no code.
  """
  @spec same_code?(Path.t(), String.t(), String.t()) :: boolean()
  def same_code?(repo, ref, tag) do
    with {:ok, _} <- git(repo, ["rev-parse", "--verify", "--quiet", "--end-of-options", "#{ref}^{commit}"]),
         {:ok, _} <- git(repo, ["diff", "--quiet", ref, tag, "--", "." | excludes()]) do
      version_only?(git!(repo, ["diff", "--unified=0", ref, tag, "--", "mix.exs"]))
    else
      :error -> false
    end
  end

  # mix.exs is compared on its own, by version_only?/1.
  defp excludes, do: Enum.map(["mix.exs" | @ignored], &":(exclude)#{&1}")

  # Every changed line of a mix.exs diff is the @version line.
  defp version_only?(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, ["+", "-"]) and not String.starts_with?(&1, ["+++", "---"])))
    |> Enum.all?(&Regex.match?(~r/\A[+-]\s*@version "\d+\.\d+\.\d+"\s*\z/, &1))
  end

  @doc "The day a tag's commit was made, in UTC."
  @spec tag_date(Path.t(), String.t()) :: Date.t()
  def tag_date(repo, tag) do
    repo
    # format-local in UTC, as release-notes.sh dates the changelog section: %cs would give the committer's own
    # offset, and a tag made at night west of UTC would name the day before.
    |> git!(["log", "-1", "--date=format-local:%Y-%m-%d", "--format=%cd", "--end-of-options", "#{tag}^{commit}"], [
      {"TZ", "UTC0"}
    ])
    |> String.trim()
    |> Date.from_iso8601!()
  end

  defp git(repo, args, env \\ []) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, out}
      {_out, _status} -> :error
    end
  end

  defp git!(repo, args, env \\ []) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: env) do
      {out, 0} -> out
      {out, status} -> Mix.raise("git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(out)}")
    end
  end
end
