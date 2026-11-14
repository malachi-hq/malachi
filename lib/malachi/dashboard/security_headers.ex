defmodule Malachi.Dashboard.SecurityHeaders do
  @moduledoc """
  Security headers for dashboard HTTP responses.

  Implements defense-in-depth security controls:
  - Content Security Policy (CSP)
  - HTTP Strict Transport Security (HSTS)
  - X-Frame-Options (clickjacking prevention)
  - X-Content-Type-Options (MIME sniffing prevention)
  - X-XSS-Protection
  - Referrer-Policy
  - Permissions-Policy (powerful browser features)
  - CORS (Cross-Origin Resource Sharing)
  """

  # The dashboard's own JavaScript only issues fetch and EventSource calls, so it needs none of these
  # browser features. Denying every one of them keeps an injected script from reaching the camera, the
  # credential API or geolocation on the dashboard's origin. Deprecated names (interest-cohort) are left
  # out on purpose: browsers that dropped them answer with an unrecognized-feature console warning.
  @permissions_policy Enum.map_join(
                        ~w(accelerometer autoplay camera display-capture encrypted-media fullscreen
                           geolocation gyroscope magnetometer microphone midi payment
                           picture-in-picture publickey-credentials-get screen-wake-lock usb
                           xr-spatial-tracking),
                        ", ",
                        &"#{&1}=()"
                      )

  @doc """
  Adds security headers to an HTTP response string.

  ## Parameters

  - `response` - HTTP response string (must include status line and headers)
  - `request_path` - Path being accessed (e.g., "/", "/metrics", "/stream")

  ## Returns

  Modified response string with security headers prepended.

  ## Examples

      iex> response = "HTTP/1.1 200 OK\\r\\nContent-Type: text/html\\r\\n\\r\\n<html>"
      iex> with_headers = Malachi.Dashboard.SecurityHeaders.add_security_headers(response, "/")
      iex> String.contains?(with_headers, "Permissions-Policy: accelerometer=(), autoplay=()")
      true

  The full response carries every header this module builds; the exact set depends on configuration
  (the CSP is configurable, HSTS only appears under TLS), which is why the example asserts one line
  instead of spelling the whole response out.
  """
  def add_security_headers(response, request_path, request_origin \\ nil) do
    prepend_headers(response, headers(request_path, request_origin))
  end

  @doc """
  The security headers for a response to `request_path`, as `{name, value}` tuples with lowercase
  names, which is the shape `Plug.Conn` takes. `add_security_headers/3` renders the same list into a
  raw response, so the dashboard and the console endpoint send one set of headers from one place.

  The CSP comes from `build_csp_header/0`, HSTS from `build_hsts_header/0`, and CORS from
  `build_cors_headers/2` unless `cors: false` is passed. The console passes it: CORS is a property of
  the dashboard's `/metrics` and `/stream` routes, and the console serves a page at those paths, not
  the API.

  ## Examples

      iex> headers = Malachi.Dashboard.SecurityHeaders.headers("/", nil, cors: false)
      iex> List.keyfind(headers, "x-frame-options", 0)
      {"x-frame-options", "DENY"}

  """
  @spec headers(String.t(), String.t() | nil, keyword()) :: [{String.t(), String.t()}]
  def headers(request_path, request_origin \\ nil, opts \\ []) do
    base_headers = [
      {"x-content-type-options", "nosniff"},
      {"x-frame-options", "DENY"},
      {"x-xss-protection", "1; mode=block"},
      {"referrer-policy", "no-referrer"},
      {"permissions-policy", @permissions_policy}
    ]

    cors_headers =
      if Keyword.get(opts, :cors, true),
        do: build_cors_headers(request_path, request_origin),
        else: []

    base_headers ++ build_csp_header() ++ build_hsts_header() ++ cors_headers
  end

  # No 'unsafe-inline' and no 'unsafe-eval' (#38): the dashboard's script and stylesheet are files of their own
  # (Malachi.Dashboard.Assets), and no page carries an inline block, an inline handler or a style attribute.
  @default_csp "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'"

  # Source keywords that let injected markup run or style the page. Matched case-insensitively, as browsers do.
  @weak_keywords ["'unsafe-inline'", "'unsafe-eval'", "'unsafe-hashes'"]

  @doc """
  The Content-Security-Policy sent when `MALACHI_DASHBOARD_CSP` is not set.

  ## Examples

      iex> Malachi.Dashboard.SecurityHeaders.default_csp()
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'"

  """
  @spec default_csp() :: String.t()
  def default_csp, do: @default_csp

  @doc """
  The operator's policy from `:dashboard_csp` (`MALACHI_DASHBOARD_CSP`), or `nil` when there is none. A value
  that is empty or only whitespace counts as none: sent as is it would be an empty header, which is no policy at
  all, the opposite of what anyone setting the variable wants.
  """
  @spec csp_override() :: String.t() | nil
  def csp_override do
    case Application.get_env(:malachi, :dashboard_csp) do
      csp when is_binary(csp) -> if String.trim(csp) == "", do: nil, else: csp
      _unset -> nil
    end
  end

  @doc """
  Whether `csp` allows any of `'unsafe-inline'`, `'unsafe-eval'` or `'unsafe-hashes'`, in any letter case.
  `Malachi.Dashboard` warns at boot when the operator's policy does.

  ## Examples

      iex> Malachi.Dashboard.SecurityHeaders.weak_csp?("script-src 'self' 'UNSAFE-INLINE'")
      true

      iex> Malachi.Dashboard.SecurityHeaders.weak_csp?(Malachi.Dashboard.SecurityHeaders.default_csp())
      false

  """
  @spec weak_csp?(String.t()) :: boolean()
  def weak_csp?(csp) do
    lowered = String.downcase(csp)
    Enum.any?(@weak_keywords, &String.contains?(lowered, &1))
  end

  @doc """
  Builds the Content-Security-Policy header: the operator's policy when `csp_override/0` has one, otherwise
  `default_csp/0`, which allows nothing inline.

  The same policy covers the dashboard (both HTML pages and their assets) and the console endpoint, which takes
  its headers from `headers/3`.
  """
  def build_csp_header do
    [{"content-security-policy", csp_override() || @default_csp}]
  end

  @doc """
  Builds HTTP Strict Transport Security header.

  Only included when TLS is enabled. Instructs browsers to only connect via HTTPS
  for the specified duration (default: 1 year).
  """
  def build_hsts_header do
    tls_enabled = Application.get_env(:malachi, :enable_tls, false)
    hsts_enabled = Application.get_env(:malachi, :hsts_enabled, true)

    if tls_enabled and hsts_enabled do
      max_age = Application.get_env(:malachi, :hsts_max_age, 31_536_000)
      include_subdomains = Application.get_env(:malachi, :hsts_include_subdomains, true)

      hsts_value =
        if include_subdomains do
          "max-age=#{max_age}; includeSubDomains"
        else
          "max-age=#{max_age}"
        end

      [{"strict-transport-security", hsts_value}]
    else
      []
    end
  end

  @doc """
  Builds CORS headers for API endpoints.

  CORS is only enabled for `/metrics` and `/stream` endpoints when explicitly configured. With the default
  wildcard whitelist every origin gets `*`; with an explicit whitelist the request's own `Origin` is echoed
  back, and only when it is listed, since `Access-Control-Allow-Origin` accepts a single origin. An origin
  outside the whitelist (or a request with no `Origin`) gets no allow header, which the browser reads as not
  allowed, but still gets `Vary: origin` so a cache cannot reuse that denial for a whitelisted origin.

  Returns a list of `{name, value}` tuples, empty when CORS does not apply at all. `Malachi.Dashboard` uses
  it for both the real responses and the `OPTIONS` preflight, so a preflight can never advertise a permission
  the actual request would not receive.

  ## Configuration

      export MALACHI_DASHBOARD_CORS_ENABLED=true
      export MALACHI_DASHBOARD_CORS_ORIGINS="https://app.example.com,https://admin.example.com"
  """
  def build_cors_headers(request_path, request_origin \\ nil) do
    # CORS only for API endpoints, and only when turned on
    if request_path in ["/metrics", "/stream"] and
         Application.get_env(:malachi, :dashboard_cors_enabled, false) do
      origins = Application.get_env(:malachi, :dashboard_cors_origins, ["*"])

      cors_headers_for(origins, allowed_origin(origins, request_origin))
    else
      []
    end
  end

  defp cors_headers_for(origins, allowed) do
    # Under a wildcard every origin gets the same answer, so the response does not vary. Under an explicit
    # whitelist it does, and `Vary` has to be there even when the origin is refused: otherwise a cache can
    # store the header-less denial and later replay it to a whitelisted origin.
    vary = if "*" in origins, do: [], else: [{"vary", "origin"}]

    allow =
      case allowed do
        nil ->
          []

        origin ->
          [
            {"access-control-allow-origin", origin},
            {"access-control-allow-methods", "GET, OPTIONS"},
            {"access-control-allow-headers", "Authorization, Content-Type"},
            {"access-control-max-age", "86400"}
          ]
      end

    allow ++ vary
  end

  # A wildcard whitelist answers "*" to everyone. Otherwise the request's own Origin is echoed back, and only
  # when it is whitelisted: `Access-Control-Allow-Origin` takes a single origin, so listing several of them
  # (the previous behavior) produced a header browsers reject, which silently broke a multi-origin whitelist.
  # nil means not allowed: no Origin on the request, or one outside the list.
  defp allowed_origin(origins, request_origin) do
    cond do
      "*" in origins -> "*"
      request_origin in origins -> request_origin
      true -> nil
    end
  end

  @doc """
  Prepends headers to an HTTP response string.

  Inserts headers after the status line, before existing headers.

  ## Examples

      iex> response = "HTTP/1.1 200 OK\\r\\nContent-Type: text/html\\r\\n\\r\\nBody"
      iex> headers = [{"x-frame-options", "DENY"}]
      iex> Malachi.Dashboard.SecurityHeaders.prepend_headers(response, headers)
      "HTTP/1.1 200 OK\\r\\nX-Frame-Options: DENY\\r\\nContent-Type: text/html\\r\\n\\r\\nBody"
  """
  def prepend_headers(response, headers) do
    # Split response into status line and rest
    case String.split(response, "\r\n", parts: 2) do
      [status_line, rest] ->
        # Build header strings
        header_strings =
          Enum.map(headers, fn {key, value} ->
            # Capitalize header names (X-Frame-Options, not x-frame-options)
            formatted_key =
              key
              |> String.split("-")
              |> Enum.map_join("-", &String.capitalize/1)

            "#{formatted_key}: #{value}\r\n"
          end)

        # Reconstruct response with security headers first
        status_line <> "\r\n" <> Enum.join(header_strings, "") <> rest

      _ ->
        # Malformed response, return as-is
        response
    end
  end
end
