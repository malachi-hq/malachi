defmodule Mix.Tasks.Malachi.Docs.SiteTest do
  # Mix.shell/1 and File.cd!/2 are global process state, so this file is not async.
  use ExUnit.Case, async: false

  alias Malachi.Site.Chart
  alias Malachi.Test.SiteFixture
  alias Mix.Tasks.Malachi.Docs.Site

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    SiteFixture.minimal(root)

    %{root: root}
  end

  defp messages do
    receive do
      {:mix_shell, :info, [message]} -> [message | messages()]
    after
      0 -> []
    end
  end

  test "stages the landing page with the version from mix.exs", %{root: root} do
    Site.run(["--root", root])

    version = Mix.Project.config()[:version]
    assert File.read!(Path.join(root, "doc/index.html")) =~ "#{version} MIT"
    assert messages() == ["staged the landing page at doc/index.html"]
  end

  test "without --root, stages into the current directory", %{root: root} do
    File.cd!(root, fn -> Site.run([]) end)

    assert File.read!(Path.join(root, "doc/index.html")) =~ "malachi:landing"
  end

  test "--check passes on a staged tree", %{root: root} do
    Site.run(["--root", root])

    # The stage message is drained first, so the only message left is the one --check prints.
    messages()

    assert Site.run(["--root", root, "--check"]) == :ok

    assert messages() == [
             "landing page: staged and filled; every sitemap URL and every link to this site in llms.txt resolves; the blog is staged and every post is finished"
           ]
  end

  test "--check fails, listing the problem, when a linked page is gone", %{root: root} do
    Site.run(["--root", root])
    File.rm!(Path.join(root, "doc/sitemap.xml"))

    error = assert_raise Mix.Error, fn -> Site.run(["--root", root, "--check"]) end
    assert error.message =~ "doc/sitemap.xml is missing"
  end

  test "--check --lfs-pointers accepts a blog chart image left as its Git LFS pointer (#373)", %{root: root} do
    json = ~s({"name": "rate", "title": "Rate", "unit": "r/s", "points": [{"label": "v1.0.0", "value": 1}]})
    {:ok, chart} = Chart.parse(json)

    SiteFixture.write(
      root,
      "site/blog/2026-11-16-x.md",
      "---\ntitle: T\ndate: 2026-11-16\nversions: [1.0.0]\nauthor: A\nsummary: S\n---\n\n```malachi-chart\n#{json}\n```\n"
    )

    SiteFixture.write(
      root,
      "site/blog/2026-11-16-x/#{Chart.png_name(chart, json)}",
      "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 9\n"
    )

    Site.run(["--root", root])
    assert Site.run(["--root", root, "--check", "--lfs-pointers"]) == :ok
    error = assert_raise Mix.Error, fn -> Site.run(["--root", root, "--check"]) end
    assert error.message =~ "is a Git LFS pointer"
  end

  test "an argument the task does not take fails, rather than being ignored", %{root: root} do
    error = assert_raise Mix.Error, fn -> Site.run(["--root", root, "stray"]) end

    assert error.message == "unexpected arguments: stray"

    # The task stops before staging, so ExDoc's redirect is still in place.
    assert File.read!(Path.join(root, "doc/index.html")) =~ "refresh"
  end
end
