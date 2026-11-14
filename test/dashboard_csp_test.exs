defmodule Malachi.DashboardCSPTest do
  # Not async: it rewrites :dashboard_csp, which every dashboard response reads, and starts a second dashboard.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Malachi.Dashboard.Assets
  alias Malachi.Dashboard.SecurityHeaders
  alias Malachi.Test.DashboardHelper

  # #38: no page carries inline script or style, so the policy can forbid both. These run against the
  # application's dashboard over a real socket; the browser half (the page actually working under the policy,
  # with no violation reported) is site/checks/dashboard.mjs.

  @admin "csp_test_admin"
  @password "csp_test_pass_123"

  @dir Path.expand("../priv/static/dashboard", __DIR__)

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    _ = Malachi.Auth.remove_user(@admin)
    :ok = Malachi.Auth.add_user(@admin, @password, [:admin])
    {:ok, token} = Malachi.Auth.authenticate(@admin, @password, {127, 0, 0, 1})

    original_csp = Application.fetch_env(:malachi, :dashboard_csp)
    Application.delete_env(:malachi, :dashboard_csp)

    on_exit(fn ->
      case original_csp do
        {:ok, value} -> Application.put_env(:malachi, :dashboard_csp, value)
        :error -> Application.delete_env(:malachi, :dashboard_csp)
      end

      _ = Malachi.Auth.remove_user(@admin)
      Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    end)

    {:ok, token: token}
  end

  describe "the policy on every dashboard route a browser loads" do
    test "is the default, with nothing inline, on both pages and every asset", %{token: token} do
      for path <- ["/", "/login" | Assets.paths()] do
        response = get(path, token)

        assert response.status == 200, "GET #{path} answered #{response.status}"
        assert [csp] = header_values(response, "content-security-policy"), "GET #{path}"
        assert csp == SecurityHeaders.default_csp(), "GET #{path}"
        refute csp =~ "unsafe", "GET #{path}"
      end
    end

    test "the login redirect carries it too" do
      response = get("/", nil)

      assert response.status == 302
      assert header_values(response, "content-security-policy") == [SecurityHeaders.default_csp()]
    end
  end

  describe "the HTML pages" do
    for {path, own_script, other_script} <- [{"/", "/app.js", "/login.js"}, {"/login", "/login.js", "/app.js"}] do
      test "#{path} has no inline script, style, handler or style attribute", %{token: token} do
        html = get(unquote(path), token).body

        refute html =~ ~r/<style/i
        refute html =~ ~r/\sstyle\s*=/i
        refute html =~ ~r/\son[a-z]+\s*=/i
        refute html =~ ~r/javascript:/i

        # Every script tag loads a file and has an empty body.
        scripts = Regex.scan(~r/<script\b([^>]*)>(.*?)<\/script>/is, html)
        assert scripts != []

        for [_tag, attributes, body] <- scripts do
          assert attributes =~ ~r/\ssrc="/, "a script without src: #{attributes}"
          assert String.trim(body) == "", "a script with a body: #{body}"
        end
      end

      test "#{path} loads the stylesheet and its own script by their current versioned URLs", %{token: token} do
        html = get(unquote(path), token).body

        assert html =~ ~s(<link rel="stylesheet" href="#{Assets.versioned_path("/app.css")}">)
        assert html =~ ~s(<script src="#{Assets.versioned_path(unquote(own_script))}" defer></script>)
        refute html =~ unquote(other_script)
      end
    end

    test "the topic list the dashboard script fills is on the page", %{token: token} do
      html = get("/", token).body

      for id <- ~w(processes memory topics), do: assert(html =~ ~s(id="#{id}"))
    end

    test "the login form the login script binds is on the page" do
      html = get("/login", nil).body

      for id <- ~w(loginForm error username password loginBtn), do: assert(html =~ ~s(id="#{id}"))
      assert html =~ ~s(<body class="login-page">)
      # Without the script the browser submits the form itself; it must never be a GET with the password in the URL.
      assert html =~ ~s(<form id="loginForm" method="post" action="/login">)
    end
  end

  test "the form the browser submits on its own, without login.js, is refused and logs no one in" do
    {:ok, socket} = DashboardHelper.connect()

    :ok =
      DashboardHelper.send_request(socket, :POST, "/login",
        headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
        body: "username=#{@admin}&password=#{@password}"
      )

    {:ok, response} = DashboardHelper.recv_framed(socket)
    :gen_tcp.close(socket)

    assert response.status == 400
    assert header_values(response, "set-cookie") == []
  end

  describe "the assets" do
    for path <- Assets.paths() do
      test "#{path} is served without credentials, as the repository file, typed and not sniffable" do
        response = get(Assets.versioned_path(unquote(path)), nil)
        {:ok, asset} = Assets.fetch(unquote(path))

        assert response.status == 200
        assert response.body == File.read!(Path.join(@dir, Path.basename(unquote(path))))
        assert header_values(response, "content-type") == [asset.content_type]
        assert header_values(response, "x-content-type-options") == ["nosniff"]
      end

      # A rolling upgrade can send the new page's asset request to an old node: whatever v the request names,
      # the node answers with its own bytes, and caches them for a year only under its own version.
      test "#{path} is cached for a year only under this build's version, and served under any" do
        current = Assets.versioned_path(unquote(path))
        [_, version] = String.split(current, "?v=")
        immutable = "public, max-age=31536000, immutable"

        cases = [
          {current, immutable},
          {current <> "&x=1", immutable},
          {unquote(path) <> "?x=1&v=" <> version, immutable},
          {unquote(path) <> "?v=000000000000", "no-store"},
          {unquote(path) <> "?v=" <> String.upcase(version), "no-store"},
          {unquote(path) <> "?v=" <> binary_part(version, 0, 11), "no-store"},
          {unquote(path) <> "?v=", "no-store"},
          {unquote(path) <> "?v=%zz", "no-store"},
          {unquote(path), "no-store"}
        ]

        bodies =
          for {url, cache_control} <- cases do
            response = get(url, nil)
            assert response.status == 200, url
            assert header_values(response, "cache-control") == [cache_control], url
            response.body
          end

        assert bodies |> Enum.uniq() |> length() == 1
      end
    end

    test "a path near an asset is not public" do
      for path <- ["/app.js.map", "/foo.js", "/dashboard/app.js"] do
        assert get(path, nil).status == 401, path
      end
    end

    test "a method other than GET on an asset is not served" do
      response = request(:POST, "/app.js", nil)

      assert response.status == 401
    end
  end

  describe "the scripts as shipped" do
    for file <- ["app.js", "login.js"] do
      test "#{file} builds no inline handler and no style attribute" do
        source = File.read!(Path.join(@dir, unquote(file)))

        refute source =~ ~r/\son[a-z]+\s*=\s*["'`$]/i
        refute source =~ ~r/\sstyle\s*=\s*["'`$]/i
        refute source =~ ~r/\beval\s*\(|new Function\s*\(/
      end
    end

    test "app.css carries every class the pages and the script use instead of style attributes" do
      css = File.read!(Path.join(@dir, "app.css"))

      for selector <- [".brand-logo", ".topic-groups", ".login-page .brand-logo", "body.login-page"] do
        assert css =~ selector, selector
      end
    end
  end

  describe "the boot warning for a weak override" do
    test "is logged when the override allows inline code" do
      log = start_dashboard_capturing("default-src 'self'; script-src 'self' 'unsafe-inline'")

      assert log =~ "MALACHI_DASHBOARD_CSP allows inline code or eval"
      assert log =~ "script-src 'self' 'unsafe-inline'"
    end

    test "is not logged for the default or a strict override" do
      for csp <- [nil, "", "default-src 'none'"] do
        refute start_dashboard_capturing(csp) =~ "MALACHI_DASHBOARD_CSP allows", inspect(csp)
      end
    end
  end

  defp start_dashboard_capturing(csp) do
    if csp,
      do: Application.put_env(:malachi, :dashboard_csp, csp),
      else: Application.delete_env(:malachi, :dashboard_csp)

    name = :"csp_test_dashboard_#{System.unique_integer([:positive])}"

    capture_log([level: :warning], fn ->
      {:ok, pid} = Malachi.Dashboard.start_link({0, name: name})
      # The dashboard sits in a blocking accept, so it cannot answer GenServer.stop; the warning is logged in
      # init/1, before start_link returns, and a kill closes the listen socket with the process.
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end)
  end

  defp get(path, token), do: request(:GET, path, token)

  defp request(method, path, token) do
    {:ok, socket} = DashboardHelper.connect()
    headers = if token, do: %{"Cookie" => "malachi_token=#{token}"}, else: %{}
    :ok = DashboardHelper.send_request(socket, method, path, headers: headers)
    {:ok, response} = DashboardHelper.recv_framed(socket)
    :gen_tcp.close(socket)
    response
  end

  defp header_values(response, name), do: for({^name, value} <- response.headers, do: value)
end
