defmodule DockerRegressionTest do
  # scripts/docker-regression-test.sh (`make docker-regression-test`) boots the image, logs in to the
  # dashboard and runs its checks. Since #180 it must do all of that without a password or the session
  # token ever being a process argument: the passwords reach the container by name (`docker run -e NAME`),
  # the login body and the bearer reach curl on stdin. The script runs for real in a throwaway tree, with
  # Malachi.Test.DockerHarnessStubs first on the PATH and the two checks it delegates to other scripts
  # (static assets, the image HEALTHCHECK, each tested on its own) replaced by ones that pass.
  use ExUnit.Case, async: true

  alias Malachi.Test.DockerHarnessStubs, as: Stubs

  @moduletag :tmp_dir

  @scripts Path.expand("../../scripts", __DIR__)
  @passwords ~w(MALACHI_ADMIN_PASS MALACHI_PRODUCER_PASS MALACHI_CONSUMER_PASS MALACHI_APP_PASS)

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    for tool <- ~w(bash jq) do
      System.find_executable(tool) || flunk("#{tool} is required to test scripts/docker-regression-test.sh")
    end

    :ok
  end

  setup %{tmp_dir: dir} do
    tree = Path.join(dir, "tree")
    File.mkdir_p!(Path.join([tree, "scripts", "lib"]))

    for file <- ~w(docker-regression-test.sh metrics_scrape_lib.sh lib/dashboard_curl.sh) do
      File.cp!(Path.join(@scripts, file), Path.join([tree, "scripts", file]))
    end

    for check <- ~w(docker-static-assets-check.sh docker-image-health-check.sh) do
      path = Path.join([tree, "scripts", check])
      File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    Map.put(Stubs.install!(dir), :script, Path.join([tree, "scripts", "docker-regression-test.sh"]))
  end

  test "a passing run keeps every password and the session token off every process argument", ctx do
    assert {output, 0} = run(ctx)
    assert output =~ "All regression tests passed!"

    for check <- ["Dashboard HTTP endpoint", "Metrics endpoint returns JSON", "SSE stream endpoint available"] do
      assert output =~ ~r/Testing: #{check}\.\.\. .*PASS/
    end

    env = Stubs.container_env(ctx)
    argv = Stubs.argv(ctx)

    for var <- @passwords do
      assert env[var] =~ ~r/^regression_/, "#{var} did not reach the container"
      assert argv =~ "-e #{var} "
      refute argv =~ env[var], "#{var}'s value reached a process argument"
    end

    refute argv =~ "stub-token"
    refute argv =~ "Bearer"

    # Where they did go: the login body and the bearer, on curl's stdin.
    stdin = Stubs.curl_stdin(ctx)
    assert Jason.decode!(hd(stdin)) == %{"username" => "admin", "password" => env["MALACHI_ADMIN_PASS"]}
    assert Enum.count(stdin, &(&1 == ~s(header = "Authorization: Bearer stub-token"\n))) == 3
  end

  for {behavior, reason} <- [
        {"login403", "login failed: HTTP 403 (the dashboard refused the credentials)"},
        {"badtoken", "login failed: the answer carried a malformed token"}
      ] do
    test "#{behavior}: the run stops before any check, saying why", ctx do
      assert {output, 1} = run(ctx, [{"STUB_CURL", unquote(behavior)}])
      assert output =~ "FAIL: Could not authenticate to dashboard (#{unquote(reason)})"
      refute output =~ "Testing:"
    end
  end

  test "a stream the dashboard refuses fails its check", ctx do
    assert {output, 1} = run(ctx, [{"STUB_CURL", "stream401"}])
    assert output =~ ~r/Testing: Metrics endpoint returns JSON\.\.\. .*PASS/
    assert output =~ ~r/Testing: SSE stream endpoint available\.\.\. .*FAIL/
  end

  test "without jq it refuses to start, before touching docker", ctx do
    # A PATH holding only the stubs and the shell tools the script reaches before its check.
    bin = Path.join(Path.dirname(ctx.stubs), "bin")
    File.mkdir_p!(bin)

    for tool <- ~w(bash dirname curl) do
      File.ln_s!(System.find_executable(tool) || Path.join(ctx.stubs, tool), Path.join(bin, tool))
    end

    assert {output, 1} = run(ctx, [{"PATH", bin}])
    assert output =~ "FAIL: jq is required"
    refute File.exists?(ctx.argv_log)
  end

  defp run(ctx, env \\ []) do
    System.cmd(System.find_executable("bash"), [ctx.script, "malachi:stub"],
      env: Stubs.env(ctx, env),
      stderr_to_stdout: true
    )
  end
end
