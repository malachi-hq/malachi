defmodule OciDailyRunScriptTest do
  # The daily run is a shell script that drives the OCI CLI, Docker and curl. These tests run the real script
  # with stand-ins for those four commands on PATH. Each stand-in writes its argv to a log, so the tests check
  # what the script did and in what order: the sweep, the config update, the apply, the probes, the restart,
  # the memory read, the destroy and the final sweep. The real GNU coreutils come from Homebrew's gnubin when
  # present (sha256sum and date -d are GNU), so the same script runs on this Mac and on the Linux CI.
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
    write_stub(stubs, "sleep", "#!/bin/bash\necho \"sleep $*\" >> \"$FAKE_LOG\"\nexit 0\n")

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

  # Records every call; answers by the subcommand; the FAKE_* variables pick the scenario.
  defp oci_stub do
    ~S"""
    #!/bin/bash
    echo "oci $*" >> "$FAKE_LOG"
    case "$*" in
      *"resource-manager job create-apply-job"*)
        if [ "${FAKE_APPLY:-ok}" = "ok" ]; then echo SUCCEEDED; else echo FAILED; fi ;;
      *"resource-manager job get-job-logs"*)
        if [ "${FAKE_APPLY:-ok}" = "capacity" ]; then echo "Error: Out of host capacity."; else echo "Error: something else"; fi ;;
      *"resource-manager job list"*) echo "ocid1.ormjob.oc1..fake" ;;
      *"resource-manager job create-destroy-job"*)
        # The real CLI can exit 0 with a FAILED lifecycle state, so the state is what the script must read.
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
      *"summarize-metrics-data"*) echo "${FAKE_MEMORY:-12}" ;;
      *"ons message publish"*) exit 0 ;;
      *"structured-search"*)
        if grep -q "create-destroy-job" "$FAKE_LOG"; then echo "${FAKE_LEFTOVERS_AFTER:-0}"; else echo "${FAKE_LEFTOVERS:-0}"; fi ;;
      *) echo "unexpected oci call: $*" >&2; exit 2 ;;
    esac
    """
    |> String.replace("__SECRET__", @secret)
  end

  defp docker_stub do
    ~S"""
    #!/bin/bash
    echo "docker $*" >> "$FAKE_LOG"
    case "$*" in
      *"tls: false"*) [ "${FAKE_PLAIN:-refused}" = "accepted" ] && exit 0 || exit 1 ;;
      *"tls: true"*) [ "${FAKE_SMOKE:-pass}" = "pass" ] && exit 0 || exit 1 ;;
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

  defp run(ctx, env \\ []) do
    work = Path.join(ctx.dir, "work")
    base = [
      {"PATH", Enum.join([ctx.stubs, @gnubin, System.get_env("PATH")], ":")},
      {"FAKE_LOG", ctx.log},
      {"FAKE_TARBALL", ctx.tarball},
      {"STACK_ID", "ocid1.ormstack.oc1..fake"},
      {"CLUSTER_COMPARTMENT_ID", "ocid1.compartment.oc1..cluster"},
      {"TOPIC_ID", "ocid1.onstopic.oc1..fake"},
      {"CONFIG_COMMIT_SHA", String.duplicate("a", 40)},
      {"CONFIG_TARBALL_SHA256", sha256_hex(ctx.tarball)},
      {"IMAGE_TAG", "0.22.7"},
      {"REGION", "replace-me-region"},
      {"AVAILABILITY_DOMAIN", "replace-me-ad"},
      {"WORK", work},
      {"DOCKER", "docker"}
    ]

    {out, status} =
      System.cmd("bash", [@script],
        env: base ++ Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end),
        stderr_to_stdout: true
      )

    calls = ctx.log |> File.read!() |> String.split("\n", trim: true)
    %{status: status, out: out, calls: calls, work: work}
  end

  # Index of the first call whose line matches, so ordering can be asserted.
  defp index_of(calls, fragment) do
    Enum.find_index(calls, &String.contains?(&1, fragment)) ||
      flunk("no call containing #{inspect(fragment)} in:\n" <> Enum.join(calls, "\n"))
  end

  defp report(result), do: File.read!(Path.join(result.work, "report.txt"))

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

    # The final sweep is the last structured-search, after the destroy, not the first one before the apply.
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
    applies = Enum.count(r.calls, &String.contains?(&1, "create-apply-job"))
    assert applies == 3
    assert Enum.count(r.calls, &String.contains?(&1, "sleep 1800")) == 2
    assert Enum.any?(r.calls, &String.contains?(&1, "create-destroy-job"))
    assert report(r) =~ "result: no-capacity"
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
  test "a plaintext connection that is accepted fails the verdict: the client port must enforce TLS", ctx do
    r = run(ctx, FAKE_PLAIN: "accepted")
    assert r.status != 0
    assert report(r) =~ "ACCEPTED"
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
  test "memory over the limit is reported as degraded, not as a failed run", ctx do
    r = run(ctx, FAKE_MEMORY: "85")
    assert r.status == 0, r.out
    assert report(r) =~ "over-limit"
    assert report(r) =~ "result: pass"
  end

  @tag :tmp_dir
  test "the probe password never reaches a command line", ctx do
    r = run(ctx)
    refute Enum.any?(r.calls, &String.contains?(&1, @secret))
    refute File.read!(Path.join(r.work, "report.txt")) =~ @secret
  end
end
