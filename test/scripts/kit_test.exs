defmodule KitTest do
  # The kit (site/kit, #373): the images site/kit/render.sh draws are the sizes their sources declare and are
  # stored in Git LFS, the post templates leave every sentence to the maintainer, and the site and the README
  # link the LinkedIn Page.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @kit Path.join(@root, "site/kit")
  @page "https://www.linkedin.com/company/malachi-hq"
  @lfs_pointer "version https://git-lfs.github.com/spec/"

  # The name and size of each image, as render.sh lists them.
  defp images do
    script = File.read!(Path.join(@kit, "render.sh"))
    [_, list] = Regex.run(~r/images="([^"]+)"/, script)

    for line <- String.split(list, "\n", trim: true) do
      [name, size] = String.split(line)
      [w, h] = size |> String.split("x") |> Enum.map(&String.to_integer/1)
      {name, w, h}
    end
  end

  test "render.sh draws the three images the kit documents" do
    assert Enum.map(images(), &elem(&1, 0)) == ["logo", "linkedin-cover", "social-preview"]
    readme = File.read!(Path.join(@kit, "README.md"))

    for {name, w, h} <- images() do
      assert readme =~ "| `#{name}.svg` | `#{name}.png` | #{w}x#{h} |", name
    end
  end

  test "each source is the size render.sh draws it at, and holds no sentence, only a name" do
    for {name, w, h} <- images() do
      svg = File.read!(Path.join(@kit, name <> ".svg"))
      assert svg =~ ~s(viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}"), name

      # Every text the image holds or announces: the text between any tags (<text>, <tspan>, <title>, <desc>)
      # and the accessible label. Only the project's wordmark, or the Page's name on its own cover.
      texts =
        svg
        |> String.replace(~r/<[^>]*>/, "\n")
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      labels = ~r/aria-label="([^"]*)"/ |> Regex.scan(svg, capture: :all_but_first) |> List.flatten()
      assert labels != [], name
      assert Enum.all?(texts, &(&1 in ["malachi", "MalachiHQ"])), "#{name}: #{inspect(texts)}"
      assert Enum.all?(labels, &(&1 == "Malachi")), "#{name}: #{inspect(labels)}"
    end
  end

  test "each image is committed beside its source, through Git LFS, at its size when it was fetched" do
    for {name, w, h} <- images() do
      path = Path.join(@kit, name <> ".png")
      assert File.regular?(path), name

      {attr, 0} = System.cmd("git", ["check-attr", "filter", "--", "site/kit/#{name}.png"], cd: @root)
      assert attr =~ "filter: lfs", name

      # In CI the images are not fetched, and the file is its pointer; fetched, it is the PNG itself.
      case File.read!(path) do
        @lfs_pointer <> _ ->
          :ok

        <<137, "PNG", _::binary-size(12), width::32, height::32, _::binary>> ->
          assert {width, height} == {w, h}, name
      end
    end
  end

  test "the post templates leave every sentence to the maintainer: labels, fields and markers only" do
    for file <- ["linkedin-feed-post.md", "linkedin-article.md"] do
      text = File.read!(Path.join(@kit, file))
      assert text =~ "<!-- narrative:", file
      assert text =~ "{{post_url}}", file

      visible =
        text
        |> String.replace(~r/<!--.*?-->/s, "")
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      # What stays once the comments are gone: a title field, the version line and the attribution line.
      for line <- visible do
        assert line in [
                 "# {{title}}",
                 "Malachi {{version}}: {{post_url}}",
                 "Originally published at {{post_url}} on {{date}}."
               ],
               "#{file}: #{line}"
      end
    end
  end

  test "the landing page names the Page in its structured data and its footer" do
    html = File.read!(Path.join(@root, "site/ui_kits/website/index.html"))
    [json] = Regex.run(~r{<script type="application/ld\+json">(.*?)</script>}s, html, capture: :all_but_first)
    data = json |> String.replace(["{{version}}", "{{license}}", "{{base_url}}"], "x") |> JSON.decode!()
    # The Page belongs to the organization that makes the code, not to the code itself.
    assert %{"@type" => "Organization", "name" => "MalachiHQ", "sameAs" => same_as} = data["author"]
    assert @page in same_as
    refute Map.has_key?(data, "sameAs")
    assert html =~ ~s(<a href="#{@page}">LinkedIn</a>)
  end

  test "the README and the kit link the Page" do
    assert File.read!(Path.join(@root, "README.md")) =~ "](#{@page})"
    assert File.read!(Path.join(@kit, "README.md")) =~ "<#{@page}>"
  end
end
