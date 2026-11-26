defmodule Malachi.Site.CommentsTest do
  # The comments under each blog post (#373): the blog_comments setting, the giscus section, the one script a
  # post's page may load, and the site staged and checked with them.
  use ExUnit.Case, async: true

  alias Malachi.Site
  alias Malachi.Site.Comments
  alias Malachi.Test.SiteFixture

  import SiteFixture, only: [write: 3]

  @comments [repo: "malachi-hq/malachi", repo_id: "R_kgDOabc", category: "Blog comments", category_id: "DIC_kwDOxyz"]
  @config %{version: "1.2.3", licenses: ["MIT"], site_url: "https://example.test/malachi", main: "introduction"}

  describe "parse/1" do
    test "nil is no comments, and the four keys are comments" do
      assert Comments.parse(nil) == {:ok, nil}

      assert Comments.parse(@comments) ==
               {:ok,
                %{
                  repo: "malachi-hq/malachi",
                  repo_id: "R_kgDOabc",
                  category: "Blog comments",
                  category_id: "DIC_kwDOxyz"
                }}
    end

    for {opts, reason} <- [
          {[], "is nil or a keyword list"},
          {"x", "is nil or a keyword list"},
          {[{"repo", "a/b"}], "is a keyword list"},
          {[repo: "a/b", host: "x"], "has unknown keys [:host]"},
          {[repo: "a/b", repo: "a/b", repo_id: "R", category: "C", category_id: "D"], "names a key twice"},
          {[repo: "a", repo_id: "R", category: "C", category_id: "D"], "repo is not valid"},
          {[repo: "a/b c", repo_id: "R", category: "C", category_id: "D"], "repo is not valid"},
          {[repo: "a/b", repo_id: "R\"", category: "C", category_id: "D"], "repo_id is not valid"},
          {[repo: "a/b", repo_id: "R", category: "<C>", category_id: "D"], "category is not valid"},
          {[repo: "a/b", repo_id: "R", category: "C"], "category_id is a string, got nil"}
        ] do
      test "refuses #{inspect(opts)}" do
        assert {:error, reason} = Comments.parse(unquote(Macro.escape(opts)))
        assert reason =~ unquote(reason)
      end
    end

    test "the project's own setting is a valid one, for this repository" do
      comments = Comments.from_config!(Site.from_project(Mix.Project.config()))
      assert comments.repo == "malachi-hq/malachi"
    end

    test "from_config!/1 names the setting it refuses" do
      assert_raise ArgumentError, ~r/the blog_comments in mix.exs: repo is not valid/, fn ->
        Comments.from_config!(%{blog_comments: [repo: "x", repo_id: "R", category: "C", category_id: "D"]})
      end
    end
  end

  test "section/1 is giscus's script, lazily loaded, mapped by path, escaped, with a link for no script" do
    {:ok, comments} = Comments.parse(Keyword.put(@comments, :category, "Blog & comments"))
    html = Comments.section(comments)
    assert html =~ ~s(<script src="https://giscus.app/client.js" data-repo="malachi-hq/malachi")
    assert html =~ ~s(data-category="Blog &amp; comments")
    assert html =~ ~s(data-mapping="pathname")
    assert html =~ ~s(data-loading="lazy")
    assert html =~ ~s(crossorigin="anonymous" async></script>)
    assert html =~ ~s(<a href="https://github.com/malachi-hq/malachi/discussions">GitHub</a>)
  end

  describe "script_errors/4" do
    setup do
      {:ok, comments} = Comments.parse(@comments)
      %{comments: comments, section: Comments.section(comments)}
    end

    test "a page without a script is fine unless it is a post's with comments", %{comments: c} do
      assert Comments.script_errors("a.html", "<p>x</p>", nil, true) == []
      assert Comments.script_errors("a.html", "<p>x</p>", c, false) == []

      assert Comments.script_errors("a.html", "<p>x</p>", c, true) == [
               "doc/a.html has no comments, and mix.exs configures them; stage the site again"
             ]
    end

    test "giscus's script only on a post's page with comments", %{comments: c, section: section} do
      assert Comments.script_errors("a.html", section, c, true) == []

      assert Comments.script_errors("a.html", section, c, false) == [
               "doc/a.html loads a script; this blog page loads none"
             ]

      assert Comments.script_errors("a.html", section, nil, true) == [
               "doc/a.html loads a script; this blog page loads none"
             ]
    end

    test "any other script, a second one, or giscus's for another repository", %{comments: c, section: section} do
      other = ~s(<script src="https://evil.test/x.js"></script>)
      elsewhere = String.replace(section, ~s(data-repo="malachi-hq/malachi"), ~s(data-repo="other/repo"))

      for html <- [other, section <> other, elsewhere, String.replace(section, "giscus.app", "giscus.app.evil.test")] do
        assert [message] = Comments.script_errors("a.html", html, c, true)
        assert message =~ "loads a script other than the comments'"
      end
    end
  end

  describe "the site with comments" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      SiteFixture.minimal(root)

      write(
        root,
        "site/blog/2026-11-16-a.md",
        "---\ntitle: T\ndate: 2026-11-16\nversions: [1.2.3]\nauthor: Maintainer\nsummary: S\n---\n\nText.\n"
      )

      %{config: Map.put(@config, :blog_comments, @comments)}
    end

    test "a post ends with its comments, the index has none, and the check passes", %{tmp_dir: root, config: config} do
      :ok = Site.stage(root, config)
      assert File.read!(Path.join(root, "doc/blog/2026-11-16-a.html")) =~ ~s(<section class="comments")
      refute File.read!(Path.join(root, "doc/blog/index.html")) =~ "<script"
      assert Site.verify(root, config) == []
    end

    test "a post staged without comments, while mix.exs configures them, is reported", %{tmp_dir: root, config: config} do
      :ok = Site.stage(root, @config)

      assert "doc/blog/2026-11-16-a.html has no comments, and mix.exs configures them; stage the site again" in Site.verify(
               root,
               config
             )
    end
  end
end
