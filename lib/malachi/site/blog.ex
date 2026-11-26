defmodule Malachi.Site.Blog do
  @moduledoc """
  The blog of the published site (issue #373): one page per post under `blog/`, an index, and an Atom feed.
  `Malachi.Site.stage/2` calls `stage/4` and `Malachi.Site.verify/3` adds `errors/4`.

  A post is `site/blog/YYYY-MM-DD-<slug>.md`: front matter between two `---` lines, then Markdown
  (`Malachi.Site.Markdown`). The front matter holds exactly these keys, one per line as `key: value`:

    * `title`, `author` and `summary`: text;
    * `date`: the post's day, `YYYY-MM-DD`, the same as its file name's;
    * `versions`: the releases it covers, `[0.28.1, 0.28.2]`, at least one.

  A post's images are in `site/blog/<file name without .md>/`, and are staged beside its page, so
  `blog/<slug>.html` and `blog/<slug>/` sit together. They are of two kinds, both PNG, because dev.to, Medium and
  LinkedIn do not show SVG:

    * its charts (`Malachi.Site.Chart`), drawn inline on the site and rendered to PNG for the other places;
    * its illustrations: a diagram the post shows as `![alt](<slug>/<name>.png)`, rendered from the SVG source
      `<name>.svg` beside it by `mix malachi.release.post --images`, drawn at 1200x675.

  Only those PNGs are published; an SVG source stays in the repository. The post's `og:image` is its first
  chart, else its first illustration, else the kit's social preview, with its size and alt text. A post's page
  also carries its `BlogPosting` structured data (JSON-LD), and an illustration whose PNG declares its size is
  shown with that `width` and `height`, so the page does not shift as it loads. `llms_section/2` lists the
  newest posts for `llms.txt`.

  `stage/4` refuses (raises) a post it cannot read or render. `errors/4` reports what keeps a post from being
  published:

    * a `<!-- narrative -->` placeholder left in it (its title and summary included) or a `malachi-seed` block;
    * a file name that is not `YYYY-MM-DD-<slug>.md`, or a date that differs from the file name's;
    * a version covered by two posts;
    * more than 3 charts or 5 illustrations; a chart or an illustration whose PNG is missing, is a Git LFS
      pointer (the image was not fetched) or exceeds 150 KB; a chart PNG not named for the chart's current data;
      an image shown from the post's folder that is not a lowercase `<name>.png`; a file beside a post that is
      neither one of its images nor an illustration's SVG source;
    * on the staged tree: a page, the index or the feed missing; the feed not in date order, over 20
      entries, or not holding one entry per post among the newest; a link or image on a blog page that does not
      resolve on this site, or a relative one that climbs above it; a script loaded from anywhere on a blog page;
    * the newsletter's (`Malachi.Site.Newsletter`): a form while none is configured, a page without exactly
      one form posting to the configured `action`, a form on the privacy note, and a privacy note that is
      missing, unfinished (a placeholder or a `malachi-seed` block) or draws a chart.
  """

  alias Malachi.Release.Devto
  alias Malachi.Site.Authors
  alias Malachi.Site.Chart
  alias Malachi.Site.Comments
  alias Malachi.Site.Markdown
  alias Malachi.Site.Newsletter

  @dir "site/blog"
  @max_charts 3
  @max_illustrations 5
  @illustration_size {1200, 675}
  @illustration_name ~r/\A[a-z0-9][a-z0-9-]*\.png\z/
  @max_png_bytes 150 * 1024
  @feed_entries 20
  @file_name ~r/\A(\d{4}-\d{2}-\d{2})-([a-z0-9][a-z0-9-]*)\.md\z/
  @keys ~w(title date versions author summary)
  @optional_keys ~w(cover)
  @words_per_minute 238
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @version ~r/\A\d+\.\d+\.\d+\z/
  @lfs_pointer "version https://git-lfs.github.com/spec/"

  @typedoc "A post read from its file."
  @type post :: %{
          file: String.t(),
          slug: String.t(),
          title: String.t(),
          date: Date.t(),
          versions: [String.t()],
          author: String.t(),
          summary: String.t(),
          cover: String.t() | nil,
          html: String.t(),
          charts: [Markdown.chart()],
          images: [%{src: String.t(), alt: String.t()}],
          narratives: non_neg_integer(),
          seeds: non_neg_integer()
        }

  @doc """
  Every post under `root/site/blog`, newest first (then by slug), each read or with what is wrong with it.
  A folder that does not exist holds no post.
  """
  @spec read_all(Path.t()) :: [{:ok, post()} | {:error, String.t()}]
  def read_all(root) do
    dir = Path.join(root, @dir)

    names =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, :enoent} -> []
        {:error, reason} -> Mix.raise("#{@dir}: cannot be listed (#{:file.format_error(reason)})")
      end

    names
    |> Enum.filter(&(String.ends_with?(&1, ".md") and File.regular?(Path.join(dir, &1))))
    |> Enum.sort()
    |> Enum.map(&read(dir, &1))
    |> Enum.sort_by(fn
      {:ok, post} -> {0, -Date.to_gregorian_days(post.date), post.slug}
      {:error, message} -> {1, 0, message}
    end)
  end

  @doc "Reads one post, `name` being its file name in `dir`."
  @spec read(Path.t(), String.t()) :: {:ok, post()} | {:error, String.t()}
  def read(dir, name) do
    where = "#{@dir}/#{name}"

    with {:ok, file_date, _} <- file_name(name),
         {:ok, text} <- read_text(Path.join(dir, name)),
         {:ok, fields, body} <- front_matter(text),
         {:ok, meta} <- fields(fields),
         :ok <- same_date(meta.date, file_date),
         {:ok, rendered} <- render(body) do
      {:ok, Map.merge(meta, Map.merge(rendered, %{file: name, slug: Path.rootname(name)}))}
    else
      {:error, reason} -> {:error, "#{where}: #{reason}"}
    end
  end

  defp file_name(name) do
    with [_, date, slug] <- Regex.run(@file_name, name),
         {:ok, date} <- Date.from_iso8601(date) do
      {:ok, date, slug}
    else
      _ -> {:error, "a post's file name is YYYY-MM-DD-<slug>.md, with a real date and a lowercase slug"}
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, text} ->
        if String.valid?(text), do: {:ok, text}, else: {:error, "is not UTF-8"}

      {:error, reason} ->
        {:error, "cannot be read (#{:file.format_error(reason)})"}
    end
  end

  # The block between a first line `---` and the next `---` line, and the Markdown after it.
  defp front_matter(text) do
    case String.split(String.replace(text, "\r\n", "\n"), "\n") do
      ["---" | rest] ->
        case Enum.split_while(rest, &(&1 != "---")) do
          {fields, ["---" | body]} -> {:ok, fields, Enum.join(body, "\n")}
          _ -> {:error, "its front matter is not closed by a --- line"}
        end

      _ ->
        {:error, "a post starts with front matter between two --- lines"}
    end
  end

  defp fields(lines) do
    lines
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case Regex.run(~r/\A([a-z]+):[ \t]*(.*?)[ \t]*\z/, line) do
        [_, key, value] when key in @keys or key in @optional_keys ->
          if Map.has_key?(acc, key),
            do: {:halt, {:error, "its front matter has #{key} twice"}},
            else: {:cont, {:ok, Map.put(acc, key, value)}}

        [_, key, _] ->
          {:halt,
           {:error,
            "its front matter has an unknown key #{key}; the keys are #{Enum.join(@keys ++ @optional_keys, ", ")}"}}

        nil ->
          {:halt, {:error, "its front matter line #{inspect(line)} is not key: value"}}
      end
    end)
    |> case do
      {:ok, map} -> typed(map)
      error -> error
    end
  end

  defp typed(map) do
    with :ok <- required(map),
         {:ok, date} <- date(map["date"]),
         {:ok, versions} <- versions(map["versions"]),
         {:ok, cover} <- cover(map["cover"]) do
      {:ok,
       %{
         title: map["title"],
         author: map["author"],
         summary: map["summary"],
         date: date,
         versions: versions,
         cover: cover
       }}
    end
  end

  defp cover(nil), do: {:ok, nil}

  defp cover(name) do
    if Regex.match?(@illustration_name, name),
      do: {:ok, name},
      else: {:error, "its cover #{inspect(name)} is a lowercase <name>.png beside the post"}
  end

  defp required(map) do
    case Enum.filter(@keys, &(Map.get(map, &1, "") == "")) do
      [] -> :ok
      missing -> {:error, "its front matter lacks #{Enum.join(missing, ", ")}"}
    end
  end

  defp date(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "its date #{inspect(text)} is not a YYYY-MM-DD date"}
    end
  end

  defp versions(text) do
    with [_, inner] <- Regex.run(~r/\A\[(.*)\]\z/, text),
         list = inner |> String.split(",") |> Enum.map(&String.trim/1),
         true <- list != [""] and Enum.all?(list, &Regex.match?(@version, &1)) do
      if Enum.uniq(list) == list,
        do: {:ok, list},
        else: {:error, "its versions name one release twice"}
    else
      _ -> {:error, "its versions are a list of releases, as [0.28.1, 0.28.2], got #{inspect(text)}"}
    end
  end

  defp same_date(date, date), do: :ok

  defp same_date(date, file_date),
    do: {:error, "its date #{date} is not the date in its file name, #{file_date}"}

  defp render(body) do
    case Markdown.render(body) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, errors} -> {:error, Enum.join(errors, "; ")}
    end
  end

  @doc """
  Writes every post's page and images, `blog/index.html` and (when there is a post) `blog/feed.xml` into `doc`.
  With a `newsletter`, each page but the privacy note ends with its form, and `blog/privacy.html` is written.
  Raises when a post or the privacy note cannot be read or rendered: staging part of the blog would publish the
  rest without it.
  """
  @spec stage(
          Path.t(),
          Path.t(),
          %{String.t() => String.t()},
          (Path.t(), String.t() -> :ok),
          Newsletter.t() | nil,
          Comments.t() | nil
        ) :: :ok
  def stage(root, doc, meta, write, newsletter \\ nil, comments \\ nil) do
    posts =
      case Enum.split_with(read_all(root), &match?({:ok, _}, &1)) do
        {ok, []} -> Enum.map(ok, fn {:ok, post} -> post end)
        {_, failed} -> Mix.raise("the blog cannot be staged:\n" <> Enum.map_join(failed, "\n", &elem(&1, 1)))
      end

    authors =
      case Authors.read(root) do
        {:ok, authors} -> authors
        {:error, message} -> Mix.raise("the blog cannot be staged:\n" <> message)
      end

    privacy =
      case newsletter && Newsletter.privacy(root) do
        nil -> nil
        {:ok, rendered} -> rendered
        {:error, message} -> Mix.raise("the blog cannot be staged:\n" <> message)
      end

    blog = Path.join(doc, "blog")
    File.rm_rf!(blog)

    for post <- posts do
      write.(Path.join("blog", post.slug <> ".html"), page(root, post, meta, newsletter, authors, comments))
      copy_images(root, blog, post)
    end

    :ok = Authors.stage(root, doc, posts, authors)

    write.("blog/index.html", index(posts, meta, newsletter))
    if posts != [], do: write.("blog/feed.xml", feed(posts, meta))
    if privacy, do: write.("blog/privacy.html", privacy_page(privacy, meta))
    :ok
  end

  # Only the PNGs the post shows are published: an SVG source, or a file nothing names, stays out of the site.
  defp copy_images(root, blog, post) do
    source = Path.join([root, @dir, post.slug])

    for name <- chart_images(post) ++ illustrations(post), File.regular?(Path.join(source, name)) do
      File.mkdir_p!(Path.join(blog, post.slug))
      File.cp!(Path.join(source, name), Path.join([blog, post.slug, name]))
    end
  end

  @doc "The file names of a post's chart PNGs, in the order it draws them."
  @spec chart_images(post()) :: [String.t()]
  def chart_images(post), do: Enum.map(post.charts, &Chart.png_name(&1.chart, &1.json))

  @doc """
  The file names of the illustrations a post shows from its own folder, `![alt](<slug>/<name>.png)`, in order and
  without repeats. An image from its folder with any other name is not one; the check reports it.
  """
  @spec illustrations(post()) :: [String.t()]
  def illustrations(post) do
    [Map.get(post, :cover) | own_images(post)]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&Regex.match?(@illustration_name, &1))
    |> Enum.uniq()
  end

  @doc "The size an illustration's SVG source is drawn at, as `{width, height}`."
  @spec illustration_size() :: {pos_integer(), pos_integer()}
  def illustration_size, do: @illustration_size

  # What the post shows from its own folder, by the path under it.
  defp own_images(post) do
    prefix = post.slug <> "/"
    for %{src: src} <- post.images, String.starts_with?(src, prefix), do: String.replace_prefix(src, prefix, "")
  end

  @doc """
  The `## Blog` section of `llms.txt`: the blog, its feed and its #{@feed_entries} newest posts, each with its
  summary, so an assistant that reads `llms.txt` finds them. Empty when there is no post.
  """
  @spec llms_section(Path.t(), map()) :: String.t()
  def llms_section(root, meta) do
    case for({:ok, post} <- read_all(root), do: post) do
      [] ->
        ""

      posts ->
        base = meta["base_url"]

        entries =
          posts
          |> Enum.take(@feed_entries)
          |> Enum.map_join("\n", fn post ->
            "- [#{link_text(post.title)}](#{url(post, meta)}): #{one_line(post.summary)} (#{post.date})"
          end)

        """
        ## Blog

        - [Malachi blog](#{base}/blog/index.html): posts about each release and the engineering behind it
        - [Atom feed](#{base}/blog/feed.xml)
        #{entries}
        """
    end
  end

  defp link_text(text), do: text |> one_line() |> String.replace("[", "(") |> String.replace("]", ")")
  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  # The PNG's own size, from its IHDR chunk, or nil when the file is not a PNG that says it.
  defp png_size(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 24)) do
      {:ok, <<137, "PNG", 13, 10, 26, 10, _len::32, "IHDR", width::32, height::32>>} when width > 0 and height > 0 ->
        {width, height}

      _ ->
        nil
    end
  end

  # The post's HTML with each illustration given its PNG's width and height, read from the source folder.
  defp sized_html(root, post) do
    Enum.reduce(illustrations(post), post.html, fn name, html ->
      case png_size(Path.join([root, @dir, post.slug, name])) do
        {w, h} ->
          String.replace(
            html,
            ~s(<img src="#{post.slug}/#{name}"),
            ~s(<img width="#{w}" height="#{h}" src="#{post.slug}/#{name}")
          )

        nil ->
          html
      end
    end)
  end

  # The regular files beside a post, without the ones whose name starts with a dot.
  defp image_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&File.regular?(Path.join(dir, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "A post's URL on the site."
  @spec url(post(), map()) :: String.t()
  def url(post, meta), do: "#{meta["base_url"]}/blog/#{post.slug}.html"

  @doc "The URL of a chart's PNG, published beside the post."
  @spec image_url(post(), Markdown.chart(), map()) :: String.t()
  def image_url(post, %{chart: chart, json: json}, meta),
    do: "#{meta["base_url"]}/blog/#{post.slug}/#{Chart.png_name(chart, json)}"

  # The image of the post's link previews, as {url, {width, height}, alt}: its cover, else its first chart, else
  # its first illustration (at the size it is rendered at), else the kit's social preview.
  defp og_image(%{cover: cover} = post, meta) when is_binary(cover),
    do: {"#{meta["base_url"]}/blog/#{post.slug}/#{cover}", @illustration_size, post.title}

  defp og_image(post, meta) do
    case {post.charts, illustrations(post)} do
      {[first | _], _} ->
        {image_url(post, first, meta), Chart.size(), first.chart.title}

      {[], [first | _]} ->
        alt = Enum.find_value(post.images, "", &(&1.src == "#{post.slug}/#{first}" && &1.alt))
        {"#{meta["base_url"]}/blog/#{post.slug}/#{first}", @illustration_size, alt}

      {[], []} ->
        {"#{meta["base_url"]}/kit/social-preview.png", {1280, 640}, "Malachi"}
    end
  end

  # The post's BlogPosting structured data. `<` is written as its JSON escape, so no text of the post can close
  # the script element.
  defp json_ld(post, url, {img, {w, h}, _alt}, meta) do
    base = meta["base_url"]

    %{
      "@context" => "https://schema.org",
      "@type" => "BlogPosting",
      "headline" => post.title,
      "description" => post.summary,
      "datePublished" => Date.to_iso8601(post.date),
      "dateModified" => Date.to_iso8601(post.date),
      "inLanguage" => "en",
      "url" => url,
      "mainEntityOfPage" => url,
      "image" => %{"@type" => "ImageObject", "url" => img, "width" => w, "height" => h},
      "author" => %{"@type" => "Person", "name" => post.author},
      "publisher" => %{
        "@type" => "Organization",
        "name" => "MalachiHQ",
        "url" => base <> "/",
        "logo" => %{"@type" => "ImageObject", "url" => base <> "/assets/logo-mark.svg"}
      },
      "isPartOf" => %{"@type" => "Blog", "name" => "Malachi blog", "url" => base <> "/blog/index.html"},
      "about" => %{
        "@type" => "SoftwareSourceCode",
        "name" => "Malachi",
        "codeRepository" => "https://github.com/malachi-hq/malachi"
      }
    }
    |> JSON.encode!()
    |> String.replace("<", "\\u003c")
  end

  defp page(root, post, meta, newsletter, authors, comments) do
    url = url(post, meta)

    {img, {w, h}, alt} = og = og_image(post, meta)

    image =
      ~s(<meta property="og:image" content="#{e(img)}">\n) <>
        ~s(<meta property="og:image:width" content="#{w}">\n<meta property="og:image:height" content="#{h}">\n) <>
        ~s(<meta property="og:image:alt" content="#{e(alt)}">\n) <>
        ~s(<meta name="twitter:card" content="summary_large_image">\n) <>
        ~s(<meta name="twitter:image" content="#{e(img)}">\n<meta name="twitter:image:alt" content="#{e(alt)}">\n) <>
        ~s(<script type="application/ld+json">#{json_ld(post, url, og, meta)}</script>)

    shell(
      feed?: true,
      title: "#{post.title} | Malachi blog",
      description: post.summary,
      canonical: url,
      head: """
      <meta property="og:type" content="article">
      <meta property="og:site_name" content="Malachi">
      <meta property="og:title" content="#{e(post.title)}">
      <meta property="og:description" content="#{e(post.summary)}">
      <meta property="og:url" content="#{e(url)}">
      <meta property="article:published_time" content="#{post.date}">
      <meta name="twitter:title" content="#{e(post.title)}">
      <meta name="twitter:description" content="#{e(post.summary)}">
      #{image}
      """,
      main: """
      <article class="post">
      <header class="post-head">
      <h1>#{e(post.title)}</h1>
      <p class="lede">#{e(post.summary)}</p>
      #{byline(post, Map.get(authors, post.author))}
      </header>
      #{cover_figure(root, post)}
      #{sized_html(root, post)}
      </article>
      #{if comments, do: Comments.section(comments), else: ""}
      #{form(newsletter)}
      """
    )
  end

  defp versions_text(versions), do: Enum.map_join(versions, ", ", &"v#{&1}")

  # As Medium shows it: the author's photo and name with a Follow link, then the reading time, the date and the
  # releases. An author missing from authors.json gets the name alone; the check reports it.
  defp byline(post, author) do
    {photo, follow} =
      case author do
        %{photo: photo, follow: follow} ->
          {~s(<img class="avatar" src="authors/#{e(photo)}" width="44" height="44" alt="#{e(post.author)}">\n),
           ~s( <a class="follow" href="#{e(follow)}" rel="author noopener">Follow</a>)}

        nil ->
          {"", ""}
      end

    """
    <div class="byline">
    #{photo}<div class="byline-text">
    <p class="byline-name"><span class="author">#{e(post.author)}</span>#{follow}</p>
    <p class="post-meta">#{reading_minutes(post.html)} min read · <time datetime="#{post.date}">#{us_date(post.date)}</time> · #{versions_text(post.versions)}</p>
    </div>
    </div>
    """
  end

  # The cover, the large image under the byline, at its PNG's size when the PNG says it.
  defp cover_figure(_root, %{cover: nil}), do: ""

  defp cover_figure(root, post) do
    {w, h} = png_size(Path.join([root, @dir, post.slug, post.cover])) || @illustration_size

    ~s(<figure class="cover"><img src="#{post.slug}/#{post.cover}" width="#{w}" height="#{h}" alt="#{e(post.title)}" fetchpriority="high" decoding="async"></figure>)
  end

  @doc "Minutes to read a post's HTML at #{@words_per_minute} words a minute, rounded up, at least 1."
  @spec reading_minutes(String.t()) :: pos_integer()
  def reading_minutes(html) do
    words = html |> String.replace(~r/<[^>]*>/, " ") |> String.split() |> length()
    max(1, ceil(words / @words_per_minute))
  end

  @doc "A date as US readers write it: `Nov 25, 2026`."
  @spec us_date(Date.t()) :: String.t()
  def us_date(date), do: "#{Enum.at(@months, date.month - 1)} #{date.day}, #{date.year}"

  defp index(posts, meta, newsletter) do
    items =
      case posts do
        [] ->
          ~s(<p class="muted">No posts yet.</p>)

        _ ->
          entries =
            Enum.map_join(posts, "\n", fn post ->
              """
              <li><a href="#{post.slug}.html">#{e(post.title)}</a>
              <p class="post-meta"><time datetime="#{post.date}">#{us_date(post.date)}</time> · #{reading_minutes(post.html)} min read · #{versions_text(post.versions)}</p>
              <p>#{e(post.summary)}</p></li>
              """
            end)

          ~s(<ul class="post-list">\n#{entries}</ul>)
      end

    shell(
      feed?: posts != [],
      title: "Malachi blog",
      description: "Malachi blog",
      canonical: "#{meta["base_url"]}/blog/",
      head: ~s(<meta property="og:type" content="website">\n<meta property="og:title" content="Malachi blog">),
      main: """
      <section class="post">
      <h1>Malachi blog</h1>
      #{if posts != [], do: ~s(<p><a href="feed.xml">Atom feed</a></p>), else: ""}
      #{items}
      </section>
      #{form(newsletter)}
      """
    )
  end

  defp form(nil), do: ""
  defp form(newsletter), do: Newsletter.form(newsletter)

  # The maintainer's privacy note, under the blog's header and footer, with no form of its own.
  defp privacy_page(rendered, meta) do
    shell(
      feed?: false,
      title: "Newsletter privacy | Malachi blog",
      description: "Newsletter privacy",
      canonical: "#{meta["base_url"]}/blog/privacy.html",
      head: ~s(<meta property="og:type" content="website">),
      main: """
      <article class="post">
      <h1>Newsletter privacy</h1>
      #{rendered.html}
      </article>
      """
    )
  end

  # The page around a post or the index: the landing page's header, footer and styles, one level down.
  defp shell(opts) do
    {feed_head, feed_foot} =
      if opts[:feed?],
        do:
          {~s(<link rel="alternate" type="application/atom+xml" title="Malachi blog" href="feed.xml">\n),
           ~s(<a href="feed.xml">Atom feed</a>\n)},
        else: {"", ""}

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{e(opts[:title])}</title>
    <meta name="description" content="#{e(opts[:description])}">
    <link rel="canonical" href="#{e(opts[:canonical])}">
    #{opts[:head]}
    #{feed_head}<link rel="stylesheet" href="../styles.css">
    <link rel="stylesheet" href="../tokens/marketing.css">
    <link rel="stylesheet" href="../site.css">
    <link rel="stylesheet" href="../blog.css">
    </head>
    <body>
    <a class="skip" href="#main">Skip to content</a>
    <header class="top wrap">
    <a class="brand" href="../index.html" aria-label="Malachi home"><img src="../assets/logo-mark.svg" width="28" height="28" alt=""><span>malachi</span></a>
    <nav class="top-nav" aria-label="Primary">
    <a href="index.html">Blog</a>
    <a class="hide-sm" href="../introduction.html">Docs</a>
    <a href="https://github.com/malachi-hq/malachi">GitHub</a>
    </nav>
    </header>
    <main id="main" class="wrap">
    #{opts[:main]}
    </main>
    <footer class="foot">
    <div class="wrap foot-in">
    <p class="muted small">MIT license. Not production-ready.</p>
    <nav class="foot-nav" aria-label="Footer">
    <a href="index.html">Blog</a>
    #{feed_foot}<a href="../introduction.html">Docs</a>
    <a href="https://github.com/malachi-hq/malachi/releases">Releases</a>
    <a href="https://www.linkedin.com/company/malachi-hq">LinkedIn</a>
    </nav>
    </div>
    </footer>
    </body>
    </html>
    """
  end

  @doc """
  The Atom feed: the #{@feed_entries} newest posts, newest first, each with its whole page body as escaped HTML
  (an RSS-to-email service sends what the feed holds). An entry's id is a `tag:` URI of the site's host, the
  post's date and its path, so it does not change when the post is edited.
  """
  @spec feed([post()], map()) :: String.t()
  def feed([newest | _] = posts, meta) do
    host = URI.parse(meta["base_url"]).host

    entries =
      posts
      |> Enum.take(@feed_entries)
      |> Enum.map_join("\n", fn post ->
        """
        <entry>
        <id>#{entry_id(post, host)}</id>
        <title>#{e(post.title)}</title>
        <link rel="alternate" type="text/html" href="#{e(url(post, meta))}"/>
        <published>#{post.date}T00:00:00Z</published>
        <updated>#{post.date}T00:00:00Z</updated>
        <author><name>#{e(post.author)}</name></author>
        <summary>#{e(post.summary)}</summary>
        <content type="html">#{e(feed_html(post, meta))}</content>
        </entry>
        """
      end)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
    <id>tag:#{host},2026:/blog/</id>
    <title>Malachi blog</title>
    <link rel="self" type="application/atom+xml" href="#{e(meta["base_url"])}/blog/feed.xml"/>
    <link rel="alternate" type="text/html" href="#{e(meta["base_url"])}/blog/"/>
    <updated>#{newest.date}T00:00:00Z</updated>
    #{entries}
    </feed>
    """
  end

  # A post's HTML as a feed reader or an email shows it: its cover first, and every relative src or href made
  # absolute from the post's URL, since neither has the page's address to resolve them from.
  defp feed_html(post, meta) do
    url = url(post, meta)

    cover =
      if post.cover,
        do: ~s(<p><img src="#{post.slug}/#{post.cover}" alt="#{e(post.title)}"></p>\n),
        else: ""

    Regex.replace(~r/\b(src|href)="([^"]*)"/, cover <> post.html, fn _whole, attr, target ->
      ~s(#{attr}="#{e(Devto.resolve(unescape_attr(target), url))}")
    end)
  end

  defp unescape_attr(text), do: String.replace(text, "&amp;", "&")

  defp entry_id(post, host), do: "tag:#{host},#{post.date}:/blog/#{post.slug}"

  @doc """
  Every problem in the blog's source and in its staged pages. See the moduledoc.

  `lfs_pointers: true` accepts a chart image that is still its Git LFS pointer: a fork's pull request never
  fetches the images, and `scripts/site-images-pull.sh --check-only` has checked their declared sizes instead.
  `newsletter:` is the configured `Malachi.Site.Newsletter`, `nil` (the default) when there is none.
  """
  @spec errors(Path.t(), Path.t(), map(), keyword()) :: [String.t()]
  def errors(root, doc, meta, opts \\ []) do
    pointers? = Keyword.get(opts, :lfs_pointers, false)
    newsletter = Keyword.get(opts, :newsletter)
    comments = Keyword.get(opts, :comments)
    read = read_all(root)
    posts = for {:ok, post} <- read, do: post

    for({:error, message} <- read, do: message) ++
      Enum.flat_map(posts, &unfinished/1) ++
      duplicate_versions(posts) ++
      Enum.flat_map(posts, &image_errors(root, &1, pointers?)) ++
      Authors.errors(root, posts, pointers?) ++
      Newsletter.source_errors(root, newsletter) ++
      staged_errors(doc, posts, meta, newsletter, comments)
  end

  defp unfinished(post) do
    where = "#{@dir}/#{post.file}"

    narratives =
      post.narratives + Enum.count([post.title, post.summary], &String.contains?(&1, "<!-- narrative"))

    placeholders =
      if narratives > 0,
        do: ["#{where} still has #{narratives} <!-- narrative --> placeholder(s) to write"],
        else: []

    seeds =
      if post.seeds > 0,
        do: ["#{where} still has the malachi-seed block of release highlights; fold it into the narrative"],
        else: []

    placeholders ++ seeds
  end

  defp duplicate_versions(posts) do
    posts
    |> Enum.flat_map(fn post -> Enum.map(post.versions, &{&1, post.file}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_version, files} -> length(files) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {version, files} ->
      "v#{version} is covered by more than one post: #{files |> Enum.sort() |> Enum.join(", ")}"
    end)
  end

  defp image_errors(root, post, pointers?) do
    where = "#{@dir}/#{post.file}"
    dir = Path.join([root, @dir, post.slug])
    charts = chart_images(post)
    illustrations = illustrations(post)
    sources = Enum.map(illustrations, &(Path.rootname(&1) <> ".svg"))

    missing_chart = fn shown ->
      "#{where} draws a chart whose image #{shown} is missing: run node site/checks/render.mjs"
    end

    missing_illustration = fn shown ->
      if File.regular?(Path.rootname(Path.join(root, shown)) <> ".svg"),
        do: "#{where} shows #{shown}, which is not rendered: run mix malachi.release.post --images #{where}",
        else: "#{where} shows #{shown}, which is missing, and so is its SVG source"
    end

    counts(where, charts, illustrations) ++
      Enum.flat_map(charts, &png_errors(dir, post.slug, &1, missing_chart, pointers?)) ++
      Enum.flat_map(illustrations, &png_errors(dir, post.slug, &1, missing_illustration, pointers?)) ++
      for name <- Enum.uniq(own_images(post)) -- illustrations do
        "#{where} shows #{post.slug}/#{name}; an image beside a post is a lowercase <name>.png"
      end ++
      for name <- image_files(dir) -- (charts ++ illustrations ++ sources) do
        "#{@dir}/#{post.slug}/#{name} is neither an image #{post.file} shows nor an illustration's SVG source " <>
          "(stale after a change?); remove it"
      end
  end

  defp counts(where, charts, illustrations) do
    chart_count =
      if length(charts) > @max_charts,
        do: ["#{where} has #{length(charts)} charts; a post has at most #{@max_charts}"],
        else: []

    illustration_count =
      if length(illustrations) > @max_illustrations,
        do: ["#{where} has #{length(illustrations)} illustrations; a post has at most #{@max_illustrations}"],
        else: []

    chart_count ++ illustration_count
  end

  defp png_errors(dir, slug, name, missing, pointers?) do
    path = Path.join(dir, name)
    shown = "#{@dir}/#{slug}/#{name}"

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_png_bytes ->
        ["#{shown} is #{div(size, 1024)} KB; an image beside a post is at most #{div(@max_png_bytes, 1024)} KB"]

      {:ok, %File.Stat{type: :regular}} ->
        if not pointers? and lfs_pointer?(path),
          do: ["#{shown} is a Git LFS pointer, not the image: run git lfs pull"],
          else: []

      _ ->
        [missing.(shown)]
    end
  end

  @doc false
  # For Malachi.Site, which checks the kit's social preview the same way.
  @spec lfs_pointer?(Path.t()) :: boolean()
  def lfs_pointer?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, byte_size(@lfs_pointer))) do
      {:ok, @lfs_pointer} -> true
      _ -> false
    end
  end

  defp staged_errors(doc, posts, meta, newsletter, comments) do
    # Each page, its URL, whether it carries the newsletter's form (every page but the privacy note) and whether
    # it is a post's (the only pages with comments).
    pages =
      for post <- posts, do: {"blog/#{post.slug}.html", url(post, meta), true, true}

    privacy =
      if newsletter,
        do: [{"blog/privacy.html", "#{meta["base_url"]}/blog/privacy.html", false, false}],
        else: []

    pages = [{"blog/index.html", "#{meta["base_url"]}/blog/index.html", true, false} | pages] ++ privacy

    Enum.flat_map(pages, fn {rel, page_url, form?, post?} ->
      checks = fn html ->
        Comments.script_errors(rel, html, comments, post?) ++ Newsletter.form_errors(rel, html, newsletter, form?)
      end

      page_errors(doc, rel, page_url, meta, checks)
    end) ++
      feed_errors(doc, posts)
  end

  defp page_errors(doc, rel, page_url, meta, checks) do
    case File.read(Path.join(doc, rel)) do
      {:ok, html} ->
        checks.(html) ++ link_errors(doc, rel, html, page_url, meta)

      {:error, _} ->
        ["doc/#{rel} is missing; stage the site again"]
    end
  end

  @href ~r/\b(?:href|src)="([^"]*)"/

  defp link_errors(doc, rel, html, page_url, meta) do
    # Text inside a code block is an example, not a link.
    html = Regex.replace(~r{<pre\b.*?</pre>}s, html, "")

    @href
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&unescape/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn ref ->
      absolute = page_url |> URI.merge(ref) |> URI.to_string()
      where = "doc/#{rel} (#{ref})"

      # Made absolute, a relative link that climbs above the site reads as another site's page on this host,
      # which Malachi.Site passes over. It is this site's own link, and it leads nowhere on the site.
      if dot_relative?(ref) and not under_site?(absolute, meta),
        do: ["#{where} leaves this site, to #{absolute}"],
        else: Malachi.Site.link_errors(doc, meta, absolute, where)
    end)
  end

  defp dot_relative?(ref) do
    uri = URI.parse(ref)
    uri.scheme == nil and uri.host == nil and not String.starts_with?(ref, ["/", "#"])
  end

  defp under_site?(absolute, %{"base_url" => base}),
    do: absolute == base or String.starts_with?(absolute, base <> "/")

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp feed_errors(_doc, []), do: []

  defp feed_errors(doc, posts) do
    case File.read(Path.join(doc, "blog/feed.xml")) do
      {:ok, xml} ->
        updated = Regex.scan(~r{<entry>.*?<updated>([^<]+)</updated>}s, xml, capture: :all_but_first)
        updated = List.flatten(updated)
        ids = ~r{<entry>\s*<id>([^<]+)</id>}s |> Regex.scan(xml, capture: :all_but_first) |> List.flatten()
        wanted = posts |> Enum.take(@feed_entries) |> Enum.map(&entry_id(&1, feed_host(xml)))

        order =
          if updated == Enum.sort(updated, :desc), do: [], else: ["doc/blog/feed.xml is not newest first"]

        size =
          if length(ids) > @feed_entries,
            do: ["doc/blog/feed.xml holds #{length(ids)} entries; it holds the #{@feed_entries} newest"],
            else: []

        entries =
          if ids == wanted,
            do: [],
            else: ["doc/blog/feed.xml does not hold one entry per post among the newest; stage the site again"]

        order ++ size ++ entries

      {:error, _} ->
        ["doc/blog/feed.xml is missing; stage the site again"]
    end
  end

  defp feed_host(xml) do
    case Regex.run(~r{<feed[^>]*>\s*<id>tag:([^,]+),}, xml) do
      [_, host] -> host
      nil -> ""
    end
  end

  defp e(text), do: Chart.escape(text)
end
