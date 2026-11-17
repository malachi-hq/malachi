defmodule Malachi.Release.Devto do
  @moduledoc """
  Turns a finished blog post into a dev.to draft (issue #373): the article `scripts/devto-draft.sh` sends.

  The draft is never published (`published: false`): the maintainer reviews it on dev.to and publishes it
  there. Its `canonical_url` is the post on this site, so dev.to credits it as the original.

  dev.to does not draw inline SVG and does not know this site's relative links, so the Markdown is adapted:
  each `malachi-chart` block becomes its PNG on the site (the image `mix malachi.release.post --images`
  rendered), and each relative link or image becomes an absolute one, resolved from the post's own URL.

  A post that still holds a `<!-- narrative -->` placeholder or a `malachi-seed` block is refused, as the site
  check refuses it: nothing unfinished leaves the repository.
  """

  alias Malachi.Site.Blog
  alias Malachi.Site.Chart

  @chart_block ~r/^```malachi-chart[ \t]*\n(.*?)\n```[ \t]*$/ms
  @link ~r/(!?\[[^\]]*\]\()([^)\s]+)((?:\s+"[^"]*")?\))/
  @fence ~r/^(```|~~~)/m

  @doc """
  The article for dev.to's API, from a post's source Markdown and the post as `Malachi.Site.Blog` read it.
  `meta` holds the site's `base_url`.
  """
  @spec article(String.t(), Blog.post(), map()) :: {:ok, map()} | {:error, String.t()}
  def article(source, post, meta) do
    if unfinished?(post) do
      {:error,
       "site/blog/#{post.file} is not finished: write its <!-- narrative --> placeholders and fold its malachi-seed block in first"}
    else
      url = Blog.url(post, meta)

      {:ok,
       %{
         "article" => %{
           "title" => post.title,
           "description" => post.summary,
           "canonical_url" => url,
           "published" => false,
           "body_markdown" => body(source, post, meta, url)
         }
       }}
    end
  end

  defp unfinished?(post) do
    post.narratives > 0 or post.seeds > 0 or
      Enum.any?([post.title, post.summary], &String.contains?(&1, "<!-- narrative"))
  end

  defp body(source, post, meta, url) do
    source
    |> without_front_matter()
    |> charts_as_images(post, meta)
    |> absolute_links(url)
    |> String.trim()
    |> Kernel.<>("\n")
  end

  # The post was read by Malachi.Site.Blog, which refuses one without front matter or with a chart it cannot
  # draw, so both are taken as given here.
  defp without_front_matter(source) do
    ["", _front, body] = String.split(String.replace(source, "\r\n", "\n"), ~r/^---$/m, parts: 3)
    body
  end

  defp charts_as_images(text, post, meta) do
    Regex.replace(@chart_block, text, fn _whole, json ->
      {:ok, chart} = Chart.parse(json)
      "![#{chart.title}](#{Blog.image_url(post, %{chart: chart, json: json}, meta)})"
    end)
  end

  # Links outside code blocks only: the text between fences alternates with the code, and only the former is
  # rewritten.
  defp absolute_links(text, url) do
    text
    |> String.split(@fence, include_captures: true)
    |> rewrite_outside_code(url, false, [])
  end

  defp rewrite_outside_code([], _url, _in_code?, acc), do: acc |> Enum.reverse() |> Enum.join()

  defp rewrite_outside_code([part | rest], url, in_code?, acc) do
    cond do
      Regex.match?(~r/\A(```|~~~)\z/, part) -> rewrite_outside_code(rest, url, not in_code?, [part | acc])
      in_code? -> rewrite_outside_code(rest, url, in_code?, [part | acc])
      true -> rewrite_outside_code(rest, url, in_code?, [absolute(part, url) | acc])
    end
  end

  defp absolute(text, url) do
    Regex.replace(@link, text, fn _whole, open, target, close ->
      open <> resolve(target, url) <> close
    end)
  end

  @doc "A link target made absolute from the post's URL; one with a scheme is kept as it is."
  @spec resolve(String.t(), String.t()) :: String.t()
  def resolve(target, url) do
    case URI.parse(target) do
      %URI{scheme: nil} -> url |> URI.merge(target) |> URI.to_string()
      _ -> target
    end
  end
end
