defmodule Malachi.Dashboard.SecurityHeadersListTest do
  # Not async: the CORS, CSP and HSTS cases rewrite application env other suites read.
  use ExUnit.Case, async: false

  alias Malachi.Dashboard.SecurityHeaders

  @keys [:dashboard_cors_enabled, :dashboard_cors_origins, :dashboard_csp, :enable_tls, :hsts_enabled]

  setup do
    originals = Map.new(@keys, &{&1, Application.fetch_env(:malachi, &1)})

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:malachi, key, value)
        {key, :error} -> Application.delete_env(:malachi, key)
      end)
    end)
  end

  describe "headers/3" do
    test "carries the five base headers with lowercase names" do
      headers = SecurityHeaders.headers("/")

      for name <- ~w(x-content-type-options x-frame-options x-xss-protection referrer-policy permissions-policy) do
        assert List.keymember?(headers, name, 0), "missing #{name}"
      end

      assert Enum.all?(headers, fn {name, _} -> name == String.downcase(name) end)
    end

    test "carries the configured CSP" do
      Application.put_env(:malachi, :dashboard_csp, "default-src 'none'")

      assert {"content-security-policy", "default-src 'none'"} in SecurityHeaders.headers("/")
    end

    test "carries the default CSP, which allows nothing inline, when no override is set" do
      Application.delete_env(:malachi, :dashboard_csp)

      assert {"content-security-policy", csp} = List.keyfind(SecurityHeaders.headers("/"), "content-security-policy", 0)
      assert csp == SecurityHeaders.default_csp()
      refute SecurityHeaders.weak_csp?(csp)
    end

    test "a blank override falls back to the default instead of an empty, policy-less header" do
      for blank <- ["", " ", "\t\n"] do
        Application.put_env(:malachi, :dashboard_csp, blank)

        assert SecurityHeaders.csp_override() == nil
        assert {"content-security-policy", SecurityHeaders.default_csp()} in SecurityHeaders.headers("/")
      end
    end

    test "a non-string override counts as none" do
      Application.put_env(:malachi, :dashboard_csp, nil)
      assert SecurityHeaders.csp_override() == nil

      Application.put_env(:malachi, :dashboard_csp, :strict)
      assert SecurityHeaders.csp_override() == nil
    end

    test "carries HSTS only when TLS and HSTS are both on" do
      Application.put_env(:malachi, :enable_tls, false)
      refute List.keymember?(SecurityHeaders.headers("/"), "strict-transport-security", 0)

      Application.put_env(:malachi, :enable_tls, true)
      Application.put_env(:malachi, :hsts_enabled, true)
      assert List.keymember?(SecurityHeaders.headers("/"), "strict-transport-security", 0)
    end

    test "carries CORS on a CORS route by default and drops it with cors: false" do
      Application.put_env(:malachi, :dashboard_cors_enabled, true)
      Application.put_env(:malachi, :dashboard_cors_origins, ["*"])

      assert {"access-control-allow-origin", "*"} in SecurityHeaders.headers("/metrics")

      refute List.keymember?(
               SecurityHeaders.headers("/metrics", nil, cors: false),
               "access-control-allow-origin",
               0
             )
    end

    test "add_security_headers/3 renders exactly the list headers/3 returns" do
      Application.put_env(:malachi, :dashboard_cors_enabled, true)
      Application.put_env(:malachi, :dashboard_cors_origins, ["*"])
      response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html>"

      assert SecurityHeaders.add_security_headers(response, "/metrics") ==
               SecurityHeaders.prepend_headers(response, SecurityHeaders.headers("/metrics"))
    end
  end

  describe "default_csp/0 and weak_csp?/1" do
    test "the default names 'self' for scripts and styles and nothing unsafe" do
      csp = SecurityHeaders.default_csp()

      assert csp =~ "script-src 'self';"
      assert csp =~ "style-src 'self';"
      refute csp =~ "unsafe"
    end

    test "flags each unsafe keyword in any letter case and nothing else" do
      for keyword <- ["'unsafe-inline'", "'unsafe-eval'", "'unsafe-hashes'", "'UNSAFE-INLINE'", "'Unsafe-Eval'"] do
        assert SecurityHeaders.weak_csp?("default-src 'self'; script-src 'self' #{keyword}"), keyword
      end

      refute SecurityHeaders.weak_csp?("default-src 'none'")
      refute SecurityHeaders.weak_csp?("script-src 'self' 'nonce-abc'")
      # The bare word, without the quotes CSP requires, is a host name to a browser, not the keyword.
      refute SecurityHeaders.weak_csp?("script-src unsafe-inline.example")
    end
  end
end
