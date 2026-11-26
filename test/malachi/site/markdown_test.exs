defmodule Malachi.Site.MarkdownTest do
  use ExUnit.Case, async: true

  alias Malachi.Site.Markdown

  defp html!(markdown) do
    assert {:ok, %{html: html}} = Markdown.render(markdown)
    html
  end

  defp errors!(markdown) do
    assert {:error, errors} = Markdown.render(markdown)
    Enum.join(errors, "\n")
  end

  test "renders what a post needs: headings, lists, emphasis, code, quotes, tables, links and images" do
    html =
      html!("""
      ## Section

      A *b* **c** ~~d~~ `e` [f](https://example.test/f "T") ![g](https://example.test/g.png) [h](../introduction.html) [i](#top)

      - one
      - two

      3. three

      > quote

      ---

      ```elixir
      IO.puts(:x)
      ```

      | a | b |
      |---|--:|
      | 1 | 2 |
      """)

    assert html =~ "<h2>Section</h2>"
    assert html =~ "<em>b</em> <strong>c</strong> <del>d</del> <code>e</code>"
    assert html =~ ~s(<a href="https://example.test/f" title="T">f</a>)
    assert html =~ ~s(<img src="https://example.test/g.png" alt="g" loading="lazy" decoding="async">)
    assert html =~ ~s(<a href="../introduction.html">h</a>)
    assert html =~ ~s(<a href="#top">i</a>)
    assert html =~ "<ul><li>one</li>\n<li>two</li>\n</ul>"
    assert html =~ ~s(<ol start="3">)
    assert html =~ "<blockquote><p>quote</p>\n</blockquote>"
    assert html =~ "<hr>"
    assert html =~ ~s[<pre><code class="language-elixir">IO.puts(:x)</code></pre>]
    assert html =~ ~s(<td style="text-align: right;">2</td>)
  end

  test "inline HTML is text, escaped, and a quote in a title cannot leave its attribute" do
    html = html!(~S'A <b onclick="x">raw</b> & [l](https://e.test "a\"b") here' <> "\n")
    assert html =~ "&lt;b onclick=&quot;x&quot;&gt;raw&lt;/b&gt; &amp;"
    refute html =~ "<b"
    # The parser keeps the backslash; what matters is that the quote is escaped inside the attribute.
    assert html =~ ~s(title="a\\&quot;b")
  end

  test "a code block's text is escaped, and a block without a language has no class" do
    assert html!("```\n<script>&\n```\n") =~ "<pre><code>&lt;script&gt;&amp;</code></pre>"
  end

  for {markdown, reason} <- [
        {"<div>raw</div>\n", "raw HTML"},
        {"<script>alert(1)</script>\n", "raw HTML"},
        {"# Title\n", "headings start at ##"},
        {"[x](javascript:alert(1))\n", "uses javascript:"},
        {"[x](JavaScript:alert(1))\n", "uses javascript:"},
        {"[x](data:text/html,hi)\n", "uses data:"},
        {"[x](vbscript:x)\n", "uses vbscript:"},
        {"[x](//evil.test/a)\n", "without a scheme"},
        {"[x](<java\tscript:a>)\n", "control character"},
        {"![x](http://example.test/a.png)\n", "uses http:"},
        {"![x](data:image/png;base64,AA)\n", "uses data:"},
        {"##### Deep\n", "<h5> is not allowed"}
      ] do
    test "refuses #{inspect(markdown)}" do
      assert errors!(unquote(markdown)) =~ unquote(reason)
    end
  end

  test "a link or an image with no URL is refused, and a list that starts at one takes no start" do
    errors = errors!("[x]()\n\n![y]()\n")
    assert errors =~ ~s(the link "" has no URL)
    assert errors =~ ~s(the image "" has no URL)
    assert html!("1. a\n") =~ "<ol>\n<li>a</li>\n</ol>"
  end

  test "a mailto link and an https or relative image are allowed" do
    html = html!("[m](mailto:a@example.test) ![r](chart.png)\n")
    assert html =~ ~s(href="mailto:a@example.test")
    assert html =~ ~s(src="chart.png")
  end

  test "returns every image it shows, its src as written and its alt, in order, and none of a refused one" do
    {:ok, rendered} = Markdown.render("![a](x/one.png) text ![b](https://h.test/two.png)\n\n![a](x/one.png)\n")

    assert rendered.images == [
             %{src: "x/one.png", alt: "a"},
             %{src: "https://h.test/two.png", alt: "b"},
             %{src: "x/one.png", alt: "a"}
           ]

    assert {:ok, %{images: []}} = Markdown.render("No image.\n")
    assert {:error, _} = Markdown.render("![a](javascript:x) ![b](ok.png)\n")
  end

  test "an image's alt text is escaped once, quotes, ampersands and brackets included, and loads lazily" do
    {:ok, rendered} = Markdown.render(~s|![a producer's "x" & <y> &amp;lt;](p.png "t's & u")\n|)

    assert rendered.html =~
             ~s|<img src="p.png" alt="a producer&#39;s &quot;x&quot; &amp; &lt;y&gt; &amp;lt;" title="t&#39;s &amp; u" loading="lazy" decoding="async">|

    assert [%{alt: ~s(a producer's "x" & <y> &lt;)}] = rendered.images
  end

  test "a malachi-chart block is drawn inline as SVG with its caption, and returned with its JSON" do
    json = ~s({"name": "rate", "title": "Rate", "unit": "r/s", "points": [{"label": "v1.0.0", "value": 10}]})
    assert {:ok, result} = Markdown.render("```malachi-chart\n#{json}\n```\n")
    assert result.html =~ ~s(<figure class="chart">)
    assert result.html =~ "<svg"
    assert result.html =~ "<figcaption>Rate</figcaption>"
    assert [%{chart: %{name: "rate"}, json: ^json}] = result.charts
  end

  test "a malachi-chart block with bad data is refused with the chart's reason" do
    assert errors!(~s(```malachi-chart\n{"name": "x"}\n```\n)) =~ "needs a title"
  end

  test "counts the narrative placeholders and the seed blocks, and drops other comments" do
    assert {:ok, result} =
             Markdown.render("""
             <!-- narrative -->

             <!-- narrative: why this release matters -->

             <!-- an ordinary comment -->

             ```malachi-seed
             Highlights from the pull request.
             ```
             """)

    assert result.narratives == 2
    assert result.seeds == 1
    refute result.html =~ "<!--"
    assert result.html =~ ~s(<pre class="seed">)
  end

  test "a post with neither has no placeholder and no seed" do
    assert {:ok, %{narratives: 0, seeds: 0, charts: []}} = Markdown.render("Plain text.\n")
  end

  test "a parser warning is an error, with its line" do
    assert errors!("A `code span never closed\n") =~ ~r/line \d+:/
  end
end
