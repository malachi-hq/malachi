defmodule Malachi.Console.ApiMetricsHistoryTest do
  # `GET /api/v1/metrics/history`: the per second history the test node keeps, as columns.
  #
  # async: false. The history table is the node's.
  use ExUnit.Case, async: false

  alias Malachi.Console.Reads
  alias Malachi.Test.AccessHelper

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    %{token: AccessHelper.account!("history_viewer", [], :viewer)}
  end

  defp get(path, token), do: AccessHelper.call(:console, "GET", path, token, [])

  # A sample in the history table at `timestamp`, as `Malachi.Metrics` takes them, with a recognizable run
  # queue so the test reads its own points among the node's.
  defp put_sample!(timestamp, run_queue) do
    system = Malachi.Metrics.get_system_metrics() |> Map.put(:run_queue, run_queue)
    :ets.insert(:malachi_metrics_history, {timestamp, %{timestamp: timestamp, system: system}})
  end

  test "every node's history comes back as aligned columns, oldest first", %{token: token} do
    now = System.system_time(:second)
    put_sample!(now - 2, 9_001)
    put_sample!(now - 1, 9_002)

    assert %{status: 200, json: body} = get("/api/v1/metrics/history?window=10&series=run_queue,memory.total_mb", token)
    assert %{"window_seconds" => 10, "series" => ["run_queue", "memory.total_mb"], "unanswered_nodes" => []} = body
    assert [%{"node" => node_name, "timestamps" => timestamps, "series" => series}] = body["nodes"]
    assert node_name == Atom.to_string(node())

    assert timestamps == Enum.sort(timestamps)
    assert Map.keys(series) == ["memory.total_mb", "run_queue"]
    assert length(series["run_queue"]) == length(timestamps)
    assert length(series["memory.total_mb"]) == length(timestamps)

    points = Enum.zip(timestamps, series["run_queue"])
    assert {now - 2, 9_001} in points
    assert {now - 1, 9_002} in points
    assert Enum.all?(timestamps, &(&1 >= now - 10))
  end

  test "without parameters it is every served series over the last minute", %{token: token} do
    assert %{status: 200, json: %{"window_seconds" => 60, "series" => series, "nodes" => [node_history]}} =
             get("/api/v1/metrics/history", token)

    assert series == Reads.history_series()
    assert Map.keys(node_history["series"]) |> Enum.sort() == Reads.history_series()
  end

  test "an unknown series, a window out of range, or a repeated parameter is a 400", %{token: token} do
    for query <- [
          "series=run_queue,nope",
          "series=",
          "series=,",
          "window=0",
          "window=301",
          "window=x",
          "window=10s",
          "window[]=1",
          "series[]=run_queue"
        ] do
      assert %{status: 400, json: %{"type" => "errors.http.invalid_request"}} =
               get("/api/v1/metrics/history?" <> query, token),
             query
    end
  end

  test "it takes a viewer" do
    wire_only = AccessHelper.account!("history_wire_only", [:produce], nil)
    assert %{status: 401} = get("/api/v1/metrics/history", nil)
    assert %{status: 403} = get("/api/v1/metrics/history", wire_only)
  end

  test "every served series resolves to a number in a real sample" do
    system = Malachi.Metrics.get_system_metrics()
    now = System.system_time(:second)
    :ets.insert(:malachi_metrics_history, {now, %{timestamp: now, system: system}})

    %{series: series} = Reads.metrics_history(5, Reads.history_series())

    for name <- Reads.history_series() do
      assert is_number(List.last(series[name])), "#{name} is not a number in a sample"
    end

    # a name it does not serve is left out
    assert Reads.metrics_history(5, ["nope"]).series == %{}
  end
end
