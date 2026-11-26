defmodule Malachi.Site.Comments do
  @moduledoc """
  The comments under each blog post (issue #373), through [giscus](https://giscus.app): each post's comments are
  a discussion on GitHub, shown by giscus's script at the end of the post. It is the one script a blog page
  loads, only on a post's page, and only from `#{"https://giscus.app/client.js"}`; it loads lazily, when the
  reader scrolls to the comments. The newsletter's privacy note says what it receives.

  It is configured by the `blog_comments:` key of the project in `mix.exs`, with the values giscus.app gives for
  the repository once its app is installed and the category exists:

    * `repo`: `owner/name`;
    * `repo_id` and `category_id`: GitHub's node IDs of the repository and of the discussion category;
    * `category`: the category's name.

  While the key is `nil` a post has no comments and no blog page loads a script. Any other key, or a value of
  another shape, is refused, so a typo never stages a script that loads comments from somewhere else.
  """

  alias Malachi.Site.Chart

  @client "https://giscus.app/client.js"
  @keys [:repo, :repo_id, :category, :category_id]
  @repo ~r/\A[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}\z/
  @node_id ~r/\A[A-Za-z0-9_-]{1,100}\z/
  @category ~r/\A[^\x00-\x1f<>"]{1,100}\z/

  @typedoc "Configured comments."
  @type t :: %{repo: String.t(), repo_id: String.t(), category: String.t(), category_id: String.t()}

  @doc "The URL of the one script a blog page may load."
  @spec client() :: String.t()
  def client, do: @client

  @doc "The comments of a site config (`Malachi.Site.from_project/1`), or `nil`. Raises naming what is wrong."
  @spec from_config!(map()) :: t() | nil
  def from_config!(config) do
    case parse(Map.get(config, :blog_comments)) do
      {:ok, comments} -> comments
      {:error, reason} -> raise ArgumentError, "the blog_comments in mix.exs: #{reason}"
    end
  end

  @doc "Reads the `blog_comments:` setting: `nil`, or the keyword list the moduledoc describes."
  @spec parse(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def parse(nil), do: {:ok, nil}

  def parse(opts) when is_list(opts) and opts != [] do
    with true <- Keyword.keyword?(opts) || {:error, "is a keyword list, got #{inspect(opts)}"},
         :ok <- known_keys(opts),
         {:ok, repo} <- field(opts, :repo, @repo),
         {:ok, repo_id} <- field(opts, :repo_id, @node_id),
         {:ok, category} <- field(opts, :category, @category),
         {:ok, category_id} <- field(opts, :category_id, @node_id) do
      {:ok, %{repo: repo, repo_id: repo_id, category: category, category_id: category_id}}
    end
  end

  def parse(other), do: {:error, "is nil or a keyword list, got #{inspect(other)}"}

  defp known_keys(opts) do
    keys = Keyword.keys(opts)

    cond do
      (unknown = keys |> Enum.reject(&(&1 in @keys)) |> Enum.uniq()) != [] ->
        {:error, "has unknown keys #{inspect(unknown)}; the keys are #{inspect(@keys)}"}

      keys != Enum.uniq(keys) ->
        {:error, "names a key twice"}

      true ->
        :ok
    end
  end

  defp field(opts, key, pattern) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        if Regex.match?(pattern, value), do: {:ok, value}, else: {:error, "#{key} is not valid, got #{inspect(value)}"}

      other ->
        {:error, "#{key} is a string, got #{inspect(other)}"}
    end
  end

  @doc """
  The comments section, as HTML for the end of a post's page: giscus's script, which maps the post to its
  discussion by the page's path, and a link to the discussions for a reader whose browser runs no script.
  """
  @spec section(t()) :: String.t()
  def section(comments) do
    attrs =
      [
        {"src", @client},
        {"data-repo", comments.repo},
        {"data-repo-id", comments.repo_id},
        {"data-category", comments.category},
        {"data-category-id", comments.category_id},
        {"data-mapping", "pathname"},
        {"data-strict", "1"},
        {"data-reactions-enabled", "1"},
        {"data-emit-metadata", "0"},
        {"data-input-position", "top"},
        {"data-theme", "preferred_color_scheme"},
        {"data-lang", "en"},
        {"data-loading", "lazy"},
        {"crossorigin", "anonymous"}
      ]
      |> Enum.map_join(" ", fn {name, value} -> ~s(#{name}="#{e(value)}") end)

    """
    <section class="comments" aria-labelledby="comments-title">
    <h2 id="comments-title">Comments</h2>
    <script #{attrs} async></script>
    <noscript><p>Comments are discussions on <a href="https://github.com/#{e(comments.repo)}/discussions">GitHub</a>.</p></noscript>
    </section>
    """
  end

  @script ~r/<script\b[^>]*\bsrc\s*=\s*"([^"]*)"[^>]*>/i
  @any_src ~r/<script\b[^>]*\bsrc\s*=/i

  @doc """
  The problems with the scripts a staged blog page loads, `rel` under `doc/`: a page that is not a post's
  (`post?` false), or a post's page with no comments configured, loads none; a post's page with comments loads
  exactly giscus's, configured for this repository.
  """
  @spec script_errors(String.t(), String.t(), t() | nil, boolean()) :: [String.t()]
  def script_errors(rel, html, comments, post?) do
    total = length(Regex.scan(@any_src, html))
    scripts = Regex.scan(@script, html)

    cond do
      total == 0 and (comments == nil or not post?) ->
        []

      comments == nil or not post? ->
        ["doc/#{rel} loads a script; this blog page loads none"]

      total == 1 and match?([[_, @client]], scripts) and repo?(hd(hd(scripts)), comments) ->
        []

      total == 0 ->
        ["doc/#{rel} has no comments, and mix.exs configures them; stage the site again"]

      true ->
        ["doc/#{rel} loads a script other than the comments' (#{@client} for #{comments.repo}); stage the site again"]
    end
  end

  defp repo?(tag, comments), do: String.contains?(tag, ~s(data-repo="#{e(comments.repo)}"))

  defp e(text), do: Chart.escape(text)
end
