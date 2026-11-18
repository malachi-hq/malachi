defmodule SiteImagesPullTest do
  # scripts/site-images-pull.sh checks every blog and kit image from its Git LFS pointer before anything is
  # downloaded (#373): an image committed outside LFS, or one over budget, fails the build without spending the
  # LFS quota. It runs for real against a git repository built per test, whose "images" are pointer files, with
  # `git-lfs` replaced by a stub on the PATH that records whether a pull was asked for.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @script Path.expand("../../scripts/site-images-pull.sh", __DIR__)

  @lfs_stub ~S"""
  #!/usr/bin/env bash
  printf '%s\n' "$*" >> "$LFS_STUB_DIR/calls"
  [ -f "$LFS_STUB_DIR/fail" ] && exit 1
  exit 0
  """

  setup do
    root = TmpDir.path("site_images_pull")
    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    for dir <- [repo, bin], do: File.mkdir_p!(dir)
    File.write!(Path.join(bin, "git-lfs"), @lfs_stub)
    File.chmod!(Path.join(bin, "git-lfs"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repo, ["init", "-q", "-b", "main"])
    %{root: root, repo: repo, bin: bin}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args], cd: repo)
    out
  end

  defp pointer(size),
    do: "version https://git-lfs.github.com/spec/v1\noid sha256:#{String.duplicate("a", 64)}\nsize #{size}\n"

  defp add!(ctx, path, content) do
    full = Path.join(ctx.repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    git!(ctx.repo, ["add", path])
  end

  defp run(ctx, args \\ []) do
    {out, code} =
      System.cmd("bash", [@script | args],
        cd: ctx.repo,
        stderr_to_stdout: true,
        env: [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}, {"LFS_STUB_DIR", ctx.root}]
      )

    {out, code}
  end

  defp lfs_calls(ctx) do
    case File.read(Path.join(ctx.root, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "with no image, passes and fetches nothing", ctx do
    assert {"site-images-pull: 0 image(s) within budget\n", 0} = run(ctx)
    assert lfs_calls(ctx) == []
  end

  test "images within budget are fetched, from the two folders alone", ctx do
    add!(ctx, "site/blog/2026-11-16-v1/rate-0123abcd.png", pointer(150 * 1024))
    add!(ctx, "site/kit/social-preview.png", pointer(300 * 1024))
    assert {out, 0} = run(ctx)
    assert out =~ "2 image(s) within budget"
    assert lfs_calls(ctx) == ["pull --include=site/blog/**/*.png,site/kit/**/*.png"]
  end

  test "reads each pointer from the index, so an image the checkout already replaced still passes", ctx do
    add!(ctx, "site/blog/2026-11-16-v1/rate-0123abcd.png", pointer(10))
    # What `git lfs install` leaves in the working tree after a checkout: the image, not its pointer.
    File.write!(Path.join(ctx.repo, "site/blog/2026-11-16-v1/rate-0123abcd.png"), <<137, "PNG", 0::size(64)>>)
    assert {out, 0} = run(ctx)
    assert out =~ "1 image(s) within budget"
    assert lfs_calls(ctx) == ["pull --include=site/blog/**/*.png,site/kit/**/*.png"]
  end

  test "--check-only checks and fetches nothing, as on a fork's pull request", ctx do
    add!(ctx, "site/blog/2026-11-16-v1/rate-0123abcd.png", pointer(10))
    assert {_, 0} = run(ctx, ["--check-only"])
    assert lfs_calls(ctx) == []
  end

  test "a blog chart over 150 KB or a kit image over 300 KB fails before anything is fetched", ctx do
    add!(ctx, "site/blog/2026-11-16-v1/rate-0123abcd.png", pointer(150 * 1024 + 1))
    add!(ctx, "site/kit/cover.png", pointer(300 * 1024 + 1))
    assert {out, 1} = run(ctx)
    assert out =~ "site/blog/2026-11-16-v1/rate-0123abcd.png is 150 KB; the budget is 150 KB"
    assert out =~ "site/kit/cover.png is 300 KB; the budget is 300 KB"
    assert lfs_calls(ctx) == []
  end

  test "an image committed outside Git LFS, or a pointer without a size, fails", ctx do
    add!(ctx, "site/blog/2026-11-16-v1/raw.png", <<137, "PNG", 0::size(64)>>)
    add!(ctx, "site/kit/odd.png", "version https://git-lfs.github.com/spec/v1\noid sha256:00\n")
    assert {out, 1} = run(ctx, ["--check-only"])
    assert out =~ "site/blog/2026-11-16-v1/raw.png is committed outside Git LFS"
    assert out =~ "site/kit/odd.png is a Git LFS pointer without a size"
  end

  test "a PNG elsewhere in the repository is not the site's and is not checked", ctx do
    add!(ctx, "docs/diagram.png", <<137, "PNG">>)
    assert {_, 0} = run(ctx, ["--check-only"])
  end

  test "a failed fetch fails the build", ctx do
    add!(ctx, "site/kit/cover.png", pointer(10))
    File.write!(Path.join(ctx.root, "fail"), "")
    assert {_, 1} = run(ctx)
  end

  test "an argument it does not take is a usage error", ctx do
    assert {out, 2} = run(ctx, ["--everything"])
    assert out =~ "site-images-pull.sh [--check-only]"
    assert {_, 2} = run(ctx, ["--check-only", "extra"])
  end
end
