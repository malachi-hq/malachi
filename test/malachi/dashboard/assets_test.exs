defmodule Malachi.Dashboard.AssetsTest do
  use ExUnit.Case, async: true

  alias Malachi.Dashboard.Assets

  doctest Assets

  @dir Path.expand("../../../priv/static/dashboard", __DIR__)

  @expected %{
    "/app.css" => {"app.css", "text/css; charset=utf-8"},
    "/app.js" => {"app.js", "text/javascript; charset=utf-8"},
    "/login.js" => {"login.js", "text/javascript; charset=utf-8"}
  }

  test "serves exactly the three files, sorted" do
    assert Assets.paths() == @expected |> Map.keys() |> Enum.sort()
  end

  for {path, {file, content_type}} <- @expected do
    test "#{path} is #{file} byte for byte, with its type and its SHA-256" do
      body = File.read!(Path.join(@dir, unquote(file)))

      assert {:ok, asset} = Assets.fetch(unquote(path))
      assert asset.body == body
      assert asset.content_type == unquote(content_type)
      assert asset.hash == :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    end

    test "#{path} is versioned by the first 12 hex digits of its hash" do
      {:ok, %{hash: hash}} = Assets.fetch(unquote(path))

      assert Assets.versioned_path(unquote(path)) == unquote(path) <> "?v=" <> binary_part(hash, 0, 12)
    end
  end

  test "only an exact path is an asset" do
    for path <- ["/app.js.map", "/APP.JS", "/app.js/", "//app.js", "/dashboard/app.js", "app.js", "", "/"] do
      assert Assets.fetch(path) == :error, inspect(path)
    end
  end

  test "versioned_path/1 raises for a path that is not an asset" do
    assert_raise KeyError, fn -> Assets.versioned_path("/missing.js") end
  end

  for path <- Map.keys(@expected) do
    test "#{path} is immutable only under its own version" do
      [_, version] = String.split(Assets.versioned_path(unquote(path)), "?v=")

      assert Assets.cache_control(unquote(path), "v=" <> version) == "public, max-age=31536000, immutable"
      assert Assets.cache_control(unquote(path), "a=1&v=" <> version <> "&b=2") == "public, max-age=31536000, immutable"
      assert Assets.cache_control(unquote(path), "") == "no-store"
      assert Assets.cache_control(unquote(path), "v=deadbeef0000") == "no-store"
      assert Assets.cache_control(unquote(path), "version=" <> version) == "no-store"
      assert Assets.cache_control(unquote(path), "v=" <> version <> "0") == "no-store"
    end
  end

  test "the version of one asset does not unlock the cache of another" do
    [_, css_version] = String.split(Assets.versioned_path("/app.css"), "?v=")

    assert Assets.cache_control("/app.js", "v=" <> css_version) == "no-store"
  end

  test "cache_control/2 raises for a path that is not an asset" do
    assert_raise KeyError, fn -> Assets.cache_control("/missing.js", "") end
  end
end
