defmodule Malachi.Console.Page do
  @moduledoc """
  The paging contract every `/api/v1` listing answers with, in one place so the web console, the terminal UI
  and the desktop build read one shape (section 10.3 of `docs/design/operator-interfaces.md`).

  It follows AIP-158 literally:

    * `page_size` is how many items a page holds: absent or `0` is the default of 100, a size past the
      maximum of 1000 is lowered to it, and a negative size or one that does not parse is an invalid
      request.
    * `page_token` is opaque: the position after the last item a page returned, which a client passes back
      unchanged to read the next page. It names a position in the listing's order, not an index, so an item
      that appears or goes away between two requests shifts nothing already read. It is opaque, not secret.
    * `next_page_token` is empty only on the last page.

  Two members come with every page. `total` follows Elasticsearch's `{count, relation}`: `"eq"` when every
  source answered, `"gte"` when some did not and the count is a lower bound. `complete` is false once any
  page of a walk had a source that did not answer, since what that source held before the position reached
  can no longer be returned: a walk whose last page says `complete: false` is restarted from the first page.
  The token is what carries that from one page to the next.

  A listing supplies its order: a key per item, which sorts in Erlang term order the way the listing wants,
  and how that key is written into a token and read back (`t:listing/0`). The token is text, parsed field by
  field, and never evaluated: nothing a client sends is turned into a term by `binary_to_term`.

  A token names its listing, so a token from one listing given to another is an invalid request rather than
  a position in the wrong order.
  """

  @default_size 100
  @max_size 1_000
  @version "v1"

  @typedoc "What a request asked for: the page size, the position to resume after, and whether the walk so far missed items."
  @type request :: %{size: pos_integer(), after: term() | nil, missed?: boolean()}

  @typedoc """
  A listing's order: its `kind` (the name its tokens carry), the key of an item, the key written as text
  fields, and those fields read back into a key (`:error` for anything else).
  """
  @type listing :: %{
          kind: String.t(),
          key: (term() -> term()),
          encode: (term() -> [String.t()]),
          decode: ([String.t()] -> {:ok, term()} | :error)
        }

  @typedoc "One page: its items, the token for the next one (empty on the last), whether the walk is complete, and the total."
  @type t :: %{
          items: [term()],
          next_page_token: String.t(),
          complete: boolean(),
          total: %{count: non_neg_integer(), relation: :eq | :gte}
        }

  @doc "The default page size."
  @spec default_size() :: pos_integer()
  def default_size, do: @default_size

  @doc "The largest page size; a larger request is lowered to it."
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @doc """
  Reads `page_size` and `page_token` from a request's decoded query `params` for `listing`. A repeated or
  bracketed parameter (`page_size[]=1`) arrives as a list or a map and is an invalid request.

  ## Examples

      iex> listing = %{kind: "n", key: & &1, encode: &[Integer.to_string(&1)], decode: fn [n] -> {:ok, String.to_integer(n)} end}
      iex> Malachi.Console.Page.request(%{"page_size" => "0"}, listing)
      {:ok, %{size: 100, after: nil, missed?: false}}
      iex> Malachi.Console.Page.request(%{"page_size" => "-1"}, listing)
      :error

  """
  @spec request(map(), listing()) :: {:ok, request()} | :error
  def request(params, listing) when is_map(params) do
    with {:ok, size} <- size(params["page_size"]),
         {:ok, after_key, missed?} <- token(params["page_token"], listing) do
      {:ok, %{size: size, after: after_key, missed?: missed?}}
    end
  end

  defp size(nil), do: {:ok, @default_size}

  defp size(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {0, ""} -> {:ok, @default_size}
      {size, ""} when size > 0 -> {:ok, min(size, @max_size)}
      _negative_or_invalid -> :error
    end
  end

  defp size(_not_text), do: :error

  defp token(nil, _listing), do: {:ok, nil, false}
  defp token("", _listing), do: {:ok, nil, false}

  defp token(raw, %{kind: kind, decode: decode}) when is_binary(raw) do
    with {:ok, text} <- Base.url_decode64(raw, padding: false),
         [@version, ^kind, missed | fields] when missed in ["0", "1"] <- String.split(text, "."),
         {:ok, decoded} <- decode_fields(fields),
         {:ok, key} <- decode.(decoded) do
      {:ok, key, missed == "1"}
    else
      _invalid -> :error
    end
  end

  defp token(_not_text, _listing), do: :error

  # Each field is Base64url on its own, so a field may hold any byte, the separator included.
  defp decode_fields(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case Base.url_decode64(field, padding: false) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  @doc """
  The page of `items` that `request` asks for, in `listing`'s order. `lower_bound?` says that some source
  did not answer this time, which makes the total a lower bound and the walk incomplete from here on.

  ## Examples

      iex> listing = %{kind: "n", key: & &1, encode: &[Integer.to_string(&1)], decode: fn [n] -> {:ok, String.to_integer(n)} end}
      iex> page = Malachi.Console.Page.page([3, 1, 2], %{size: 2, after: nil, missed?: false}, listing, false)
      iex> {page.items, page.complete, page.total}
      {[1, 2], true, %{count: 3, relation: :eq}}

  """
  @spec page([term()], request(), listing(), boolean()) :: t()
  def page(items, %{size: size, after: after_key, missed?: missed?}, %{key: key} = listing, lower_bound?) do
    sorted = Enum.sort_by(items, key)
    remaining = if after_key == nil, do: sorted, else: Enum.drop_while(sorted, &(key.(&1) <= after_key))
    {page, more} = Enum.split(remaining, size)
    missed? = missed? or lower_bound?

    %{
      items: page,
      next_page_token: if(more == [], do: "", else: encode_token(listing, key.(List.last(page)), missed?)),
      complete: not missed?,
      total: %{count: length(items), relation: if(lower_bound?, do: :gte, else: :eq)}
    }
  end

  @doc "The token that resumes `listing` after `key`, remembering whether the walk `missed?` items."
  @spec encode_token(listing(), term(), boolean()) :: String.t()
  def encode_token(%{kind: kind, encode: encode}, key, missed?) do
    fields = key |> encode.() |> Enum.map(&Base.url_encode64(&1, padding: false))
    Base.url_encode64(Enum.join([@version, kind, if(missed?, do: "1", else: "0") | fields], "."), padding: false)
  end

  @doc """
  The JSON members of `page`, under `items_name`: the items rendered by `render`, `total`,
  `next_page_token` and `complete`.
  """
  @spec to_json(t(), String.t(), (term() -> term())) :: map()
  def to_json(page, items_name, render) do
    %{
      items_name => Enum.map(page.items, render),
      "total" => %{"count" => page.total.count, "relation" => Atom.to_string(page.total.relation)},
      "next_page_token" => page.next_page_token,
      "complete" => page.complete
    }
  end
end
