# How long a node's broker loop keeps a caller waiting, sampled from outside (issue #283).
#
# `GET /ready` answers from `Malachi.BrokerServer.metadata_ready?/2`, a call into the broker's own loop with a
# one second bound (`Malachi.Dashboard`), so its latency is how long that loop made a client wait, read the
# same way on any build. Run inside the cluster's compose network by benchmark/loop_stall_cluster.sh:
#
#   PROBE_HOST=malachi1 PROBE_SECONDS=55 mix run --no-start benchmark/support/ready_probe.exs
#
# Prints one marked JSON line: every sample as [offset_ms, latency_us, status], offset from the probe's start.
# With PROBE_TOPICS=N it first creates N single-range topics through the node's wire port and writes one
# record to each, so the node has active ranges to recover.

defmodule ReadyProbe do
  @marker "READY_PROBE "
  @interval_ms 20
  @request_timeout_ms 3_000

  def run do
    host = System.get_env("PROBE_HOST", "malachi1")
    seconds = String.to_integer(System.get_env("PROBE_SECONDS", "55"))
    topics = String.to_integer(System.get_env("PROBE_TOPICS", "0"))
    {:ok, _apps} = Application.ensure_all_started(:inets)

    if topics > 0, do: seed_topics(host, topics)
    IO.puts("READY_PROBE_STARTED")

    started = System.monotonic_time(:millisecond)
    samples = sample(host, started, started + seconds * 1_000, [])
    IO.puts(@marker <> Jason.encode!(%{host: host, interval_ms: @interval_ms, samples: samples}))
  end

  defp sample(host, started, deadline, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      Enum.reverse(acc)
    else
      {elapsed_us, status} = :timer.tc(fn -> ready(host) end)
      Process.sleep(@interval_ms)
      sample(host, started, deadline, [[now - started, elapsed_us, status] | acc])
    end
  end

  defp ready(host) do
    url = ~c"http://#{host}:4041/ready"

    case :httpc.request(:get, {url, []}, [timeout: @request_timeout_ms], []) do
      {:ok, {{_version, status, _reason}, _headers, _body}} -> status
      {:error, reason} -> inspect(reason)
    end
  end

  defp seed_topics(host, count) do
    {:ok, client} =
      Malachi.Loadtest.Client.connect(host: host, port: 4040, user: "admin", pass: "admin123")

    for i <- 1..count do
      topic = "stall_#{i}"
      _ = Malachi.Loadtest.Client.create_topic(client, topic, 4)
      {:ok, _} = produce_once_placed(client, topic, System.monotonic_time(:millisecond) + 30_000)
    end

    Malachi.Loadtest.Client.close(client)
  end

  # A topic just created is not placed on every node at once: until it is, a produce answers `no_such_range`.
  defp produce_once_placed(client, topic, deadline) do
    case Malachi.Loadtest.Client.produce(client, topic, [Malachi.Log.Record.new("v", key: "k")], 5_000) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        if System.monotonic_time(:millisecond) >= deadline do
          error
        else
          Process.sleep(100)
          produce_once_placed(client, topic, deadline)
        end
    end
  end
end

ReadyProbe.run()
