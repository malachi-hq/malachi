defmodule ReleaseWorkflowTest do
  # main only takes reviewed pull requests, and the daily OCI run executes whatever main holds. The release
  # workflow is the one writer to main outside a pull request, through the malachi-release App, and these are the
  # properties that keep that exception narrow: the App's key is reachable only from main (environment plus push
  # trigger), only the release job mints a token, the token holds contents alone, and the bump cannot release
  # itself in a loop. A later edit that loses one of them fails here. Text checks, as workflow_hardening_test
  # does, because the repository has no YAML parser among its test dependencies.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  setup_all do
    text = File.read!(WorkflowText.path("release.yml"))
    %{text: text, jobs: WorkflowText.jobs(text)}
  end

  # The run scripts of a job: block scalars (`run: |`) and one-liners (`run: cmd`).
  defp run_scripts(job) do
    blocks = Regex.scan(~r/run: \|\n((?:          [^\n]*\n|\n)+)/, job, capture: :all_but_first)
    lines = Regex.scan(~r/run: (?!\|)([^\n]+)\n/, job, capture: :all_but_first)
    Enum.map(blocks ++ lines, &hd/1)
  end

  # A job's steps, each from its `- name:` to the next.
  defp steps(job), do: job |> String.split(~r/^      - name: /m) |> tl()

  defp step(job, name), do: job |> steps() |> Enum.find(&String.starts_with?(&1, name))

  test "the git identity of the bump is the release App's, set by the shared script", %{jobs: jobs} do
    assert jobs["release"] =~ ~s(run: scripts/app-bot-git-identity.sh "$APP_SLUG")
    refute jobs["release"] =~ "github-actions[bot]"
  end

  test "the four jobs are the ones the checks below read, and no other job dispatches Pages", %{jobs: jobs} do
    assert jobs |> Map.keys() |> Enum.sort() == ["announce", "docker", "release", "verify-ci"]

    dispatching =
      for {name, job} <- jobs, s <- steps(job), s =~ "gh workflow run pages.yml", do: {name, s}

    assert [{"release", "Rebuild the documentation site" <> _}] = dispatching
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
    test "only the pull request whose merge commit is this push's commit, so a direct push is not released for itself",
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

      # And every one from the version bump on is skipped too when the tip of main holds nothing to release.
      from_bump = after_guard |> String.split("      - name: Bump version", parts: 2) |> List.last()
      steps_from_bump = Regex.scan(~r/^      - name: /m, "      - name: Bump version" <> from_bump) |> length()

      fully_guarded =
        Regex.scan(
          ~r/if: steps\.released\.outputs\.SKIP == 'false' && steps\.bump_type\.outputs\.BUMP_TYPE != 'none'\n/,
          from_bump
        )
        |> length()

      assert steps_from_bump == fully_guarded
    end

    test "no pull request field reaches any job: the decision reads main's subjects and the API's labels",
         %{jobs: jobs} do
      refute jobs["verify-ci"] =~ ~r/^      (title|labels): /m
      refute jobs["verify-ci"] =~ "setOutput('title'"
      refute jobs["verify-ci"] =~ "setOutput('labels'"

      for {name, job} <- jobs do
        refute job =~ "pull_request.title", name
        refute job =~ "pull_request.body", name
        refute job =~ "verify-ci.outputs.title", name
        refute job =~ "verify-ci.outputs.labels", name
      end
    end

    test "no run script of any job inlines an expression that carries outside text", %{jobs: jobs} do
      for {name, job} <- jobs, script <- run_scripts(job) do
        refute script =~ ~r/\$\{\{\s*(needs\.|github\.event\.|steps\.(pr|gate|prev)\.)/,
               "#{name} inlines an expression into a run script: #{script}"
      end
    end
  end

  describe "what publishes a release (#366)" do
    test "verify-ci reads the whole history with its tags, keeping no credential", %{jobs: jobs} do
      assert jobs["verify-ci"] =~
               ~r/uses: actions\/checkout@[0-9a-f]{40} # v\d+\.\d+\.\d+\n\s+with:\n\s+fetch-depth: 0\n\s+persist-credentials: false\n/
    end

    test "verify-ci stays read-only", %{jobs: jobs} do
      assert jobs["verify-ci"] =~
               ~r/^    permissions:\n      checks: read\n      contents: read\n      pull-requests: read\n    outputs:/m
    end

    test "the gate decides from every commit since the previous release, failing on an untyped trigger",
         %{jobs: jobs} do
      gate = step(jobs["verify-ci"], "Decide whether the merged commits publish a release")
      assert gate =~ "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}"
      assert gate =~ "PR: ${{ steps.pr.outputs.pr }}"
      assert gate =~ ~s[scripts/release-prs.sh "$PREV" HEAD "$PRS"]
      assert gate =~ ~S|if [ -n "$PR" ]; then TRIGGER=(--trigger "$GITHUB_SHA"); fi|
      assert gate =~ ~S|scripts/release-bump.sh --range "$PREV" HEAD "$PRS" "${TRIGGER[@]}"|
      assert gate =~ ~S|if [ "$BUMP" = none ]; then echo "release=false"; else echo "release=true"; fi|

      assert jobs["verify-ci"] =~ "release: ${{ steps.gate.outputs.release || steps.pr.outputs.release }}"
    end

    test "a direct push still reads the merges since the previous release: it may have replaced a merge's run",
         %{jobs: jobs} do
      # The published results follow most merges and are pushed by the App, so their run is the one most
      # likely to replace a queued merge's run in the release concurrency group.
      gate = step(jobs["verify-ci"], "Decide whether the merged commits publish a release")
      refute gate =~ ~r/^        if: /m
    end

    test "the release job reads the pull requests itself and holds exactly these permissions", %{jobs: jobs} do
      assert jobs["release"] =~
               ~r/^    permissions:\n      contents: write\n      actions: write\n      pull-requests: read\n      discussions: write\n\n/m

      read = step(jobs["release"], "Read the merged pull requests")
      assert read =~ "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}"
      refute read =~ "app-token"

      bump = step(jobs["release"], "Determine version bump type")
      assert bump =~ ~s[scripts/release-bump.sh --range "$PREV" HEAD "$RUNNER_TEMP/release-prs"]
      refute bump =~ "--trigger"
    end

    test "nothing is pushed when the tip of main holds nothing to release", %{jobs: jobs} do
      for name <- [
            "Bump version",
            "Get new version",
            "Write the release notes",
            "Prepend the release to the changelog",
            "Commit version bump",
            "Create Git tag",
            "Create GitHub Release",
            "Rebuild the documentation site"
          ] do
        assert step(jobs["release"], name) =~
                 "if: steps.released.outputs.SKIP == 'false' && steps.bump_type.outputs.BUMP_TYPE != 'none'",
               name
      end
    end

    test "the notes are written before anything is pushed, and become the release body", %{jobs: jobs} do
      job = jobs["release"]
      notes = :binary.match(job, "scripts/release-notes.sh") |> elem(0)
      push = :binary.match(job, "git push origin HEAD:main") |> elem(0)
      assert notes < push

      assert job =~
               ~s[scripts/release-notes.sh "$PREV" HEAD "$NEW_VERSION" "$RUNNER_TEMP/release-prs" > "$RUNNER_TEMP/release-notes.md"]

      assert job =~ "body_path: ${{ runner.temp }}/release-notes.md"
      refute job =~ ~r/^          body: /m
      refute job =~ "git log"
    end

    test "the release opens its discussion in Announcements, from the guarded release step (#373)",
         %{jobs: jobs} do
      create = step(jobs["release"], "Create GitHub Release")
      assert create =~ "discussion_category_name: Announcements\n"
      assert create =~ "uses: softprops/action-gh-release@"

      # Only this step asks for a discussion, so the permission serves nothing else.
      assert length(Regex.scan(~r/discussion_category_name:/, jobs["release"])) == 1
    end

    test "the changelog takes the same notes, before the push, and goes into the bump commit (#373)",
         %{jobs: jobs} do
      job = jobs["release"]
      changelog = step(job, "Prepend the release to the changelog")

      assert changelog =~ "PREV: ${{ steps.prev.outputs.TAG }}"
      assert changelog =~ "NEW_VERSION: ${{ steps.version.outputs.NEW_VERSION }}"

      assert changelog =~
               ~s[run: scripts/changelog-prepend.sh "$PREV" HEAD "$NEW_VERSION" "$RUNNER_TEMP/release-prs" CHANGELOG.md\n]

      position = fn text -> job |> :binary.match(text) |> elem(0) end
      assert position.("scripts/release-notes.sh") < position.("scripts/changelog-prepend.sh")
      assert position.("scripts/changelog-prepend.sh") < position.("git push origin HEAD:main")

      assert step(job, "Commit version bump") =~ "git add mix.exs CHANGELOG.md\n"
    end
  end

  describe "the communication checklist issue (#373)" do
    test "comes from its own job, after a release that published a version", %{jobs: jobs} do
      job = jobs["announce"]
      assert job =~ ~r/^    needs: release$/m
      assert job =~ "if: needs.release.outputs.new_version != ''"
    end

    test "the job holds issues write and contents read, nothing else, and neither the environment nor the App",
         %{jobs: jobs} do
      job = jobs["announce"]
      assert job =~ ~r/^    permissions:\n      contents: read\n      issues: write\n\n/m
      refute job =~ "environment:"
      refute job =~ "create-github-app-token"
      refute job =~ "RELEASE_APP"
    end

    test "checks out without keeping a credential, behind the hardened runner", %{jobs: jobs} do
      job = jobs["announce"]
      assert job =~ ~r/uses: step-security\/harden-runner@[0-9a-f]{40} # v\d+\.\d+\.\d+\n/
      assert job =~ ~r/uses: actions\/checkout@[0-9a-f]{40} # v\d+\.\d+\.\d+\n\s+with:\n\s+persist-credentials: false\n/
    end

    test "opens the issue from the template through the script, the version passed by env", %{jobs: jobs} do
      open = step(jobs["announce"], "Open the communication checklist issue")
      assert open =~ "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}"
      assert open =~ "VERSION: ${{ needs.release.outputs.new_version }}"

      assert open =~
               ~s[run: scripts/release-checklist-issue.sh "$VERSION" .github/ISSUE_TEMPLATE/release-communication.md\n]

      assert File.exists?(Path.expand("../../.github/ISSUE_TEMPLATE/release-communication.md", __DIR__))
    end

    test "the GITHUB_TOKEN is given only to the step that needs it", %{jobs: jobs} do
      assert length(Regex.scan(~r/secrets\.GITHUB_TOKEN/, jobs["announce"])) == 1
    end
  end

  describe "the other files the release rule reaches (#366)" do
    test "pr-checks validates the title with the release's own parser, through env" do
      job = "pr-checks.yml" |> WorkflowText.path() |> File.read!() |> WorkflowText.jobs() |> Map.fetch!("pr-validation")
      title = step(job, "🔍 Check PR title follows conventional commits")
      assert title =~ "PR_TITLE: ${{ github.event.pull_request.title }}"
      assert title =~ "run: scripts/release-bump.sh --check\n"
    end

    test "the labeler adds no version label: only a person adds major or release" do
      text = File.read!(WorkflowText.path("pr-checks.yml"))

      for label <- ["major", "minor", "patch", "release"] do
        refute text =~ "labels.add('#{label}')", label
      end
    end

    test "Dependabot's development packages do not take the deps scope, which publishes a release" do
      text = File.read!(Path.expand("../../.github/dependabot.yml", __DIR__))
      [mix, _] = String.split(text, ~s(package-ecosystem: "github-actions"), parts: 2)
      assert mix =~ ~S|prefix: "chore(deps):"|
      assert mix =~ ~S|prefix-development: "chore(dev-deps):"|
    end

    test "Terraform updates do not take the deps scope, which publishes a release" do
      text = File.read!(Path.expand("../../.github/dependabot.yml", __DIR__))
      [_, terraform] = String.split(text, ~s(package-ecosystem: "terraform"), parts: 2)
      assert terraform =~ ~S|prefix: "chore(terraform):"|
      refute terraform =~ "chore(deps)"
    end

    test "docker-build publishes main's image as main and sha tags, never a version nor latest" do
      text = File.read!(WorkflowText.path("docker-build.yml"))
      refute text =~ "tags:\n      - 'v*'"
      refute text =~ "type=semver"
      refute text =~ "value=latest"
      refute text =~ ":latest"
      refute text =~ ~r/IMAGE_NAME \}\}:\$\{\{ steps\.version/
      assert text =~ "type=ref,event=branch"
      assert text =~ "type=sha,prefix=sha-,format=long,enable={{is_default_branch}}"
      assert text =~ "tags: ${{ steps.meta.outputs.tags }}"
    end

    test "only the release's docker job publishes the version tags and latest", %{jobs: jobs} do
      assert jobs["docker"] =~ "/malachi:latest"
      assert jobs["docker"] =~ "ref: v${{ needs.release.outputs.new_version }}"
    end

    test "a merge that publishes no release still rebuilds the site, after Publish results" do
      text = File.read!(WorkflowText.path("pages.yml"))
      assert text =~ ~r/^  workflow_run:\n    workflows: \[Publish results\]\n    types: \[completed\]$/m
      results = File.read!(WorkflowText.path("results.yml"))
      assert results =~ ~r/^  push:\n    branches: \[main\]$/m
    end

    test "the site links its sources to the commit it was built from" do
      text = File.read!(WorkflowText.path("pages.yml"))
      assert text =~ "MALACHI_DOCS_SOURCE_REF=$(git rev-parse HEAD)"
      assert text =~ "export MALACHI_DOCS_SOURCE_REF"

      assert File.read!(Path.expand("../../mix.exs", __DIR__)) =~
               ~s[source_ref: System.get_env("MALACHI_DOCS_SOURCE_REF", "v\#{@version}")]
    end
  end
end
