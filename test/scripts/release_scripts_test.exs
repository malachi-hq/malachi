defmodule ReleaseScriptsTest do
  # The release rule of #366 lives in scripts/release_lib.sh and is read by three scripts: release-prs.sh records
  # the merged pull requests' labels and descriptions, release-bump.sh decides the version (and checks titles in
  # pr-checks), release-notes.sh writes the body. A wrong read here publishes a release nobody asked for, skips
  # one that matters, or puts a stranger's edited description in front of every watcher, so each script runs
  # for real against a git repository built per test, with `gh` replaced by a stub on the PATH.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @scripts Path.expand("../../scripts", __DIR__)

  # Answers `gh api repos/<repo>/pulls/<N> --jq <filter>` from <stub>/<N>.json and
  # `gh api repos/<repo>/collaborators/<login>/permission --jq <filter>` from <stub>/perm-<login>.json through
  # the real jq, and records every call. HTTP 404 for <N>.404 or a login with no file, HTTP 502 for <N>.502
  # or perm-<login>.502.
  @gh_stub ~S"""
  #!/usr/bin/env bash
  set -u
  echo "$*" >> "$GH_STUB_DIR/calls"
  [ "$1" = api ] || { echo "stub: unexpected $*" >&2; exit 99; }
  path=$2
  filter=$4
  case "$path" in
    */collaborators/*/permission)
      login=${path%/permission}
      f="$GH_STUB_DIR/perm-${login##*/}"
      ;;
    */pulls/*)
      f="$GH_STUB_DIR/${path##*/}"
      [ -f "$f.404" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      ;;
    *) echo "stub: unexpected path $path" >&2; exit 97 ;;
  esac
  if [ -f "$f.502" ]; then echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; fi
  [ -f "$f.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  # gh prints a string result raw, as jq -r does.
  exec jq -r "$filter" "$f.json"
  """

  setup do
    root = TmpDir.path("release_scripts")
    repo = Path.join(root, "repo")
    stub = Path.join(root, "stub")
    bin = Path.join(root, "bin")
    for dir <- [repo, stub, bin], do: File.mkdir_p!(dir)
    File.write!(Path.join(bin, "gh"), @gh_stub)
    File.chmod!(Path.join(bin, "gh"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(repo, ["init", "-q", "-b", "main"])
    commit!(repo, "chore: initial import")
    tag!(repo, "v0.1.0")

    %{root: root, repo: repo, stub: stub, bin: bin, prs: Path.join(root, "prs")}
  end

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
        cd: repo,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp commit!(repo, subject) do
    git!(repo, ["commit", "-q", "--allow-empty", "-m", subject])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp tag!(repo, tag), do: git!(repo, ["tag", "-a", tag, "-m", tag])

  # A pull request as the API returns it, and its author's permission on the repository (`permission: nil`
  # leaves the author unknown to the permission endpoint, which then answers 404).
  defp pr!(ctx, n, fields) do
    fields = Keyword.merge([labels: [], login: "maint", permission: "admin", body: nil], fields)

    pr = %{
      "labels" => Enum.map(fields[:labels], &%{"name" => &1}),
      "user" => %{"login" => fields[:login]},
      "body" => fields[:body]
    }

    File.write!(Path.join(ctx.stub, "#{n}.json"), JSON.encode!(pr))

    if fields[:permission] do
      File.write!(
        Path.join(ctx.stub, "perm-#{fields[:login]}.json"),
        JSON.encode!(%{"permission" => fields[:permission]})
      )
    end
  end

  defp pr_call(n), do: "api repos/owner/repo/pulls/#{n} --jq " <> jq_filter()
  defp permission_call(login), do: ~s(api repos/owner/repo/collaborators/#{login}/permission --jq .permission // "none")

  # Runs a script from the fixture repository; stdout and stderr apart, with the exit status.
  defp run(ctx, script, args, env \\ []) do
    err = Path.join(ctx.root, "stderr")

    {out, code} =
      System.cmd("bash", ["-c", ~s("$0" "$@" 2>"$ERR_FILE"), Path.join(@scripts, script) | args],
        cd: ctx.repo,
        env:
          [
            {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
            {"GH_STUB_DIR", ctx.stub},
            {"GITHUB_REPOSITORY", "owner/repo"},
            {"RELEASE_PRS_RETRY_DELAY", "0"},
            {"ERR_FILE", err}
          ] ++ env
      )

    {out, code, File.read!(err)}
  end

  defp calls(ctx) do
    case File.read(Path.join(ctx.stub, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp prs!(ctx, prev \\ "v0.1.0") do
    assert {_, 0, _} = run(ctx, "release-prs.sh", [prev, "HEAD", ctx.prs])
  end

  defp bump(ctx, extra \\ [], prev \\ "v0.1.0") do
    {out, code, err} = run(ctx, "release-bump.sh", ["--range", prev, "HEAD", ctx.prs | extra])
    {String.trim(out), code, err}
  end

  defp notes(ctx, prev \\ "v0.1.0") do
    {out, 0, _} = run(ctx, "release-notes.sh", [prev, "HEAD", "1.2.3", ctx.prs])
    out
  end

  describe "release-bump.sh --check, the pull request title" do
    @valid [
      "feat: add range reads",
      "fix(storage): close the segment",
      "feat!: drop the v1 protocol",
      "fix(api)!: rename the field",
      "chore(deps): bump ra to 3.2.0",
      "revert: undo the cache",
      "docs: describe retention"
    ]
    @invalid [
      "",
      "Add range reads",
      "feat add range reads",
      "feat : add range reads",
      "Feat: add range reads",
      "feature: add range reads",
      "feat:",
      "feat: ",
      "fix(a) (b): two scopes",
      "fix(): empty scope",
      ~s(Revert "feat: add range reads")
    ]

    for title <- @valid do
      test "accepts #{inspect(title)}", ctx do
        assert {_, 0, _} = run(ctx, "release-bump.sh", ["--check"], [{"PR_TITLE", unquote(title)}])
      end
    end

    for title <- @invalid do
      test "refuses #{inspect(title)} with the forms it accepts", ctx do
        assert {_, 3, err} = run(ctx, "release-bump.sh", ["--check"], [{"PR_TITLE", unquote(title)}])
        assert err =~ "type(scope)!: summary"
      end
    end
  end

  describe "release-bump.sh --range, one merge" do
    @table [
      {"feat: x (#2)", [], "minor"},
      {"fix: x (#2)", [], "patch"},
      {"perf: x (#2)", [], "patch"},
      {"revert: x (#2)", [], "patch"},
      {"chore(deps): bump ra (#2)", [], "patch"},
      {"chore(docker): bump the base image (#2)", [], "patch"},
      {"chore(ci): bump actions (#2)", [], "none"},
      {"chore(terraform): bump the provider (#2)", [], "none"},
      {"chore: tidy (#2)", [], "none"},
      {"docs: x (#2)", [], "none"},
      {"ci: x (#2)", [], "none"},
      {"test: x (#2)", [], "none"},
      {"refactor: x (#2)", [], "none"},
      {"style: x (#2)", [], "none"},
      {"build: x (#2)", [], "none"},
      {"feat!: x (#2)", [], "major"},
      {"docs(api)!: x (#2)", [], "major"},
      {"feat: x (#2)", ["major"], "major"},
      {"docs: x (#2)", ["release"], "patch"},
      {"feat: x (#2)", ["release"], "minor"},
      {"docs: x (#2)", ["majority", "pre-release", "patch", "minor"], "none"},
      {"chore(deps-dev): x (#2)", [], "none"},
      {"chore(dev-deps): bump credo (#2)", [], "none"}
    ]

    for {subject, labels, expected} <- @table do
      test "#{inspect(subject)} with labels #{inspect(labels)} is #{expected}", ctx do
        commit!(ctx.repo, unquote(subject))
        pr!(ctx, 2, labels: unquote(labels))
        prs!(ctx)
        assert {unquote(expected), 0, _} = bump(ctx)
      end
    end

    test "nothing since the previous release is none, and nothing is fetched", ctx do
      prs!(ctx)
      assert {"none", 0, _} = bump(ctx)
      assert calls(ctx) == []
    end
  end

  describe "release-bump.sh --range, the largest bump since the previous release" do
    test "a feat merged before a docs merge is still a minor: its own run may have been cancelled", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      commit!(ctx.repo, "docs: y (#3)")
      for n <- [2, 3], do: pr!(ctx, n, [])
      prs!(ctx)
      assert {"minor", 0, _} = bump(ctx)
    end

    test "a feat merged after the fix that started the run makes the release a minor", ctx do
      fix = commit!(ctx.repo, "fix: x (#2)")
      commit!(ctx.repo, "feat: y (#3)")
      for n <- [2, 3], do: pr!(ctx, n, [])
      prs!(ctx)
      assert {"minor", 0, _} = bump(ctx, ["--trigger", fix])
    end

    test "the major label of an earlier merge still counts", ctx do
      commit!(ctx.repo, "docs: x (#2)")
      commit!(ctx.repo, "fix: y (#3)")
      pr!(ctx, 2, labels: ["major"])
      pr!(ctx, 3, [])
      prs!(ctx)
      assert {"major", 0, _} = bump(ctx)
    end

    test "commits of an earlier release do not count", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      tag!(ctx.repo, "v0.2.0")
      commit!(ctx.repo, "docs: y (#3)")
      pr!(ctx, 3, [])
      prs!(ctx, "v0.2.0")
      assert {"none", 0, _} = bump(ctx, [], "v0.2.0")
      assert calls(ctx) == [pr_call(3), permission_call("maint")]
    end

    test "the version bump and the published results never count, nor are fetched", ctx do
      commit!(ctx.repo, "chore: bump version to 0.1.1")
      commit!(ctx.repo, "chore(results): refresh published benchmark and chaos results from CI")
      prs!(ctx)
      assert {"none", 0, _} = bump(ctx)
      assert calls(ctx) == []
    end

    test "with no previous release the whole history counts and nothing is fetched", ctx do
      commit!(ctx.repo, "fix: x (#2)")
      prs!(ctx, "")
      assert {"patch", 0, _} = bump(ctx, [], "")
      assert calls(ctx) == []
    end
  end

  describe "release-bump.sh --range, a subject with no recognised type" do
    test "is none in the middle of the range, and says so", ctx do
      commit!(ctx.repo, "Merge pull request #2 from someone/branch")
      trigger = commit!(ctx.repo, "docs: y (#3)")
      for n <- [2, 3], do: pr!(ctx, n, [])
      prs!(ctx)
      assert {"none", 0, err} = bump(ctx, ["--trigger", trigger])
      assert err =~ "no recognised type, counted as none: Merge pull request #2"
    end

    test "fails the merge that started the run, saying what to do", ctx do
      trigger = commit!(ctx.repo, "Add range reads (#2)")
      pr!(ctx, 2, [])
      prs!(ctx)
      assert {"", 3, err} = bump(ctx, ["--trigger", trigger])
      assert err =~ "Apply the label `release` (a patch) or `major` to pull request #2"
      assert err =~ "listed under Other in the next release"
    end

    test "the merge that started the run is released when a label decides", ctx do
      trigger = commit!(ctx.repo, "Add range reads (#2)")
      pr!(ctx, 2, labels: ["release"])
      prs!(ctx)
      assert {"patch", 0, _} = bump(ctx, ["--trigger", trigger])
    end

    test "a merge commit names its pull request, so a label on it decides", ctx do
      trigger = commit!(ctx.repo, "Merge pull request #2 from someone/branch")
      pr!(ctx, 2, labels: ["release"])
      prs!(ctx)
      assert pr_call(2) in calls(ctx)
      assert {"patch", 0, _} = bump(ctx, ["--trigger", trigger])
    end

    test "a merge commit without a label fails as its own run, naming its pull request", ctx do
      trigger = commit!(ctx.repo, "Merge pull request #2 from someone/branch")
      pr!(ctx, 2, [])
      prs!(ctx)
      assert {"", 3, err} = bump(ctx, ["--trigger", trigger])
      assert err =~ "or `major` to pull request #2 and re-run"
    end

    test "a subject that names no pull request says so instead of a number", ctx do
      trigger = commit!(ctx.repo, "Add range reads")
      prs!(ctx)
      assert {"", 3, err} = bump(ctx, ["--trigger", trigger])
      assert err =~ "or `major` to its pull request and re-run"
    end

    test "without --trigger it never fails: the release job only takes the largest", ctx do
      commit!(ctx.repo, "Add range reads (#2)")
      commit!(ctx.repo, "fix: y (#3)")
      for n <- [2, 3], do: pr!(ctx, n, [])
      prs!(ctx)
      assert {"patch", 0, _} = bump(ctx)
    end
  end

  describe "release-bump.sh usage" do
    test "an unknown ref, a missing directory or a bad flag is a usage error", ctx do
      File.mkdir_p!(ctx.prs)
      assert {_, 2, _} = run(ctx, "release-bump.sh", ["--range", "v9.9.9", "HEAD", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-bump.sh", ["--range", "v0.1.0", "nope", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-bump.sh", ["--range", "v0.1.0", "HEAD", "/nonexistent"])
      assert {_, 2, _} = run(ctx, "release-bump.sh", ["--range", "v0.1.0", "HEAD", ctx.prs, "--trigger", "nope"])
      assert {_, 2, _} = run(ctx, "release-bump.sh", ["--range", "v0.1.0", "HEAD", ctx.prs, "--other", "x"])
      assert {_, 2, _} = run(ctx, "release-bump.sh", ["--check", "extra"])
      assert {_, 2, _} = run(ctx, "release-bump.sh", [])
    end
  end

  describe "release-prs.sh" do
    test "fetches each pull request once, by the number at the end of its subject only", ctx do
      commit!(ctx.repo, "fix: x (#123) (#4)")
      commit!(ctx.repo, "docs: mentions (#5) in the middle")
      commit!(ctx.repo, "feat: y (#4)")
      pr!(ctx, 4, labels: ["release"])
      prs!(ctx)
      assert calls(ctx) == [pr_call(4), permission_call("maint")]

      assert JSON.decode!(File.read!(Path.join(ctx.prs, "4.json"))) == %{
               "labels" => ["release"],
               "author" => "maint",
               "permission" => "admin",
               "body" => nil
             }
    end

    test "records the author's permission on the repository, not their association", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      pr!(ctx, 2, login: "someone", permission: "read")
      prs!(ctx)
      assert %{"author" => "someone", "permission" => "read"} = JSON.decode!(File.read!(Path.join(ctx.prs, "2.json")))
    end

    test "an author the permission endpoint does not know is none", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      pr!(ctx, 2, login: "stranger", permission: nil)
      prs!(ctx)
      assert %{"permission" => "none"} = JSON.decode!(File.read!(Path.join(ctx.prs, "2.json")))
    end

    test "a login GitHub would not issue (a bot) is none, and is never put in a path", ctx do
      commit!(ctx.repo, "chore(deps): x (#2)")
      pr!(ctx, 2, login: "dependabot[bot]")
      prs!(ctx)
      assert calls(ctx) == [pr_call(2)]
      assert %{"permission" => "none"} = JSON.decode!(File.read!(Path.join(ctx.prs, "2.json")))
    end

    test "a permission that cannot be read fails the run like the pull request itself", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      pr!(ctx, 2, [])
      File.write!(Path.join(ctx.stub, "perm-maint.502"), "")
      assert {_, 1, err} = run(ctx, "release-prs.sh", ["v0.1.0", "HEAD", ctx.prs])
      assert err =~ "could not read #2 after 3 attempts"
      refute File.exists?(Path.join(ctx.prs, "2.json"))
    end

    test "a pull request that no longer exists is recorded with no labels and no body", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      File.write!(Path.join(ctx.stub, "2.404"), "")
      assert {_, 0, err} = run(ctx, "release-prs.sh", ["v0.1.0", "HEAD", ctx.prs])
      assert err =~ "#2 does not exist (HTTP 404)"

      assert %{"labels" => [], "body" => nil, "permission" => "none"} =
               JSON.decode!(File.read!(Path.join(ctx.prs, "2.json")))

      assert calls(ctx) == [pr_call(2)]
      assert {"minor", 0, _} = bump(ctx)
    end

    test "any other failure is retried, then fails the run and leaves no partial file", ctx do
      commit!(ctx.repo, "feat: x (#2)")
      File.write!(Path.join(ctx.stub, "2.502"), "")
      assert {_, 1, err} = run(ctx, "release-prs.sh", ["v0.1.0", "HEAD", ctx.prs])
      assert err =~ "attempt 3/3"
      assert err =~ "could not read #2 after 3 attempts"
      assert length(calls(ctx)) == 3
      refute File.exists?(Path.join(ctx.prs, "2.json"))
    end

    test "needs the repository, a commit and three arguments", ctx do
      assert {_, 2, _} = run(ctx, "release-prs.sh", ["v0.1.0", "HEAD", ctx.prs], [{"GITHUB_REPOSITORY", ""}])
      assert {_, 2, _} = run(ctx, "release-prs.sh", ["v0.1.0", "nope", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-prs.sh", ["v0.1.0", "HEAD"])
    end

    test "an unknown previous release fails instead of fetching nothing", ctx do
      assert {_, code, _} = run(ctx, "release-prs.sh", ["v9.9.9", "HEAD", ctx.prs])
      assert code != 0
    end
  end

  describe "release-notes.sh, the grouped changes" do
    setup ctx do
      for subject <- [
            "docs: describe retention (#2)",
            "chore(results): refresh published benchmark and chaos results from CI",
            "feat(storage): batch frames (#3)",
            "chore: bump version to 0.1.1",
            "fix: close the segment (#4)",
            "perf: faster reads (#5)",
            "chore(deps): bump ra to 3.2.0 (#6)",
            "chore(docker): bump the base image (#10)",
            "feat!: drop the v1 protocol (#7)",
            "test: cover the edge (#8)",
            "Merge pull request #9 from someone/branch"
          ] do
        commit!(ctx.repo, subject)
      end

      for n <- [2, 3, 4, 5, 6, 7, 8, 9, 10], do: pr!(ctx, n, [])
      prs!(ctx)
      :ok
    end

    test "lists the groups in a fixed order, merge order within each, without the bump and the results", ctx do
      assert notes(ctx) == """
             ## 🚀 Malachi v1.2.3

             ### Features

             - **storage:** batch frames (#3)
             - **Breaking:** drop the v1 protocol (#7)

             ### Fixes

             - close the segment (#4)

             ### Performance

             - faster reads (#5)

             ### Dependencies

             - **deps:** bump ra to 3.2.0 (#6)
             - **docker:** bump the base image (#10)

             ### Documentation

             - describe retention (#2)

             ### Other

             - cover the edge (#8)
             - Merge pull request #9 from someone/branch

             ### 🐳 Docker

             ```bash
             docker pull hectorcardoso/malachi:1.2.3
             ```

             ### 📦 Installation

             ```bash
             git clone https://github.com/malachi-hq/malachi.git
             cd malachi
             git checkout v1.2.3
             ```
             """
    end

    test "leaves an empty group out", ctx do
      tag!(ctx.repo, "v0.2.0")
      commit!(ctx.repo, "fix: only a fix (#10)")
      pr!(ctx, 10, [])
      prs!(ctx, "v0.2.0")
      out = notes(ctx, "v0.2.0")
      assert out =~ "### Fixes\n\n- only a fix (#10)\n"

      for group <- ["Features", "Performance", "Dependencies", "Documentation", "Other", "Highlights"] do
        refute out =~ "### #{group}\n"
      end
    end
  end

  describe "release-notes.sh, edge cases" do
    test "says so when nothing is listed", ctx do
      commit!(ctx.repo, "chore: bump version to 0.1.1")
      prs!(ctx)
      assert notes(ctx) =~ "## 🚀 Malachi v1.2.3\n\nNo user-facing changes since the previous release.\n"
    end

    test "with no previous release lists the whole history", ctx do
      commit!(ctx.repo, "fix: x (#2)")
      prs!(ctx, "")
      out = notes(ctx, "")
      assert out =~ "### Fixes\n\n- x (#2)\n"
      assert out =~ "### Other\n\n- initial import\n"
    end

    test "refuses a version that is not one, an unknown ref, and a missing directory", ctx do
      File.mkdir_p!(ctx.prs)
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["v0.1.0", "HEAD", "1.2", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["v0.1.0", "HEAD", "1.2.3; id", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["v9.9.9", "HEAD", "1.2.3", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["v0.1.0", "HEAD", "1.2.3", "/nonexistent"])
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["v0.1.0", "HEAD", "1.2.3"])
    end
  end

  describe "release-notes.sh, the highlights" do
    defp highlighted(ctx, body, permission \\ "admin") do
      commit!(ctx.repo, "feat: x (#2)")
      pr!(ctx, 2, body: body, permission: permission)
      prs!(ctx)
      notes(ctx)
    end

    @body """
    ## 📝 Description

    What changed.

    ## Release highlights

    <!--
    The template's instructions.
    -->
    Range reads are here: a consumer can **replay any window** of a topic.

    ## 🔖 Type of Change
    """

    test "open the notes, with the pull request they came from", ctx do
      assert highlighted(ctx, @body) =~
               "## 🚀 Malachi v1.2.3\n\n### Highlights\n\n" <>
                 "Range reads are here: a consumer can **replay any window** of a topic.\n\n(#2)\n\n### Features\n"
    end

    test "come from several pull requests in merge order", ctx do
      commit!(ctx.repo, "docs: a (#2)")
      commit!(ctx.repo, "feat: b (#3)")
      pr!(ctx, 2, body: "## Release highlights\nFirst.\n")
      pr!(ctx, 3, body: "## Release highlights\nSecond.\n")
      prs!(ctx)
      assert notes(ctx) =~ "### Highlights\n\nFirst.\n\n(#2)\n\nSecond.\n\n(#3)\n\n### Features"
    end

    for permission <- ["admin", "maintain", "write"] do
      test "are taken from an author with write access (#{permission})", ctx do
        assert highlighted(ctx, @body, unquote(permission)) =~ "### Highlights"
      end
    end

    for permission <- ["triage", "read", "none", nil] do
      test "are ignored from an author without write access (#{inspect(permission)})", ctx do
        out = highlighted(ctx, @body, unquote(permission))
        refute out =~ "Highlights"
        refute out =~ "replay any window"
        assert out =~ "### Features\n\n- x (#2)\n"
      end
    end

    test "are absent when the description has none, is null, or holds only the template's comment", ctx do
      for body <- [nil, "## 📝 Description\n\nNothing more.\n", "## Release highlights\n<!-- only -->\n\n## Next\n"] do
        File.rm_rf!(ctx.prs)
        File.rm_rf!(ctx.repo)
        File.mkdir_p!(ctx.repo)
        git!(ctx.repo, ["init", "-q", "-b", "main"])
        commit!(ctx.repo, "chore: initial import")
        tag!(ctx.repo, "v0.1.0")
        refute highlighted(ctx, body) =~ "Highlights", inspect(body)
      end
    end

    test "are absent when a comment is never closed, since its end cannot be known", ctx do
      refute highlighted(ctx, "## Release highlights\nText <!-- open\nmore\n") =~ "Highlights"
    end

    test "survive CRLF line endings, a heading in another case, and a heading inside a comment or a code block",
         ctx do
      body =
        "## Description\r\n\r\n<!--\r\n## Release highlights\r\nnot this\r\n-->\r\n" <>
          "```\r\n## Release highlights\r\nnor this\r\n```\r\n" <>
          "## RELEASE Highlights\r\nThis one.\r\n\r\n```\r\n## kept, inside a block\r\n```\r\n\r\n## Next\r\n"

      out = highlighted(ctx, body)
      assert out =~ "### Highlights\n\nThis one.\n\n```\n## kept, inside a block\n```\n\n(#2)\n"
      refute out =~ "not this"
      refute out =~ "nor this"
      refute out =~ "\r"
    end
  end

  describe "release-notes.sh, the upgrade notes (#373)" do
    @upgrade_body """
    ## Release highlights

    Range reads are here.

    ## Upgrading

    <!--
    The template's instructions.
    -->
    Set `MALACHI_RANGE_READS=true` before the rolling restart.

    ## 🔖 Type of Change
    """

    defp upgraded(ctx, body, permission \\ "admin") do
      commit!(ctx.repo, "feat: x (#2)")
      pr!(ctx, 2, body: body, permission: permission)
      prs!(ctx)
      notes(ctx)
    end

    test "follow the highlights, with the pull request they came from", ctx do
      assert upgraded(ctx, @upgrade_body) =~
               "### Highlights\n\nRange reads are here.\n\n(#2)\n\n" <>
                 "### Upgrading\n\nSet `MALACHI_RANGE_READS=true` before the rolling restart.\n\n(#2)\n\n### Features\n"
    end

    test "come from several pull requests in merge order, and stand without highlights", ctx do
      commit!(ctx.repo, "fix: a (#2)")
      commit!(ctx.repo, "feat: b (#3)")
      pr!(ctx, 2, body: "## Upgrading\nFirst step.\n")
      pr!(ctx, 3, body: "## Upgrading\nSecond step.\n")
      prs!(ctx)
      out = notes(ctx)

      assert out =~
               "## 🚀 Malachi v1.2.3\n\n### Upgrading\n\nFirst step.\n\n(#2)\n\nSecond step.\n\n(#3)\n\n### Features"

      refute out =~ "### Highlights"
    end

    for permission <- ["admin", "maintain", "write"] do
      test "are taken from an author with write access (#{permission})", ctx do
        assert upgraded(ctx, @upgrade_body, unquote(permission)) =~ "### Upgrading"
      end
    end

    for permission <- ["triage", "read", "none", nil] do
      test "are ignored from an author without write access (#{inspect(permission)})", ctx do
        out = upgraded(ctx, @upgrade_body, unquote(permission))
        refute out =~ "Upgrading"
        refute out =~ "MALACHI_RANGE_READS"
        assert out =~ "### Features\n\n- x (#2)\n"
      end
    end

    test "are absent when the section holds only the template's comment or a comment left open", ctx do
      refute upgraded(ctx, "## Upgrading\n<!-- only -->\n\n## Next\n") =~ "Upgrading"
      File.rm_rf!(ctx.prs)
      pr!(ctx, 2, body: "## Upgrading\nText <!-- open\nmore\n")
      prs!(ctx)
      refute notes(ctx) =~ "Upgrading"
    end
  end

  describe "release-notes.sh --changes-only, the CHANGELOG section (#373)" do
    defp changes(ctx, prev \\ "v0.1.0") do
      # A zone that is not UTC, so a CI runner (already UTC) still proves the script dates in UTC itself.
      {out, 0, _} =
        run(ctx, "release-notes.sh", ["--changes-only", prev, "HEAD", "1.2.3", ctx.prs], [{"TZ", "Asia/Tokyo"}])

      out
    end

    # A commit dated in a time zone ahead of UTC, so the section's date shows which day it takes.
    defp commit_at!(repo, subject, date) do
      {_, 0} =
        System.cmd(
          "git",
          ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", subject],
          cd: repo,
          env: [{"GIT_COMMITTER_DATE", date}, {"GIT_AUTHOR_DATE", date}]
        )
    end

    test "dates the section by the head commit in UTC and leaves out the image and the checkout", ctx do
      commit_at!(ctx.repo, "fix: close the segment (#2)", "2026-11-17T01:30:00+03:00")
      pr!(ctx, 2, body: "## Release highlights\nShort.\n\n## Upgrading\nNothing to do.\n")
      prs!(ctx)

      assert changes(ctx) == """
             ## v1.2.3 (2026-11-16)

             ### Highlights

             Short.

             (#2)

             ### Upgrading

             Nothing to do.

             (#2)

             ### Fixes

             - close the segment (#2)
             """
    end

    test "says so when nothing is listed, still without the image", ctx do
      commit_at!(ctx.repo, "chore: bump version to 0.1.1", "2026-11-16T12:00:00Z")
      prs!(ctx)

      assert changes(ctx) ==
               "## v1.2.3 (2026-11-16)\n\nNo user-facing changes since the previous release.\n"
    end

    test "lists the whole history with no previous release, as the backfill's first section needs", ctx do
      commit_at!(ctx.repo, "fix: x (#2)", "2026-01-02T00:00:00Z")
      prs!(ctx, "")
      out = changes(ctx, "")
      assert out =~ "## v1.2.3 (2026-01-02)\n"
      assert out =~ "### Fixes\n\n- x (#2)\n"
      assert out =~ "### Other\n\n- initial import\n"
    end

    test "the flag goes first, and the arguments are checked as without it", ctx do
      File.mkdir_p!(ctx.prs)
      assert {_, 2, err} = run(ctx, "release-notes.sh", ["v0.1.0", "HEAD", "1.2.3", ctx.prs, "--changes-only"])
      assert err =~ "[--changes-only]"
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["--changes-only", "v0.1.0", "HEAD", "1.2", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["--changes-only", "v9.9.9", "HEAD", "1.2.3", ctx.prs])
      assert {_, 2, _} = run(ctx, "release-notes.sh", ["--changes-only"])
    end
  end

  describe "changelog-prepend.sh (#373)" do
    setup ctx do
      commit!(ctx.repo, "fix: close the segment (#2)")
      pr!(ctx, 2, [])
      prs!(ctx)
      %{changelog: Path.join(ctx.root, "CHANGELOG.md")}
    end

    defp prepend(ctx, version) do
      run(ctx, "changelog-prepend.sh", ["v0.1.0", "HEAD", version, ctx.prs, ctx.changelog])
    end

    defp section(ctx, version) do
      {out, 0, _} = run(ctx, "release-notes.sh", ["--changes-only", "v0.1.0", "HEAD", version, ctx.prs])
      out
    end

    test "creates the changelog with its heading and the release's section", ctx do
      assert {"", 0, ""} = prepend(ctx, "1.2.3")
      text = File.read!(ctx.changelog)
      assert text =~ ~r/\A# Changelog\n\nEvery release of Malachi, newest first\./
      assert String.ends_with?(text, "\n\n" <> section(ctx, "1.2.3"))
    end

    test "puts a newer release above the older ones, below the heading", ctx do
      assert {_, 0, _} = prepend(ctx, "1.2.3")
      assert {_, 0, _} = prepend(ctx, "1.2.4")
      text = File.read!(ctx.changelog)
      {newer, _} = :binary.match(text, "## v1.2.4 (")
      {older, _} = :binary.match(text, "## v1.2.3 (")
      {heading, _} = :binary.match(text, "# Changelog")
      assert heading < newer and newer < older
      assert text =~ section(ctx, "1.2.4") <> "\n## v1.2.3 ("
    end

    test "keeps a hand-written heading and whatever precedes the first section", ctx do
      File.write!(ctx.changelog, "# Changes\n\nIntro.\n\n## v1.0.0 (2026-01-01)\n\n- old\n")
      assert {_, 0, _} = prepend(ctx, "1.2.3")

      assert File.read!(ctx.changelog) ==
               "# Changes\n\nIntro.\n\n" <> section(ctx, "1.2.3") <> "\n## v1.0.0 (2026-01-01)\n\n- old\n"
    end

    test "refuses a version already in the changelog, and leaves the file as it was", ctx do
      assert {_, 0, _} = prepend(ctx, "1.2.3")
      before = File.read!(ctx.changelog)
      assert {"", 1, err} = prepend(ctx, "1.2.3")
      assert err =~ "already has v1.2.3"
      assert File.read!(ctx.changelog) == before
    end

    test "a version that only starts like one already there is not refused", ctx do
      File.write!(ctx.changelog, "# Changelog\n\n## v1.2.30 (2026-01-01)\n\n- other\n")
      assert {_, 0, _} = prepend(ctx, "1.2.3")
      assert File.read!(ctx.changelog) =~ "## v1.2.3 ("
    end

    test "leaves the changelog untouched when the notes cannot be written, or on a usage error", ctx do
      File.write!(ctx.changelog, "# Changelog\n")

      assert {_, 2, _} =
               run(ctx, "changelog-prepend.sh", ["v9.9.9", "HEAD", "1.2.3", ctx.prs, ctx.changelog])

      assert {_, 2, _} = prepend(ctx, "1.2")
      assert {_, 2, _} = run(ctx, "changelog-prepend.sh", ["v0.1.0", "HEAD", "1.2.3", ctx.prs])
      assert File.read!(ctx.changelog) == "# Changelog\n"
      refute File.exists?(ctx.changelog <> ".tmp")
    end
  end

  defp jq_filter, do: ~s|{labels: [.labels[]?.name], author: (.user.login // ""), body: .body}|
end
