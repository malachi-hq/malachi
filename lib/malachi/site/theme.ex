defmodule Malachi.Site.Theme do
  @moduledoc """
  The site's light, dark and system themes, from one source for every page that offers them: the landing page and
  the blog (#385).

  `site/ui_kits/website/theme.js` is the whole switch. Inlined into a page's head, it sets the `dark` class on the
  root element before the page paints, from the reader's choice in `localStorage` (`malachi-theme`) or, for the
  system choice, from `prefers-color-scheme`. It follows a change of the system preference, and a change of the
  radio group `toggle/0` renders, which it stores. The stored value is only ever compared with the three names, never
  written into the page. Every colour comes from the tokens, whose dark palette applies under `.dark`.

  The script is inlined rather than served as a file: it has to run before the first paint, and the blog's pages load
  no script by `src` (`Malachi.Site.Blog`). The landing page takes both pieces through the `{{theme_head}}` and
  `{{theme_toggle}}` placeholders that `Malachi.Site.stage/2` fills, and the blog's pages through their shell.

  The script is read from the checkout when the site is staged, not when this module compiles: the release image
  compiles `lib/` without `site/`.
  """

  @source "site/ui_kits/website/theme.js"
  @themes ~w(system light dark)

  # Without JavaScript the switch does nothing, so it is hidden, as the landing page hides every `.js-only` control.
  @noscript "<noscript><style>.js-only{display:none!important}</style></noscript>"

  @doc "Where the switch's script lives, relative to the checkout."
  @spec source() :: Path.t()
  def source, do: @source

  @doc """
  The switch's script from the checkout at `root`, without surrounding whitespace. Raises when it cannot be read: a
  page staged without it would offer a switch that does nothing.
  """
  @spec script!(Path.t()) :: String.t()
  def script!(root) do
    case File.read(Path.join(root, @source)) do
      {:ok, text} -> String.trim(text)
      {:error, reason} -> raise File.Error, reason: reason, action: "read the theme switch", path: @source
    end
  end

  @doc "The theme names, in the order the switch offers them; the first is the default."
  @spec themes() :: [String.t()]
  def themes, do: @themes

  @doc """
  What a page's head carries: the inline `script` (from `script!/1`), which must come before the stylesheets so the
  first paint already has the reader's theme, and the rule that hides the switch when JavaScript is off.
  """
  @spec head(String.t()) :: String.t()
  def head(script), do: "<script>" <> script <> "</script>\n" <> @noscript

  @doc "The switch itself: one radio per theme, system checked until the script reads the reader's choice."
  @spec toggle() :: String.t()
  def toggle do
    radios =
      for theme <- @themes do
        checked = if theme == "system", do: " checked", else: ""

        ~s(<label><input type="radio" name="theme" value="#{theme}"#{checked}><span>#{String.capitalize(theme)}</span></label>)
      end

    Enum.join(
      [~s(<fieldset class="seg js-only">), ~s(<legend class="label">Theme</legend>) | radios] ++ ["</fieldset>"],
      "\n"
    )
  end

  @doc "The landing page's placeholders for the two pieces, for `Malachi.Site.fill/2`."
  @spec placeholders(String.t()) :: %{String.t() => String.t()}
  def placeholders(script), do: %{"theme_head" => head(script), "theme_toggle" => toggle()}
end
