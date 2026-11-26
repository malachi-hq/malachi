defmodule Malachi.Site.Authors do
  @moduledoc """
  The blog's authors (issue #373): who wrote a post, shown in its byline with a small photo and a Follow link.

  They are listed in `site/blog/authors.json`, an object keyed by the name a post's `author` gives:

      {"Hector Cardoso": {"photo": "hector-cardoso.png", "follow": "https://www.linkedin.com/in/hectorcardoso"}}

    * `photo`: a lowercase `<name>.png` in `site/blog/authors/`, square, at most 50 KB. It is published under
      `blog/authors/`, so a reader's browser never asks another site for it;
    * `follow`: an `https` URL with a host, where a reader follows the author.

  `errors/3` reports a file that is not that shape, a post whose author is not listed, and a listed photo that is
  missing, is not a PNG, is a Git LFS pointer (not fetched) or exceeds 50 KB.
  """

  alias Malachi.Site.Blog

  @file_path "site/blog/authors.json"
  @dir "site/blog/authors"
  @photo ~r/\A[a-z0-9][a-z0-9-]*\.png\z/
  @max_photo_bytes 50 * 1024

  @typedoc "An author, by the name posts give."
  @type author :: %{photo: String.t(), follow: String.t()}

  @doc "The folder of the photos, under the checkout."
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc """
  The authors in `site/blog/authors.json` under `root`, by name, or what is wrong with the file. A missing file
  lists no author.
  """
  @spec read(Path.t()) :: {:ok, %{String.t() => author()}} | {:error, String.t()}
  def read(root) do
    case File.read(Path.join(root, @file_path)) do
      {:ok, text} -> parse(text)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "#{@file_path} cannot be read (#{:file.format_error(reason)})"}
    end
  end

  defp parse(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) ->
        Enum.reduce_while(Enum.sort(map), {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
          case entry(name, entry) do
            {:ok, author} -> {:cont, {:ok, Map.put(acc, name, author)}}
            {:error, reason} -> {:halt, {:error, "#{@file_path}: #{reason}"}}
          end
        end)

      {:ok, _other} ->
        {:error, "#{@file_path} is an object keyed by author name"}

      {:error, _reason} ->
        {:error, "#{@file_path} is not valid JSON"}
    end
  end

  defp entry(name, %{"photo" => photo, "follow" => follow} = entry) when map_size(entry) == 2 do
    cond do
      String.trim(name) == "" ->
        {:error, "an author has an empty name"}

      not (is_binary(photo) and Regex.match?(@photo, photo)) ->
        {:error, "#{name}'s photo is a lowercase <name>.png in #{@dir}, got #{inspect(photo)}"}

      not https?(follow) ->
        {:error, "#{name}'s follow is an https URL with a host, got #{inspect(follow)}"}

      true ->
        {:ok, %{photo: photo, follow: follow}}
    end
  end

  defp entry(name, _entry), do: {:error, "#{name} has exactly a photo and a follow"}

  defp https?(url) when is_binary(url) do
    match?({:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) and host != "", URI.new(url))
  end

  defp https?(_url), do: false

  @doc """
  What keeps the posts' bylines from being published: the file's own problem, a post whose author is not listed,
  and each listed author's photo that a post shows and that is missing, not a PNG, a Git LFS pointer (unless
  `pointers?`, as on a fork's pull request) or over 50 KB.
  """
  @spec errors(Path.t(), [Blog.post()], boolean()) :: [String.t()]
  def errors(root, posts, pointers?) do
    case read(root) do
      {:error, reason} ->
        [reason]

      {:ok, authors} ->
        unlisted =
          for post <- posts, not Map.has_key?(authors, post.author) do
            "site/blog/#{post.file} names the author #{inspect(post.author)}, who is not in #{@file_path}"
          end

        photos =
          posts
          |> Enum.map(& &1.author)
          |> Enum.uniq()
          |> Enum.flat_map(fn name ->
            case authors do
              %{^name => author} -> photo_errors(root, author.photo, pointers?)
              _ -> []
            end
          end)

        unlisted ++ photos
    end
  end

  defp photo_errors(root, photo, pointers?) do
    path = Path.join([root, @dir, photo])
    shown = "#{@dir}/#{photo}"

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_photo_bytes ->
        ["#{shown} is #{div(size, 1024)} KB; an author's photo is at most #{div(@max_photo_bytes, 1024)} KB"]

      {:ok, %File.Stat{type: :regular}} ->
        cond do
          Blog.lfs_pointer?(path) ->
            if pointers?, do: [], else: ["#{shown} is a Git LFS pointer, not the image: run git lfs pull"]

          not png?(path) ->
            ["#{shown} is not a PNG"]

          true ->
            []
        end

      _ ->
        ["#{shown} is missing"]
    end
  end

  defp png?(path) do
    match?({:ok, <<137, "PNG", 13, 10, 26, 10>>}, File.open(path, [:read, :binary], &IO.binread(&1, 8)))
  end

  @doc "Copies the photos of the authors these posts name into `blog/authors/` under `doc`."
  @spec stage(Path.t(), Path.t(), [Blog.post()], %{String.t() => author()}) :: :ok
  def stage(root, doc, posts, authors) do
    for name <- posts |> Enum.map(& &1.author) |> Enum.uniq(),
        %{photo: photo} <- [Map.get(authors, name)],
        source = Path.join([root, @dir, photo]),
        File.regular?(source) do
      dest = Path.join([doc, "blog", "authors", photo])
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source, dest)
    end

    :ok
  end
end
