defmodule Malachi.Test.SiteFixture do
  @moduledoc """
  A checkout shaped like the ExDoc output plus a `site/` source tree, for the tests of `Malachi.Site`, its blog
  and `mix malachi.docs.site`. They stage into it and never touch the real `doc/`.
  """

  @doc "Writes `content` at `path` under `root`, creating its folders."
  @spec write(Path.t(), Path.t(), iodata()) :: :ok
  def write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  @doc """
  The page files the kit ships beside the landing page, one per `Malachi.Site.page_sources/0`, so a file added
  there is in every fixture. Their content is not checked, only that they are staged.
  """
  @spec write_page_kit(Path.t()) :: :ok
  def write_page_kit(root) do
    for rel <- Malachi.Site.page_sources(), do: write(root, "site/" <> rel, "/* #{rel} */")
    :ok
  end

  @doc "The first bytes of a PNG of the given size: the signature and the IHDR chunk that declares it."
  @spec png(pos_integer(), pos_integer()) :: binary()
  def png(width, height), do: <<137, "PNG", 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0>>

  @doc "The kit's social preview, which the landing page stages, as a PNG of the size the site checks."
  @spec write_social_preview(Path.t()) :: :ok
  def write_social_preview(root), do: write(root, "site/kit/social-preview.png", png(1280, 640))

  @doc """
  The newsletter's privacy note, `site/newsletter/privacy.md`. The blog stages it only while `mix.exs`
  configures a newsletter, and the real one does, so every fixture carries a finished note.
  """
  @spec write_privacy_note(Path.t(), iodata()) :: :ok
  def write_privacy_note(root, text \\ "## What is kept\n\nWhat the provider keeps.\n"),
    do: write(root, "site/newsletter/privacy.md", text)

  @doc """
  The smallest checkout that stages and verifies: a landing page and llms.txt with placeholders, one font, the
  page kit, the social preview, the newsletter's privacy note, and the ExDoc pages they link to.
  """
  @spec minimal(Path.t()) :: :ok
  def minimal(root) do
    write(
      root,
      "site/ui_kits/website/index.html",
      ~s(<meta name="malachi:landing" content="1"><p>{{version}} {{license}}</p>)
    )

    write(root, "site/ui_kits/website/llms.txt", "# Malachi\n\n> {{version}}\n")
    write(root, "site/assets/fonts/bricolage.woff2", "font-bytes")
    write_page_kit(root)
    write_social_preview(root)
    write_privacy_note(root)
    write(root, "doc/introduction.html", "<h1>Introduction</h1>")
    write(root, "doc/index.html", ~s(<meta http-equiv="refresh" content="0; url=introduction.html">))
  end
end
