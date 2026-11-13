defmodule Malachi.Console.PageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.Console.Page

  doctest Malachi.Console.Page

  # Items are `{sort_text, id}`: two fields, the first of which may hold the token's separators.
  @listing %{
    kind: "things",
    key: &Function.identity/1,
    encode: &__MODULE__.encode/1,
    decode: &__MODULE__.decode/1
  }

  def encode({text, id}), do: [text, Integer.to_string(id)]

  def decode([text, id]) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, {text, id}}
      _invalid -> :error
    end
  end

  def decode(_fields), do: :error

  defp request!(params) do
    {:ok, request} = Page.request(params, @listing)
    request
  end

  describe "request/2" do
    test "an absent size or 0 is the default, and a size past the maximum is lowered to it" do
      assert request!(%{}).size == Page.default_size()
      assert request!(%{"page_size" => "0"}).size == Page.default_size()
      assert request!(%{"page_size" => "7"}).size == 7
      assert request!(%{"page_size" => "1000"}).size == Page.max_size()
      assert request!(%{"page_size" => "1001"}).size == Page.max_size()
    end

    test "an empty or absent token starts the walk" do
      assert %{after: nil, missed?: false} = request!(%{"page_token" => ""})
      assert %{after: nil, missed?: false} = request!(%{})
    end

    test "a size or token that does not parse, or a repeated parameter, is an error" do
      other_listing = %{@listing | kind: "others"}
      foreign = Page.encode_token(other_listing, {"a", 1}, false)

      for params <- [
            %{"page_size" => "-1"},
            %{"page_size" => "1.5"},
            %{"page_size" => " 1"},
            %{"page_size" => ["1"]},
            %{"page_size" => %{"x" => "1"}},
            %{"page_token" => ["x"]},
            %{"page_token" => "%%%"},
            %{"page_token" => Base.url_encode64("v1.things.2", padding: false)},
            %{"page_token" => Base.url_encode64("v2.things.0", padding: false)},
            %{"page_token" => Base.url_encode64("v1.things.0.***", padding: false)},
            %{"page_token" => Base.url_encode64("v1.things.0", padding: false)},
            %{"page_token" => foreign}
          ] do
        assert Page.request(params, @listing) == :error, inspect(params)
      end
    end

    test "a token round trips its key and whether the walk missed items, separators in a field included" do
      for missed? <- [true, false], key <- [{"plain", 1}, {"a.b:c/=", 22}, {"", 0}] do
        token = Page.encode_token(@listing, key, missed?)
        assert {:ok, %{after: ^key, missed?: ^missed?}} = Page.request(%{"page_token" => token}, @listing)
      end
    end
  end

  describe "page/4" do
    test "the last page has an empty token, and the total is exact when every source answered" do
      items = for n <- 1..3, do: {"t", n}
      page = Page.page(items, request!(%{"page_size" => "5"}), @listing, false)
      assert page.items == items
      assert page.next_page_token == ""
      assert page.complete
      assert page.total == %{count: 3, relation: :eq}
    end

    test "a source that did not answer makes the total a lower bound and the walk incomplete from then on" do
      items = for n <- 1..3, do: {"t", n}
      first = Page.page(items, request!(%{"page_size" => "1"}), @listing, true)
      assert first.total.relation == :gte
      refute first.complete

      # every later page of the walk says so, though all sources answer it
      second = Page.page(items, request!(%{"page_size" => "1", "page_token" => first.next_page_token}), @listing, false)
      refute second.complete
      assert second.total.relation == :eq
    end

    test "an empty listing is one complete page" do
      assert %{items: [], next_page_token: "", complete: true, total: %{count: 0, relation: :eq}} =
               Page.page([], request!(%{}), @listing, false)
    end

    test "to_json/3 renders the members every listing carries" do
      page = Page.page([{"t", 1}], request!(%{}), @listing, true)

      assert Page.to_json(page, "things", fn {text, id} -> "#{text}#{id}" end) == %{
               "things" => ["t1"],
               "total" => %{"count" => 1, "relation" => "gte"},
               "next_page_token" => "",
               "complete" => false
             }
    end
  end

  # Walks `items_at.(page_number)` page by page, the listing changing between pages as it may between
  # requests, and returns every item returned.
  defp walk(items_at, size, page_number \\ 0, token \\ "", acc \\ []) do
    page =
      Page.page(items_at.(page_number), request!(%{"page_size" => "#{size}", "page_token" => token}), @listing, false)

    acc = acc ++ page.items

    case page.next_page_token do
      "" -> acc
      next -> walk(items_at, size, page_number + 1, next, acc)
    end
  end

  property "a walk returns each item once, in order, and every item present throughout the walk" do
    check all(
            stable <- uniq_list_of(tuple({string(:printable, max_length: 4), integer(0..50)}), max_length: 60),
            churn <-
              list_of(list_of(tuple({string(:printable, max_length: 4), integer(51..99)}), max_length: 5),
                max_length: 30
              ),
            size <- integer(1..7)
          ) do
      # the stable items are there for the whole walk; each page adds and drops churning ones
      items_at = fn page_number -> Enum.uniq(stable ++ Enum.at(churn, page_number, [])) end
      walked = walk(items_at, size)

      assert walked == Enum.uniq(walked), "an item was returned twice"
      assert walked == Enum.sort(walked), "the walk went backwards"
      assert MapSet.subset?(MapSet.new(stable), MapSet.new(walked)), "a stable item was skipped"
    end
  end

  test "a listing of 5000 items is walked whole in pages no larger than the maximum" do
    items = for n <- 1..5_000, do: {"segment", n}
    request = request!(%{"page_size" => "5000"})
    first = Page.page(items, request, @listing, false)
    assert length(first.items) == Page.max_size()
    assert walk(fn _page -> items end, Page.max_size()) == items
  end
end
