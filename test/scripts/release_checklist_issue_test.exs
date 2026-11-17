defmodule ReleaseChecklistIssueTest do
  # scripts/release-checklist-issue.sh opens the communication checklist issue of a release (#373) from the
  # release workflow's announce job. It runs for real here, with `gh` replaced by a stub on the PATH that
  # answers `issue list` from a file and records what `issue create` was given.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @script Path.expand("../../scripts/release-checklist-issue.sh", __DIR__)
  @template Path.expand("../../.github/ISSUE_TEMPLATE/release-communication.md", __DIR__)

  @gh_stub ~S"""
  #!/usr/bin/env bash
  set -u
  printf '%s\n' "$*" >> "$GH_STUB_DIR/calls"
  case "$1 $2" in
    "issue list")
      [ -f "$GH_STUB_DIR/list.fail" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
      cat "$GH_STUB_DIR/list.json"
      ;;
    "issue create")
      [ -f "$GH_STUB_DIR/create.fail" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --title) printf '%s' "$2" > "$GH_STUB_DIR/title"; shift 2 ;;
          --body-file) cp "$2" "$GH_STUB_DIR/body"; shift 2 ;;
          --repo) printf '%s' "$2" > "$GH_STUB_DIR/repo"; shift 2 ;;
          *) echo "stub: unexpected $1" >&2; exit 98 ;;
        esac
      done
      echo "https://github.com/owner/repo/issues/42"
      ;;
    *) echo "stub: unexpected $*" >&2; exit 99 ;;
  esac
  """

  setup do
    root = TmpDir.path("release_checklist_issue")
    stub = Path.join(root, "stub")
    bin = Path.join(root, "bin")
    for dir <- [stub, bin], do: File.mkdir_p!(dir)
    File.write!(Path.join(bin, "gh"), @gh_stub)
    File.chmod!(Path.join(bin, "gh"), 0o755)
    File.write!(Path.join(stub, "list.json"), "[]")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, stub: stub, bin: bin}
  end

  defp run(ctx, args, env \\ [{"GITHUB_REPOSITORY", "owner/repo"}]) do
    err = Path.join(ctx.root, "stderr")

    {out, code} =
      System.cmd("bash", ["-c", ~s("$0" "$@" 2>"$ERR_FILE"), @script | args],
        env: [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}, {"GH_STUB_DIR", ctx.stub}, {"ERR_FILE", err}] ++ env
      )

    {out, code, File.read!(err)}
  end

  defp stub_file(ctx, name) do
    case File.read(Path.join(ctx.stub, name)) do
      {:ok, text} -> text
      {:error, :enoent} -> nil
    end
  end

  defp calls(ctx), do: (stub_file(ctx, "calls") || "") |> String.split("\n", trim: true)

  defp template(ctx, text) do
    path = Path.join(ctx.root, "template.md")
    File.write!(path, text)
    path
  end

  test "opens the issue with the release's title and the template's body, its version filled in", ctx do
    assert {"https://github.com/owner/repo/issues/42\n", 0, ""} = run(ctx, ["1.2.3", @template])
    assert stub_file(ctx, "title") == "Release v1.2.3 communication"
    assert stub_file(ctx, "repo") == "owner/repo"

    body = stub_file(ctx, "body")
    assert body =~ "## Routine per release\n"
    assert body =~ "`mix malachi.release.post v1.2.3`"
    refute body =~ "vX.Y.Z"
    refute body =~ "about:"
    refute String.starts_with?(body, "---")
    refute String.starts_with?(body, "\n")
  end

  test "searches by the exact title first, open or closed", ctx do
    run(ctx, ["1.2.3", @template])
    [list | _] = calls(ctx)
    assert list =~ ~s(issue list --repo owner/repo --state all --search "Release v1.2.3 communication" in:title)
  end

  test "opens nothing when the release already has its issue, open or closed", ctx do
    File.write!(
      Path.join(ctx.stub, "list.json"),
      ~s([{"number": 7, "title": "Release v1.2.3 communication"}])
    )

    assert {out, 0, ""} = run(ctx, ["1.2.3", @template])
    assert out =~ "#7 is already Release v1.2.3 communication"
    assert length(calls(ctx)) == 1
    assert stub_file(ctx, "title") == nil
  end

  test "a search hit whose title only resembles the release's does not count", ctx do
    File.write!(
      Path.join(ctx.stub, "list.json"),
      ~s([{"number": 7, "title": "Release v1.2.30 communication"}, {"number": 8, "title": "Re: Release v1.2.3 communication"}])
    )

    assert {_, 0, _} = run(ctx, ["1.2.3", @template])
    assert stub_file(ctx, "title") == "Release v1.2.3 communication"
  end

  test "a template without front matter is used whole, its leading blank lines dropped", ctx do
    path = template(ctx, "\n\n- [ ] Post vX.Y.Z.\n---\nafter a rule\n")
    assert {_, 0, _} = run(ctx, ["0.1.0", path])
    assert stub_file(ctx, "body") == "- [ ] Post v0.1.0.\n---\nafter a rule\n"
  end

  test "refuses a template with nothing after its front matter", ctx do
    path = template(ctx, "---\nname: x\n---\n\n")
    assert {_, 2, err} = run(ctx, ["1.2.3", path])
    assert err =~ "has no body"
    assert stub_file(ctx, "title") == nil
  end

  test "fails when GitHub fails, and opens nothing after a failed search", ctx do
    File.write!(Path.join(ctx.stub, "list.fail"), "")
    assert {_, 1, _} = run(ctx, ["1.2.3", @template])
    assert stub_file(ctx, "title") == nil

    File.rm!(Path.join(ctx.stub, "list.fail"))
    File.write!(Path.join(ctx.stub, "create.fail"), "")
    assert {_, 1, _} = run(ctx, ["1.2.3", @template])
  end

  test "refuses a version that is not one before anything reaches GitHub", ctx do
    for version <- ["1.2", "v1.2.3", "1.2.3; id", "1.2.3\nx", "$(id)"] do
      assert {_, 2, _} = run(ctx, [version, @template]), inspect(version)
    end

    assert calls(ctx) == []
  end

  test "usage errors: arguments, an unreadable template, no repository", ctx do
    assert {_, 2, _} = run(ctx, ["1.2.3"])
    assert {_, 2, _} = run(ctx, ["1.2.3", Path.join(ctx.root, "missing.md")])
    # Unset, not just left out: a CI runner sets it for every step.
    assert {_, 2, err} = run(ctx, ["1.2.3", @template], [{"GITHUB_REPOSITORY", nil}])
    assert err =~ "GITHUB_REPOSITORY"
    assert calls(ctx) == []
  end
end
