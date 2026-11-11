defmodule PublishWorkflowsTest do
  # The measured results reach main the way the release does: pushed by the malachi-release App, whose key lives
  # in the release environment that only main may use. These pin what keeps that narrow in results.yml and
  # upgrade-chaos.yml, and the one property that matters most once an App pushes: a push by an App starts
  # workflows, so results.yml must skip the App's own pushes or it measures and publishes forever.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  @app_guard "github.actor != 'malachi-release[bot]'"
  @token_action ~r/uses: actions\/create-github-app-token@[0-9a-f]{40} # v\d+\.\d+\.\d+\n/

  setup_all do
    results = File.read!(WorkflowText.path("results.yml"))
    upgrade = File.read!(WorkflowText.path("upgrade-chaos.yml"))

    %{
      results: results,
      results_jobs: WorkflowText.jobs(results),
      upgrade_jobs: WorkflowText.jobs(upgrade)
    }
  end

  # The checks every job that pushes to main as the App shares, wherever it lives.
  defp assert_pushes_as_the_app(job, label) do
    assert job =~ ~r/^    environment: release$/m, "#{label} does not run in the release environment"
    assert job =~ @token_action, "#{label} mints no pinned App token"
    assert job =~ "client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}"
    assert Regex.scan(~r/permission-[a-z-]+: \S+/, job) == [["permission-contents: write"]], label
    assert job =~ ~r/fetch-depth: 0\n\s+token: \$\{\{ steps\.app-token\.outputs\.token \}\}/, label
    assert job =~ ~s(run: scripts/app-bot-git-identity.sh "$APP_SLUG"), label
    assert job =~ "run: scripts/publish-results.sh", label
    # The job's own token stays read-only: the push is the App's.
    assert job =~ ~r/^    permissions:\n      contents: read\n\n/m, "#{label} grants its own token more than read"
    refute job =~ "github-actions[bot]", label

    assert job =~
             ~r/concurrency:\n      group: publish-results-\$\{\{ github\.ref \}\}\n      cancel-in-progress: false/
  end

  describe "results.yml" do
    test "the jobs are the ones these checks read", %{results_jobs: jobs} do
      assert jobs |> Map.keys() |> Enum.sort() == ["chaos", "commit-results", "loadtest", "publish"]
    end

    test "every job skips a push by the release App, so its commits never start another measurement",
         %{results_jobs: jobs} do
      # Either the job skips the App's pushes, or it runs on a pull request only, which the App never opens.
      pull_request_only = "github.event_name == 'pull_request' }}"

      for {id, job} <- jobs do
        assert job =~ @app_guard or job =~ pull_request_only,
               "#{id} would run on the release App's own push"
      end

      assert jobs["loadtest"] =~ "if: github.event_name != 'push' || #{@app_guard}"
      assert jobs["chaos"] =~ "if: github.event_name != 'push' || #{@app_guard}"
    end

    test "the header says why the App's pushes are skipped", %{results: text} do
      [header, _] = String.split(text, ~r/^on:$/m, parts: 2)
      assert header =~ "skips a push by that App"
    end

    test "commit-results runs on a push to main only, and pushes as the App", %{results_jobs: jobs} do
      job = jobs["commit-results"]

      assert job =~
               ~r/\$\{\{ !cancelled\(\) && github\.event_name == 'push' && github\.ref == 'refs\/heads\/main' &&\n\s+#{Regex.escape(@app_guard)} \}\}/

      assert_pushes_as_the_app(job, "commit-results")
    end

    test "commit-results never clears a published result before committing", %{results_jobs: jobs} do
      refute jobs["commit-results"] =~ "rm -f"
    end

    test "the pull request job only comments: no environment, no App, no write to contents, no push",
         %{results_jobs: jobs} do
      job = jobs["publish"]
      assert job =~ "if: ${{ !cancelled() && github.event_name == 'pull_request' }}"
      assert job =~ ~r/^    permissions:\n      contents: read\n      pull-requests: write$/m
      refute job =~ "environment:"
      refute job =~ "create-github-app-token"
      refute job =~ "publish-results.sh"
      refute job =~ "git push"
    end
  end

  describe "upgrade-chaos.yml" do
    test "publishes from main only, never from a run taken to another release, and pushes as the App",
         %{upgrade_jobs: jobs} do
      job = jobs["publish"]
      assert job =~ "if: ${{ !cancelled() && github.ref == 'refs/heads/main' && inputs.old_ref == '' }}"
      assert_pushes_as_the_app(job, "upgrade-chaos publish")
    end

    test "the drill itself holds no App token and no environment", %{upgrade_jobs: jobs} do
      refute jobs["upgrade-chaos"] =~ "environment:"
      refute jobs["upgrade-chaos"] =~ "create-github-app-token"
    end
  end

  describe "across every workflow" do
    test "the App's key is read only by a job in the release environment" do
      for file <- WorkflowText.files(),
          {id, job} <- file |> File.read!() |> WorkflowText.jobs(),
          String.contains?(job, "secrets.RELEASE_APP_PRIVATE_KEY") do
        assert job =~ ~r/^    environment: release$/m,
               "#{Path.basename(file)} job #{id} reads the App's key outside the release environment"
      end
    end

    test "the jobs that read it are exactly the three publishers" do
      readers =
        for file <- WorkflowText.files(),
            {id, job} <- file |> File.read!() |> WorkflowText.jobs(),
            String.contains?(job, "secrets.RELEASE_APP_PRIVATE_KEY"),
            do: "#{Path.basename(file)}:#{id}"

      assert Enum.sort(readers) == [
               "release.yml:release",
               "results.yml:commit-results",
               "upgrade-chaos.yml:publish"
             ]
    end

    test "nothing commits as github-actions[bot] any more: the token it stands for cannot push to main" do
      for file <- WorkflowText.files() do
        refute File.read!(file) =~ ~r/git config user\.(name|email) ['"]?github-actions\[bot\]/,
               "#{Path.basename(file)} still commits as github-actions[bot]"
      end
    end
  end
end
