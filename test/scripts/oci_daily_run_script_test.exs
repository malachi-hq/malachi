defmodule OciDailyRunScriptTest do
  # The daily run is a shell script that drives the OCI CLI, Docker and curl. These tests run the real script
  # with stand-ins for those commands on PATH. Each stand-in writes its argv to a log, so the tests check what the
  # script did and in what order. The FAKE_* variables pick the scenario. The real GNU coreutils come from
  # Homebrew's gnubin when present (sha256sum and date -d are GNU), so the same script runs here and on the Linux CI.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "deploy/terraform/oci-always-free/orchestrator/files/daily-run.sh")
  @gnubin "/opt/homebrew/opt/coreutils/libexec/gnubin"
  @secret "SECRET-PRODUCER-PASS-7f3a"

  setup context do
    dir = context.tmp_dir
    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)
    log = Path.join(dir, "calls.log")
    File.write!(log, "")

    tarball = build_tarball(dir)
    write_stub(stubs, "oci", oci_stub())
    write_stub(stubs, "docker", docker_stub())
    write_stub(stubs, "curl", curl_stub())
    # Short real sleeps keep the polling loops fast while still letting a signal arrive between them.
    write_stub(stubs, "sleep", "#!/bin/bash\necho \"sleep $*\" >> \"$FAKE_LOG\"\n/bin/sleep 0.05\n")

    %{dir: dir, stubs: stubs, log: log, tarball: tarball}
  end

  # A tarball shaped like the repository's: the cluster root at the path the script extracts.
  defp build_tarball(dir) do
    src = Path.join(dir, "src/malachi-abc/deploy/terraform/oci-always-free/cluster")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "main.tf"), "# cluster root\n")
    tgz = Path.join(dir, "source.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", tgz, "-C", Path.join(dir, "src"), "malachi-abc"])
    tgz
  end

  defp sha256_hex(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp write_stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  # Records every call and answers by subcommand. FAKE_APPLY: ok | capacity | other | hang | slow.
  defp oci_stub do
    ~S"""
    #!/bin/bash
    echo "oci $*" >> "$FAKE_LOG"
    case "$*" in
      *"resource-manager job create-apply-job"*) echo "ocid1.ormjob.oc1..apply" ;;
      *"resource-manager job get-job-logs"*)
        if [ "${FAKE_APPLY:-ok}" = "capacity" ]; then echo "Error: Out of host capacity."; else echo "Error: something else"; fi ;;
      *"resource-manager job get --job-id"*)
        case "${FAKE_APPLY:-ok}" in
          ok) echo SUCCEEDED ;;
          hang) echo IN_PROGRESS ;;
          slow)
            n=$(grep -c "resource-manager job get --job-id" "$FAKE_LOG")
            if [ "$n" -lt 3 ]; then echo IN_PROGRESS; else echo SUCCEEDED; fi ;;
          *) echo FAILED ;;
        esac ;;
      *"resource-manager job list"*) echo "ocid1.ormjob.oc1..fake" ;;
      *"resource-manager job create-destroy-job"*)
        if [ "${FAKE_DESTROY:-ok}" = "ok" ]; then echo SUCCEEDED; else echo FAILED; fi
        exit 0 ;;
      *"resource-manager stack update"*) exit 0 ;;
      *"resource-manager stack get-stack-tf-state"*)
        out=""; while [ $# -gt 0 ]; do [ "$1" = "--file" ] && out="$2"; shift; done
        printf '%s' "{\"outputs\":{\"client_endpoint\":{\"value\":\"203.0.113.9:4040\"},\"ca_cert_pem\":{\"value\":\"CA-PEM\"},\"probe_password\":{\"value\":\"__SECRET__\"}}}" > "$out"
        exit 0 ;;
      *"network-load-balancer network-load-balancer list"*) echo "ocid1.networkloadbalancer.oc1..fake" ;;
      *"backend-set-health get"*) echo "${FAKE_HEALTH:-OK}" ;;
      *"compute instance list"*) echo "ocid1.instance.oc1..fake" ;;
      *"compute instance action"*) exit 0 ;;
      *"summarize-metrics-data"*) echo "${FAKE_MEMORY-12}" ;;
      *"ons message publish"*) exit 0 ;;
      *"structured-search"*)
        if grep -q "create-destroy-job" "$FAKE_LOG"; then
          [ "${FAKE_SEARCH_AFTER:-ok}" = "fail" ] && exit 1
          echo "${FAKE_LEFTOVERS_AFTER:-0}"
        else
          [ "${FAKE_SEARCH:-ok}" = "fail" ] && exit 1
          echo "${FAKE_LEFTOVERS:-0}"
        fi ;;
      *) echo "unexpected oci call: $*" >&2; exit 2 ;;
    esac
    exit 0
    """
    |> String.replace("__SECRET__", @secret)
  end

  # FAKE_SMOKE: pass | fail | empty (exit 3, no records). FAKE_PLAIN: refused (10) | accepted (0) | stall (124) | other (1).
  defp docker_stub do
    ~S"""
    #!/bin/bash
    echo "docker $*" >> "$FAKE_LOG"
    case "$*" in
      *"tls: false"*)
        case "${FAKE_PLAIN:-refused}" in
          refused) exit 10 ;;
          accepted) exit 0 ;;
          stall) exit 124 ;;
          *) exit 1 ;;
        esac ;;
      *"tls: true"*)
        case "${FAKE_SMOKE:-pass}" in
          pass) exit 0 ;;
          empty) exit 3 ;;
          *) exit 1 ;;
        esac ;;
    esac
    exit 0
    """
  end

  defp curl_stub do
    ~S"""
    #!/bin/bash
    echo "curl $*" >> "$FAKE_LOG"
    out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
    cp "$FAKE_TARBALL" "$out"
    """
  end

  @config_vars [
    {"STACK_ID", "ocid1.ormstack.oc1..fake"},
    {"CLUSTER_COMPARTMENT_ID", "ocid1.compartment.oc1..cluster"},
    {"TOPIC_ID", "ocid1.onstopic.oc1..fake"},
    {"CONFIG_COMMIT_SHA", String.duplicate("a", 40)},
    {"IMAGE_TAG", "0.22.7"},
    {"REGION", "replace-me-region"},
    {"AVAILABILITY_DOMAIN", "replace-me-ad"}
  ]

  defp run(ctx, env \\ [], opts \\ []) do
    work = Path.join(ctx.dir, "work")

    base =
      [
        {"PATH", Enum.join([ctx.stubs, @gnubin, System.get_env("PATH")], ":")},
        {"FAKE_LOG", ctx.log},
        {"FAKE_TARBALL", ctx.tarball},
        {"CONFIG_TARBALL_SHA256", sha256_hex(ctx.tarball)},
        {"WORK", work},
        {"DOCKER", "docker"}
      ] ++ @config_vars

    {out, status} =
      System.cmd("bash", [@script],
        env: base ++ Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end),
        stderr_to_stdout: true
      )

    calls = ctx.log |> File.read!() |> String.split("\n", trim: true)
    _ = opts
    %{status: status, out: out, calls: calls, work: work}
  end

  defp index_of(calls, fragment) do
    Enum.find_index(calls, &String.contains?(&1, fragment)) ||
      flunk("no call containing #{inspect(fragment)} in:\n" <> Enum.join(calls, "\n"))
  end

  defp report(result), do: File.read!(Path.join(result.work, "report.txt"))

  defp count(calls, fragment), do: Enum.count(calls, &String.contains?(&1, fragment))

  @tag :tmp_dir
  test "a clean run goes sweep, config, apply, probes, restart, memory, destroy, sweep, in that order", ctx do
    r = run(ctx)
    assert r.status == 0, r.out

    order = [
      "structured-search",
      "resource-manager stack update",
      "create-apply-job",
      "backend-set-health get",
      "get-stack-tf-state",
      "tls: true",
      "tls: false",
      "compute instance action --action SOFTRESET",
      "summarize-metrics-data",
      "create-destroy-job"
    ]

    indexes = Enum.map(order, &index_of(r.calls, &1))
    assert indexes == Enum.sort(indexes), "steps ran out of order: #{inspect(order)}"

    destroy_at = index_of(r.calls, "create-destroy-job")

    final_sweep_at =
      r.calls
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> String.contains?(line, "structured-search") end)
      |> List.last()
      |> elem(1)

    assert final_sweep_at > destroy_at, "the final sweep must run after the destroy"
    assert report(r) =~ "result: pass"
    assert report(r) =~ "informative only, not a benchmark"
  end

  @tag :tmp_dir
  test "a missing configuration value stops the run before any OCI call, and says which value", ctx do
    r = run(ctx, STACK_ID: "")
    assert r.status != 0
    assert report(r) =~ "missing configuration: STACK_ID"
    assert report(r) =~ "result: config-missing"
    # The one OCI call allowed is the publish of the report; nothing touches a compartment, an instance or a stack.
    oci_calls = Enum.filter(r.calls, &String.starts_with?(&1, "oci "))
    assert Enum.all?(oci_calls, &String.contains?(&1, "ons message publish"))
  end

  @tag :tmp_dir
  test "a SIGTERM during a long apply still runs the teardown, sweep and report", ctx do
    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        args: [@script],
        env:
          Enum.map(
            [
              {"PATH", Enum.join([ctx.stubs, @gnubin, System.get_env("PATH")], ":")},
              {"FAKE_LOG", ctx.log},
              {"FAKE_TARBALL", ctx.tarball},
              {"FAKE_APPLY", "hang"},
              {"CONFIG_TARBALL_SHA256", sha256_hex(ctx.tarball)},
              {"WORK", Path.join(ctx.dir, "work")},
              {"DOCKER", "docker"}
            ] ++ @config_vars,
            fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end
          )
      ])

    os_pid = Port.info(port, :os_pid) |> elem(1)
    wait_until(fn -> File.read!(ctx.log) =~ "resource-manager job get --job-id" end)
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    assert_receive_exit(port)

    calls = ctx.log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.any?(calls, &String.contains?(&1, "create-destroy-job")), "SIGTERM skipped the destroy"
    assert Enum.any?(calls, &String.contains?(&1, "structured-search")), "SIGTERM skipped the final sweep"
    assert File.read!(Path.join([ctx.dir, "work", "report.txt"])) =~ "result: failed"
  end

  defp wait_until(fun, tries \\ 600) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(50)
        wait_until(fun, tries - 1)
    end
  end

  defp assert_receive_exit(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      60_000 -> flunk("the script did not exit after SIGTERM")
    end
  end

  @tag :tmp_dir
  test "an apply job still running at the limit is not raced by a destroy", ctx do
    r = run(ctx, FAKE_APPLY: "hang", APPLY_WAIT_LIMIT: "0")
    assert r.status != 0
    refute Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job")), "a destroy raced a running apply"
    assert report(r) =~ "result: apply-stuck"
    assert report(r) =~ "no destroy will race it"
  end

  @tag :tmp_dir
  test "an apply job that is still in progress is polled until it finishes, then the run goes on", ctx do
    r = run(ctx, FAKE_APPLY: "slow")
    assert r.status == 0, r.out
    assert count(r.calls, "resource-manager job get --job-id") >= 3
    assert index_of(r.calls, "backend-set-health get") > index_of(r.calls, "resource-manager job get --job-id")
    assert report(r) =~ "result: pass"
  end

  @tag :tmp_dir
  test "the destroy runs and the run fails when the apply fails for any other reason", ctx do
    r = run(ctx, FAKE_APPLY: "other")
    assert r.status != 0
    assert Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job"))
    assert report(r) =~ "result: apply-failed"
  end

  @tag :tmp_dir
  test "out-of-capacity is retried three times, reported as no-capacity, and still torn down", ctx do
    r = run(ctx, FAKE_APPLY: "capacity")
    assert r.status != 0
    assert count(r.calls, "create-apply-job") == 3
    assert count(r.calls, "sleep 1800") == 2
    assert Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job"))
    assert report(r) =~ "result: no-capacity"
  end

  @tag :tmp_dir
  test "the last successful configuration is put back on the stack before the destroy", ctx do
    # A previous day's apply left its configuration on record; today's config differs, as after a broken commit.
    work = Path.join(ctx.dir, "work")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "applied.zip"), "the configuration of the last good apply")

    r = run(ctx, FAKE_APPLY: "other")
    assert r.status != 0
    assert report(r) =~ "restored to the one of the last successful apply"

    restore_at = index_of(r.calls, "applied.zip")
    destroy_at = index_of(r.calls, "create-destroy-job")
    assert restore_at < destroy_at, "the configuration must be restored before the destroy"
  end

  @tag :tmp_dir
  test "a failing TLS smoke fails the verdict even though the teardown still runs", ctx do
    r = run(ctx, FAKE_SMOKE: "fail")
    assert r.status != 0
    assert report(r) =~ "TLS produce smoke FAILED"
    assert report(r) =~ "result: failed"
    assert Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job"))
  end

  @tag :tmp_dir
  test "a smoke with no records written fails, even when the probe exits zero" do
    # The produce check lives in the probe expression: a run that wrote nothing or errored must exit non-zero.
    script = File.read!(@script)
    assert script =~ "r.records > 0 and r.errors == 0"
  end

  @tag :tmp_dir
  test "a smoke that wrote nothing is a failed smoke", ctx do
    r = run(ctx, FAKE_SMOKE: "empty")
    assert report(r) =~ "TLS produce smoke FAILED"
    assert report(r) =~ "result: failed"
  end

  @tag :tmp_dir
  test "a plaintext connection that gets in fails the verdict: the client port must enforce TLS", ctx do
    r = run(ctx, FAKE_PLAIN: "accepted")
    assert r.status != 0
    assert report(r) =~ "ACCEPTED"
    assert report(r) =~ "result: failed"
  end

  @tag :tmp_dir
  test "a plaintext probe that stalls is indeterminate, never counted as a refusal", ctx do
    r = run(ctx, FAKE_PLAIN: "stall")
    assert r.status != 0
    assert report(r) =~ "plaintext check indeterminate"
    refute report(r) =~ "refused at setup"
    assert report(r) =~ "result: failed"
  end

  @tag :tmp_dir
  test "leftovers before the apply stop the run before anything is applied, and the destroy still runs", ctx do
    r = run(ctx, FAKE_LEFTOVERS: "3")
    assert r.status != 0
    refute Enum.any?(r.calls, &String.contains?(&1, "create-apply-job"))
    assert Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job"))
    assert report(r) =~ "result: leftovers"
  end

  @tag :tmp_dir
  test "a sweep that cannot count the compartment stops the run as sweep-failed, not as leftovers", ctx do
    r = run(ctx, FAKE_SEARCH: "fail")
    assert r.status != 0
    refute Enum.any?(r.calls, &String.contains?(&1, "create-apply-job"))
    assert report(r) =~ "result: sweep-failed"
    refute report(r) =~ "result: leftovers"
  end

  @tag :tmp_dir
  test "the sweep leaves out terminated resources", ctx do
    r = run(ctx)
    assert Enum.any?(r.calls, &String.contains?(&1, "lifecycleState != 'TERMINATED'"))
  end

  @tag :tmp_dir
  test "a config tarball that does not match its pinned SHA-256 is never applied", ctx do
    r = run(ctx, CONFIG_TARBALL_SHA256: String.duplicate("0", 64))
    assert r.status != 0
    assert r.out =~ "does not match its pinned SHA-256"
    refute Enum.any?(r.calls, &String.contains?(&1, "resource-manager stack update"))
    refute Enum.any?(r.calls, &String.contains?(&1, "create-apply-job"))
    assert Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job"))
  end

  @tag :tmp_dir
  test "a failed destroy is loud: the report says so and the run exits non-zero", ctx do
    r = run(ctx, FAKE_DESTROY: "fail")
    assert r.status != 0
    assert report(r) =~ "DESTROY FAILED"
    assert report(r) =~ "result: destroy-failed"
  end

  @tag :tmp_dir
  test "a leak after a failed destroy keeps the destroy-failed verdict", ctx do
    r = run(ctx, FAKE_DESTROY: "fail", FAKE_LEFTOVERS_AFTER: "2")
    assert report(r) =~ "result: destroy-failed"
    refute report(r) =~ "result: leak"
  end

  @tag :tmp_dir
  test "leftovers after a clean destroy are a leak, and the run fails", ctx do
    r = run(ctx, FAKE_LEFTOVERS_AFTER: "2")
    assert r.status != 0
    assert report(r) =~ "LEAK: resources remain after destroy"
    assert report(r) =~ "result: leak"
  end

  @tag :tmp_dir
  test "a sweep that cannot count after the destroy is sweep-failed, not a leak", ctx do
    r = run(ctx, FAKE_SEARCH_AFTER: "fail")
    assert r.status != 0
    assert report(r) =~ "result: sweep-failed"
    refute report(r) =~ "result: leak"
  end

  @tag :tmp_dir
  test "memory over the limit is reported as over-limit, and the verdict is still pass", ctx do
    r = run(ctx, FAKE_MEMORY: "85")
    assert r.status == 0, r.out
    assert report(r) =~ "over-limit"
    assert report(r) =~ "result: pass"
  end

  @tag :tmp_dir
  test "a memory reading that cannot be made is unmeasured, never within-limit", ctx do
    r = run(ctx, FAKE_MEMORY: "none")
    assert report(r) =~ "unmeasured"
    refute report(r) =~ "within-limit"
  end

  @tag :tmp_dir
  test "the probe password never reaches a command line", ctx do
    r = run(ctx)
    refute Enum.any?(r.calls, &String.contains?(&1, @secret))
    refute File.read!(Path.join(r.work, "report.txt")) =~ @secret
  end
end
