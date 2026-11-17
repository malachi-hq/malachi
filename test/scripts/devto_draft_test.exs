defmodule DevtoDraftTest do
  # scripts/devto-draft.sh (#373) against a fake dev.to: a Plug served by Bandit on this machine that answers
  # as the API does and records every request, so the tests see what curl sends, headers and body included.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @script Path.expand("../../scripts/devto-draft.sh", __DIR__)
  @canonical "https://example.test/malachi/blog/2026-11-16-v1-0-0.html"

  defmodule FakeDevto do
    @moduledoc false
    import Plug.Conn

    def init(state), do: state

    def call(conn, state) do
      {:ok, body, conn} = read_body(conn)
      key = conn |> get_req_header("api-key") |> List.first()

      Agent.update(
        state,
        &Map.update!(&1, :requests, fn r -> r ++ [{conn.method, conn.request_path, conn.query_string, key, body}] end)
      )

      %{answers: answers} = Agent.get(state, & &1)

      {status, reply} =
        cond do
          key != "secret-key" -> {401, %{"error" => "unauthorized"}}
          answer = answers[{conn.method, conn.request_path}] -> answer.(conn, body)
          true -> {404, %{"error" => "not found"}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(reply))
    end
  end

  setup do
    {:ok, state} = Agent.start_link(fn -> %{requests: [], answers: %{}} end)
    {:ok, server} = Bandit.start_link(plug: {FakeDevto, state}, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    root = TmpDir.path("devto_draft")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    article = Path.join(root, "article.json")
    write_article(article, %{})
    %{state: state, base: "http://127.0.0.1:#{port}", root: root, article: article}
  end

  defp write_article(path, overrides) do
    article =
      Map.merge(
        %{"title" => "Malachi v1.0.0", "canonical_url" => @canonical, "published" => false, "body_markdown" => "Text."},
        overrides
      )

    File.write!(path, JSON.encode!(%{"article" => article}))
  end

  defp answer(ctx, method, path, fun), do: Agent.update(ctx.state, &put_in(&1, [:answers, {method, path}], fun))
  defp requests(ctx), do: Agent.get(ctx.state, & &1.requests)

  defp pages(ctx, pages) do
    answer(ctx, "GET", "/api/articles/me/all", fn conn, _ ->
      page = conn.query_string |> URI.decode_query() |> Map.fetch!("page") |> String.to_integer()
      {200, Enum.at(pages, page - 1, [])}
    end)
  end

  defp run(ctx, args \\ nil, env \\ []) do
    {out, code} =
      System.cmd("bash", [@script | args || [ctx.article]],
        stderr_to_stdout: true,
        env: [{"DEVTO_API_KEY", "secret-key"}, {"DEVTO_API_BASE", ctx.base}] ++ env
      )

    {out, code}
  end

  test "creates the draft once, with the key in a header and the article as it was built", ctx do
    pages(ctx, [[%{"id" => 1, "canonical_url" => "https://other.test/x"}]])
    answer(ctx, "POST", "/api/articles", fn _, _ -> {201, %{"id" => 77, "url" => "https://dev.to/a/x-temp"}} end)

    assert {out, 0} = run(ctx)
    assert out =~ "created draft 77: https://dev.to/a/x-temp"

    assert [
             {"GET", _, "per_page=100&page=1", "secret-key", ""},
             {"GET", _, "per_page=100&page=2", _, _},
             {"POST", "/api/articles", "", "secret-key", body}
           ] = requests(ctx)

    assert JSON.decode!(body) == JSON.decode!(File.read!(ctx.article))
  end

  test "updates the draft whose canonical URL is the post's, on a later page, instead of a second one", ctx do
    pages(ctx, [
      [%{"id" => 1, "canonical_url" => "https://other.test/x", "published" => true}],
      [%{"id" => 42, "canonical_url" => @canonical, "published" => false}]
    ])

    answer(ctx, "PUT", "/api/articles/42", fn _, _ -> {200, %{"id" => 42, "url" => "https://dev.to/a/x"}} end)

    assert {out, 0} = run(ctx)
    assert out =~ "updated draft 42"
    methods = Enum.map(requests(ctx), &{elem(&1, 0), elem(&1, 1)})
    assert {"PUT", "/api/articles/42"} in methods
    refute {"POST", "/api/articles"} in methods
  end

  test "refuses an article already published on dev.to, which published: false would take down", ctx do
    pages(ctx, [[%{"id" => 42, "canonical_url" => @canonical, "published" => true}]])
    answer(ctx, "PUT", "/api/articles/42", fn _, _ -> {200, %{"id" => 42}} end)

    assert {out, 1} = run(ctx)
    assert out =~ "article 42 with this canonical URL is already published on dev.to; edit it there"
    refute Enum.any?(requests(ctx), &(elem(&1, 0) in ["PUT", "POST"]))
  end

  test "runs under the system's /bin/bash, the 3.2 of macOS included: an empty curl body is no unbound variable",
       ctx do
    pages(ctx, [])
    answer(ctx, "POST", "/api/articles", fn _, _ -> {201, %{"id" => 7}} end)

    {out, code} =
      System.cmd("/bin/bash", [@script, ctx.article],
        stderr_to_stdout: true,
        env: [{"DEVTO_API_KEY", "secret-key"}, {"DEVTO_API_BASE", ctx.base}]
      )

    assert code == 0, out
    refute out =~ "unbound variable"

    # CI's /bin/bash is 5, where the plain form passes too: the script's text is what keeps the guard there.
    script = File.read!(@script)
    assert script =~ ~S|${data[@]+"${data[@]}"} "$base$path"|
    refute script =~ ~S|'%{http_code}' "${data[@]}"|
  end

  for {status, message} <- [
        {401, "refused DEVTO_API_KEY (HTTP 401)"},
        {422, "refused the article (HTTP 422): Title can't be blank"},
        {429, "rate limiting this key (HTTP 429)"},
        {500, "answered HTTP 500"}
      ] do
    test "an HTTP #{status} from dev.to fails, saying what it means", ctx do
      pages(ctx, [])

      answer(ctx, "POST", "/api/articles", fn _, _ ->
        {unquote(status), %{"error" => "Title can't be blank"}}
      end)

      assert {out, 1} = run(ctx)
      assert out =~ unquote(message)
    end
  end

  test "a key dev.to refuses fails at the first request", ctx do
    assert {out, 1} = run(ctx, nil, [{"DEVTO_API_KEY", "wrong"}])
    assert out =~ "refused DEVTO_API_KEY"
    assert length(requests(ctx)) == 1
  end

  test "the key never reaches curl's arguments" do
    script = File.read!(@script)
    assert script =~ ~s(printf 'header = "api-key: %s"\\n' "$DEVTO_API_KEY" |)
    assert script =~ "curl --silent --show-error --config -"
    refute script =~ ~r/curl[^\n]*\$DEVTO_API_KEY/
    refute script =~ "set -x"
  end

  test "refuses, before any request: no key, another host, an article that would publish or lacks its URL",
       ctx do
    assert {out, 2} = run(ctx, nil, [{"DEVTO_API_KEY", nil}])
    assert out =~ "DEVTO_API_KEY is not set"

    for base <- ["https://evil.test", "http://dev.to", "https://dev.to.evil.test", "http://127.0.0.1.evil.test:80"] do
      assert {out, 2} = run(ctx, nil, [{"DEVTO_API_BASE", base}])
      assert out =~ "DEVTO_API_BASE may be"
    end

    write_article(ctx.article, %{"published" => true})
    assert {out, 2} = run(ctx)
    assert out =~ "only drafts"

    for url <- [nil, "http://example.test/x"] do
      write_article(ctx.article, %{"canonical_url" => url})
      assert {out, 2} = run(ctx)
      assert out =~ "has no https canonical_url"
    end

    assert {_, 2} = run(ctx, [])
    assert {_, 2} = run(ctx, [Path.join(ctx.root, "missing.json")])
    assert requests(ctx) == []
  end
end
