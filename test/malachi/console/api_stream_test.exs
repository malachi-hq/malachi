defmodule Malachi.Console.ApiStreamTest do
  # `GET /api/v1/stream` over a real socket to the console endpoint, against a hub of the test's own that
  # reads overviews the test sets, so every event is one the test caused.
  #
  # async: false. The endpoint and its stream options are the node's.
  use ExUnit.Case, async: false

  alias Malachi.Console.Endpoint
  alias Malachi.Console.Stream, as: ConsoleStream
  alias Malachi.Console.StreamHub
  alias Malachi.Test.AccessHelper
  alias Malachi.Test.HttpClient

  doctest Malachi.Console.Stream

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    {:ok, source} = Agent.start_link(fn -> {:ok, overview(0)} end)
    name = :"stream_hub_#{System.unique_integer([:positive])}"

    start_supervised!(
      {StreamHub, name: name, read: fn -> Agent.get(source, & &1) end, interval_ms: 3_600_000, ring_size: 3}
    )

    Application.put_env(:malachi, :console_stream, hub: name, heartbeat_ms: 200)
    on_exit(fn -> Application.delete_env(:malachi, :console_stream) end)

    %{hub: name, source: source, token: AccessHelper.account!("stream_viewer", [], :viewer)}
  end

  defp overview(run_queue), do: %{"system" => %{"run_queue" => run_queue}, "topics" => %{}}

  # Sets the next overview and lets the hub sample it, waiting until it has.
  defp next!(%{hub: hub, source: source}, run_queue) do
    Agent.update(source, fn _ -> {:ok, overview(run_queue)} end)
    send(Process.whereis(hub), :tick)
    _ = :sys.get_state(hub)
  end

  # A stream kept open by another client, so the hub goes on sampling while the one under test is away (with
  # nobody watching it samples nothing, and a returning client gets what changed as a single delta).
  defp keep_watching(token) do
    stream = open(token)
    {_retry, stream} = next_block(stream)
    {_snapshot, stream} = next_block(stream)
    on_exit(fn -> :gen_tcp.close(stream.socket) end)
    stream
  end

  # Opens the stream and answers the status line, the headers and a reader of what follows.
  defp open(token, headers \\ []) do
    {:ok, socket} = HttpClient.connect(Endpoint.port())
    auth = if token, do: [{"Authorization", "Bearer #{token}"}], else: []
    :ok = HttpClient.send_raw(socket, HttpClient.encode("GET", "/api/v1/stream", auth ++ headers))
    {head, rest} = read_head(socket, "")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_version, status | _reason] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{socket: socket, status: String.to_integer(status), headers: headers, buffer: rest}
  end

  defp read_head(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] -> {head, rest}
      [_partial] -> read_head(socket, buffer <> recv!(socket))
    end
  end

  defp recv!(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    data
  end

  # The next Server-Sent Events block (up to a blank line) of a chunked body, as `{block, stream}`.
  defp next_block(%{socket: socket, buffer: buffer} = stream) do
    {body, rest} = dechunk(buffer)

    case String.split(body, "\n\n", parts: 2) do
      [block, more] -> {block, %{stream | buffer: rechunk(more) <> rest}}
      [_partial] -> next_block(%{stream | buffer: buffer <> recv!(socket)})
    end
  end

  # Takes every complete chunk off the front of `buffer`, joined, and what is left.
  defp dechunk(buffer, acc \\ "") do
    with [size_line, rest] <- String.split(buffer, "\r\n", parts: 2),
         {size, ""} <- Integer.parse(size_line, 16),
         <<data::binary-size(size), "\r\n", more::binary>> <- rest do
      dechunk(more, acc <> data)
    else
      _incomplete -> {acc, buffer}
    end
  end

  defp rechunk(""), do: ""
  defp rechunk(data), do: Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"

  defp event(block) do
    for line <- String.split(block, "\n"), [key, value] = String.split(line, ": ", parts: 2), into: %{} do
      if key == "data", do: {key, Jason.decode!(value)}, else: {key, value}
    end
  end

  test "the stream opens with an explicit retry and a snapshot, then carries numbered deltas", ctx do
    stream = open(ctx.token)
    assert stream.status == 200
    assert stream.headers["content-type"] =~ "text/event-stream"
    assert stream.headers["cache-control"] == "no-store"

    assert {"retry: 5000", stream} = next_block(stream)
    assert {snapshot, stream} = next_block(stream)
    assert %{"event" => "snapshot", "id" => snapshot_id, "data" => %{"system" => %{"run_queue" => 0}}} = event(snapshot)

    next!(ctx, 1)
    assert {delta, _stream} = next_block(stream)
    assert %{"event" => "overview", "id" => id, "data" => %{"system" => %{"run_queue" => 1}}} = event(delta)
    assert id != snapshot_id
    :gen_tcp.close(stream.socket)
  end

  test "a dropped connection resumes from its last id with nothing skipped or repeated", ctx do
    keep_watching(ctx.token)
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {snapshot, stream} = next_block(stream)
    %{"id" => seen} = event(snapshot)
    :gen_tcp.close(stream.socket)

    # what happened while it was away
    next!(ctx, 1)
    next!(ctx, 2)

    resumed = open(ctx.token, [{"Last-Event-ID", seen}])
    {_retry, resumed} = next_block(resumed)
    {first, resumed} = next_block(resumed)
    {second, _resumed} = next_block(resumed)
    assert %{"data" => %{"system" => %{"run_queue" => 1}}} = event(first)
    assert %{"data" => %{"system" => %{"run_queue" => 2}}} = event(second)
    :gen_tcp.close(resumed.socket)
  end

  test "an id the ring no longer holds is reported as a gap, then a snapshot", ctx do
    keep_watching(ctx.token)
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {snapshot, stream} = next_block(stream)
    %{"id" => seen} = event(snapshot)
    :gen_tcp.close(stream.socket)

    # the ring holds 3: five events lose the first two
    for n <- 1..5, do: next!(ctx, n)

    resumed = open(ctx.token, [{"Last-Event-ID", seen}])
    {_retry, resumed} = next_block(resumed)
    {gap, resumed} = next_block(resumed)
    {snapshot, _resumed} = next_block(resumed)
    assert %{"event" => "gap", "data" => %{"dropped" => 2, "reason" => "expired", "from" => ^seen}} = event(gap)
    assert %{"event" => "snapshot", "data" => %{"system" => %{"run_queue" => 5}}} = event(snapshot)
    :gen_tcp.close(resumed.socket)
  end

  test "a quiet stream sends a heartbeat comment", ctx do
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {_snapshot, stream} = next_block(stream)
    assert {": heartbeat", _stream} = next_block(stream)
    :gen_tcp.close(stream.socket)
  end

  test "an error after the stream opened is an event on it, not a change of status", ctx do
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {_snapshot, stream} = next_block(stream)

    Agent.update(ctx.source, fn _ -> {:error, :down} end)
    send(Process.whereis(ctx.hub), :tick)
    assert {error, _stream} = next_block(stream)
    assert %{"event" => "error", "data" => %{"type" => "errors.http.unavailable"}} = event(error)
    :gen_tcp.close(stream.socket)
  end

  test "before the stream opens a refusal keeps its status, as a problem" do
    assert %{status: 401, headers: %{"content-type" => "application/problem+json"}} = open(nil)
    wire_only = AccessHelper.account!("stream_wire_only", [:produce], nil)
    assert %{status: 403, headers: %{"content-type" => "application/problem+json"}} = open(wire_only)
  end

  test "a client that returns after nobody watched gets what changed as one delta", ctx do
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {snapshot, stream} = next_block(stream)
    %{"id" => seen} = event(snapshot)
    :gen_tcp.close(stream.socket)
    wait_until(fn -> :sys.get_state(ctx.hub).subscribers == %{} end)

    # nobody is watching: these are not sampled one by one
    next!(ctx, 1)
    next!(ctx, 2)

    resumed = open(ctx.token, [{"Last-Event-ID", seen}])
    {_retry, resumed} = next_block(resumed)
    {delta, _resumed} = next_block(resumed)
    assert %{"event" => "overview", "data" => %{"system" => %{"run_queue" => 2}}} = event(delta)
    :gen_tcp.close(resumed.socket)
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        wait_until(check, attempts - 1)
    end
  end

  test "a stream whose hub restarts goes on from the new hub with a gap and a snapshot", ctx do
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {snapshot, stream} = next_block(stream)
    %{"id" => seen} = event(snapshot)

    old = Process.whereis(ctx.hub)
    Process.exit(old, :kill)
    wait_until(fn -> Process.whereis(ctx.hub) not in [nil, old] end)

    {gap, stream} = next_block(stream)
    {resync, stream} = next_block(stream)
    assert %{"event" => "gap", "data" => %{"reason" => "unknown", "from" => ^seen, "dropped" => nil}} = event(gap)
    assert %{"event" => "snapshot"} = event(resync)

    # and it carries the new hub's events
    next!(ctx, 7)
    {delta, _stream} = next_block(stream)
    assert %{"event" => "overview", "data" => %{"system" => %{"run_queue" => 7}}} = event(delta)
    :gen_tcp.close(stream.socket)
  end

  test "a heartbeat setting that is not a positive integer falls back to 15 s" do
    for invalid <- [0, -1, "x"] do
      Application.put_env(:malachi, :console_stream_heartbeat_ms, invalid)
      assert ConsoleStream.heartbeat_ms() == 15_000
    end

    Application.delete_env(:malachi, :console_stream_heartbeat_ms)
  end

  test "a closed stream leaves the hub", ctx do
    stream = open(ctx.token)
    {_retry, stream} = next_block(stream)
    {_snapshot, stream} = next_block(stream)
    assert map_size(:sys.get_state(ctx.hub).subscribers) == 1
    :gen_tcp.close(stream.socket)

    # the closed socket shows on the next write, the heartbeat at the latest
    next!(ctx, 1)
    wait_until(fn -> :sys.get_state(ctx.hub).subscribers == %{} end)
  end
end
