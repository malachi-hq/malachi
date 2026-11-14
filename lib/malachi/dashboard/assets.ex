defmodule Malachi.Dashboard.Assets do
  @moduledoc """
  The dashboard's script and stylesheet, embedded at compile time from `priv/static/dashboard`.

  They are separate files, not inline blocks, so the Content-Security-Policy can say `script-src 'self'` and
  `style-src 'self'` with no `'unsafe-inline'` (#38). Each file is read once, when this module compiles
  (`@external_resource` recompiles it when a file changes), and its SHA-256 is taken then. Serving one is a
  map lookup by exact path: no request reaches the filesystem, so nothing outside this fixed set can be served
  whatever the request spells.

  The hash is the cache-busting key. The HTML pages, which are never cached, reference each asset as
  `versioned_path/1` (`/app.js?v=<first 12 hex of the hash>`). A request whose `v` is this build's version
  gets the asset `immutable` for a year: a browser keeps it until an upgrade changes its bytes, and the
  upgraded page then asks for a URL it has never seen. Any other `v`, or none, still gets this build's bytes,
  but `no-store` (`cache_control/2`): during a rolling upgrade a page from an upgraded node can send its asset
  request to a node that is not upgraded yet, and caching that node's older bytes under the newer URL would
  pin the stale script in the browser until the next release.
  """

  @dir Path.expand("../../../priv/static/dashboard", __DIR__)

  @files [
    {"/app.css", "app.css", "text/css; charset=utf-8"},
    {"/app.js", "app.js", "text/javascript; charset=utf-8"},
    {"/login.js", "login.js", "text/javascript; charset=utf-8"}
  ]

  @typedoc "One asset: its bytes, its content type and the lowercase hex SHA-256 of its bytes."
  @type asset :: %{body: binary(), content_type: String.t(), hash: String.t()}

  for {_path, file, _content_type} <- @files do
    @external_resource Path.join(@dir, file)
  end

  @assets Map.new(@files, fn {path, file, content_type} ->
            body = File.read!(Path.join(@dir, file))
            hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
            {path, %{body: body, content_type: content_type, hash: hash}}
          end)

  @paths @files |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  # A cache lives as long as the browser keeps it, so one year and `immutable`: the URL changes with the bytes.
  @immutable "public, max-age=31536000, immutable"

  @doc """
  The asset served at `path` (the request path without its query).

  ## Examples

      iex> {:ok, asset} = Malachi.Dashboard.Assets.fetch("/app.js")
      iex> asset.content_type
      "text/javascript; charset=utf-8"

      iex> Malachi.Dashboard.Assets.fetch("/app.js.map")
      :error

  """
  @spec fetch(String.t()) :: {:ok, asset()} | :error
  def fetch(path), do: Map.fetch(@assets, path)

  @doc """
  The URL a page uses for the asset at `path`: the path with the first 12 hex digits of its hash as `v`.
  Raises for a path that is not an asset, since that is a bug in the page that names it.

  ## Examples

      iex> path = Malachi.Dashboard.Assets.versioned_path("/app.css")
      iex> {String.starts_with?(path, "/app.css?v="), byte_size(path)}
      {true, 23}

  """
  @spec versioned_path(String.t()) :: String.t()
  def versioned_path(path) do
    %{hash: hash} = Map.fetch!(@assets, path)
    path <> "?v=" <> binary_part(hash, 0, 12)
  end

  @doc "Every asset path, sorted."
  @spec paths() :: [String.t()]
  def paths, do: @paths

  @doc """
  The `Cache-Control` for the asset at `path` requested with `query` (the request's query string, without
  the `?`): `immutable` for a year when the query carries this build's `v`, as `versioned_path/1` writes it,
  and `no-store` otherwise. Raises for a path that is not an asset.

  ## Examples

      iex> query = "v=" <> (Malachi.Dashboard.Assets.versioned_path("/app.js") |> String.split("v=") |> List.last())
      iex> Malachi.Dashboard.Assets.cache_control("/app.js", query)
      "public, max-age=31536000, immutable"

      iex> Malachi.Dashboard.Assets.cache_control("/app.js", "v=000000000000")
      "no-store"

  """
  @spec cache_control(String.t(), String.t()) :: String.t()
  def cache_control(path, query) do
    if current_version?(path, query), do: @immutable, else: "no-store"
  end

  # The query is compared as raw `name=value` pairs: the version is lowercase hex, which needs no decoding, so
  # a malformed escape elsewhere in the query cannot raise here.
  defp current_version?(path, query) do
    %{hash: hash} = Map.fetch!(@assets, path)
    ("v=" <> binary_part(hash, 0, 12)) in String.split(query, "&")
  end
end
