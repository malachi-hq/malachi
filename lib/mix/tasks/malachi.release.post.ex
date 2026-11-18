defmodule Mix.Tasks.Malachi.Release.Post do
  @shortdoc "Writes the draft blog post of a release, renders its chart images, or sends it to dev.to"

  @moduledoc """
  #{@shortdoc} (issue #373).

      mix malachi.release.post v0.29.0                   # the draft of one release
      mix malachi.release.post v0.28.1..v0.28.2          # one draft for consecutive patch releases of a minor
      mix malachi.release.post v0.29.0 --author "Name"   # the author, git's user.name by default
      mix malachi.release.post v0.29.0 --force           # write over this release's existing draft
      mix malachi.release.post --images site/blog/2026-11-20-v0-29-0.md
      mix malachi.release.post --devto site/blog/2026-11-20-v0-29-0.md   # with DEVTO_API_KEY set

  The draft lands in `site/blog/` with the measurements, the changes and the charts filled in from the
  repository, and `<!-- narrative -->` placeholders where the maintainer writes (`Malachi.Release.Post` says
  what it holds and why). The site check refuses to publish it until every placeholder is written and the
  `malachi-seed` block of release highlights is folded into the text.

  A post's charts are also published as PNG images, for the places that do not render inline SVG. The draft is
  followed by `--images`, which renders each chart's missing image with the Playwright already pinned in
  `site/checks` (`node site/checks/render.mjs`) and removes an image no chart names any more. Run it again after
  editing a chart. Without Node or Playwright it says what to install and what to run then.

  `--devto` sends a finished post to dev.to as a draft, through `scripts/devto-draft.sh`, which creates it once
  and updates it afterwards (`Malachi.Release.Devto` says how the Markdown is adapted). It needs DEVTO_API_KEY
  in the environment, and refuses a post that still holds a placeholder.

  Runs locally, never in CI: it reads the repository's history and tags, and `CHANGELOG.md` from the working
  tree. A release already covered by a post is refused, unless `--force` writes over that same file.
  `--root` points the task at another checkout, for the tests.
  """

  use Mix.Task

  alias Malachi.Release.Devto
  alias Malachi.Release.Measurements
  alias Malachi.Release.Post
  alias Malachi.Site.Blog
  alias Malachi.Site.Chart

  @switches [author: :string, force: :boolean, images: :string, devto: :string, root: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, rest} = OptionParser.parse!(argv, strict: @switches)
    root = Keyword.get(opts, :root, File.cwd!())

    case {opts[:images], opts[:devto], rest} do
      {nil, nil, [spec]} ->
        draft(root, spec, opts)

      {post, nil, []} when is_binary(post) ->
        images(root, post)

      {nil, post, []} when is_binary(post) ->
        devto(root, post)

      _ ->
        Mix.raise(
          "usage: mix malachi.release.post vX.Y.Z | vA..vB [--author NAME] [--force] | --images POST | --devto POST"
        )
    end
  end

  defp draft(root, spec, opts) do
    tags = Measurements.tags(root)
    author = opts[:author] || git_user(root)

    with {:ok, releases} <- Post.releases(spec, tags),
         {:ok, draft} <- Post.build(root, releases, tags, author: author),
         :ok <- not_covered(root, draft, Keyword.get(opts, :force, false)) do
      path = Path.join([root, "site/blog", draft.file])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, draft.markdown)
      Mix.shell().info("wrote #{Path.relative_to(path, root)}: write its <!-- narrative --> placeholders")
      images(root, Path.relative_to(path, root))
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp git_user(root) do
    case System.cmd("git", ["config", "user.name"], cd: root, stderr_to_stdout: true) do
      {name, 0} when name != "" -> String.trim(name)
      _ -> Mix.raise("no author: pass --author or set git's user.name")
    end
  end

  # Every release keeps one post: another post covering one of these versions is always refused, and this
  # draft's own file is written over only with --force.
  defp not_covered(root, draft, force?) do
    others =
      for {:ok, post} <- Blog.read_all(root),
          post.file != draft.file,
          overlap = Enum.filter(draft.versions, &(&1 in post.versions)),
          overlap != [] do
        "site/blog/#{post.file} already covers #{Enum.map_join(overlap, ", ", &"v#{&1}")}"
      end

    cond do
      others != [] ->
        {:error, Enum.join(others, "\n")}

      File.exists?(Path.join([root, "site/blog", draft.file])) and not force? ->
        {:error, "site/blog/#{draft.file} exists; pass --force to write over it"}

      true ->
        :ok
    end
  end

  # A post as the blog reads it, and its source; refused as the blog refuses it.
  defp read_post(root, post_path) do
    dir = Path.join(root, Path.dirname(post_path))

    case Blog.read(dir, Path.basename(post_path)) do
      {:ok, post} -> {post, File.read!(Path.join(dir, post.file))}
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp images(root, post_path) do
    {post, _source} = read_post(root, post_path)
    dir = Path.join(root, Path.dirname(post_path))

    images_dir = Path.join(dir, post.slug)
    wanted = Enum.map(post.charts, &{&1, Chart.png_name(&1.chart, &1.json)})
    remove_stale(images_dir, Enum.map(wanted, &elem(&1, 1)))
    missing = Enum.reject(wanted, fn {_, name} -> File.exists?(Path.join(images_dir, name)) end)

    case {wanted, missing} do
      {[], _} -> Mix.shell().info("#{post_path}: no chart, so no image to render")
      {_, []} -> Mix.shell().info("#{post_path}: every chart image is in place")
      _ -> render(root, post_path, images_dir, missing)
    end
  end

  defp remove_stale(images_dir, names) do
    case File.ls(images_dir) do
      {:ok, present} ->
        for name <- present, String.ends_with?(name, ".png"), name not in names do
          File.rm!(Path.join(images_dir, name))
          Mix.shell().info("removed #{name}, which no chart names any more")
        end

      {:error, _} ->
        :ok
    end
  end

  defp render(root, post_path, images_dir, missing) do
    work = Path.join(System.tmp_dir!(), "malachi-release-post-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    File.mkdir_p!(images_dir)

    try do
      pairs =
        Enum.flat_map(missing, fn {%{chart: chart}, name} ->
          svg = Path.join(work, Path.rootname(name) <> ".svg")
          File.write!(svg, Chart.to_svg(chart))
          [svg, Path.join(images_dir, name)]
        end)

      {width, height} = Chart.size()
      script = Path.join(root, "site/checks/render.mjs")

      with node when is_binary(node) <- System.find_executable("node"),
           {_, 0} <-
             System.cmd(node, [script, "#{width}x#{height}" | pairs],
               cd: root,
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
        Mix.shell().info("rendered #{length(missing)} chart image(s) beside #{post_path}")
      else
        _ ->
          # An images folder this run made and left empty is not left behind; one holding images is kept.
          File.rmdir(images_dir)

          Mix.raise("""
          the chart images could not be rendered. Install the renderer once:

              cd site/checks && npm ci && npx playwright install --only-shell chromium

          then run: mix malachi.release.post --images #{post_path}
          """)
      end
    after
      File.rm_rf!(work)
    end
  end

  defp devto(root, post_path) do
    {post, source} = read_post(root, post_path)
    meta = Malachi.Site.metadata(Malachi.Site.from_project(Mix.Project.config()))

    article =
      case Devto.article(source, post, meta) do
        {:ok, article} -> article
        {:error, reason} -> Mix.raise(reason)
      end

    file = Path.join(System.tmp_dir!(), "malachi-devto-#{System.unique_integer([:positive])}.json")
    File.write!(file, JSON.encode!(article))

    try do
      case System.cmd(Path.join(root, "scripts/devto-draft.sh"), [file], stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} -> :ok
        {_, status} -> Mix.raise("scripts/devto-draft.sh failed (#{status}); see above")
      end
    after
      File.rm(file)
    end
  end
end
