defmodule Malachi.Loadtest.ConnAuthTest do
  # Which handshake Malachi.Loadtest.Conn.authenticate/2 makes when several credentials are present. The
  # mix task's moduledoc and docs/guides/running-the-elixir-loadtest.md promise one order (a token over a
  # certificate, either over the user and password), and since #180 a token can arrive from MALACHI_TOKEN
  # without being typed, so the order is what decides the identity of a run. The stub refuses each of
  # the three auth keys with a reason of its own, and the reason that comes back names the key that was
  # sent.
  use ExUnit.Case, async: true

  alias Malachi.Loadtest.Conn
  alias Malachi.Test.StreamStub
  alias Malachi.Wire

  setup do
    stub =
      StreamStub.start(%{
        Wire.token_auth_key() => {:error, "token handshake"},
        Wire.mtls_auth_key() => {:error, "mtls handshake"},
        Wire.auth_key() => {:error, "password handshake"}
      })

    on_exit(fn -> StreamStub.stop(stub) end)
    %{stub: stub}
  end

  defp handshake(stub, credentials) do
    {:ok, conn} = Conn.connect(port: stub.port)
    {:error, reason} = Conn.authenticate(conn, credentials)
    reason
  end

  test "a token wins over a certificate and over a user and password", %{stub: stub} do
    reason = handshake(stub, token: "t", cert: "c.pem", key: "k.pem", user: "u", pass: "p")
    assert inspect(reason) =~ "token handshake"
  end

  test "a certificate wins over a user and password", %{stub: stub} do
    reason = handshake(stub, cert: "c.pem", key: "k.pem", user: "u", pass: "p")
    assert inspect(reason) =~ "mtls handshake"
  end

  test "with neither, the user and password are sent", %{stub: stub} do
    reason = handshake(stub, user: "u", pass: "p")
    assert inspect(reason) =~ "password handshake"
  end
end
