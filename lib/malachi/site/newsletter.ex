defmodule Malachi.Site.Newsletter do
  @moduledoc """
  The blog's newsletter form (issue #373): a plain HTML form that posts the reader's email to the newsletter
  provider, with no script of its own and no cookie or pixel on the blog's pages, and the privacy note it links
  to.

  It is configured by the `newsletter:` key of the project in `mix.exs`, copied from the form code the provider
  generates. While the key is `nil` the blog has no form and no privacy note. When it is set:

    * `action`: the form's address, an `https` URL with a host and no user or fragment;
    * `email_field`: the name of the email input;
    * `consent_field`: the name of the checkbox that accepts the privacy note, and `consent_value` its value
      (`"1"` when left out);
    * `hidden`: the provider's fixed fields (a group, a source, an empty honeypot), as `[{name, value}]` in the
      order the provider lists them, `[]` when left out.

  A name is 1 to 64 letters, digits, `_`, `-`, `.`, `[` or `]`. Any other key, or a value of another shape, is
  refused, so a typo never stages a form that posts to the wrong place.

  The privacy note is the maintainer's text in `#{"site/newsletter/privacy.md"}`, Markdown rendered by
  `Malachi.Site.Markdown` (its headings start at `##`, under the page's title), and is staged at
  `blog/privacy.html`. `Malachi.Site.Blog` stages the form at the end
  of the index and of every post, and its check reports a blog page with a form while none is configured, a blog
  page without exactly one form posting to the configured `action`, a form on the privacy note, and a privacy
  note that is missing, unfinished (a placeholder or a `malachi-seed` block) or draws a chart. The check reads
  the form's tag, not its fields: after a change to the fields, stage the site again.
  """

  alias Malachi.Site.Chart
  alias Malachi.Site.Markdown

  @privacy "site/newsletter/privacy.md"
  @keys [:action, :email_field, :consent_field, :consent_value, :hidden]
  @name ~r/\A[A-Za-z0-9_.\[\]-]{1,64}\z/

  @typedoc "A configured newsletter form."
  @type t :: %{
          action: String.t(),
          email_field: String.t(),
          consent_field: String.t(),
          consent_value: String.t(),
          hidden: [{String.t(), String.t()}]
        }

  @doc """
  The newsletter of a site config (`Malachi.Site.from_project/1`), or `nil` when none is configured. Raises an
  `ArgumentError` naming what is wrong with a configured one.
  """
  @spec from_config!(map()) :: t() | nil
  def from_config!(config) do
    case parse(Map.get(config, :newsletter)) do
      {:ok, newsletter} -> newsletter
      {:error, reason} -> raise ArgumentError, "the newsletter in mix.exs: #{reason}"
    end
  end

  @doc "Reads the `newsletter:` setting: `nil`, or the keyword list the moduledoc describes."
  @spec parse(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def parse(nil), do: {:ok, nil}

  def parse(opts) when is_list(opts) and opts != [] do
    with true <- Keyword.keyword?(opts) || {:error, "is a keyword list, got #{inspect(opts)}"},
         :ok <- known_keys(opts),
         {:ok, action} <- action(Keyword.get(opts, :action)),
         {:ok, email} <- name(:email_field, Keyword.get(opts, :email_field)),
         {:ok, consent} <- name(:consent_field, Keyword.get(opts, :consent_field)),
         {:ok, value} <- text(:consent_value, Keyword.get(opts, :consent_value, "1")),
         {:ok, hidden} <- hidden(Keyword.get(opts, :hidden, [])) do
      {:ok, %{action: action, email_field: email, consent_field: consent, consent_value: value, hidden: hidden}}
    end
  end

  def parse(other), do: {:error, "is nil or a keyword list, got #{inspect(other)}"}

  defp known_keys(opts) do
    keys = Keyword.keys(opts)

    case keys |> Enum.reject(&(&1 in @keys)) |> Enum.uniq() do
      [] ->
        if keys == Enum.uniq(keys), do: :ok, else: {:error, "names a key twice"}

      unknown ->
        {:error, "has unknown keys #{inspect(unknown)}; the keys are #{inspect(@keys)}"}
    end
  end

  defp action(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}} when is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, "action is an https URL with a host and no user or fragment, got #{inspect(url)}"}
    end
  end

  defp action(other), do: {:error, "action is an https URL, got #{inspect(other)}"}

  defp name(key, value) do
    if is_binary(value) and Regex.match?(@name, value),
      do: {:ok, value},
      else: {:error, "#{key} is 1 to 64 letters, digits, _, -, ., [ or ], got #{inspect(value)}"}
  end

  defp text(_key, value) when is_binary(value), do: {:ok, value}
  defp text(key, value), do: {:error, "#{key} is a string, got #{inspect(value)}"}

  defp hidden(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      {field, value}, {:ok, acc} when is_binary(value) ->
        case name(:hidden, field) do
          {:ok, field} -> {:cont, {:ok, [{field, value} | acc]}}
          error -> {:halt, error}
        end

      entry, _ ->
        {:halt, {:error, "hidden holds {name, value} pairs of strings, got #{inspect(entry)}"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp hidden(other), do: {:error, "hidden is a list of {name, value} pairs, got #{inspect(other)}"}

  @doc "The form, as HTML for the end of a blog page's main content. The privacy note is `privacy.html` beside it."
  @spec form(t()) :: String.t()
  def form(newsletter) do
    hidden =
      Enum.map_join(newsletter.hidden, "", fn {field, value} ->
        ~s(<input type="hidden" name="#{e(field)}" value="#{e(value)}">\n)
      end)

    """
    <section class="newsletter" aria-labelledby="newsletter-title">
    <h2 id="newsletter-title">Newsletter</h2>
    <form method="post" action="#{e(newsletter.action)}">
    <label for="newsletter-email">Email</label>
    <input id="newsletter-email" type="email" name="#{e(newsletter.email_field)}" autocomplete="email" maxlength="254" required>
    <label class="consent"><input type="checkbox" name="#{e(newsletter.consent_field)}" value="#{e(newsletter.consent_value)}" required> I accept the <a href="privacy.html">privacy note</a></label>
    #{hidden}<button type="submit">Subscribe</button>
    </form>
    </section>
    """
  end

  @doc """
  The privacy note rendered from `#{"site/newsletter/privacy.md"}` under `root`, or what keeps it from being
  staged: missing, unreadable, or refused by `Malachi.Site.Markdown`.
  """
  @spec privacy(Path.t()) :: {:ok, Markdown.result()} | {:error, String.t()}
  def privacy(root) do
    with {:ok, text} <- read(Path.join(root, @privacy)),
         {:ok, rendered} <- Markdown.render(text) do
      {:ok, rendered}
    else
      {:error, reason} when is_binary(reason) -> {:error, "#{@privacy} #{reason}"}
      {:error, errors} -> {:error, "#{@privacy}: #{Enum.join(errors, "; ")}"}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} ->
        if String.valid?(text), do: {:ok, text}, else: {:error, "is not UTF-8"}

      {:error, :enoent} ->
        {:error, "is missing, and the newsletter form links to it: write the privacy note"}

      {:error, reason} ->
        {:error, "cannot be read (#{:file.format_error(reason)})"}
    end
  end

  @doc "What keeps the privacy note of a configured newsletter from being published; `[]` with no newsletter."
  @spec source_errors(Path.t(), t() | nil) :: [String.t()]
  def source_errors(_root, nil), do: []

  def source_errors(root, _newsletter) do
    case privacy(root) do
      {:ok, rendered} ->
        narratives =
          if rendered.narratives > 0,
            do: ["#{@privacy} still has #{rendered.narratives} <!-- narrative --> placeholder(s) to write"],
            else: []

        charts = if rendered.charts != [], do: ["#{@privacy} draws a chart; the privacy note has none"], else: []
        seeds = if rendered.seeds > 0, do: ["#{@privacy} has a malachi-seed block; the privacy note has none"], else: []
        narratives ++ charts ++ seeds

      {:error, message} ->
        [message]
    end
  end

  @form ~r/<form\b[^>]*>/i
  @action ~r/\baction="([^"]*)"/

  @doc """
  The problems with the forms on one staged blog page, `rel` under `doc/`: none when `wanted?` is false or no
  newsletter is configured, else exactly one form, posting with `method="post"` to the configured `action`. Its
  fields are not compared.
  """
  @spec form_errors(String.t(), String.t(), t() | nil, boolean()) :: [String.t()]
  def form_errors(rel, html, newsletter, wanted?) do
    forms = @form |> Regex.scan(html) |> List.flatten()

    case {newsletter, wanted?, forms} do
      {_, _, []} when newsletter == nil or not wanted? ->
        []

      {nil, _, _} ->
        ["doc/#{rel} has a form, and mix.exs configures no newsletter; stage the site again"]

      {_, false, _} ->
        ["doc/#{rel} has a form; the privacy note has none"]

      {_, true, [form]} ->
        if form_tag?(form, newsletter),
          do: [],
          else: ["doc/#{rel} has a form that does not post to #{newsletter.action}; stage the site again"]

      {_, true, forms} ->
        ["doc/#{rel} has #{length(forms)} forms; a blog page has one, the newsletter's; stage the site again"]
    end
  end

  # The staged attribute holds the action escaped, as form/1 writes it.
  defp form_tag?(form, newsletter) do
    Regex.match?(~r/\bmethod="post"/i, form) and
      Regex.run(@action, form) == [~s(action="#{e(newsletter.action)}"), e(newsletter.action)]
  end

  defp e(text), do: Chart.escape(text)
end
