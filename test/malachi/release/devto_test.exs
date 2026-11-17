defmodule Malachi.Release.DevtoTest do
  use ExUnit.Case, async: true

  alias Malachi.Release.Devto
  alias Malachi.Site.Blog
  alias Malachi.Site.Chart

  @moduletag :tmp_dir

  @meta %{"base_url" => "https://example.test/malachi"}
  @json ~s({"name": "rate", "title": "Produce rate", "unit": "r/s", "points": [{"label": "v1.0.0", "value": 1}]})

  defp post!(dir, body, front \\ []) do
    fields =
      Keyword.merge(
        [title: "Malachi v1.0.0", date: "2026-11-16", versions: "[1.0.0]", author: "A", summary: "S."],
        front
      )

    source = "---\n" <> Enum.map_join(fields, "\n", fn {k, v} -> "#{k}: #{v}" end) <> "\n---\n\n" <> body
    File.write!(Path.join(dir, "2026-11-16-v1-0-0.md"), source)
    {:ok, post} = Blog.read(dir, "2026-11-16-v1-0-0.md")
    {source, post}
  end

  test "a draft with the post's title, summary and canonical URL, never published", %{tmp_dir: dir} do
    {source, post} = post!(dir, "Text.\n")
    assert {:ok, %{"article" => article}} = Devto.article(source, post, @meta)
    assert article["title"] == "Malachi v1.0.0"
    assert article["description"] == "S."
    assert article["canonical_url"] == "https://example.test/malachi/blog/2026-11-16-v1-0-0.html"
    assert article["published"] == false
    assert article["body_markdown"] == "Text.\n"
    refute article["body_markdown"] =~ "title:"
  end

  test "a chart becomes its PNG on the site, the image the site publishes", %{tmp_dir: dir} do
    {source, post} = post!(dir, "Before.\n\n```malachi-chart\n#{@json}\n```\n\nAfter.\n")
    {:ok, %{"article" => %{"body_markdown" => body}}} = Devto.article(source, post, @meta)
    {:ok, chart} = Chart.parse(@json)

    assert body ==
             "Before.\n\n![Produce rate](https://example.test/malachi/blog/2026-11-16-v1-0-0/#{Chart.png_name(chart, @json)})\n\nAfter.\n"
  end

  test "relative links and images become absolute from the post's URL; others and code are kept",
       %{tmp_dir: dir} do
    body = """
    [docs](../introduction.html) [here](#measurements) ![x](chart.png) [abs](https://other.test/a "T")
    [mail](mailto:a@example.test)

    ```
    [not a link](../kept.html)
    ```
    """

    {source, post} = post!(dir, body)
    {:ok, %{"article" => %{"body_markdown" => out}}} = Devto.article(source, post, @meta)
    assert out =~ "[docs](https://example.test/malachi/introduction.html)"
    assert out =~ "[here](https://example.test/malachi/blog/2026-11-16-v1-0-0.html#measurements)"
    assert out =~ "![x](https://example.test/malachi/blog/chart.png)"
    assert out =~ ~s{[abs](https://other.test/a "T")}
    assert out =~ "[mail](mailto:a@example.test)"
    assert out =~ "[not a link](../kept.html)"
  end

  test "an unfinished post is refused: a placeholder in the body, title or summary, or a seed block",
       %{tmp_dir: dir} do
    for {body, front} <- [
          {"<!-- narrative -->\n", []},
          {"```malachi-seed\nHighlights.\n```\n", []},
          {"Text.\n", [summary: "<!-- narrative: one sentence -->"]},
          {"Text.\n", [title: "<!-- narrative -->"]}
        ] do
      {source, post} = post!(dir, body, front)
      assert {:error, message} = Devto.article(source, post, @meta)
      assert message =~ "is not finished"
    end
  end

  test "resolve/2 keeps a URL that has a scheme" do
    assert Devto.resolve("https://a.test/x", "https://b.test/y") == "https://a.test/x"
    assert Devto.resolve("x.png", "https://b.test/dir/y.html") == "https://b.test/dir/x.png"
  end
end
