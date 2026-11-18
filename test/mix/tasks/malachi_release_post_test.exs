defmodule Mix.Tasks.Malachi.Release.PostTest do
  # mix malachi.release.post (#373): writes a release's draft into site/blog and renders its chart images with
  # site/checks/render.mjs. Here `node` is a stub on the PATH that records its arguments and writes each PNG it
  # is asked for, since the real renderer needs a browser. Mix.shell/1 and the PATH are global state, so this
  # file is not async.
  use ExUnit.Case, async: false

  alias Malachi.Site.Blog
  alias Malachi.Site.Chart
  alias Mix.Tasks.Malachi.Release.Post, as: Task

  @moduletag :tmp_dir

  @node_stub ~S"""
  #!/usr/bin/env bash
  printf '%s\n' "$*" >> "$NODE_STUB_DIR/calls"
  [ -f "$NODE_STUB_DIR/fail" ] && { echo "Cannot find package 'playwright'" >&2; exit 1; }
  shift 2
  while [ $# -gt 0 ]; do printf 'PNG' > "$2"; shift 2; done
  """

  setup %{tmp_dir: root} do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "node"), @node_stub)
    File.chmod!(Path.join(bin, "node"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    System.put_env("NODE_STUB_DIR", root)

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("NODE_STUB_DIR")
    end)

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.name", "Git Name"])
    write(repo, "mix.exs", ~s(@version "0.1.0"\n))
    commit!(repo, "chore: bump version to 0.1.0")
    git!(repo, ["tag", "-a", "v0.1.0", "-m", "v0.1.0"])
    write(repo, "mix.exs", ~s(@version "0.2.0"\n))
    commit!(repo, "chore: bump version to 0.2.0")
    git!(repo, ["tag", "-a", "v0.2.0", "-m", "v0.2.0"])

    write(
      repo,
      "CHANGELOG.md",
      "# Changelog\n\n## v0.2.0 (2026-11-16)\n\n### Features\n\n- x (#1)\n\n## v0.1.0 (2026-11-16)\n\n### Fixes\n\n- y (#2)\n"
    )

    %{root: root, repo: repo}
  end

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.email=t@example.com" | args],
        cd: repo,
        stderr_to_stdout: true,
        env: [{"GIT_COMMITTER_DATE", "2026-11-16T12:00:00Z"}, {"GIT_AUTHOR_DATE", "2026-11-16T12:00:00Z"}]
      )

    out
  end

  defp commit!(repo, subject) do
    git!(repo, ["add", "-A"])
    git!(repo, ["-c", "user.name=t", "commit", "-q", "-m", subject])
  end

  defp write(repo, path, content) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp messages do
    receive do
      {:mix_shell, :info, [message]} -> [message | messages()]
    after
      0 -> []
    end
  end

  defp node_calls(root) do
    case File.read(Path.join(root, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "writes the draft of a minor release and renders its two chart images", %{root: root, repo: repo} do
    Task.run(["v0.2.0", "--root", repo])
    post = Path.join(repo, "site/blog/2026-11-16-v0-2-0.md")
    text = File.read!(post)
    assert text =~ "author: Git Name"
    assert text =~ "### Features\n\n- x (#1)"

    [call] = node_calls(root)
    assert call =~ ~r{^#{Regex.escape(repo)}/site/checks/render.mjs 1200x630 }
    pngs = Path.wildcard(Path.join(repo, "site/blog/2026-11-16-v0-2-0/*.png"))
    assert length(pngs) == 2
    assert Enum.all?(pngs, &(Path.basename(&1) =~ ~r/\A(node|elixir)-produce-rate-[0-9a-f]{8}\.png\z/))

    assert Enum.any?(messages(), &(&1 =~ "rendered 2 chart image(s)"))
  end

  test "a patch draft has no chart and renders nothing; --author names the author", %{root: root, repo: repo} do
    write(repo, "mix.exs", ~s(@version "0.2.1"\n))
    commit!(repo, "chore: bump version to 0.2.1")
    git!(repo, ["tag", "-a", "v0.2.1", "-m", "v0.2.1"])
    File.write!(Path.join(repo, "CHANGELOG.md"), "## v0.2.1 (2026-11-16)\n\n### Fixes\n\n- z (#3)\n", [:append])

    Task.run(["v0.2.1", "--root", repo, "--author", "Someone"])
    assert File.read!(Path.join(repo, "site/blog/2026-11-16-v0-2-1.md")) =~ "author: Someone"
    assert node_calls(root) == []
    assert "site/blog/2026-11-16-v0-2-1.md: no chart, so no image to render" in messages()
  end

  test "refuses to write over a draft without --force, and another post covering the release always",
       %{repo: repo} do
    Task.run(["v0.2.0", "--root", repo])
    error = assert_raise Mix.Error, fn -> Task.run(["v0.2.0", "--root", repo]) end
    assert error.message =~ "2026-11-16-v0-2-0.md exists; pass --force"

    Task.run(["v0.2.0", "--root", repo, "--force"])
    assert File.exists?(Path.join(repo, "site/blog/2026-11-16-v0-2-0.md"))

    write(
      repo,
      "site/blog/2026-11-17-other.md",
      "---\ntitle: T\ndate: 2026-11-17\nversions: [0.2.0]\nauthor: A\nsummary: S\n---\n\nText.\n"
    )

    error = assert_raise Mix.Error, fn -> Task.run(["v0.2.0", "--root", repo, "--force"]) end
    assert error.message =~ "site/blog/2026-11-17-other.md already covers v0.2.0"
  end

  test "without the renderer, says what to install and what to run then, and leaves no empty folder",
       %{root: root, repo: repo} do
    File.write!(Path.join(root, "fail"), "")
    error = assert_raise Mix.Error, fn -> Task.run(["v0.2.0", "--root", repo]) end
    assert error.message =~ "npx playwright install --only-shell chromium"
    assert error.message =~ "mix malachi.release.post --images site/blog/2026-11-16-v0-2-0.md"
    assert File.exists?(Path.join(repo, "site/blog/2026-11-16-v0-2-0.md"))
    refute File.exists?(Path.join(repo, "site/blog/2026-11-16-v0-2-0"))

    File.rm!(Path.join(root, "fail"))
    Task.run(["--images", "site/blog/2026-11-16-v0-2-0.md", "--root", repo])
    assert length(Path.wildcard(Path.join(repo, "site/blog/2026-11-16-v0-2-0/*.png"))) == 2
  end

  test "without node on the PATH at all, says what to install", %{root: root, repo: repo} do
    Task.run(["v0.2.0", "--root", repo])
    dir = Path.join(repo, "site/blog/2026-11-16-v0-2-0")
    Enum.each(Path.wildcard(Path.join(dir, "*.png")), &File.rm!/1)
    File.rm!(Path.join(root, "bin/node"))
    path = System.get_env("PATH")
    # Only the stubs' folder: no node anywhere. --images runs no other program before it looks for node.
    System.put_env("PATH", Path.join(root, "bin"))

    try do
      error = assert_raise Mix.Error, fn -> Task.run(["--images", "site/blog/2026-11-16-v0-2-0.md", "--root", repo]) end
      assert error.message =~ "npx playwright install --only-shell chromium"
    after
      System.put_env("PATH", path)
    end
  end

  test "--images renders only what is missing and removes an image no chart names", %{root: root, repo: repo} do
    Task.run(["v0.2.0", "--root", repo])
    dir = Path.join(repo, "site/blog/2026-11-16-v0-2-0")
    File.write!(Path.join(dir, "node-produce-rate-00000000.png"), "stale")

    [first | _] =
      Path.wildcard(Path.join(dir, "*-produce-rate-*.png")) -- [Path.join(dir, "node-produce-rate-00000000.png")]

    File.rm!(first)
    File.rm!(Path.join(root, "calls"))
    messages()

    Task.run(["--images", "site/blog/2026-11-16-v0-2-0.md", "--root", repo])
    assert [call] = node_calls(root)
    assert call =~ Path.basename(first)
    refute File.exists?(Path.join(dir, "node-produce-rate-00000000.png"))
    assert "removed node-produce-rate-00000000.png, which no chart names any more" in messages()

    Task.run(["--images", "site/blog/2026-11-16-v0-2-0.md", "--root", repo])
    assert "site/blog/2026-11-16-v0-2-0.md: every chart image is in place" in messages()
  end

  test "--images on a post that cannot be read says why", %{repo: repo} do
    write(repo, "site/blog/2026-11-16-bad.md", "no front matter")
    error = assert_raise Mix.Error, fn -> Task.run(["--images", "site/blog/2026-11-16-bad.md", "--root", repo]) end
    assert error.message =~ "starts with front matter"
  end

  test "usage errors, an unknown release, and no author", %{repo: repo} do
    for argv <- [[], ["v0.2.0", "v0.1.0"], ["--images", "x.md", "v0.2.0"]] do
      error = assert_raise Mix.Error, fn -> Task.run(argv ++ ["--root", repo]) end
      assert error.message =~ "usage: mix malachi.release.post"
    end

    error = assert_raise Mix.Error, fn -> Task.run(["v9.9.9", "--root", repo]) end
    assert error.message =~ "v9.9.9 is not a release tag here"
  end

  test "without --author and without git's user.name, asks for one", %{root: root, repo: repo} do
    git!(repo, ["config", "--unset", "user.name"])
    # The contributor's own git configuration would otherwise supply a name.
    System.put_env("GIT_CONFIG_GLOBAL", Path.join(root, "no-global-config"))
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")

    on_exit(fn ->
      System.delete_env("GIT_CONFIG_GLOBAL")
      System.delete_env("GIT_CONFIG_NOSYSTEM")
    end)

    error = assert_raise Mix.Error, fn -> Task.run(["v0.2.0", "--root", repo]) end
    assert error.message == "no author: pass --author or set git's user.name"
  end

  describe "--devto" do
    # The repository's own scripts/devto-draft.sh is tested against a fake dev.to (devto_draft_test.exs);
    # here a stand-in records the article the task hands it.
    setup %{root: root, repo: repo} do
      write(repo, "scripts/devto-draft.sh", """
      #!/usr/bin/env bash
      cp "$1" "#{root}/sent.json"
      [ -f "#{root}/devto.fail" ] && { echo "devto-draft: dev.to refused" >&2; exit 1; }
      echo "devto-draft: created draft 1"
      """)

      File.chmod!(Path.join(repo, "scripts/devto-draft.sh"), 0o755)

      write(
        repo,
        "site/blog/2026-11-16-v0-2-0.md",
        "---\ntitle: Malachi v0.2.0\ndate: 2026-11-16\nversions: [0.2.0]\nauthor: A\nsummary: Written.\n---\n\nWritten text.\n"
      )

      :ok
    end

    test "hands the script a draft article of a finished post, and the file is gone after", %{root: root, repo: repo} do
      Task.run(["--devto", "site/blog/2026-11-16-v0-2-0.md", "--root", repo])
      %{"article" => article} = root |> Path.join("sent.json") |> File.read!() |> JSON.decode!()
      assert article["published"] == false
      assert article["canonical_url"] == "https://malachi-hq.github.io/malachi/blog/2026-11-16-v0-2-0.html"
      assert article["body_markdown"] == "Written text.\n"

      assert Path.wildcard(Path.join(System.tmp_dir!(), "malachi-devto-*.json"))
             |> Enum.filter(&(File.read!(&1) =~ "Written text")) == []
    end

    test "refuses an unfinished post before the script runs", %{root: root, repo: repo} do
      write(
        repo,
        "site/blog/2026-11-16-v0-2-0.md",
        "---\ntitle: T\ndate: 2026-11-16\nversions: [0.2.0]\nauthor: A\nsummary: S\n---\n\n<!-- narrative -->\n"
      )

      error = assert_raise Mix.Error, fn -> Task.run(["--devto", "site/blog/2026-11-16-v0-2-0.md", "--root", repo]) end
      assert error.message =~ "is not finished"
      refute File.exists?(Path.join(root, "sent.json"))
    end

    test "fails when the script fails", %{root: root, repo: repo} do
      File.write!(Path.join(root, "devto.fail"), "")
      error = assert_raise Mix.Error, fn -> Task.run(["--devto", "site/blog/2026-11-16-v0-2-0.md", "--root", repo]) end
      assert error.message =~ "scripts/devto-draft.sh failed (1)"
    end
  end

  test "the chart image a draft names is the one the site check expects", %{repo: repo} do
    Task.run(["v0.2.0", "--root", repo])
    {:ok, post} = Blog.read(Path.join(repo, "site/blog"), "2026-11-16-v0-2-0.md")

    for %{chart: chart, json: json} <- post.charts do
      assert File.exists?(Path.join([repo, "site/blog/2026-11-16-v0-2-0", Chart.png_name(chart, json)]))
    end
  end
end
