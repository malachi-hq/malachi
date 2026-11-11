defmodule ReleaseWorkflowTest do
  # main only takes reviewed pull requests, and the daily OCI run executes whatever main holds. The release
  # workflow is the one writer to main outside a pull request, through the malachi-release App, and these are the
  # properties that keep that exception narrow: the App's key is reachable only from main (environment plus push
  # trigger), only the release job mints a token, the token holds contents alone, and the bump cannot release
  # itself in a loop. A later edit that loses one of them fails here. Text checks, as workflow_hardening_test
  # does, because the repository has no YAML parser among its test dependencies.
  use ExUnit.Case, async: true

  @path Path.expand("../../.github/workflows/release.yml", __DIR__)

  setup_all do
    text = File.read!(@path)
    %{text: text, jobs: jobs(text)}
  end

  # Each job's text, keyed by its name: from `  <name>:` at two spaces to the next job or the end of the file.
  defp jobs(text) do
    [_, body] = String.split(text, ~r/^jobs:\n/m, parts: 2)

    # A comment above a job is split off as its own chunk with no job key, and is dropped.
    for job <- Regex.split(~r/^(?=  [a-z][a-z0-9_-]*:\n)/m, body, trim: true),
        [name] <- [Regex.run(~r/\A  ([a-z][a-z0-9_-]*):/, job, capture: :all_but_first)],
        into: %{},
        do: {name, job}
  end

  test "the three jobs are the ones the checks below read", %{jobs: jobs} do
    assert jobs |> Map.keys() |> Enum.sort() == ["docker", "release", "verify-ci"]
  end

  describe "the trigger" do
    test "is a push to main, and never a pull request event, whose ref could not use the environment",
         %{text: text} do
      assert text =~ ~r/^on:\n  push:\n    branches: \[main\]\n\n/m
      refute text =~ ~r/^\s+pull_request(_target)?:/m
      refute text =~ "workflow_dispatch"
    end

    test "releases run one at a time and are never cancelled midway", %{text: text} do
      assert text =~ ~r/^concurrency:\n  group: release\n  cancel-in-progress: false$/m
    end

    test "grants only read at the top level", %{text: text} do
      assert text =~ ~r/^permissions:\n  contents: read\n\n/m
    end
  end

  describe "the App's key" do
    test "is read in exactly one place, the release job, which runs in the release environment",
         %{text: text, jobs: jobs} do
      assert length(Regex.scan(~r/secrets\.RELEASE_APP_PRIVATE_KEY/, text)) == 1
      assert jobs["release"] =~ "secrets.RELEASE_APP_PRIVATE_KEY"
      assert jobs["release"] =~ ~r/^    environment: release$/m
    end

    test "no other job runs in the environment or mints an App token", %{jobs: jobs} do
      for {name, job} <- jobs, name != "release" do
        refute job =~ "environment:", "#{name} runs in an environment"
        refute job =~ "create-github-app-token", "#{name} mints an App token"
      end
    end

    test "the token action is pinned by commit SHA, and the token holds contents write and nothing else",
         %{jobs: jobs} do
      job = jobs["release"]

      assert job =~
               ~r/uses: actions\/create-github-app-token@[0-9a-f]{40} # v\d+\.\d+\.\d+\n/

      assert job =~ "client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}"
      assert Regex.scan(~r/permission-[a-z-]+: \S+/, job) == [["permission-contents: write"]]
    end
  end

  describe "the push to main" do
    test "checks out the tip of main with the App's token", %{jobs: jobs} do
      assert jobs["release"] =~
               ~r/ref: main\n\s+fetch-depth: 0\n\s+token: \$\{\{ steps\.app-token\.outputs\.token \}\}/
    end

    test "is a fast-forward of the checked-out main, never a force push", %{jobs: jobs} do
      assert jobs["release"] =~ "git push origin HEAD:main"
      refute jobs["release"] =~ ~r/git push[^\n]*(--force|-f\b|\+)/
    end

    test "the bump commit does not start another release", %{jobs: jobs} do
      job = jobs["verify-ci"]
      assert job =~ ~s[if: "!startsWith(github.event.head_commit.message, 'chore: bump version')"]
      # And the message the release job writes is the one the condition matches.
      assert jobs["release"] =~ ~s[git commit -m "chore: bump version to]
    end
  end

  describe "which merges are released" do
    test "only the pull request whose merge commit is this push's commit, so a direct push is not released",
         %{jobs: jobs} do
      job = jobs["verify-ci"]
      assert job =~ "listPullRequestsAssociatedWithCommit"
      assert job =~ "p.merge_commit_sha === context.sha"
      assert job =~ "core.setOutput('release', 'false')"
    end

    test "the release job runs only when verify-ci found that pull request", %{jobs: jobs} do
      assert jobs["release"] =~ "if: needs.verify-ci.outputs.release == 'true'"
    end

    test "a commit already inside a tag is not released twice, and the docker job then does not run",
         %{jobs: jobs} do
      assert jobs["release"] =~ ~s[git tag --contains "$SHA" --list 'v*']
      assert jobs["docker"] =~ "if: needs.release.outputs.new_version != ''"

      # Every release step after the guard is skipped by it.
      after_guard = jobs["release"] |> String.split("id: released", parts: 2) |> List.last()
      steps_after = Regex.scan(~r/^      - name: /m, after_guard) |> length()
      guarded = Regex.scan(~r/if: steps\.released\.outputs\.SKIP == 'false'/, after_guard) |> length()
      assert steps_after == guarded
    end

    test "the pull request's title and labels reach the shell through env, never inlined into a script",
         %{jobs: jobs} do
      job = jobs["release"]
      assert job =~ "PR_TITLE: ${{ needs.verify-ci.outputs.title }}"
      assert job =~ "PR_LABELS: ${{ needs.verify-ci.outputs.labels }}"

      for script <- Regex.scan(~r/run: \|\n((?:          [^\n]*\n|\n)+)/, job, capture: :all_but_first) do
        refute hd(script) =~ "verify-ci.outputs", "a run script inlines a pull request field"
      end
    end
  end
end
