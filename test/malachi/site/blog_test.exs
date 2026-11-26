defmodule Malachi.Site.BlogTest do
  # The blog staged by Malachi.Site (#373), against a checkout built per test (Malachi.Test.SiteFixture): what
  # a post page, the index and the feed hold, and every problem the check reports.
  use ExUnit.Case, async: true

  alias Malachi.Site
  alias Malachi.Site.Blog
  alias Malachi.Site.Chart
  alias Malachi.Test.SiteFixture

  import SiteFixture, only: [write: 3]

  @moduletag :tmp_dir

  @config %{version: "1.2.3", licenses: ["MIT"], site_url: "https://example.test/malachi", main: "introduction"}
  @meta Site.metadata(@config)

  @chart ~s({"name": "rate", "title": "Produce rate", "unit": "records/s", "points": [{"label": "v1.2.2", "value": 10}, {"label": "v1.2.3", "value": 12}]})

  setup %{tmp_dir: root} do
    SiteFixture.minimal(root)
    %{root: root}
  end

  defp post(root, file, opts \\ []) do
    fields =
      Keyword.merge(
        [
          title: "Release v1.2.3",
          date: String.slice(file, 0, 10),
          versions: "[1.2.3]",
          author: "Maintainer",
          summary: "What v1.2.3 delivered."
        ],
        Keyword.get(opts, :fields, [])
      )

    front = Enum.map_join(fields, "\n", fn {key, value} -> "#{key}: #{value}" end)
    write(root, "site/blog/#{file}", "---\n#{front}\n---\n\n#{Keyword.get(opts, :body, "Body text.\n")}")
  end

  # A post with a chart and its image, as the generator and the renderer leave them.
  defp charted_post(root, file \\ "2026-11-16-v1-2-3.md") do
    post(root, file, body: "Text.\n\n```malachi-chart\n#{@chart}\n```\n")
    {:ok, chart} = Chart.parse(@chart)
    write(root, "site/blog/#{Path.rootname(file)}/#{Chart.png_name(chart, @chart)}", <<137, "PNG", 0::size(64)>>)
    Chart.png_name(chart, @chart)
  end

  # A post that shows an illustration, with its SVG source and the PNG the renderer drew from it.
  defp illustrated_post(root, body \\ "Text.\n\n![A range splits](2026-11-16-v1-2-3/split.png)\n") do
    post(root, "2026-11-16-v1-2-3.md", body: body)
    write(root, "site/blog/2026-11-16-v1-2-3/split.svg", "<svg/>")
    write(root, "site/blog/2026-11-16-v1-2-3/split.png", <<137, "PNG", 0::size(64)>>)
  end

  defp stage!(root), do: :ok = Site.stage(root, @config)
  defp verify(root), do: Site.verify(root, @config)
  defp read(root, path), do: File.read!(Path.join(root, path))

  describe "with no post" do
    test "stages an index that says so, no feed, and passes the check", %{root: root} do
      stage!(root)
      index = read(root, "doc/blog/index.html")
      assert index =~ "No posts yet."
      refute index =~ "feed.xml"
      refute File.exists?(Path.join(root, "doc/blog/feed.xml"))
      assert verify(root) == []
      assert read(root, "doc/sitemap.xml") =~ "<loc>https://example.test/malachi/blog/</loc>"
    end
  end

  describe "a finished post" do
    test "is staged as a page with its canonical link, open graph and twitter tags, and its chart",
         %{root: root} do
      png = charted_post(root)
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      url = "https://example.test/malachi/blog/2026-11-16-v1-2-3.html"

      assert page =~ ~s(<link rel="canonical" href="#{url}">)
      assert page =~ ~s(<meta property="og:type" content="article">)
      assert page =~ ~s(<meta property="og:url" content="#{url}">)
      assert page =~ ~s(<meta property="og:title" content="Release v1.2.3">)
      assert page =~ ~s(<meta property="og:description" content="What v1.2.3 delivered.">)
      assert page =~ ~s(<meta property="article:published_time" content="2026-11-16">)
      assert page =~ ~s(<meta name="twitter:card" content="summary_large_image">)

      assert page =~
               ~s(<meta property="og:image" content="https://example.test/malachi/blog/2026-11-16-v1-2-3/#{png}">)

      assert page =~ "<svg"
      assert page =~ ~s(<link rel="alternate" type="application/atom+xml" title="Malachi blog" href="feed.xml">)
      assert page =~ ~s(<link rel="stylesheet" href="../blog.css">)
      assert page =~ ~s(<a href="https://www.linkedin.com/company/malachi-hq">LinkedIn</a>)
      assert File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/#{png}"))
      assert File.exists?(Path.join(root, "doc/blog.css"))
      assert verify(root) == []
    end

    test "without a chart or an illustration takes the kit's social preview for its link previews", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md")
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      assert page =~ ~s(<meta name="twitter:card" content="summary_large_image">)
      assert page =~ ~s(<meta property="og:image" content="https://example.test/malachi/kit/social-preview.png">)
      assert page =~ ~s(<meta name="twitter:image" content="https://example.test/malachi/kit/social-preview.png">)
      assert page =~ ~s(<meta property="og:image:width" content="1280">)
      assert page =~ ~s(<meta property="og:image:height" content="640">)
      assert page =~ ~s(<meta property="og:image:alt" content="Malachi">)
      assert File.exists?(Path.join(root, "doc/kit/social-preview.png"))
      assert verify(root) == []
    end

    test "an illustration is published as its PNG beside the page, its SVG source is not, and it is the og:image",
         %{root: root} do
      illustrated_post(root)
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      assert page =~ ~s(<img src="2026-11-16-v1-2-3/split.png" alt="A range splits" loading="lazy" decoding="async">)
      assert page =~ ~s(<meta property="og:image:width" content="1200">)
      assert page =~ ~s(<meta property="og:image:height" content="675">)
      assert page =~ ~s(<meta property="og:image:alt" content="A range splits">)

      assert page =~
               ~s(<meta property="og:image" content="https://example.test/malachi/blog/2026-11-16-v1-2-3/split.png">)

      assert File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/split.png"))
      refute File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/split.svg"))
      assert verify(root) == []
    end

    test "a chart comes before an illustration as the og:image", %{root: root} do
      png = charted_post(root)
      body = "![A range splits](2026-11-16-v1-2-3/split.png)\n\n```malachi-chart\n#{@chart}\n```\n"
      post(root, "2026-11-16-v1-2-3.md", body: body)
      write(root, "site/blog/2026-11-16-v1-2-3/split.png", <<137, "PNG", 0::size(64)>>)
      write(root, "site/blog/2026-11-16-v1-2-3/split.svg", "<svg/>")
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      assert page =~ ~s(<meta property="og:image" content="https://example.test/malachi/blog/2026-11-16-v1-2-3/#{png}">)
      {w, h} = Chart.size()
      assert page =~ ~s(<meta property="og:image:width" content="#{w}">)
      assert page =~ ~s(<meta property="og:image:height" content="#{h}">)
      assert page =~ ~s(<meta property="og:image:alt" content="Produce rate">)
      assert File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/split.png"))
      assert verify(root) == []
    end

    test "an illustration whose PNG declares its size is shown with that width and height", %{root: root} do
      illustrated_post(root)
      write(root, "site/blog/2026-11-16-v1-2-3/split.png", SiteFixture.png(1200, 675))
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      assert page =~ ~s(<img width="1200" height="675" src="2026-11-16-v1-2-3/split.png" alt="A range splits")
    end

    test "carries its BlogPosting structured data, and no text of the post can close the script", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", fields: [title: "A </script><script>x()</script> title", author: "Ana"])
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")

      [json] = Regex.run(~r{<script type="application/ld\+json">(.*?)</script>}s, page, capture: :all_but_first)
      refute json =~ "<"
      data = JSON.decode!(json)

      assert data["@type"] == "BlogPosting"
      assert data["headline"] == "A </script><script>x()</script> title"
      assert data["datePublished"] == "2026-11-16"
      assert data["author"] == %{"@type" => "Person", "name" => "Ana"}
      assert data["url"] == "https://example.test/malachi/blog/2026-11-16-v1-2-3.html"
      assert data["image"]["url"] == "https://example.test/malachi/kit/social-preview.png"
      assert data["publisher"]["name"] == "MalachiHQ"
      assert length(Regex.scan(~r/<script\b/, page)) == 1
      assert verify(root) == []
    end

    test "opens as Medium does: headline, sub headline, the author's photo and Follow, reading time, US date",
         %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", body: String.duplicate("word ", 500) <> "\n")
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")

      [head] = Regex.run(~r{<header class="post-head">.*?</header>}s, page)
      assert head =~ ~r{<h1>Release v1.2.3</h1>\s*<p class="lede">What v1.2.3 delivered.</p>\s*<div class="byline">}
      assert head =~ ~s(<img class="avatar" src="authors/maintainer.png" width="44" height="44" alt="Maintainer">)

      assert head =~
               ~s(<span class="author">Maintainer</span> <a class="follow" href="https://www.linkedin.com/in/maintainer" rel="author noopener">Follow</a>)

      assert head =~ ~s(3 min read · <time datetime="2026-11-16">Nov 16, 2026</time> · v1.2.3)
      assert File.exists?(Path.join(root, "doc/blog/authors/maintainer.png"))

      index = read(root, "doc/blog/index.html")
      assert index =~ ~s(<time datetime="2026-11-16">Nov 16, 2026</time> · 3 min read · v1.2.3)
      assert verify(root) == []
    end

    test "an author missing from authors.json gets the name alone, and the check reports it", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", fields: [author: "Nobody"])
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      assert page =~ ~s(<span class="author">Nobody</span></p>)
      refute page =~ ~s(class="avatar")

      assert ~s(site/blog/2026-11-16-v1-2-3.md names the author "Nobody", who is not in site/blog/authors.json) in verify(
               root
             )
    end

    test "a cover is the large image under the byline, the og:image and the feed's first image", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", fields: [cover: "cover.png"], body: "[docs](../introduction.html)\n")
      write(root, "site/blog/2026-11-16-v1-2-3/cover.svg", "<svg/>")
      write(root, "site/blog/2026-11-16-v1-2-3/cover.png", SiteFixture.png(1200, 675))
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")

      assert page =~
               ~s(</header>\n<figure class="cover"><img src="2026-11-16-v1-2-3/cover.png" width="1200" height="675" alt="Release v1.2.3" fetchpriority="high" decoding="async"></figure>)

      assert page =~
               ~s(<meta property="og:image" content="https://example.test/malachi/blog/2026-11-16-v1-2-3/cover.png">)

      assert page =~ ~s(<meta property="og:image:alt" content="Release v1.2.3">)
      assert File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/cover.png"))
      refute File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/cover.svg"))

      feed = read(root, "doc/blog/feed.xml")
      assert feed =~ "&lt;img src=&quot;https://example.test/malachi/blog/2026-11-16-v1-2-3/cover.png&quot;"
      assert feed =~ "href=&quot;https://example.test/malachi/introduction.html&quot;"
      assert verify(root) == []
    end

    test "a cover that is not a lowercase <name>.png, or that is not rendered", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", fields: [cover: "Cover.jpg"])
      stage_error = assert_raise Mix.Error, fn -> stage!(root) end
      assert stage_error.message =~ ~s(its cover "Cover.jpg" is a lowercase <name>.png beside the post)

      post(root, "2026-11-16-v1-2-3.md", fields: [cover: "cover.png"])
      write(root, "site/blog/2026-11-16-v1-2-3/cover.svg", "<svg/>")
      stage!(root)
      assert Enum.any?(verify(root), &(&1 =~ "shows site/blog/2026-11-16-v1-2-3/cover.png, which is not rendered"))
    end

    test "escapes its front matter in every attribute and text", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", fields: [title: ~s(A "quoted" <b> & 'it'), summary: ~s(S"<x>)])
      stage!(root)
      page = read(root, "doc/blog/2026-11-16-v1-2-3.html")
      assert page =~ ~s(content="A &quot;quoted&quot; &lt;b&gt; &amp; &#39;it&#39;")
      assert page =~ "<h1>A &quot;quoted&quot; &lt;b&gt; &amp; &#39;it&#39;</h1>"
      refute page =~ "<b>"
      refute page =~ "<x>"
      feed = read(root, "doc/blog/feed.xml")
      assert feed =~ "<title>A &quot;quoted&quot; &lt;b&gt; &amp; &#39;it&#39;</title>"
    end

    test "is listed in the index, the sitemap and the feed", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md")
      stage!(root)
      assert read(root, "doc/blog/index.html") =~ ~s(<a href="2026-11-16-v1-2-3.html">Release v1.2.3</a>)
      assert read(root, "doc/sitemap.xml") =~ "https://example.test/malachi/blog/2026-11-16-v1-2-3.html"
      feed = read(root, "doc/blog/feed.xml")
      assert feed =~ "<id>tag:example.test,2026-11-16:/blog/2026-11-16-v1-2-3</id>"
      assert feed =~ ~s(<content type="html">&lt;p&gt;Body text.&lt;/p&gt;)
    end
  end

  describe "llms.txt" do
    test "lists the blog, its feed and each post with its summary, in a block replaced at every staging",
         %{root: root} do
      post(root, "2026-11-16-a.md", fields: [title: "First [one]", versions: "[1.2.2]"])
      stage!(root)
      llms = read(root, "doc/llms.txt")
      assert llms =~ "<!-- malachi:blog begin -->\n## Blog\n"
      assert llms =~ "- [Atom feed](https://example.test/malachi/blog/feed.xml)"

      assert llms =~
               "- [First (one)](https://example.test/malachi/blog/2026-11-16-a.html): What v1.2.3 delivered. (2026-11-16)"

      assert verify(root) == []

      post(root, "2026-11-17-b.md", fields: [title: "Second"])
      stage!(root)
      llms = read(root, "doc/llms.txt")
      assert length(Regex.scan(~r/malachi:blog begin/, llms)) == 1
      assert llms =~ "(https://example.test/malachi/blog/2026-11-17-b.html)"
      assert llms =~ "(https://example.test/malachi/blog/2026-11-16-a.html)"

      File.rm!(Path.join(root, "site/blog/2026-11-16-a.md"))
      File.rm!(Path.join(root, "site/blog/2026-11-17-b.md"))
      stage!(root)
      refute read(root, "doc/llms.txt") =~ "malachi:blog"
    end
  end

  describe "the feed" do
    test "is well-formed Atom with the 20 newest posts, newest first", %{root: root} do
      for day <- 1..21 do
        date = Date.new!(2026, 10, day) |> Date.to_iso8601()
        post(root, "#{date}-post-#{day}.md", fields: [versions: "[1.0.#{day}]"])
      end

      stage!(root)
      xml = read(root, "doc/blog/feed.xml")
      {doc, _} = xml |> String.to_charlist() |> :xmerl_scan.string(quiet: true)
      assert elem(doc, 1) == :feed

      ids = ~r{<entry>\s*<id>([^<]+)</id>}s |> Regex.scan(xml, capture: :all_but_first) |> List.flatten()
      assert length(ids) == 20
      assert hd(ids) == "tag:example.test,2026-10-21:/blog/2026-10-21-post-21"
      refute Enum.any?(ids, &String.ends_with?(&1, "post-1"))
      assert xml =~ "<updated>2026-10-21T00:00:00Z</updated>\n<entry>"
      assert verify(root) == []
    end

    test "a feed out of order, with an entry too many or one missing, or no feed at all is reported",
         %{root: root} do
      post(root, "2026-11-15-a.md", fields: [versions: "[1.2.2]"])
      post(root, "2026-11-16-b.md")
      stage!(root)
      feed = Path.join(root, "doc/blog/feed.xml")
      xml = File.read!(feed)

      swapped =
        xml
        |> String.replace("2026-11-16T00:00:00Z", "TMP")
        |> String.replace("2026-11-15T00:00:00Z", "2026-11-16T00:00:00Z")
        |> String.replace("TMP", "2026-11-15T00:00:00Z")

      File.write!(feed, swapped)
      assert "doc/blog/feed.xml is not newest first" in verify(root)

      File.write!(feed, String.replace(xml, ~r{<entry>.*?</entry>\n}s, "", global: false))
      assert "doc/blog/feed.xml does not hold one entry per post among the newest; stage the site again" in verify(root)

      File.rm!(feed)
      assert "doc/blog/feed.xml is missing; stage the site again" in verify(root)
    end
  end

  describe "what keeps a post from being published" do
    test "a narrative placeholder or a seed block left in it", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md",
        body: "<!-- narrative -->\n\n```malachi-seed\nHighlights.\n```\n\n<!-- narrative: more -->\n"
      )

      stage!(root)
      errors = verify(root)
      assert "site/blog/2026-11-16-v1-2-3.md still has 2 <!-- narrative --> placeholder(s) to write" in errors

      assert "site/blog/2026-11-16-v1-2-3.md still has the malachi-seed block of release highlights; fold it into the narrative" in errors
    end

    test "a version covered by two posts", %{root: root} do
      post(root, "2026-11-16-a.md", fields: [versions: "[1.2.2, 1.2.3]"])
      post(root, "2026-11-17-b.md", fields: [versions: "[1.2.3]"])
      stage!(root)
      assert "v1.2.3 is covered by more than one post: 2026-11-16-a.md, 2026-11-17-b.md" in verify(root)
    end

    test "a chart image missing, a Git LFS pointer, too large, or one no chart names", %{root: root} do
      png = charted_post(root)
      dir = Path.join(root, "site/blog/2026-11-16-v1-2-3")

      File.write!(Path.join(dir, png), "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 9\n")
      stage!(root)
      assert "site/blog/2026-11-16-v1-2-3/#{png} is a Git LFS pointer, not the image: run git lfs pull" in verify(root)

      File.write!(Path.join(dir, png), :binary.copy(<<0>>, 150 * 1024 + 1))
      assert "site/blog/2026-11-16-v1-2-3/#{png} is 150 KB; an image beside a post is at most 150 KB" in verify(root)

      File.rm!(Path.join(dir, png))
      File.write!(Path.join(dir, "rate-00000000.png"), "old")
      errors = verify(root)

      assert Enum.any?(errors, &(&1 =~ "draws a chart whose image site/blog/2026-11-16-v1-2-3/#{png} is missing"))

      assert Enum.any?(
               errors,
               &(&1 =~
                   "rate-00000000.png is neither an image 2026-11-16-v1-2-3.md shows nor an illustration's SVG source")
             )
    end

    test "a Git LFS pointer is accepted with lfs_pointers, as on a fork's pull request, and nothing else is",
         %{root: root} do
      png = charted_post(root)
      dir = Path.join(root, "site/blog/2026-11-16-v1-2-3")
      File.write!(Path.join(dir, png), "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 9\n")
      stage!(root)

      assert Site.verify(root, @config, lfs_pointers: true) == []
      assert Enum.any?(Site.verify(root, @config), &(&1 =~ "is a Git LFS pointer"))

      File.rm!(Path.join(dir, png))
      assert Enum.any?(Site.verify(root, @config, lfs_pointers: true), &(&1 =~ "is missing"))
    end

    test "an illustration not rendered, missing with its source, a Git LFS pointer, or too large", %{root: root} do
      illustrated_post(root)
      dir = Path.join(root, "site/blog/2026-11-16-v1-2-3")
      stage!(root)

      File.rm!(Path.join(dir, "split.png"))

      assert ("site/blog/2026-11-16-v1-2-3.md shows site/blog/2026-11-16-v1-2-3/split.png, which is not rendered: " <>
                "run mix malachi.release.post --images site/blog/2026-11-16-v1-2-3.md") in verify(root)

      File.rm!(Path.join(dir, "split.svg"))

      assert ("site/blog/2026-11-16-v1-2-3.md shows site/blog/2026-11-16-v1-2-3/split.png, which is missing, " <>
                "and so is its SVG source") in verify(root)

      File.write!(Path.join(dir, "split.png"), "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 9\n")

      assert "site/blog/2026-11-16-v1-2-3/split.png is a Git LFS pointer, not the image: run git lfs pull" in verify(
               root
             )

      assert Site.verify(root, @config, lfs_pointers: true) == []

      File.write!(Path.join(dir, "split.png"), :binary.copy(<<0>>, 150 * 1024 + 1))
      assert "site/blog/2026-11-16-v1-2-3/split.png is 150 KB; an image beside a post is at most 150 KB" in verify(root)
    end

    test "an image from the post's folder that is not a lowercase <name>.png, and a file nothing shows",
         %{root: root} do
      illustrated_post(root, "![a](2026-11-16-v1-2-3/split.png) ![b](2026-11-16-v1-2-3/Split.PNG)\n")
      write(root, "site/blog/2026-11-16-v1-2-3/notes.txt", "draft")
      write(root, "site/blog/2026-11-16-v1-2-3/orphan.svg", "<svg/>")
      stage!(root)
      errors = verify(root)

      assert ("site/blog/2026-11-16-v1-2-3.md shows 2026-11-16-v1-2-3/Split.PNG; an image beside a post is a " <>
                "lowercase <name>.png") in errors

      for name <- ["notes.txt", "orphan.svg"] do
        assert ("site/blog/2026-11-16-v1-2-3/#{name} is neither an image 2026-11-16-v1-2-3.md shows nor an " <>
                  "illustration's SVG source (stale after a change?); remove it") in errors
      end

      refute File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/notes.txt"))
      refute File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3/orphan.svg"))
    end

    test "more than five illustrations; one shown twice counts once", %{root: root} do
      names = for i <- 1..6, do: "d#{i}.png"
      body = Enum.map_join(names ++ ["d1.png"], "\n\n", &"![x](2026-11-16-v1-2-3/#{&1})") <> "\n"
      post(root, "2026-11-16-v1-2-3.md", body: body)
      for name <- names, do: write(root, "site/blog/2026-11-16-v1-2-3/#{name}", <<137, "PNG", 0::size(64)>>)
      stage!(root)
      assert "site/blog/2026-11-16-v1-2-3.md has 6 illustrations; a post has at most 5" in verify(root)
    end

    test "more than three charts", %{root: root} do
      blocks =
        for i <- 1..4 do
          "```malachi-chart\n" <> String.replace(@chart, ~s("rate"), ~s("rate-#{i}")) <> "\n```\n"
        end

      post(root, "2026-11-16-v1-2-3.md", body: Enum.join(blocks, "\n"))
      stage!(root)
      assert "site/blog/2026-11-16-v1-2-3.md has 4 charts; a post has at most 3" in verify(root)
    end

    test "a link on a blog page that does not resolve on this site; one elsewhere is not checked", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md",
        body: "[a](../introduction.html) [b](../gone.html) [c](https://other.test/x) [d](#top)\n"
      )

      stage!(root)

      assert verify(root) == [
               "doc/blog/2026-11-16-v1-2-3.html (../gone.html) links to https://example.test/malachi/gone.html, which is not in doc/"
             ]
    end

    test "a relative link that climbs above the site is reported, though made absolute it names this host",
         %{root: root} do
      post(root, "2026-11-16-v1-2-3.md", body: "[out](../../other.html) [root](/elsewhere.html)\n")
      stage!(root)

      assert verify(root) == [
               "doc/blog/2026-11-16-v1-2-3.html (../../other.html) leaves this site, to https://example.test/other.html"
             ]
    end

    test "a script loaded on a blog page", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md")
      stage!(root)
      page = Path.join(root, "doc/blog/2026-11-16-v1-2-3.html")
      File.write!(page, File.read!(page) <> ~s(<script src="https://cdn.test/x.js"></script>))
      assert "doc/blog/2026-11-16-v1-2-3.html loads a script; this blog page loads none" in verify(root)
    end

    test "a staged page or index gone", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md")
      stage!(root)
      File.rm!(Path.join(root, "doc/blog/2026-11-16-v1-2-3.html"))
      File.rm!(Path.join(root, "doc/blog/index.html"))
      errors = verify(root)
      assert "doc/blog/2026-11-16-v1-2-3.html is missing; stage the site again" in errors
      assert "doc/blog/index.html is missing; stage the site again" in errors
    end
  end

  describe "a post that cannot be read" do
    for {{name, fields_or_body, reason}, i} <-
          Enum.with_index([
            {"bad-name.md", [], "file name is YYYY-MM-DD-<slug>.md"},
            {"2026-02-30-x.md", [], "file name is YYYY-MM-DD-<slug>.md"},
            {"2026-11-16-Upper.md", [], "file name is YYYY-MM-DD-<slug>.md"},
            {"2026-11-16-x.md", [fields: [date: "2026-11-17"]], "is not the date in its file name"},
            {"2026-11-16-x.md", [fields: [date: "16/11/2026"]], "is not a YYYY-MM-DD date"},
            {"2026-11-16-x.md", [fields: [title: ""]], "lacks title"},
            {"2026-11-16-x.md", [fields: [versions: "1.2.3"]], "are a list of releases"},
            {"2026-11-16-x.md", [fields: [versions: "[]"]], "are a list of releases"},
            {"2026-11-16-x.md", [fields: [versions: "[v1.2.3]"]], "are a list of releases"},
            {"2026-11-16-x.md", [fields: [versions: "[1.2.3, 1.2.3]"]], "name one release twice"},
            {"2026-11-16-x.md", [fields: [tags: "x"]], "unknown key tags"},
            {"2026-11-16-x.md", [body: "<div>raw</div>\n"], "raw HTML"},
            {"2026-11-16-x.md", [body: "[x](javascript:alert(1))\n"], "uses javascript:"}
          ]) do
      test "is refused by stage and reported by the check, #{i}: #{reason} (#{name})", %{root: root} do
        post(root, unquote(name), unquote(fields_or_body))
        error = assert_raise Mix.Error, fn -> Site.stage(root, @config) end
        assert error.message =~ unquote(reason)
        assert Enum.any?(Blog.errors(root, Path.join(root, "doc"), @meta), &(&1 =~ unquote(reason)))
      end
    end

    test "front matter that is missing, not closed, holds a key twice, or a line that is not key: value",
         %{root: root} do
      for {text, reason} <- [
            {"No front matter.\n", "starts with front matter"},
            {"---\ntitle: x\n", "not closed"},
            {"---\ntitle: a\ntitle: b\n---\n", "title twice"},
            {"---\njust text\n---\n", "is not key: value"}
          ] do
        write(root, "site/blog/2026-11-16-x.md", text)
        assert [{:error, message}] = Blog.read_all(root)
        assert message =~ reason
      end
    end

    test "a refused post leaves the staged blog as it was", %{root: root} do
      post(root, "2026-11-16-v1-2-3.md")
      stage!(root)
      before = read(root, "doc/blog/index.html")
      post(root, "2026-11-17-bad.md", body: "<div>raw</div>\n")
      assert_raise Mix.Error, fn -> Site.stage(root, @config) end
      assert read(root, "doc/blog/index.html") == before
    end
  end

  test "staging again removes the page of a post that is gone", %{root: root} do
    post(root, "2026-11-16-v1-2-3.md")
    stage!(root)
    File.rm!(Path.join(root, "site/blog/2026-11-16-v1-2-3.md"))
    stage!(root)
    refute File.exists?(Path.join(root, "doc/blog/2026-11-16-v1-2-3.html"))
    refute read(root, "doc/sitemap.xml") =~ "2026-11-16-v1-2-3"
  end

  test "a site/blog that is not a folder cannot be listed, and says so", %{root: root} do
    File.rm_rf!(Path.join(root, "site/blog"))
    write(root, "site/blog", "a file where the folder should be")
    error = assert_raise Mix.Error, fn -> Blog.read_all(root) end
    assert error.message =~ "site/blog: cannot be listed"
  end

  # test_helper excludes `:non_root` under root, which reads any file.
  @tag :non_root
  test "a post that cannot be read is reported with the reason", %{root: root} do
    post(root, "2026-11-16-x.md")
    path = Path.join(root, "site/blog/2026-11-16-x.md")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o644) end)
    assert [{:error, message}] = Blog.read_all(root)
    assert message =~ "site/blog/2026-11-16-x.md: cannot be read"
  end

  test "a post that is not UTF-8 is refused", %{root: root} do
    write(root, "site/blog/2026-11-16-x.md", <<"---\ntitle: ", 0xFF, "\n---\n">>)
    assert [{:error, message}] = Blog.read_all(root)
    assert message =~ "is not UTF-8"
  end

  test "a feed holding more entries than it may, or without its tag id, is reported", %{root: root} do
    post(root, "2026-11-16-v1-2-3.md")
    stage!(root)
    feed = Path.join(root, "doc/blog/feed.xml")
    xml = File.read!(feed)
    [entry] = Regex.run(~r{<entry>.*?</entry>\n}s, xml)
    File.write!(feed, String.replace(xml, entry, String.duplicate(entry, 21)))
    assert "doc/blog/feed.xml holds 21 entries; it holds the 20 newest" in verify(root)

    File.write!(feed, String.replace(xml, ~r{<id>tag:example.test,2026:/blog/</id>}, "<id>other</id>"))
    assert "doc/blog/feed.xml does not hold one entry per post among the newest; stage the site again" in verify(root)
  end

  test "read_all/1 lists the newest post first, a file that is not a post is skipped", %{root: root} do
    post(root, "2026-11-15-a.md", fields: [versions: "[1.2.2]"])
    post(root, "2026-11-16-b.md")
    write(root, "site/blog/notes.txt", "not a post")
    assert [{:ok, %{slug: "2026-11-16-b"}}, {:ok, %{slug: "2026-11-15-a"}}] = Blog.read_all(root)
  end
end
