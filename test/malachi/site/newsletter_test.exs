defmodule Malachi.Site.NewsletterTest do
  # The blog's newsletter form and privacy note (#373): the mix.exs setting, the form's HTML, and what staging
  # and the check do with them, against a checkout built per test (Malachi.Test.SiteFixture).
  use ExUnit.Case, async: true

  alias Malachi.Site
  alias Malachi.Site.Newsletter
  alias Malachi.Test.SiteFixture

  import SiteFixture, only: [write: 3]

  @moduletag :tmp_dir

  @base %{version: "1.2.3", licenses: ["MIT"], site_url: "https://example.test/malachi", main: "introduction"}
  @action "https://forms.example.test/f/abc?x=1&y=2"
  @newsletter [
    action: @action,
    email_field: "subscriber[email]",
    consent_field: "privacy",
    hidden: [{"groups[]", "7"}, {"hp", ""}]
  ]
  @config Map.put(@base, :newsletter, @newsletter)
  @privacy "site/newsletter/privacy.md"

  setup %{tmp_dir: root} do
    SiteFixture.minimal(root)
    %{root: root}
  end

  defp post(root) do
    write(
      root,
      "site/blog/2026-11-16-v1-2-3.md",
      "---\ntitle: Release v1.2.3\ndate: 2026-11-16\nversions: [1.2.3]\nauthor: Maintainer\nsummary: What v1.2.3 delivered.\n---\n\nBody.\n"
    )
  end

  defp privacy(root, text \\ "## What is kept\n\nWhat the provider keeps.\n"), do: write(root, @privacy, text)
  defp read(root, path), do: File.read!(Path.join(root, path))
  defp edit(root, path, fun), do: write(root, path, fun.(read(root, path)))
  defp forms(html), do: ~r/<form\b/ |> Regex.scan(html) |> length()

  describe "parse/1" do
    test "nil is no newsletter" do
      assert Newsletter.parse(nil) == {:ok, nil}
    end

    test "reads the setting, with the consent value 1 and no hidden field by default" do
      assert Newsletter.parse(action: "https://f.example.test/s", email_field: "email", consent_field: "ok") ==
               {:ok,
                %{
                  action: "https://f.example.test/s",
                  email_field: "email",
                  consent_field: "ok",
                  consent_value: "1",
                  hidden: []
                }}
    end

    test "keeps the hidden fields in their order, a repeated name and an empty value included" do
      opts = @newsletter ++ [consent_value: "yes"]
      hidden = [{"groups[]", "7"}, {"groups[]", "8"}, {"hp", ""}]

      assert {:ok, %{consent_value: "yes", hidden: ^hidden}} =
               Newsletter.parse(Keyword.put(opts, :hidden, hidden))
    end

    for {label, opts, reason} <- [
          {"not a list", "https://x", "is nil or a keyword list"},
          {"empty", [], "is nil or a keyword list"},
          {"not a keyword list", [{"action", "https://x"}], "is a keyword list"},
          {"an unknown key", [actoin: "https://x"], "unknown keys [:actoin]"},
          {"a key twice", [action: "https://a.test", action: "https://b.test"], "names a key twice"},
          {"no action", [email_field: "e", consent_field: "c"], "action is an https URL"},
          {"an http action", [action: "http://f.test/s"], "action is an https URL with a host"},
          {"an action with no host", [action: "https:///s"], "action is an https URL with a host"},
          {"an action with a user", [action: "https://u:p@f.test/s"], "no user or fragment"},
          {"an action with a fragment", [action: "https://f.test/s#x"], "no user or fragment"},
          {"an action that is not a URL", [action: "https://f.test/a b"], "action is an https URL"},
          {"an action that is not a string", [action: :url], "action is an https URL"}
        ] do
      test "refuses #{label}" do
        assert {:error, message} = Newsletter.parse(unquote(Macro.escape(opts)))
        assert message =~ unquote(reason)
      end
    end

    for {label, key, value} <- [
          {"no email field", :email_field, nil},
          {"an email field with a quote", :email_field, ~s(e"mail)},
          {"an email field with a space", :email_field, "e mail"},
          {"an empty consent field", :consent_field, ""},
          {"a consent field over 64 characters", :consent_field, String.duplicate("a", 65)}
        ] do
      test "refuses #{label}" do
        assert {:error, message} = Newsletter.parse(Keyword.put(@newsletter, unquote(key), unquote(value)))
        assert message =~ "#{unquote(key)} is 1 to 64 letters"
      end
    end

    test "accepts a name of exactly 64 characters" do
      assert {:ok, _} = Newsletter.parse(Keyword.put(@newsletter, :email_field, String.duplicate("a", 64)))
    end

    test "refuses a consent value that is not a string" do
      assert {:error, "consent_value is a string, got 1"} =
               Newsletter.parse(Keyword.put(@newsletter, :consent_value, 1))
    end

    for {label, hidden, reason} <- [
          {"not a list", %{"g" => "1"}, "hidden is a list of {name, value} pairs"},
          {"not a pair", ["g"], "hidden holds {name, value} pairs of strings"},
          {"a value that is not a string", [{"g", 1}], "hidden holds {name, value} pairs of strings"},
          {"a bad name", [{"g<", "1"}], "hidden is 1 to 64 letters"}
        ] do
      test "refuses hidden fields that are #{label}" do
        assert {:error, message} =
                 Newsletter.parse(Keyword.put(@newsletter, :hidden, unquote(Macro.escape(hidden))))

        assert message =~ unquote(reason)
      end
    end
  end

  describe "from_config!/1" do
    test "is nil for a config without the key, which the tests' configs and an old mix.exs are" do
      assert Newsletter.from_config!(@base) == nil
    end

    test "raises naming the setting" do
      error =
        assert_raise ArgumentError, fn ->
          Newsletter.from_config!(%{newsletter: [action: "http://f.test"]})
        end

      assert error.message =~ "the newsletter in mix.exs: action is an https URL"
    end

    test "Malachi.Site.from_project/1 reads the project's newsletter key" do
      assert Site.from_project(newsletter: @newsletter).newsletter == @newsletter
      assert Site.from_project([]).newsletter == nil
    end

    test "the project's own setting is nil or a valid one" do
      assert {:ok, _} = Newsletter.parse(Mix.Project.config()[:newsletter])
    end
  end

  describe "form/1" do
    test "posts to the action, with the fields escaped, the hidden ones in order, and no script" do
      {:ok, newsletter} = Newsletter.parse(Keyword.put(@newsletter, :hidden, [{"src", ~s(a"<b>&'c)}, {"hp", ""}]))
      html = Newsletter.form(newsletter)

      assert html =~ ~s(<form method="post" action="https://forms.example.test/f/abc?x=1&amp;y=2">)

      assert html =~
               ~s(<input id="newsletter-email" type="email" name="subscriber[email]" autocomplete="email" maxlength="254" required>)

      assert html =~ ~s(<input type="checkbox" name="privacy" value="1" required>)
      assert html =~ ~s(<a href="privacy.html">privacy note</a>)

      assert html =~
               ~s(<input type="hidden" name="src" value="a&quot;&lt;b&gt;&amp;&#39;c">\n<input type="hidden" name="hp" value="">)

      refute html =~ "<script"
      assert forms(html) == 1
    end
  end

  describe "staging" do
    test "with no newsletter: no form, no privacy note, and the check passes", %{root: root} do
      post(root)
      privacy(root)
      :ok = Site.stage(root, @base)

      assert forms(read(root, "doc/blog/index.html")) == 0
      assert forms(read(root, "doc/blog/2026-11-16-v1-2-3.html")) == 0
      refute File.exists?(Path.join(root, "doc/blog/privacy.html"))
      assert Site.verify(root, @base) == []
    end

    test "with a newsletter: the form ends the index and every post, the note is staged, the check passes",
         %{root: root} do
      post(root)
      privacy(root)
      :ok = Site.stage(root, @config)

      for page <- ["doc/blog/index.html", "doc/blog/2026-11-16-v1-2-3.html"] do
        html = read(root, page)
        assert forms(html) == 1, page
        assert html =~ ~s(action="https://forms.example.test/f/abc?x=1&amp;y=2"), page
      end

      note = read(root, "doc/blog/privacy.html")
      assert note =~ "<h1>Newsletter privacy</h1>"
      assert note =~ "What the provider keeps."
      assert note =~ ~s(<link rel="canonical" href="https://example.test/malachi/blog/privacy.html">)
      assert forms(note) == 0
      assert read(root, "doc/sitemap.xml") =~ "https://example.test/malachi/blog/privacy.html"
      assert Site.verify(root, @config) == []
    end

    test "with no post, the index still carries the form", %{root: root} do
      privacy(root)
      :ok = Site.stage(root, @config)
      assert forms(read(root, "doc/blog/index.html")) == 1
      assert Site.verify(root, @config) == []
    end

    test "refuses a newsletter without its privacy note, and leaves the blog as it was", %{root: root} do
      :ok = Site.stage(root, @base)
      before = read(root, "doc/blog/index.html")

      error = assert_raise Mix.Error, fn -> Site.stage(root, @config) end
      assert error.message =~ "#{@privacy} is missing, and the newsletter form links to it"
      assert read(root, "doc/blog/index.html") == before
    end

    test "refuses a privacy note the Markdown renderer refuses", %{root: root} do
      privacy(root, "<script>x()</script>\n")
      error = assert_raise Mix.Error, fn -> Site.stage(root, @config) end
      assert error.message =~ @privacy
    end

    test "refuses an invalid setting before writing anything", %{root: root} do
      config = Map.put(@base, :newsletter, action: "http://f.test")
      assert_raise ArgumentError, ~r/the newsletter in mix.exs/, fn -> Site.stage(root, config) end
      refute File.exists?(Path.join(root, "doc/blog"))
    end
  end

  describe "the check" do
    setup %{root: root} do
      post(root)
      privacy(root)
      :ok = Site.stage(root, @config)
      :ok
    end

    test "reports a missing privacy note", %{root: root} do
      File.rm!(Path.join(root, @privacy))
      errors = Site.verify(root, @config)
      assert "#{@privacy} is missing, and the newsletter form links to it: write the privacy note" in errors
    end

    test "reports a privacy note with a narrative placeholder or a chart", %{root: root} do
      privacy(root, "<!-- narrative: what the provider keeps -->\n")
      assert "#{@privacy} still has 1 <!-- narrative --> placeholder(s) to write" in Site.verify(root, @config)

      chart = ~s({"name": "r", "title": "R", "unit": "u", "points": [{"label": "a", "value": 1}]})
      privacy(root, "```malachi-chart\n#{chart}\n```\n")
      assert "#{@privacy} draws a chart; the privacy note has none" in Site.verify(root, @config)
    end

    test "reports a privacy note with a malachi-seed block", %{root: root} do
      privacy(root, "Text.\n\n```malachi-seed\nhighlight\n```\n")
      assert "#{@privacy} has a malachi-seed block; the privacy note has none" in Site.verify(root, @config)
    end

    test "reports a privacy note that cannot be read", %{root: root} do
      File.rm!(Path.join(root, @privacy))
      File.mkdir_p!(Path.join(root, @privacy))
      assert "#{@privacy} cannot be read (illegal operation on a directory)" in Site.verify(root, @config)
    end

    test "reports a privacy note that is not UTF-8", %{root: root} do
      write(root, @privacy, <<0xFF, 0xFE>>)
      assert "#{@privacy} is not UTF-8" in Site.verify(root, @config)
    end

    test "reports a staged privacy note that is missing", %{root: root} do
      File.rm!(Path.join(root, "doc/blog/privacy.html"))
      assert "doc/blog/privacy.html is missing; stage the site again" in Site.verify(root, @config)
    end

    test "reports a page whose form posts elsewhere, or with a GET", %{root: root} do
      page = "doc/blog/2026-11-16-v1-2-3.html"
      edit(root, page, &String.replace(&1, "forms.example.test", "evil.example.test"))
      wanted = "doc/blog/2026-11-16-v1-2-3.html has a form that does not post to #{@action}; stage the site again"
      assert wanted in Site.verify(root, @config)

      :ok = Site.stage(root, @config)
      edit(root, page, &String.replace(&1, ~s(method="post"), ~s(method="get")))
      assert wanted in Site.verify(root, @config)
    end

    test "reports a page without the form, or with two", %{root: root} do
      edit(root, "doc/blog/index.html", &Regex.replace(~r{<form\b.*?</form>}s, &1, ""))

      assert "doc/blog/index.html has 0 forms; a blog page has one, the newsletter's; stage the site again" in Site.verify(
               root,
               @config
             )

      :ok = Site.stage(root, @config)
      edit(root, "doc/blog/index.html", &String.replace(&1, "</main>", ~s(<form method="post"></form></main>)))

      assert "doc/blog/index.html has 2 forms; a blog page has one, the newsletter's; stage the site again" in Site.verify(
               root,
               @config
             )
    end

    test "reports a form on the privacy note", %{root: root} do
      edit(root, "doc/blog/privacy.html", &String.replace(&1, "</main>", ~s(<form method="post"></form></main>)))
      assert "doc/blog/privacy.html has a form; the privacy note has none" in Site.verify(root, @config)
    end

    test "reports a staged form once the newsletter is taken out of mix.exs", %{root: root} do
      errors = Site.verify(root, @base)
      assert "doc/blog/index.html has a form, and mix.exs configures no newsletter; stage the site again" in errors

      assert "doc/blog/2026-11-16-v1-2-3.html has a form, and mix.exs configures no newsletter; stage the site again" in errors
    end

    test "checks the privacy note's links like any blog page's", %{root: root} do
      privacy(root, "See [the docs](../missing.html).\n")
      :ok = Site.stage(root, @config)
      assert Enum.any?(Site.verify(root, @config), &(&1 =~ "doc/blog/privacy.html (../missing.html)"))
    end
  end
end
