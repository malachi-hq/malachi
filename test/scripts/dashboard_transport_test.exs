defmodule DashboardTransportTest do
  # The dashboard plumbing every harness shares: scripts/lib/dashboard_curl.sh (the curl transport) and,
  # from scripts/metrics_scrape_lib.sh, the login and the raw HTTP response parser the in-node transport
  # uses. #180 is the reason these are tested on their own: the password and the session token must reach
  # the dashboard without ever being a process argument, where /proc/<pid>/cmdline shows them to every
  # local user. Each function runs for real under bash, with a curl stub (and a jq wrapper around the real
  # jq) first on the PATH that records its argv and its stdin apart, so a test asserts both where the
  # secret went and where it did not.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @scrape_lib Path.expand("../../scripts/metrics_scrape_lib.sh", __DIR__)
  @curl_lib Path.expand("../../scripts/lib/dashboard_curl.sh", __DIR__)

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    %{
      bash: System.find_executable("bash") || flunk("bash is required to test the dashboard transport"),
      jq: System.find_executable("jq") || flunk("jq is required to test the dashboard transport")
    }
  end

  setup %{tmp_dir: dir, jq: jq} do
    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)
    write_stub!(stubs, "curl", curl_stub())
    write_stub!(stubs, "jq", jq_wrapper(jq))
    %{stubs: stubs, argv: Path.join(dir, "argv.log"), stdin: Path.join(dir, "stdin.log")}
  end

  describe "ms_http_post" do
    test "sends the JSON on curl's stdin and prints the body of a 2xx", ctx do
      json = ~s({"username":"admin","password":"s3cret"})

      assert {"ok-body\n", 0} = call(ctx, ~s(ms_http_post /login "$ARG1"), [{"ARG1", json}])

      assert stdin_entries(ctx) == ["curl:" <> json]
      argv = File.read!(ctx.argv)
      assert argv =~ "-X POST -H Content-Type: application/json --data-binary @- http://dash.test/login"
      refute argv =~ "s3cret"
    end

    test "a refused request prints the status alone", ctx do
      assert {"HTTP 403\n", 1} = call(ctx, ~s(ms_http_post /login "{}"), [{"STUB_STATUS", "403"}])
    end
  end

  describe "ms_http_get" do
    test "sends the bearer as a curl config line on stdin and asks for text/plain", ctx do
      assert {"ok-body\n", 0} = call(ctx, ~s(ms_http_get /metrics "$ARG1"), [{"ARG1", "tok_EN-1"}])

      assert stdin_entries(ctx) == [~s(curl:header = "Authorization: Bearer tok_EN-1"\n)]
      argv = File.read!(ctx.argv)
      assert argv =~ "-K - -H Accept: text/plain http://dash.test/metrics"
      refute argv =~ "tok_EN-1"
      refute argv =~ "Bearer"
    end

    test "takes another Accept when asked", ctx do
      assert {_, 0} = call(ctx, ~s(ms_http_get /metrics tok '*/*'))
      assert File.read!(ctx.argv) =~ "-H Accept: */* http://dash.test/metrics"
    end

    for status <- ~w(401 429 500) do
      test "HTTP #{status} prints the status alone", ctx do
        assert {"HTTP #{unquote(status)}\n", 1} =
                 call(ctx, "ms_http_get /metrics tok", [{"STUB_STATUS", unquote(status)}])
      end
    end

    test "a curl that cannot connect says so with its exit status", ctx do
      assert {"curl could not reach http://dash.test (exit 7)\n", 1} =
               call(ctx, "ms_http_get /metrics tok", [{"STUB_EXIT", "7"}])
    end

    test "without curl it says so and runs nothing", ctx do
      assert {"curl not found\n", 1} = call(ctx, "ms_http_get /metrics tok", [{"CURL", "no-such-curl"}])
      refute File.exists?(ctx.argv)
    end
  end

  describe "ms_login" do
    for {name, password} <- [
          {"plain", "admin123"},
          {"quotes and backslashes", ~S(p"a\ss)},
          {"spaces", "a pass phrase"},
          {"a newline", "two\nlines"},
          {"unicode", "sênha🔑"},
          {"a leading dash", "--s3cret"}
        ] do
      test "a password with #{name} reaches the login body intact and is never a jq or curl argument", ctx do
        password = unquote(password)

        assert {"stubtoken_-1\n", 0} =
                 call(ctx, ~s(ms_login "$ARG1" "$ARG2"), [
                   {"ARG1", "bench"},
                   {"ARG2", password},
                   {"STUB_BODY", ~s({"token":"stubtoken_-1"})}
                 ])

        [body] = for "curl:" <> body <- stdin_entries(ctx), do: body
        assert Jason.decode!(body) == %{"username" => "bench", "password" => password}
        refute File.read!(ctx.argv) =~ password
        assert File.read!(ctx.argv) =~ "jq -Rsc --arg u bench"
      end
    end

    for {name, body, reason} <- [
          {"no token", ~s({"s":"ok"}), "login failed: the answer carried no token"},
          {"an empty token", ~s({"token":""}), "login failed: the answer carried no token"},
          {"a body that is not JSON", "<html>", "login failed: the answer carried no token"},
          {"a token with a quote", ~s({"token":"a\\"b"}), "login failed: the answer carried a malformed token"},
          {"a token with a line break", ~s({"token":"a\\nb"}), "login failed: the answer carried a malformed token"},
          {"a token with a carriage return", ~s({"token":"a\\rb"}),
           "login failed: the answer carried a malformed token"},
          {"a token with a space", ~s({"token":"a b"}), "login failed: the answer carried a malformed token"},
          {"a token with a backslash", ~s({"token":"a\\\\b"}), "login failed: the answer carried a malformed token"}
        ] do
      test "#{name} is refused with the reason", ctx do
        assert {unquote(reason) <> "\n", 1} =
                 call(ctx, "ms_login admin pw", [{"STUB_BODY", unquote(body)}])
      end
    end

    test "a refused login names the status and what it means", ctx do
      assert {"login failed: HTTP 403 (the dashboard refused the credentials)\n", 1} =
               call(ctx, "ms_login admin pw", [{"STUB_STATUS", "403"}])
    end
  end

  describe "ms_parse_http_response" do
    for {name, response, output, status} <- [
          {"a 200 with CRLF headers", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", "hello\n", 0},
          {"a 200 over HTTP/1.0", "HTTP/1.0 200 OK\r\n\r\nhello", "hello\n", 0},
          {"a body with blank lines of its own", "HTTP/1.1 200 OK\r\n\r\na\r\n\r\nb", "a\r\n\r\nb\n", 0},
          {"bare LF headers", "HTTP/1.1 200 OK\nContent-Length: 5\n\nhello", "hello\n", 0},
          {"bare LF headers before a body holding a CRLF blank line", "HTTP/1.1 200 OK\nX: 1\n\na\r\n\r\nb",
           "a\r\n\r\nb\n", 0},
          {"CRLF headers before a body holding a LF blank line", "HTTP/1.1 200 OK\r\nX: 1\r\n\r\na\n\nb", "a\n\nb\n",
           0},
          {"an empty body", "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n", "\n", 0},
          {"a 401", "HTTP/1.1 401 Unauthorized\r\n\r\n", "HTTP 401\n", 1},
          {"a 429", "HTTP/1.1 429 Too Many Requests\r\n\r\n", "HTTP 429\n", 1},
          {"a status line alone", "HTTP/1.1 500", "HTTP 500\n", 1},
          {"no end of headers", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n",
           "node1 gave a response with no end of headers\n", 1},
          {"nothing at all", "", "node1 gave no HTTP status line\n", 1},
          {"no status line", "<html>hello</html>", "node1 gave no HTTP status line\n", 1},
          {"a status that is not three digits", "HTTP/1.1 20 OK\r\n\r\n", "node1 gave no HTTP status line\n", 1},
          {"another protocol", "HTTP/2 200\r\n\r\nx", "node1 gave no HTTP status line\n", 1}
        ] do
      test "#{name}", ctx do
        assert {unquote(output), unquote(status)} =
                 call(ctx, ~s(ms_parse_http_response node1 "$ARG1"), [{"ARG1", unquote(response)}])
      end
    end
  end

  # --- running a function ---

  defp call(ctx, command, env \\ []) do
    base = [
      {"PATH", ctx.stubs <> ":" <> System.get_env("PATH", "")},
      {"DASHBOARD_URL", "http://dash.test"},
      {"CURL", nil},
      {"STUB_ARGV_LOG", ctx.argv},
      {"STUB_STDIN_LOG", ctx.stdin},
      {"STUB_STATUS", "200"},
      {"STUB_BODY", "ok-body"},
      {"STUB_EXIT", "0"}
    ]

    env = Enum.reduce(env, base, fn {key, value}, acc -> List.keystore(acc, key, 0, {key, value}) end)
    script = ~s(source "#{@scrape_lib}"; source "#{@curl_lib}"; #{command})
    System.cmd(ctx.bash, ["-c", script], env: env, stderr_to_stdout: true)
  end

  defp stdin_entries(ctx) do
    ctx.stdin |> File.read!() |> String.split("\u0000", trim: true)
  end

  defp write_stub!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  # Answers like curl with `-w '\n%{http_code}'`: STUB_BODY, then STUB_STATUS on its own line, or exits
  # with STUB_EXIT. The argv goes to STUB_ARGV_LOG one line per call, the stdin to STUB_STDIN_LOG as it
  # came, NUL-terminated, since a body may hold newlines.
  defp curl_stub do
    ~S"""
    #!/usr/bin/env bash
    printf 'curl %s\n' "$*" >> "$STUB_ARGV_LOG"
    { printf 'curl:'; cat; printf '\0'; } >> "$STUB_STDIN_LOG"
    [ "$STUB_EXIT" = 0 ] || exit "$STUB_EXIT"
    printf '%s\n%s' "$STUB_BODY" "$STUB_STATUS"
    """
  end

  # The real jq, its argv recorded first.
  defp jq_wrapper(jq) do
    """
    #!/usr/bin/env bash
    printf 'jq %s\\n' "$*" >> "$STUB_ARGV_LOG"
    exec "#{jq}" "$@"
    """
  end
end
