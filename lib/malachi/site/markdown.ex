defmodule Malachi.Site.Markdown do
  @moduledoc """
  Renders a blog post's Markdown to HTML (issue #373): EarmarkParser reads it, and this module writes the HTML
  from its AST against an allowlist.

  What the allowlist holds is what a post needs: paragraphs, `##` to `####` headings, lists, emphasis, code,
  quotes, rules, tables, links and images. Everything else is refused with a message rather than passed over:
  a raw HTML block, any other element, a link whose scheme is not http, https or mailto, a protocol-relative
  link, and an image that is not https or relative. Inline HTML in a paragraph is text, so it is shown as
  written and escaped. Every text and every attribute value is escaped.

  A fenced block whose info string is `malachi-chart` is a chart (`Malachi.Site.Chart`) and is drawn inline as
  SVG. Two marks of an unfinished post are counted, never rendered: an HTML comment whose text starts with
  `narrative` (where the maintainer writes) and a fenced block whose info string is `malachi-seed` (the
  release highlights the generator offers as a seed). `Malachi.Site.Blog` refuses a published post with either.

  EarmarkParser is a dev and test dependency only (mix.exs), the environments where the site is staged and
  tested. Nothing in prod calls this module.
  """

  @compile {:no_warn_undefined, EarmarkParser}

  alias Malachi.Site.Chart

  @blocks ~w(p h2 h3 h4 ul ol li blockquote hr pre table thead tbody tr th td)
  @inline ~w(em strong del code a img br)
  @align ~r/\Atext-align: (left|right|center);\z/
  @language ~r/\A[a-z0-9][a-z0-9+-]{0,30}\z/

  @typedoc "A chart drawn in the post, with the JSON text its image name is hashed from."
  @type chart :: %{chart: Chart.t(), json: String.t()}

  @typedoc """
  What rendering a post gives: its HTML, its charts, the `src` of every image it shows (in order, as written),
  and how many `<!-- narrative -->` placeholders and `malachi-seed` blocks it still holds.
  """
  @type result :: %{
          html: String.t(),
          charts: [chart()],
          images: [String.t()],
          narratives: non_neg_integer(),
          seeds: non_neg_integer()
        }

  @doc "Renders Markdown, or returns every problem found in it."
  @spec render(String.t()) :: {:ok, result()} | {:error, [String.t()]}
  def render(markdown) do
    case EarmarkParser.as_ast(markdown) do
      {:ok, ast, []} ->
        {html, acc} = nodes(ast, %{charts: [], images: [], narratives: 0, seeds: 0, errors: []})

        case acc.errors do
          [] ->
            {:ok,
             %{
               html: html,
               charts: Enum.reverse(acc.charts),
               images: Enum.reverse(acc.images),
               narratives: acc.narratives,
               seeds: acc.seeds
             }}

          errors ->
            {:error, errors |> Enum.reverse() |> Enum.uniq()}
        end

      {_status, _ast, messages} ->
        {:error, Enum.map(messages, &message/1)}
    end
  end

  defp message({_severity, line, text}), do: "line #{line}: #{text}"

  defp nodes(list, acc) do
    {parts, acc} = Enum.map_reduce(list, acc, &node/2)
    {IO.iodata_to_binary(parts), acc}
  end

  defp node(text, acc) when is_binary(text), do: {escape(text), acc}

  defp node({:comment, _attrs, lines, _meta}, acc) do
    if lines |> Enum.join("\n") |> String.trim() |> String.starts_with?("narrative"),
      do: {"", %{acc | narratives: acc.narratives + 1}},
      else: {"", acc}
  end

  defp node({tag, _attrs, _children, %{verbatim: true}}, acc) do
    {"", error(acc, "raw HTML (<#{tag}>) is not allowed in a post; write it in Markdown")}
  end

  defp node({"pre", _, [{"code", [{"class", "malachi-chart"}], [json], _}], _}, acc), do: chart(json, acc)

  defp node({"pre", _, [{"code", [{"class", "malachi-seed"}], children, _}], _}, acc) do
    {inner, acc} = nodes(children, acc)
    {~s(<pre class="seed"><code>#{inner}</code></pre>\n), %{acc | seeds: acc.seeds + 1}}
  end

  defp node({"pre", _, [{"code", attrs, children, _}], _}, acc) do
    {inner, acc} = nodes(children, acc)

    class =
      case List.keyfind(attrs, "class", 0) do
        {"class", lang} -> if Regex.match?(@language, lang), do: ~s( class="language-#{lang}"), else: ""
        nil -> ""
      end

    {"<pre><code#{class}>#{inner}</code></pre>\n", acc}
  end

  defp node({"a", attrs, children, _}, acc) do
    href = attr(attrs, "href") || ""

    case link_error(href, ["http", "https", "mailto"]) do
      nil ->
        {inner, acc} = nodes(children, acc)
        {~s(<a href="#{escape(href)}"#{title(attrs)}>#{inner}</a>), acc}

      reason ->
        {"", error(acc, "the link #{inspect(href)} #{reason}")}
    end
  end

  defp node({"img", attrs, _children, _}, acc) do
    src = attr(attrs, "src") || ""

    case link_error(src, ["https"]) do
      nil ->
        {~s(<img src="#{escape(src)}" alt="#{escape(attr(attrs, "alt") || "")}"#{title(attrs)}>),
         %{acc | images: [src | acc.images]}}

      reason ->
        {"", error(acc, "the image #{inspect(src)} #{reason}")}
    end
  end

  defp node({"code", _attrs, children, _}, acc) do
    {inner, acc} = nodes(children, acc)
    {"<code>#{inner}</code>", acc}
  end

  defp node({tag, _attrs, [], _}, acc) when tag in ["hr", "br"], do: {"<#{tag}>", acc}

  defp node({tag, attrs, children, _}, acc) when tag in ["th", "td"] do
    {inner, acc} = nodes(children, acc)

    # The parser writes the column's alignment as a style; nothing else is kept from it.
    style = attr(attrs, "style") || ""
    style = if Regex.match?(@align, style), do: ~s( style="#{style}"), else: ""

    {"<#{tag}#{style}>#{inner}</#{tag}>", acc}
  end

  defp node({"ol", attrs, children, _}, acc) do
    {inner, acc} = nodes(children, acc)

    start = attr(attrs, "start") || ""
    start = if Regex.match?(~r/\A\d{1,6}\z/, start), do: ~s( start="#{start}"), else: ""

    {"<ol#{start}>\n#{inner}</ol>\n", acc}
  end

  defp node({tag, _attrs, children, _}, acc) when tag in @blocks do
    {inner, acc} = nodes(children, acc)
    {"<#{tag}>#{inner}</#{tag}>\n", acc}
  end

  defp node({tag, _attrs, children, _}, acc) when tag in @inline do
    {inner, acc} = nodes(children, acc)
    {"<#{tag}>#{inner}</#{tag}>", acc}
  end

  defp node({"h1", _, _, _}, acc), do: {"", error(acc, "a post's headings start at ##: the title is its #")}

  defp node({tag, _, _, _}, acc), do: {"", error(acc, "<#{tag}> is not allowed in a post")}

  defp chart(json, acc) do
    case Chart.parse(json) do
      {:ok, chart} ->
        svg = Chart.to_svg(chart)

        figure =
          ~s(<figure class="chart">\n#{svg}<figcaption>#{escape(chart.title)}</figcaption>\n</figure>\n)

        {figure, %{acc | charts: [%{chart: chart, json: json} | acc.charts]}}

      {:error, reason} ->
        {"", error(acc, reason)}
    end
  end

  defp error(acc, message), do: %{acc | errors: [message | acc.errors]}

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp title(attrs) do
    case attr(attrs, "title") do
      nil -> ""
      value -> ~s( title="#{escape(value)}")
    end
  end

  # Why a link or image URL is refused, or nil. A URL with no scheme is relative to the post (or a fragment), a
  # control character or space is never part of one, and `//host` names another host without saying how.
  defp link_error("", _schemes), do: "has no URL"

  defp link_error(url, schemes) do
    cond do
      String.match?(url, ~r/[\x00-\x20\x7f]/) -> "holds a space or a control character"
      String.starts_with?(url, "//") -> "names a host without a scheme"
      true -> scheme_error(URI.parse(url).scheme, schemes)
    end
  end

  defp scheme_error(nil, _schemes), do: nil

  defp scheme_error(scheme, schemes) do
    if String.downcase(scheme) in schemes,
      do: nil,
      else: "uses #{scheme}:, and a post allows only #{Enum.join(schemes, ", ")} or a relative URL"
  end

  defp escape(text), do: Chart.escape(text)
end
