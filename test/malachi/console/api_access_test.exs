defmodule Malachi.Console.ApiAccessTest do
  # `GET /api/v1/sessions` and `GET /api/v1/lockouts`, at the admin role, against the test node's own
  # session table and lockout store.
  #
  # async: false. Sessions, lockouts and the rate limiter are the node's.
  use ExUnit.Case, async: false

  alias Malachi.Auth.LockoutManager
  alias Malachi.Console.Access
  alias Malachi.Console.AccessView
  alias Malachi.Console.Sampler
  alias Malachi.Test.AccessHelper

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    %{token: AccessHelper.account!("sessions_admin", [], :admin)}
  end

  defp get(path, token), do: AccessHelper.call(:console, "GET", path, token, [])

  test "an admin sees each active session named by its digest, never by its token", %{token: token} do
    assert %{status: 200, json: body, body: raw} = get("/api/v1/sessions?page_size=1000", token)
    digest = Access.session_digest(token)
    assert [mine] = Enum.filter(body["sessions"], &(&1["session"] == digest))

    assert %{"username" => "sessions_admin", "ip" => "127.0.0.1", "ip_binding" => true} = mine
    assert mine["node"] == Atom.to_string(node())
    assert {:ok, _created, 0} = DateTime.from_iso8601(mine["created_at"])
    assert {:ok, _expires, 0} = DateTime.from_iso8601(mine["expires_at"])

    # no part of a token reaches the listing: not the whole, not the eight character prefix
    refute raw =~ token
    refute raw =~ String.slice(token, 0, 8)
    refute Map.has_key?(mine, "token_prefix")
    assert %{"unanswered_nodes" => [], "unsupported_nodes" => [], "complete" => true} = body
  end

  test "sessions are paged in the order they were created", %{token: token} do
    # The walk reads every session the node holds, a few per request, and a node that ran the whole suite
    # holds hundreds: the session's own API budget (300 a minute) would refuse it partway, which is not what
    # this test is about (api_me_test covers the budget). A limit of 0 turns the budget off.
    Application.put_env(:malachi, :dashboard_api_rate_limit, 0)
    on_exit(fn -> Application.delete_env(:malachi, :dashboard_api_rate_limit) end)
    _other = AccessHelper.account!("sessions_other", [], :viewer)

    walk = fn walk, query, acc ->
      assert %{status: 200, json: body} = get("/api/v1/sessions?" <> query, token)
      acc = acc ++ body["sessions"]

      case body["next_page_token"] do
        "" -> acc
        next -> walk.(walk, "page_size=2&page_token=" <> next, acc)
      end
    end

    sessions = walk.(walk, "page_size=2", [])
    assert length(sessions) >= 2
    assert sessions == Enum.uniq(sessions)
    created = Enum.map(sessions, & &1["created_at"])
    assert created == Enum.sort(created)

    b64 = &Base.url_encode64(&1, padding: false)
    assert %{status: 400} = get("/api/v1/sessions?page_token=" <> b64.("v1.sessions.0." <> b64.("x")), token)

    assert %{status: 400} =
             get(
               "/api/v1/sessions?page_token=" <> b64.("v1.sessions.0." <> Enum.map_join(["x", "n", "s"], ".", b64)),
               token
             )
  end

  test "a locked out account is listed with its address and when the lock ends", %{token: token} do
    username = "locked_#{System.unique_integer([:positive])}"
    on_exit(fn -> LockoutManager.unlock_account(username) end)
    # the attempts are written in the background, so the lock is waited for, not assumed
    for _attempt <- 1..10, do: LockoutManager.record_failed_attempt(username, "10.1.2.3")
    assert eventually(fn -> match?({:locked, _ms}, LockoutManager.locked?(username, "10.1.2.3")) end)

    Sampler.clear()
    assert %{status: 200, json: body} = get("/api/v1/lockouts?page_size=1000", token)
    assert body["stale"] == false
    assert [lockout] = Enum.filter(body["lockouts"], &(&1["username"] == username))
    assert %{"ip" => "10.1.2.3", "attempts" => attempts, "remaining_ms" => remaining} = lockout
    assert attempts >= 1 and remaining > 0
    assert {:ok, _until, 0} = DateTime.from_iso8601(lockout["locked_until"])

    # a second lockout pages after the first by token
    other = username <> "_b"
    on_exit(fn -> LockoutManager.unlock_account(other) end)
    for _attempt <- 1..10, do: LockoutManager.record_failed_attempt(other, "10.1.2.4")
    assert eventually(fn -> match?({:locked, _ms}, LockoutManager.locked?(other, "10.1.2.4")) end)
    Sampler.clear()

    pages =
      Stream.unfold("page_size=1", fn
        nil ->
          nil

        query ->
          assert %{status: 200, json: page} = get("/api/v1/lockouts?" <> query, token)
          next = if page["next_page_token"] == "", do: nil, else: "page_size=1&page_token=" <> page["next_page_token"]
          {page["lockouts"], next}
      end)
      |> Enum.concat()
      |> Enum.map(& &1["username"])

    assert username in pages and other in pages
    assert pages == Enum.uniq(pages)

    b64 = &Base.url_encode64(&1, padding: false)
    assert %{status: 400} = get("/api/v1/lockouts?page_token=" <> b64.("v1.lockouts.0." <> b64.("only")), token)
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(check, attempts - 1)
    end
  end

  test "a lockout store that does not answer is a 503, not an empty list", %{token: token} do
    Sampler.clear()
    member = {Malachi.LogLockouts, node()}
    :ok = :sys.suspend(member)

    try do
      assert %{status: 503, json: %{"type" => "errors.http.unavailable"}} = get("/api/v1/lockouts", token)
    after
      :sys.resume(member)
    end
  end

  test "both take an admin" do
    viewer = AccessHelper.account!("sessions_viewer", [], :viewer)

    for path <- ["/api/v1/sessions", "/api/v1/lockouts"] do
      assert %{status: 401} = get(path, nil)
      assert %{status: 403, json: %{"required_role" => "admin", "role" => "viewer"}} = get(path, viewer)
    end
  end

  test "a lockout's address renders whatever shape the store keeps it in" do
    lockout = %{
      username: "u",
      ip: {10, 0, 0, 1},
      attempt_count: 5,
      locked_until: 1_791_720_000_000,
      time_remaining_ms: 10
    }

    assert %{"ip" => "10.0.0.1", "locked_until" => "2026-10-11T12:00:00.000Z"} = AccessView.render_lockout(lockout)
  end
end
