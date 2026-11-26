defmodule Malachi.Site.AuthorsTest do
  # The blog's authors (#373): site/blog/authors.json and the photos it names, read and checked against the posts.
  use ExUnit.Case, async: true

  alias Malachi.Site.Authors
  alias Malachi.Test.SiteFixture

  import SiteFixture, only: [write: 3]

  @moduletag :tmp_dir

  defp json(root, text), do: write(root, "site/blog/authors.json", text)
  defp post(author, file \\ "2026-11-16-a.md"), do: %{author: author, file: file}

  @valid ~s({"Ana Lima": {"photo": "ana-lima.png", "follow": "https://www.linkedin.com/in/ana"}})

  describe "read/1" do
    test "lists each author by name, and no file lists none", %{tmp_dir: root} do
      assert Authors.read(root) == {:ok, %{}}
      json(root, @valid)

      assert Authors.read(root) ==
               {:ok, %{"Ana Lima" => %{photo: "ana-lima.png", follow: "https://www.linkedin.com/in/ana"}}}
    end

    for {text, reason} <- [
          {"not json", "is not valid JSON"},
          {"[1]", "is an object keyed by author name"},
          {~s({"A": {"photo": "a.png"}}), "A has exactly a photo and a follow"},
          {~s({"A": {"photo": "a.png", "follow": "https://x.test", "x": 1}}), "A has exactly a photo and a follow"},
          {~s({"A": {"photo": "A.PNG", "follow": "https://x.test"}}), "A's photo is a lowercase <name>.png"},
          {~s({"A": {"photo": "../a.png", "follow": "https://x.test"}}), "A's photo is a lowercase <name>.png"},
          {~s({"A": {"photo": "a.png", "follow": "http://x.test"}}), "A's follow is an https URL with a host"},
          {~s|{"A": {"photo": "a.png", "follow": "javascript:alert(1)"}}|, "A's follow is an https URL"},
          {~s({"A": {"photo": "a.png", "follow": "https://u@x.test"}}), "A's follow is an https URL"},
          {~s({" ": {"photo": "a.png", "follow": "https://x.test"}}), "an author has an empty name"}
        ] do
      test "refuses #{text}", %{tmp_dir: root} do
        json(root, unquote(text))
        assert {:error, message} = Authors.read(root)
        assert message =~ "site/blog/authors.json"
        assert message =~ unquote(reason)
      end
    end
  end

  describe "errors/3" do
    setup %{tmp_dir: root} do
      json(root, @valid)
      write(root, "site/blog/authors/ana-lima.png", SiteFixture.png(96, 96))
      :ok
    end

    test "none for a listed author with a good photo", %{tmp_dir: root} do
      assert Authors.errors(root, [post("Ana Lima"), post("Ana Lima", "2026-11-17-b.md")], false) == []
    end

    test "a post whose author is not listed", %{tmp_dir: root} do
      assert Authors.errors(root, [post("Bob")], false) == [
               ~s(site/blog/2026-11-16-a.md names the author "Bob", who is not in site/blog/authors.json)
             ]
    end

    test "a photo missing, not a PNG, a Git LFS pointer, or too large", %{tmp_dir: root} do
      path = Path.join(root, "site/blog/authors/ana-lima.png")

      File.rm!(path)
      assert Authors.errors(root, [post("Ana Lima")], false) == ["site/blog/authors/ana-lima.png is missing"]

      File.write!(path, "GIF89a")
      assert Authors.errors(root, [post("Ana Lima")], false) == ["site/blog/authors/ana-lima.png is not a PNG"]

      File.write!(path, "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 9\n")

      assert Authors.errors(root, [post("Ana Lima")], false) == [
               "site/blog/authors/ana-lima.png is a Git LFS pointer, not the image: run git lfs pull"
             ]

      assert Authors.errors(root, [post("Ana Lima")], true) == []

      File.write!(path, :binary.copy(<<0>>, 50 * 1024 + 1))

      assert Authors.errors(root, [post("Ana Lima")], false) == [
               "site/blog/authors/ana-lima.png is 50 KB; an author's photo is at most 50 KB"
             ]
    end

    test "a photo no post shows is not checked", %{tmp_dir: root} do
      File.rm!(Path.join(root, "site/blog/authors/ana-lima.png"))
      assert Authors.errors(root, [], false) == []
    end

    test "the file's own problem, alone", %{tmp_dir: root} do
      json(root, "{")
      assert Authors.errors(root, [post("Ana Lima")], false) == ["site/blog/authors.json is not valid JSON"]
    end
  end

  test "stage/4 publishes the photos of the authors the posts name, and no other", %{tmp_dir: root} do
    json(
      root,
      ~s({"A": {"photo": "a.png", "follow": "https://x.test"}, "B": {"photo": "b.png", "follow": "https://x.test"}})
    )

    write(root, "site/blog/authors/a.png", SiteFixture.png(96, 96))
    write(root, "site/blog/authors/b.png", SiteFixture.png(96, 96))
    {:ok, authors} = Authors.read(root)

    :ok = Authors.stage(root, Path.join(root, "doc"), [post("A"), post("Nobody")], authors)
    assert File.exists?(Path.join(root, "doc/blog/authors/a.png"))
    refute File.exists?(Path.join(root, "doc/blog/authors/b.png"))
  end
end
