#!/bin/bash
# Daily ephemeral cluster run, executed as a systemd oneshot on the orchestrator micro under instance principal.
#
# Order: check the configuration, sweep the cluster compartment, fetch the pinned config, apply it, wait for the
# load balancer to report both A1 nodes healthy, run the probes through the public TLS endpoint, restart one node
# under load, read the micro's memory, destroy, sweep again, report.
#
# The destroy and the final sweep run from an EXIT trap, so a failure in any step still tears the cluster down.
# SIGTERM, SIGINT and SIGHUP exit through the same trap. SIGKILL and a reboot cannot run a trap: the next day's
# sweep finds the leftovers and destroys them before it applies anything. Before any destroy, the configuration
# that the last successful apply used is put back on the stack, so a broken new commit cannot block the teardown.
# A destroy is never started while an apply job may still be running. Nothing here is piped into a shell, and no
# secret is passed on a command line.
set -euo pipefail

WORK="${WORK:-/var/lib/malachi-orchestrator/run}"
REPORT="$WORK/report.txt"
OCI=(oci --auth instance_principal --region "${REGION:-}")
DOCKER="${DOCKER:-docker}"
CLUSTER_NODES="malachi1 malachi2 malachi3"
MEMORY_LIMIT_PCT=70
APPLY_WAIT_LIMIT="${APPLY_WAIT_LIMIT:-10800}"   # seconds to wait for one apply job, polled once a minute

RESULT="unknown"
DESTROYED="no"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$REPORT" >&2; }

# Writes the report and sends it to the topic. Failures to send are logged, never fatal: the run's outcome is
# what the exit code says.
publish_report() {
  "${OCI[@]}" ons message publish --topic-id "${TOPIC_ID:-}" \
    --title "malachi daily run: $RESULT" --body "$(cat "$REPORT" 2>/dev/null)" >/dev/null 2>&1 \
    || log "could not publish the report to the topic"
}

# Every value the run needs. A missing one stops the run before any OCI call, and the report says which.
check_config() {
  local v missing=""
  for v in STACK_ID CLUSTER_COMPARTMENT_ID TOPIC_ID CONFIG_COMMIT_SHA CONFIG_TARBALL_SHA256 IMAGE_TAG REGION AVAILABILITY_DOMAIN; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  if [ -n "$missing" ]; then log "missing configuration:$missing"; return 1; fi
}

instance_id() {
  "${OCI[@]}" compute instance list --compartment-id "$CLUSTER_COMPARTMENT_ID" \
    --display-name "$1" --lifecycle-state RUNNING --query 'data[0].id' --raw-output
}

lb_id() {
  "${OCI[@]}" network-load-balancer network-load-balancer list \
    --compartment-id "$CLUSTER_COMPARTMENT_ID" --display-name malachi-client \
    --query 'data[0].id' --raw-output
}

# Lists what is left in the cluster compartment, excluding terminated resources. Returns 0 when nothing is left,
# 1 when something is, and 2 when the count could not be made: a tooling failure is not a leak.
# The errors of the search go to sweep.err in the run directory.
sweep() {
  local when="$1" left
  left=$("${OCI[@]}" search resource structured-search \
    --query-text "query all resources where compartmentId = '$CLUSTER_COMPARTMENT_ID' && lifecycleState != 'TERMINATED'" \
    --query 'length(data.items)' --raw-output 2>>"$WORK/sweep.err") || left=""
  if ! [[ "$left" =~ ^[0-9]+$ ]]; then
    log "sweep $when: could not count the cluster compartment (see sweep.err)"
    return 2
  fi
  if [ "$left" -eq 0 ]; then log "sweep $when: 0 resource(s) left"; return 0; fi
  log "sweep $when: $left resource(s) left in the cluster compartment"
  return 1
}

stack_variables() {
  printf '{"region":"%s","compartment_id":"%s","availability_domain":"%s","image_tag":"%s"}' \
    "$REGION" "$CLUSTER_COMPARTMENT_ID" "$AVAILABILITY_DOMAIN" "$IMAGE_TAG"
}

fetch_config() {
  local tarball="$WORK/src.tar.gz"
  curl -fsSL -o "$tarball" "https://codeload.github.com/malachi-hq/malachi/tar.gz/$CONFIG_COMMIT_SHA"
  echo "$CONFIG_TARBALL_SHA256  $tarball" | sha256sum -c --quiet \
    || { log "config tarball does not match its pinned SHA-256: refusing to apply"; return 1; }
  rm -rf "$WORK/src" && mkdir -p "$WORK/src"
  # Extract the whole archive, then take the cluster root. A GitHub tarball has one top directory
  # (malachi-<sha>/), and selecting members by path would depend on how each tar treats that prefix.
  tar -xzf "$tarball" -C "$WORK/src" --strip-components=1
  [ -d "$WORK/src/deploy/terraform/oci-always-free/cluster" ] \
    || { log "the pinned commit has no cluster root at deploy/terraform/oci-always-free/cluster"; return 1; }
  # --config-source takes a .zip of the configuration (oci resource-manager stack update reference), so the
  # archive is built here and passed as a file. Only the cluster root's own files go in.
  python3 - "$WORK/src/deploy/terraform/oci-always-free/cluster" "$WORK/cluster.zip" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".terraform", "tests")]
        for name in files:
            if name in ("terraform.tfstate", "terraform.tfstate.backup") or name.endswith(".tfvars"):
                continue
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, root))
PY
  "${OCI[@]}" resource-manager stack update --stack-id "$STACK_ID" \
    --config-source "$WORK/cluster.zip" --variables "$(stack_variables)" --force >/dev/null
  log "stack config updated to commit $CONFIG_COMMIT_SHA"
}

# Puts back the configuration of the last successful apply, so the destroy runs against the config that created
# the state, not against a commit that may not even plan. With no applied configuration on record, the destroy
# uses whatever is on the stack.
restore_applied_config() {
  if [ ! -f "$WORK/applied.zip" ]; then
    log "no applied configuration on record: destroying with the configuration on the stack"
    return 0
  fi
  if [ -f "$WORK/cluster.zip" ] && cmp -s "$WORK/cluster.zip" "$WORK/applied.zip"; then return 0; fi
  "${OCI[@]}" resource-manager stack update --stack-id "$STACK_ID" \
    --config-source "$WORK/applied.zip" --variables "$(stack_variables)" --force >/dev/null
  log "stack configuration restored to the one of the last successful apply, before destroy"
}

# Polls one job until it reaches a final state, and leaves that state in JOB_STATE. Returns 3 with JOB_STATE=TIMEOUT
# when the limit is reached first: the job may still be running, and the caller must not start a destroy against it.
# It is a plain loop, not run in a command substitution: bash runs a trap only between commands of the shell that
# received the signal, so a SIGTERM during a wait inside $(...) would be deferred until the wait ended, which may
# be never. systemd sends SIGKILL after its stop timeout, so the teardown has to be reachable from here.
JOB_STATE=""
wait_for_job() {
  local job="$1" deadline=$((SECONDS + APPLY_WAIT_LIMIT)) state
  while :; do
    state=$("${OCI[@]}" resource-manager job get --job-id "$job" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || state="UNKNOWN"
    case "$state" in
      SUCCEEDED|FAILED|CANCELED) JOB_STATE="$state"; return 0 ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then JOB_STATE="TIMEOUT"; return 3; fi
    sleep 60
  done
}

# One apply job, waited for. Returns 0 on success, 2 when the failure is the free tier running out of A1
# capacity (a normal, retryable event), 3 when the job is still running at the limit, and 1 for anything else.
apply_once() {
  local job
  job=$("${OCI[@]}" resource-manager job create-apply-job --stack-id "$STACK_ID" \
    --execution-plan-strategy AUTO_APPROVED --query 'data.id' --raw-output) || return 1
  wait_for_job "$job" || return 3
  [ "$JOB_STATE" = "SUCCEEDED" ] && return 0
  "${OCI[@]}" resource-manager job get-job-logs --job-id "$job" >"$WORK/apply.log" 2>/dev/null || true
  if grep -qi "out of host capacity" "$WORK/apply.log" 2>/dev/null; then return 2; fi
  return 1
}

apply_cluster() {
  local attempt rc
  for attempt in 1 2 3; do
    rc=0
    apply_once || rc=$?
    if [ "$rc" -eq 0 ]; then
      cp "$WORK/cluster.zip" "$WORK/applied.zip"
      log "apply succeeded (attempt $attempt)"
      return 0
    fi
    if [ "$rc" -eq 3 ]; then RESULT="apply-stuck"; log "apply job still running at the limit: no destroy will race it"; return 1; fi
    if [ "$rc" -ne 2 ]; then break; fi
    if [ "$attempt" -lt 3 ]; then
      log "A1 capacity unavailable (attempt $attempt): waiting before retry"
      sleep 1800
    fi
  done
  if [ "$rc" -eq 2 ]; then RESULT="no-capacity"; else RESULT="apply-failed"; fi
  return 1
}

# Both A1 nodes must be healthy at the load balancer, which means their /ready answered 200. The CLI's errors go
# to lb-health.err in the run directory.
wait_for_ready() {
  local deadline=$((SECONDS + 900)) status
  while [ "$SECONDS" -lt "$deadline" ]; do
    status=$("${OCI[@]}" network-load-balancer backend-set-health get \
      --network-load-balancer-id "$NLB_ID" --backend-set-name malachi-client-tcp \
      --query 'data.status' --raw-output 2>>"$WORK/lb-health.err") || status="UNKNOWN"
    if [ "$status" = "OK" ]; then log "load balancer reports every backend healthy"; return 0; fi
    sleep 30
  done
  log "backends never became healthy (last status: $status)"
  RESULT="not-ready"
  return 1
}

# Runs the published image as a probe. Returns the container's exit code. The password reaches the container through
# an environment file, never through the command line.
# Probe exit codes: 0 means the check's condition held; 10 means the plaintext connection was refused at setup
# (SetupError); 124 means the timeout fired; any other code is a failure with no conclusion drawn from it.
run_probe() {
  local mode="$1" endpoint rc=0
  endpoint=$(jq -r '.outputs.client_endpoint.value' "$WORK/state.json")
  jq -r '.outputs.ca_cert_pem.value' "$WORK/state.json" >"$WORK/cacert.pem"
  jq -r '.outputs.probe_password.value' "$WORK/state.json" >"$WORK/probe.env.raw"
  printf 'PROBE_PASS=%s\n' "$(cat "$WORK/probe.env.raw")" >"$WORK/probe.env"
  rm -f "$WORK/probe.env.raw"; chmod 600 "$WORK/probe.env"
  local host="${endpoint%:*}" port="${endpoint##*:}" expr
  if [ "$mode" = "plaintext" ]; then
    expr=$(printf '%s\n' \
      'try do' \
      "  r = Malachi.Loadtest.run(host: \"$host\", port: $port, tls: false, user: \"producer\", pass: System.fetch_env!(\"PROBE_PASS\"), scenario: :produce, duration: 60, warmup: 5, connections: 8)" \
      '  System.halt(if(r.records > 0 and r.errors == 0, do: 0, else: 20))' \
      'rescue' \
      '  Malachi.Loadtest.SetupError -> System.halt(10)' \
      'end')
  else
    expr=$(printf '%s\n' \
      "r = Malachi.Loadtest.run(host: \"$host\", port: $port, tls: true, cacert: \"/probe/cacert.pem\", user: \"producer\", pass: System.fetch_env!(\"PROBE_PASS\"), scenario: :produce, duration: 60, warmup: 5, connections: 8)" \
      'if r.records > 0 and r.errors == 0, do: System.halt(0), else: System.halt(3)')
  fi
  timeout 900 "$DOCKER" run --rm --network host --env-file "$WORK/probe.env" \
    -v "$WORK/cacert.pem:/probe/cacert.pem:ro" \
    "hectorcardoso/malachi:$IMAGE_TAG" \
    bin/malachi eval "$expr" || rc=$?
  return "$rc"
}

# The TLS smoke passes only when the produces wrote records and none failed. The plaintext check counts as refused
# only when the probe reports a setup refusal (code 10). A timeout, or any other failure, is indeterminate and never
# a pass.
smoke() {
  local rc=0
  run_probe tls >"$WORK/probe-tls.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then log "TLS produce smoke passed: records written, no errors"; SMOKE="pass"
  else log "TLS produce smoke FAILED (probe exit $rc)"; SMOKE="fail"; fi
  rc=0
  run_probe plaintext >"$WORK/probe-plain.log" 2>&1 || rc=$?
  case "$rc" in
    0)  log "plaintext connection was ACCEPTED: client port is not enforcing TLS"; PLAIN="accepted" ;;
    10) log "plaintext connection refused at setup, as required"; PLAIN="refused" ;;
    *)  log "plaintext check indeterminate (probe exit $rc): not counted as a refusal"; PLAIN="indeterminate" ;;
  esac
}

# One node restarts while the probe runs, which is the failure the cluster exists to survive. Rotates daily.
restart_one_node() {
  local day node id
  day=$(( 10#$(date -u +%j) % 3 ))
  node=$(echo "$CLUSTER_NODES" | awk -v i="$day" '{print $(i+1)}')
  id=$(instance_id "$node")
  run_probe tls >"$WORK/probe-chaos.log" 2>&1 &
  local probe_pid=$!
  sleep 60
  "${OCI[@]}" compute instance action --action SOFTRESET --instance-id "$id" >/dev/null
  log "restarted $node under load"
  local chaos_rc=0
  wait "$probe_pid" || chaos_rc=$?
  if [ "$chaos_rc" -eq 0 ]; then CHAOS="pass:$node"; else CHAOS="fail:$node"; fi
  if ! wait_for_ready; then CHAOS="fail:$node (no recovery)"; return 1; fi
}

# Peak memory of the micro over the run, from the built-in agent namespace. Above the limit the report says
# over-limit; the verdict does not change. A value that cannot be read is reported as unmeasured, never as healthy.
memory_peak() {
  local id peak
  id=$(instance_id malachi3)
  peak=$("${OCI[@]}" monitoring metric-data summarize-metrics-data --compartment-id "$CLUSTER_COMPARTMENT_ID" \
    --namespace oci_computeagent --query-text "MemoryUtilization[1m]{resourceId = \"$id\"}.max()" \
    --start-time "$RUN_START" --end-time "$(date -u +%FT%TZ)" \
    --query 'max(data[].aggregatedDatapoints[].value)' --raw-output 2>/dev/null || echo "")
  if ! [[ "$peak" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    MEMORY_STATUS="unmeasured"
  elif [ "$(awk -v p="$peak" -v l="$MEMORY_LIMIT_PCT" 'BEGIN{print (p+0 > l+0)}')" = "1" ]; then
    MEMORY_STATUS="over-limit"
  else
    MEMORY_STATUS="within-limit"
  fi
  log "micro memory peak: ${peak:-n/a}% ($MEMORY_STATUS, limit $MEMORY_LIMIT_PCT%)"
}

# Called from the EXIT trap, where set -e does not apply: every failure must be an explicit return.
destroy_cluster() {
  local state
  state=$("${OCI[@]}" resource-manager job create-destroy-job --stack-id "$STACK_ID" \
    --execution-plan-strategy AUTO_APPROVED \
    --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 5400 \
    --query 'data."lifecycle-state"' --raw-output) || return 1
  [ "$state" = "SUCCEEDED" ] || { log "destroy job ended in state $state"; return 1; }
  DESTROYED="yes"
  log "destroy job finished"
}

on_exit() {
  local rc=$? sweep_rc=0
  if [ "$RESULT" = "config-missing" ] || [ "$RESULT" = "apply-stuck" ]; then
    : # no destroy: nothing was configured, or an apply may still be running
  elif [ "$DESTROYED" != "yes" ]; then
    restore_applied_config || log "could not restore the applied configuration before destroy"
    destroy_cluster || { log "DESTROY FAILED: the cluster may still exist; see the stack in Resource Manager"; RESULT="destroy-failed"; }
  fi
  if [ "$RESULT" != "config-missing" ]; then
    sweep "after destroy" || sweep_rc=$?
    if [ "$sweep_rc" -eq 1 ]; then
      log "LEAK: resources remain after destroy"
      [ "$RESULT" = "destroy-failed" ] || RESULT="leak"
    elif [ "$sweep_rc" -eq 2 ]; then
      log "the cluster compartment could not be counted: check it by hand"
      [ "$RESULT" = "pass" ] && RESULT="sweep-failed"
    fi
  fi
  if [ "$RESULT" = "unknown" ]; then RESULT=$([ "$rc" -eq 0 ] && echo "pass" || echo "failed"); fi
  if [ "$RESULT" != "pass" ] && [ "$rc" -eq 0 ]; then rc=1; fi
  log "result: $RESULT | smoke: ${SMOKE:-not-run} | plaintext: ${PLAIN:-not-run} | chaos: ${CHAOS:-not-run} | micro memory: ${MEMORY_STATUS:-not-measured}"
  log "informative only, not a benchmark: this rig measures correctness under load and failure, never throughput"
  publish_report
  exit "$rc"
}

main() {
  mkdir -p "$WORK"; : >"$REPORT"
  trap on_exit EXIT
  trap 'exit 143' TERM INT HUP
  if ! check_config; then RESULT="config-missing"; exit 1; fi
  RUN_START=$(date -u +%FT%TZ)
  local rc_sweep=0
  sweep "before apply" || rc_sweep=$?
  if [ "$rc_sweep" -ne 0 ]; then
    if [ "$rc_sweep" -eq 1 ]; then RESULT="leftovers"; else RESULT="sweep-failed"; fi
    exit 1
  fi
  fetch_config
  apply_cluster
  NLB_ID=$(lb_id)
  wait_for_ready
  "${OCI[@]}" resource-manager stack get-stack-tf-state --stack-id "$STACK_ID" --file "$WORK/state.json" >/dev/null
  smoke
  restart_one_node
  memory_peak
  if [ "$SMOKE" = "pass" ] && [ "$PLAIN" = "refused" ] && [ "${CHAOS%%:*}" = "pass" ]; then
    RESULT="pass"
  else
    RESULT="failed"
  fi
}

main "$@"
