defmodule Malachi.Console.AccessView do
  @moduledoc """
  The Access view's sessions and lockouts (section 6.10 of `docs/design/operator-interfaces.md`), for
  `GET /api/v1/sessions` and `GET /api/v1/lockouts`, both at the `admin` role since they name users and
  the addresses they come from.

  **Sessions** are per node: each node keeps its own, so the listing gathers every alive node's
  (`Malachi.Console.Reads.sessions/0`). A session is named by its digest
  (`Malachi.Console.Access.session_digest/1`), never by any part of its token, which would hand a live
  session to whoever reads the listing.

  **Lockouts** are replicated: every node's replica of the lockout store holds the whole cluster's
  (`Malachi.Auth.LockoutManager.locked_accounts/0`), so the node that answers reads its own.
  """

  alias Malachi.IPAddress

  @doc "A session as JSON. Its times are Unix seconds in the store, rendered as ISO 8601."
  @spec render_session(map()) :: map()
  def render_session(session) do
    %{
      "session" => session.session,
      "node" => session.node,
      "username" => session.username,
      "ip" => session.ip,
      "ip_binding" => not session.ip_binding_disabled,
      "created_at" => iso8601(session.created_at, :second),
      "last_activity" => iso8601(session.last_activity, :second),
      "expires_at" => iso8601(session.expires_at, :second)
    }
  end

  @doc "A lockout as JSON. Its times are Unix milliseconds in the store."
  @spec render_lockout(map()) :: map()
  def render_lockout(lockout) do
    %{
      "username" => lockout.username,
      "ip" => IPAddress.format(lockout.ip),
      "attempts" => lockout.attempt_count,
      "locked_until" => iso8601(lockout.locked_until, :millisecond),
      "remaining_ms" => lockout.time_remaining_ms
    }
  end

  defp iso8601(nil, _unit), do: nil
  defp iso8601(time, unit), do: time |> DateTime.from_unix!(unit) |> DateTime.to_iso8601()
end
