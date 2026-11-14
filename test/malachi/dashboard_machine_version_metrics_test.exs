defmodule Malachi.DashboardMachineVersionMetricsTest do
  # The machine version gauges reach the scrape: `GET /metrics` asking for text/plain carries
  # `malachi_ra_machine_version` and `malachi_ra_machine_version_stuck` for the replicated stores the test
  # node hosts. `Malachi.Metrics.PrometheusTest` covers how they are rendered; this covers that the
  # dashboard hands them to the exporter at all. async: false, because it reads the node's ra members.
  use ExUnit.Case, async: false

  alias Malachi.Console.Reads
  alias Malachi.Test.DashboardHelper

  @user "machine_version_reader"
  @password "machine_version_pass_1"

  setup do
    _ = Malachi.Auth.remove_user(@user)
    :ok = Malachi.Auth.add_user(@user, @password, [:admin])
    on_exit(fn -> Malachi.Auth.remove_user(@user) end)
    {:ok, token} = Malachi.Auth.authenticate(@user, @password, {127, 0, 0, 1})
    {:ok, token: token}
  end

  test "an authenticated scrape carries the machine version of every replicated store this node hosts",
       %{token: token} do
    response = DashboardHelper.scrape_metrics(token)
    assert response =~ "HTTP/1.1 200 OK"

    machines = Reads.machine_versions() |> Enum.map(& &1.machine) |> Enum.uniq()
    assert "user" in machines

    for machine <- machines do
      effective =
        DashboardHelper.metric_value(response, ~s(malachi_ra_machine_version{machine="#{machine}",kind="effective"}))

      assert effective, "no effective version for #{machine}"
      assert DashboardHelper.metric_value(response, ~s(malachi_ra_machine_version_stuck{machine="#{machine}"})) == 0
    end
  end
end
