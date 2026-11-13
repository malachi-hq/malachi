defmodule Malachi.Test.StubAcceptor do
  @moduledoc """
  An acceptor for `Malachi.TCPAcceptorPool` that only opens its listen socket and keeps it, so a test can
  start a pool with an acceptor module of its own and read back what the pool handed it.
  """
  use GenServer

  @doc "Starts the stub with the arguments the pool hands every acceptor."
  def start_link({port, opts, id, transport}), do: GenServer.start_link(__MODULE__, {port, opts, id, transport})

  @impl true
  def init({port, opts, id, transport}) do
    case transport.listen(port, opts) do
      {:ok, socket} -> {:ok, %{socket: socket, id: id, transport: transport, opts: opts}}
      {:error, reason} -> {:stop, reason}
    end
  end
end
