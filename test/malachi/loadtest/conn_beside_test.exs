defmodule Malachi.Loadtest.ConnBesideTest do
  # A request on a connection that also carries pushes (`Conn.request_beside/4`), as a routing client reads
  # the routes again over a connection its streams are open on, over a loopback socket whose far end a
  # process of the test answers from.
  use ExUnit.Case, async: true

  alias Malachi.Loadtest.Conn
  alias Malachi.Test.PollingHelper
  alias Malachi.Wire

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: 0, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, conn} = Conn.connect(host: "127.0.0.1", port: port)
    {:ok, far} = :gen_tcp.accept(listen)
    %{conn: conn, far: far}
  end

  # The far end, from another process: once the request has come, it writes `frames`, one send each, and
  # then closes when asked to.
  defp answer_with(far, frames, then \\ :stay) do
    test = self()

    pid =
      spawn(fn ->
        receive do
          :go ->
            {:ok, _request} = :gen_tcp.recv(far, 0, 2_000)
            Enum.each(frames, &(:ok = :gen_tcp.send(far, &1)))
            if then == :close, do: :gen_tcp.close(far)
            send(test, :answered)
            receive(do: (:stop -> :ok))
        end
      end)

    :ok = :gen_tcp.controlling_process(far, pid)
    send(pid, :go)
    on_exit(fn -> send(pid, :stop) end)
  end

  # Takes the socket messages an owner would, activating again after each, until `n` frames came out.
  defp frames_taken(conn, n, acc \\ [])
  defp frames_taken(_conn, n, acc) when length(acc) >= n, do: Enum.map(acc, &Wire.decode_response/1)

  defp frames_taken(%Conn{socket: socket} = conn, n, acc) do
    receive do
      {:tcp, ^socket, _data} = message ->
        {:frames, bodies, conn} = Conn.message(conn, message)
        :ok = Conn.activate(conn)
        frames_taken(conn, n, acc ++ bodies)
    after
      2_000 -> flunk("#{length(acc)} of #{n} frames reached the owner")
    end
  end

  defp delivered?(socket), do: match?({:messages, [{:tcp, ^socket, _} | _]}, Process.info(self(), :messages))

  test "the answer comes back, and every push around it reaches the owner in order", %{conn: conn, far: far} do
    :ok = Conn.activate(conn)
    # a push the socket delivered before the request went out: older than anything read after
    :ok = :gen_tcp.send(far, Wire.encode_ok(100, "p0"))
    PollingHelper.wait_until!(fn -> delivered?(conn.socket) end)

    answer_with(far, [Wire.encode_ok(101, "a"), Wire.encode_ok(7, "answer"), Wire.encode_ok(102, "b")])

    assert {:ok, 0, "answer", conn} = Conn.request_beside(conn, Wire.topic_routes_key(), 7, "q")
    assert frames_taken(conn, 3) == [{100, 0, "p0"}, {101, 0, "a"}, {102, 0, "b"}]
  end

  test "a push read before the answer reaches the owner even when nothing follows it", %{conn: conn, far: far} do
    :ok = Conn.activate(conn)
    answer_with(far, [Wire.encode_ok(101, "a") <> Wire.encode_ok(7, "answer")])

    assert {:ok, 0, "answer", conn} = Conn.request_beside(conn, Wire.topic_routes_key(), 7, "q")
    assert frames_taken(conn, 1) == [{101, 0, "a"}]
  end

  test "a connection that closes while waiting answers an error, and its owner is told", %{conn: conn, far: far} do
    :ok = Conn.activate(conn)
    answer_with(far, [Wire.encode_ok(101, "a")], :close)

    assert {:error, :closed} = Conn.request_beside(conn, Wire.topic_routes_key(), 7, "q")
    socket = conn.socket
    assert_receive {:tcp_closed, ^socket}, 2_000
  end

  test "a passive connection stays passive, the pushes kept in its buffer", %{conn: conn, far: far} do
    answer_with(far, [Wire.encode_ok(101, "a") <> Wire.encode_ok(7, "answer")])

    assert {:ok, 0, "answer", conn} = Conn.request_beside(conn, Wire.topic_routes_key(), 7, "q")
    socket = conn.socket
    refute_receive {:tcp, ^socket, _}, 100
    assert {:ok, body, %Conn{buffer: ""}} = Conn.recv_frame(conn, 0)
    assert Wire.decode_response(body) == {101, 0, "a"}
  end
end
