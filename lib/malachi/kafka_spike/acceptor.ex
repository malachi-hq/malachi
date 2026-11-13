defmodule Malachi.KafkaSpike.Acceptor do
  @moduledoc """
  One acceptor of the spike's Kafka listener, run by `Malachi.TCPAcceptorPool` in place of
  `Malachi.TCPAcceptor`: it owns a listen socket on the pool's port, accepts in a loop with the same idle
  backoff, and hands each connection to a fresh process that runs `Malachi.KafkaSpike.Connection`.

  It takes plain TCP only (the pool is started with `tls: false`): the spike has no TLS and no SASL.
  """
  use GenServer
  alias Malachi.KafkaSpike
  alias Malachi.KafkaSpike.Connection

  @doc "Starts an acceptor for `{port, listen_opts, id, :gen_tcp}`, as the pool hands it."
  def start_link({port, opts, id, :gen_tcp}), do: GenServer.start_link(__MODULE__, {port, opts, id})

  @impl true
  def init({port, opts, id}) do
    case :gen_tcp.listen(port, opts) do
      {:ok, socket} ->
        send(self(), :accept)
        {:ok, %{socket: socket, id: id, idle_count: 0}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, %{socket: socket, idle_count: idle_count} = state) do
    case :gen_tcp.accept(socket, min(100 + idle_count * 50, 30_000)) do
      {:ok, client} ->
        hand_off(client)
        send(self(), :accept)
        {:noreply, %{state | idle_count: 0}}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, %{state | idle_count: min(idle_count + 1, 20)}}

      {:error, _reason} ->
        Process.send_after(self(), :accept, 10)
        {:noreply, state}
    end
  end

  defp hand_off(client) do
    pid =
      spawn(fn ->
        receive do
          :socket_ready -> Connection.serve(client, KafkaSpike.ctx(), KafkaSpike.max_frame_size())
        after
          5_000 -> :gen_tcp.close(client)
        end
      end)

    # a client that closed before the hand-off leaves nothing to serve
    case :gen_tcp.controlling_process(client, pid) do
      :ok ->
        send(pid, :socket_ready)

      {:error, _reason} ->
        Process.exit(pid, :kill)
        :gen_tcp.close(client)
    end
  end
end
