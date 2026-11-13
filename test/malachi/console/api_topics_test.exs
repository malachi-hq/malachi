defmodule Malachi.Console.ApiTopicsTest do
  # `GET /api/v1/topics`, `/topics/:topic/ranges` and `/topics/:topic/segments`, read from a metadata sample
  # seeded into `Malachi.Console.Sampler`, so a topic of thousands of segments costs no producing.
  # `Malachi.Console.TopicsViewTest` covers the shapes; this covers the routes.
  #
  # async: false. The sampler and its interval are the node's.
  use ExUnit.Case, async: false

  alias Malachi.Console.Sampler
  alias Malachi.Metadata
  alias Malachi.Test.AccessHelper
  alias Malachi.Test.SamplerHelper

  @local {Malachi.LogReplication, node()}

  defp apply!(state, command) do
    {state, reply} = Metadata.apply(state, command)
    assert reply == :ok or elem(reply, 0) == :ok, "#{inspect(command)}: #{inspect(reply)}"
    state
  end

  # "big" holds `count` sealed segments on this node; "payments" has a name that needs encoding.
  defp metadata(count) do
    {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "big", 4})

    state =
      Enum.reduce(0..(count - 1), state, fn seq, acc ->
        acc
        |> apply!({:register_segment, root, {root, seq}, [@local], seq * 10})
        |> apply!({:seal_segment, {root, seq}, 10, 100, 1_791_720_000_000})
      end)

    {state, {:ok, _root}} = Metadata.apply(state, {:create_topic, "payments", 4})
    state
  end

  # Seeds the samples the routes read, and keeps them for the test.
  defp seed!(metadata, failed \\ MapSet.new()) do
    Application.put_env(:malachi, :console_sample_ms, 600_000)
    Sampler.clear()
    SamplerHelper.seed!(:metadata, metadata)
    SamplerHelper.seed_failed!(failed)
    SamplerHelper.seed!(:damaged, [])
  end

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    Application.put_env(:malachi, :console_fanout, nodes: [node()])

    on_exit(fn ->
      Application.delete_env(:malachi, :console_sample_ms)
      Application.delete_env(:malachi, :console_fanout)
      Sampler.clear()
    end)

    %{token: AccessHelper.account!("topics_viewer", [], :viewer)}
  end

  defp get(path, token), do: AccessHelper.call(:console, "GET", path, token, [])

  defp walk(path, token, size) do
    Stream.unfold({"page_size=#{size}", false}, fn
      :done ->
        nil

      {query, _} ->
        assert %{status: 200, json: body} = get(path <> "?" <> query, token)

        case body["next_page_token"] do
          "" -> {body, :done}
          next -> {body, {"page_size=#{size}&page_token=" <> next, true}}
        end
    end)
    |> Enum.to_list()
  end

  test "topics are listed by name with their counts and the sample's age", %{token: token} do
    seed!(metadata(3))
    assert %{status: 200, json: body} = get("/api/v1/topics", token)
    assert [%{"name" => "big", "segments" => %{"total" => 3}}, %{"name" => "payments"}] = body["topics"]
    assert %{"total" => %{"count" => 2, "relation" => "eq"}, "complete" => true, "stale" => false} = body
    assert {:ok, _at, 0} = DateTime.from_iso8601(body["sampled_at"])

    pages = walk("/api/v1/topics", token, 1)
    assert Enum.flat_map(pages, & &1["topics"]) |> Enum.map(& &1["name"]) == ["big", "payments"]
  end

  test "a topic of several thousand segments is paged, never returned whole", %{token: token} do
    seed!(metadata(5_000))

    assert %{status: 200, json: first} = get("/api/v1/topics/big/segments?page_size=5000", token)
    assert length(first["segments"]) == 1_000
    assert first["next_page_token"] != ""
    assert first["total"] == %{"count" => 5_000, "relation" => "eq"}

    segments = walk("/api/v1/topics/big/segments", token, 1_000) |> Enum.flat_map(& &1["segments"])
    assert Enum.map(segments, & &1["segment"]) == Enum.to_list(0..4_999)

    name = Atom.to_string(node())

    assert %{
             "primary" => ^name,
             "replica_set" => [^name],
             "copies" => [%{"node" => ^name, "conditions" => ["sealed"]}],
             "health" => %{"severity" => "ok"}
           } = hd(segments)
  end

  test "a topic with no segments has an empty, complete listing", %{token: token} do
    seed!(metadata(1))

    assert %{status: 200, json: %{"segments" => [], "complete" => true, "total" => %{"count" => 0}}} =
             get("/api/v1/topics/payments/segments", token)
  end

  test "a copy that failed on its node is shown failed", %{token: token} do
    seed!(metadata(2), MapSet.new([{{"big", 0}, 1}]))
    assert %{status: 200, json: %{"segments" => [ok, failed]}} = get("/api/v1/topics/big/segments", token)
    assert ok["health"]["severity"] == "ok"
    assert %{"health" => %{"label" => "sealed+failed", "severity" => "error"}} = failed
  end

  test "ranges are listed in sequence order, and a name is percent-decoded", %{token: token} do
    seed!(metadata(1))
    assert %{status: 200, json: body} = get("/api/v1/topics/big/ranges", token)
    assert %{"topic" => "big", "ranges" => [%{"range" => 0, "parents" => [], "state" => "active"}]} = body

    assert %{status: 200, json: %{"topic" => "big", "ranges" => [_root]}} = get("/api/v1/topics/%62ig/ranges", token)
  end

  test "an unknown topic is a 404 naming it, and a name that does not decode a 400", %{token: token} do
    seed!(metadata(1))

    for route <- ["ranges", "segments"] do
      assert %{status: 404, json: %{"type" => "errors.topics.not_found", "topic" => "nope"}} =
               get("/api/v1/topics/nope/#{route}", token)

      for malformed <- ["bad%zz", "bad%2", "bad%"] do
        assert %{status: 400, json: %{"type" => "errors.http.invalid_request"}} =
                 get("/api/v1/topics/#{malformed}/#{route}", token),
               malformed
      end
    end

    assert %{status: 400} = get("/api/v1/topics?page_size=-1", token)
    b64 = &Base.url_encode64(&1, padding: false)
    # a topics token with two fields, a segments token with one
    assert %{status: 400} =
             get("/api/v1/topics?page_token=" <> b64.("v1.topics.0." <> b64.("a") <> "." <> b64.("b")), token)

    assert %{status: 400} = get("/api/v1/topics/big/segments?page_token=" <> b64.("v1.segments.0." <> b64.("1")), token)

    assert %{status: 400} =
             get(
               "/api/v1/topics/big/segments?page_token=" <> b64.("v1.segments.0." <> b64.("1") <> "." <> b64.("x")),
               token
             )

    token_of_other = Base.url_encode64("v1.vnodes.0." <> Base.url_encode64("1", padding: false), padding: false)
    assert %{status: 400} = get("/api/v1/topics/big/segments?page_token=" <> token_of_other, token)
  end

  test "metadata that cannot be read is a 503, not an empty listing", %{token: token} do
    Application.put_env(:malachi, :console_sample_ms, 0)
    Sampler.clear()
    :ok = :sys.suspend(Malachi.LogBroker)

    try do
      assert %{status: 503, json: %{"type" => "errors.http.unavailable"}} = get("/api/v1/topics", token)
    after
      :sys.resume(Malachi.LogBroker)
    end
  end

  test "the topic routes take a viewer" do
    wire_only = AccessHelper.account!("topics_wire_only", [:produce], nil)

    for path <- ["/api/v1/topics", "/api/v1/topics/big/ranges", "/api/v1/topics/big/segments"] do
      assert %{status: 401} = get(path, nil)
      assert %{status: 403} = get(path, wire_only)
    end
  end
end
