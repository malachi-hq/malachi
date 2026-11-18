defmodule DemoScriptTest do
  # scripts/demo/run.sh (#373), with `docker` and `curl` replaced by stubs on the PATH: what it asks compose to
  # do, in which order, under which project, and how it reports a step that fails. The real run is on Docker.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @script Path.expand("../../scripts/demo/run.sh", __DIR__)

  @docker_stub ~S"""
  #!/usr/bin/env bash
  printf '%s\n' "$*" >> "$STUB_DIR/docker"
  case "$*" in
    *" up "*) [ -f "$STUB_DIR/up.fail" ] && exit 1 ;;
  esac
  exit 0
  """

  # The clients: records where each one connects, as whom, and with what arguments.
  @node_stub ~S"""
  #!/usr/bin/env bash
  printf '%s %s:%s %s %s\n' "$MALACHI_USER" "$MALACHI_HOST" "$MALACHI_PORT" "$MALACHI_PASS" "$*" >> "$STUB_DIR/node"
  case "$*" in
    *producer.js*) [ -f "$STUB_DIR/produce.fail" ] && exit 1 ;;
  esac
  exit 0
  """

  # Answers Jaeger's and Prometheus's APIs from <STUB_DIR>/jaeger.json and prometheus.json; a missing file is a
  # failed request, as curl -f makes a 404.
  @curl_stub ~S"""
  #!/usr/bin/env bash
  url=${!#}
  printf '%s\n' "$url" >> "$STUB_DIR/curl"
  case "$url" in
    *"/api/traces"*) f="$STUB_DIR/jaeger.json" ;;
    *"/api/v1/query"*) f="$STUB_DIR/prometheus.json" ;;
    *) exit 22 ;;
  esac
  [ -f "$f" ] && cat "$f" || exit 22
  """

  @trace ~s({"data": [{"traceID": "c0", "spans": [{"operationName": "malachi.consume"}]}, {"traceID": "abc", "spans": [{"operationName": "malachi.produce"}, {"operationName": "malachi.broker.produce"}, {"operationName": "malachi.produce"}]}]})
  @metric ~s({"data": {"result": [{"value": [1, "20"]}]}})

  setup do
    root = TmpDir.path("demo_script")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    for {name, stub} <- [{"docker", @docker_stub}, {"curl", @curl_stub}, {"node", @node_stub}] do
      File.write!(Path.join(bin, name), stub)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, bin: bin}
  end

  defp run(ctx, args \\ [], env \\ []) do
    System.cmd("bash", [@script | args],
      stderr_to_stdout: true,
      env:
        [
          {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
          {"STUB_DIR", ctx.root},
          {"DEMO_TIMEOUT", "2"},
          {"DEMO_INTERVAL", "1"},
          {"COMPOSE_PROJECT_NAME", "malachi-373"},
          {"JAEGER_UI_PORT", "23732"},
          {"MALACHI_TCP_PORT", "23730"},
          {"PROMETHEUS_PORT", "23734"},
          # Unset, not left out: a password exported in the runner's shell would reach the clients.
          {"MALACHI_PRODUCER_PASS", nil},
          {"MALACHI_CONSUMER_PASS", nil}
        ] ++ env
    )
  end

  defp lines(ctx, file) do
    case File.read(Path.join(ctx.root, file)) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp answers(ctx, trace \\ @trace, metric \\ @metric) do
    if trace, do: File.write!(Path.join(ctx.root, "jaeger.json"), trace)
    if metric, do: File.write!(Path.join(ctx.root, "prometheus.json"), metric)
  end

  test "starts the stack, produces, consumes, shows the trace and the metric, then removes the stack", ctx do
    answers(ctx)
    {out, 0} = run(ctx)

    assert [up, down] = lines(ctx, "docker")
    prefix = "compose -p malachi-373-demo -f docker-compose.yml"
    assert up == "#{prefix} up -d --wait malachi jaeger metrics-token prometheus"
    assert down == "#{prefix} down -v --remove-orphans"

    # On this machine, against the published port the node advertises, each as its own user.
    assert [produce, consume] = lines(ctx, "node")

    assert produce =~
             ~r/^producer 127\.0\.0\.1:23730 malachi-local-only-producer scripts\/producer\.js demo_\d+ 20 --create$/

    assert consume =~
             ~r/^consumer 127\.0\.0\.1:23730 malachi-local-only-consumer scripts\/consumer\.js demo_\d+ --group demo$/

    assert out =~ "trace abc: 3 spans, malachi.broker.produce, malachi.produce"
    refute out =~ "trace c0"
    assert out =~ "Open http://127.0.0.1:23732/search?service=malachi"
    assert out =~ "sum(malachi_records_produced_total) = 20"
    assert out =~ "Open http://127.0.0.1:23734/graph?g0.expr=sum(malachi_records_produced_total)"
  end

  test "the produce and the consume use the same topic", ctx do
    answers(ctx)
    run(ctx)
    [produce, consume] = lines(ctx, "node")
    [topic] = Regex.run(~r/demo_\d+/, produce)
    assert consume =~ "consumer.js #{topic} --group demo"
  end

  test "--keep leaves the stack running and says how to stop it", ctx do
    answers(ctx)
    {out, 0} = run(ctx, ["--keep"])
    refute Enum.any?(lines(ctx, "docker"), &(&1 =~ " down "))
    assert out =~ "Stop it with: docker compose -p malachi-373-demo down -v"
  end

  test "never names the development stack's project, so its volumes are safe", ctx do
    answers(ctx)
    run(ctx, [], [{"COMPOSE_PROJECT_NAME", nil}])
    assert Enum.all?(lines(ctx, "docker"), &String.starts_with?(&1, "compose -p malachi-demo "))
  end

  test "a stack that does not become healthy, or a failed produce, stops the demo and still removes the stack",
       ctx do
    File.write!(Path.join(ctx.root, "up.fail"), "")
    {out, 1} = run(ctx)
    assert out =~ "demo: the stack did not become healthy"
    assert List.last(lines(ctx, "docker")) =~ " down -v"

    File.rm!(Path.join(ctx.root, "up.fail"))
    File.write!(Path.join(ctx.root, "produce.fail"), "")
    {out, 1} = run(ctx)
    assert out =~ "demo: the produce failed"
    refute Enum.any?(lines(ctx, "node"), &(&1 =~ "consumer.js"))
    assert List.last(lines(ctx, "docker")) =~ " down -v"
  end

  test "no trace or no scraped metric within the timeout fails, saying which", ctx do
    answers(ctx, ~s({"data": [{"traceID": "c0", "spans": [{"operationName": "malachi.consume"}]}]}), nil)
    {out, 1} = run(ctx)
    assert out =~ "Jaeger recorded no trace of a produce within 2s"

    answers(ctx, @trace, ~s({"data": {"result": [{"value": [1, "0"]}]}}))
    {out, 1} = run(ctx)
    assert out =~ "Prometheus scraped no produced record within 2s"
  end

  test "an argument it does not take is a usage error, before anything starts", ctx do
    {out, 2} = run(ctx, ["--all"])
    assert out =~ "scripts/demo/run.sh [--keep]"
    assert lines(ctx, "docker") == []
  end

  test "without Node.js, says so before starting anything", ctx do
    File.rm!(Path.join(ctx.bin, "node"))
    # A PATH of the stubs and the one tool the script runs before it looks for node, so a node installed in
    # /usr/bin (a distribution's package) cannot be found either.
    tools = Path.join(ctx.root, "tools")
    File.mkdir_p!(tools)
    File.ln_s!(System.find_executable("dirname"), Path.join(tools, "dirname"))
    path = Enum.join([ctx.bin, tools], ":")
    {out, 1} = run(ctx, [], [{"PATH", path}])
    assert out =~ "Node.js is needed"
    refute Enum.any?(lines(ctx, "docker"), &(&1 =~ " up "))
  end
end
