defmodule Malachi.Site.ThemeTest do
  # The light, dark and system theme switch (#385): one source, site/ui_kits/website/theme.js, inlined by the landing
  # page and every blog page. These read the real source, so a change to it is checked here.
  use ExUnit.Case, async: true

  alias Malachi.Site.Theme
  alias Malachi.Test.SiteFixture

  @root Path.expand("../../..", __DIR__)

  setup_all do
    {:ok, script: Theme.script!(@root)}
  end

  describe "the real theme.js" do
    test "is a self-contained script: no file to load, no placeholder left, no closing tag inside", %{script: script} do
      refute script =~ ~r/\bsrc\s*=/i
      refute script =~ "{{"
      refute script =~ ~r{</script}i
      assert script == String.trim(script)
    end

    test "keeps the reader's choice under malachi-theme and no other key", %{script: script} do
      assert script =~ ~s("malachi-theme")
      assert [_] = Regex.scan(~r/localStorage\.setItem\(/, script)
      refute script =~ ~r/document\.cookie|sessionStorage|indexedDB|fetch\(|XMLHttpRequest|sendBeacon/
    end

    test "only ever compares the stored value with the theme names, never writes it into the page", %{script: script} do
      for theme <- Theme.themes(), do: assert(script =~ ~s("#{theme}"))
      refute script =~ ~r/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|Function\(/
    end

    test "sets the dark class on the root element, which the dark palette of the tokens selects", %{script: script} do
      assert script =~ ~s(classList.toggle("dark")
      assert File.read!(Path.join(@root, "site/tokens/colors.css")) =~ ~r/^\.dark\b/m
    end
  end

  describe "head/1" do
    test "inlines the script, then hides the switch when JavaScript is off", %{script: script} do
      head = Theme.head(script)
      assert head =~ ~r{\A<script>.*</script>\n<noscript>}s
      assert head =~ "<script>" <> script <> "</script>"
      assert head =~ ".js-only{display:none!important}"
    end
  end

  describe "toggle/0" do
    test "offers system, light and dark, in that order, with system checked" do
      toggle = Theme.toggle()

      assert Regex.scan(~r/<input type="radio" name="theme" value="([a-z]+)"/, toggle, capture: :all_but_first) ==
               [["system"], ["light"], ["dark"]]

      assert [_] = Regex.scan(~r/ checked>/, toggle)
      assert toggle =~ ~s(value="system" checked>)
      assert toggle =~ ~r/\A<fieldset class="seg js-only">\n<legend class="label">Theme<\/legend>/
      assert toggle =~ ~r/<\/fieldset>\z/
    end

    test "is the switch the landing page's stylesheet styles" do
      assert File.read!(Path.join(@root, "site/ui_kits/website/site.css")) =~ ".seg input:checked+span"
    end
  end

  describe "placeholders/1" do
    test "fills the landing page's two theme placeholders", %{script: script} do
      assert Theme.placeholders(script) == %{"theme_head" => Theme.head(script), "theme_toggle" => Theme.toggle()}
    end
  end

  describe "script!/1" do
    @describetag :tmp_dir

    test "raises naming the source when the checkout has no theme.js", %{tmp_dir: dir} do
      error = assert_raise File.Error, fn -> Theme.script!(dir) end
      assert Exception.message(error) =~ Theme.source()
    end

    test "trims the file's surrounding whitespace", %{tmp_dir: dir} do
      SiteFixture.write_theme(dir, "\n  x();  \n")
      assert Theme.script!(dir) == "x();"
    end
  end

  test "the landing page's source takes both pieces through placeholders, not a copy" do
    html = File.read!(Path.join(@root, "site/ui_kits/website/index.html"))
    assert [_] = Regex.scan(~r/\{\{theme_head\}\}/, html)
    assert [_] = Regex.scan(~r/\{\{theme_toggle\}\}/, html)
    refute html =~ "malachi-theme"
    refute html =~ ~s(name="theme")
  end

  test "site.js no longer carries a copy of the switch" do
    js = File.read!(Path.join(@root, "site/ui_kits/website/site.js"))
    refute js =~ "malachi-theme"
    refute js =~ "localStorage"
  end
end
