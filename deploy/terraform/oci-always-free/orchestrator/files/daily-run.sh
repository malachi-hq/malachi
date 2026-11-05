#!/bin/bash
# Daily ephemeral cluster run, executed as a systemd oneshot on the orchestrator micro under instance principal.
#
# Order: sweep the cluster compartment, fetch the pinned config, apply it, wait for the load balancer to
# report both A1 nodes healthy, run the probe through the public TLS endpoint, restart one node under load,
# read the micro's memory, report, destroy, sweep again.
#
# The destroy and the final sweep run from an EXIT trap, so a failure in any step above still tears the
# cluster down. Nothing here is piped into a shell, and no secret is passed on a command line.
set -euo pipefail

: "${STACK_ID:?}" "${CLUSTER_COMPARTMENT_ID:?}" "${TOPIC_ID:?}" "${CONFIG_COMMIT_SHA:?}"
: "${CONFIG_TARBALL_SHA256:?}" "${IMAGE_TAG:?}" "${REGION:?}"

WORK="${WORK:-/var/lib/malachi-orchestrator/run}"
OCI=(oci --auth instance_principal --region "$REGION")
DOCKER="${DOCKER:-docker}"
CLUSTER_NODES="malachi1 malachi2 malachi3"
LB_NODES="malachi1 malachi2"
MEMORY_LIMIT_PCT=70

RESULT="unknown"
DESTROYED="no"
REPORT="$WORK/report.txt"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$REPORT" >&2; }

# Writes the report and sends it to the topic. Failures to send are logged, never fatal: the run's outcome is
# what the exit code says.
publish_report() {
  "${OCI[@]}" ons message publish --topic-id "$TOPIC_ID" \
    --title "malachi daily run: $RESULT" --body "$(cat "$REPORT")" >/dev/null 2>&1 \
    || log "could not publish the report to the topic"
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

# Anything left in the cluster compartment after a destroy is a leak. The sweep lists it, and a leftover
# destroy from the stack's own state is the only way it is removed: the run never deletes by resource type.
sweep() {
  local when="$1" left
  left=$("${OCI[@]}" search resource structured-search \
    --query-text "query all resources where compartmentId = '$CLUSTER_COMPARTMENT_ID'" \
    --query 'length(data.items)' --raw-output 2>/dev/null || echo "unknown")
  log "sweep $when: $left resource(s) left in the cluster compartment"
  [ "$left" = "0" ]
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
  python3 - "$WORK/src/deploy/terraform/oci-always-free/cluster" "$WORK/config.json" <<'PY'
import base64, io, json, os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, _, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, root))
json.dump({"configSourceType": "ZIP_UPLOAD",
           "zipFileBase64Encoded": base64.b64encode(buf.getvalue()).decode()}, open(out, "w"))
PY
  "${OCI[@]}" resource-manager stack update --stack-id "$STACK_ID" \
    --config-source "file://$WORK/config.json" --variables "$(stack_variables)" --force >/dev/null
  log "stack config updated to commit $CONFIG_COMMIT_SHA"
}

# Stack variables are passed the same way every day, so a drift cannot happen between two runs.
stack_variables() {
  printf '{"region":"%s","compartment_id":"%s","availability_domain":"%s","image_tag":"%s"}' \
    "$REGION" "$CLUSTER_COMPARTMENT_ID" "${AVAILABILITY_DOMAIN:?}" "$IMAGE_TAG"
}

# One apply job, waited for. Returns 0 on success, 2 when the failure is the free tier running out of A1
# capacity (a normal, retryable event), and 1 for anything else.
apply_once() {
  local state
  state=$("${OCI[@]}" resource-manager job create-apply-job --stack-id "$STACK_ID" \
    --execution-plan-strategy AUTO_APPROVED \
    --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 5400 \
    --query 'data."lifecycle-state"' --raw-output)
  [ "$state" = "SUCCEEDED" ] && return 0
  "${OCI[@]}" resource-manager job get-job-logs --job-id "$(last_job_id)" >"$WORK/apply.log" 2>/dev/null || true
  if grep -qi "out of host capacity" "$WORK/apply.log" 2>/dev/null; then return 2; fi
  return 1
}

apply_cluster() {
  local attempt rc
  for attempt in 1 2 3; do
    rc=0
    apply_once || rc=$?
    if [ "$rc" -eq 0 ]; then log "apply succeeded (attempt $attempt)"; return 0; fi
    if [ "$rc" -ne 2 ]; then break; fi
    if [ "$attempt" -lt 3 ]; then
      log "A1 capacity unavailable (attempt $attempt): waiting before retry"
      sleep 1800
    fi
  done
  if [ "$rc" -eq 2 ]; then RESULT="no-capacity"; else RESULT="apply-failed"; fi
  return 1
}

# Both A1 nodes must be healthy at the load balancer, which means their /ready answered 200.
wait_for_ready() {
  local deadline=$((SECONDS + 900)) status
  while [ "$SECONDS" -lt "$deadline" ]; do
    status=$("${OCI[@]}" network-load-balancer backend-set-health get \
      --network-load-balancer-id "$NLB_ID" --backend-set-name malachi-client-tcp \
      --query 'data.status' --raw-output 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "OK" ]; then log "load balancer reports every backend healthy"; return 0; fi
    sleep 30
  done
  log "backends never became healthy (last status: $status)"
  RESULT="not-ready"
  return 1
}

# The probe is the published image, run once against the public TLS endpoint. The password reaches the
# container through an environment file, never through the command line.
run_probe() {
  local mode="$1" endpoint
  endpoint=$(jq -r '.outputs.client_endpoint.value' "$WORK/state.json")
  jq -r '.outputs.ca_cert_pem.value' "$WORK/state.json" >"$WORK/cacert.pem"
  jq -r '.outputs.probe_password.value' "$WORK/state.json" >"$WORK/probe.env.raw"
  printf 'PROBE_PASS=%s\n' "$(cat "$WORK/probe.env.raw")" >"$WORK/probe.env"
  rm -f "$WORK/probe.env.raw"; chmod 600 "$WORK/probe.env"
  local host="${endpoint%:*}" port="${endpoint##*:}"
  local tls="true"; [ "$mode" = "plaintext" ] && tls="false"
  timeout 900 "$DOCKER" run --rm --network host --env-file "$WORK/probe.env" \
    -v "$WORK/cacert.pem:/probe/cacert.pem:ro" \
    "hectorcardoso/malachi:$IMAGE_TAG" \
    bin/malachi eval "Malachi.Loadtest.run(host: \"$host\", port: $port, tls: $tls, cacert: \"/probe/cacert.pem\", user: \"producer\", pass: System.fetch_env!(\"PROBE_PASS\"), scenario: :produce, duration: 60, warmup: 5, connections: 8)"
}

smoke() {
  if run_probe tls >"$WORK/probe-tls.log" 2>&1; then log "TLS produce smoke passed"; SMOKE="pass"
  else log "TLS produce smoke FAILED"; SMOKE="fail"; fi
  if run_probe plaintext >"$WORK/probe-plain.log" 2>&1; then log "plaintext connection was ACCEPTED: client port is not enforcing TLS"; PLAIN="accepted"
  else log "plaintext connection refused, as required"; PLAIN="refused"; fi
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

# Peak memory of the micro over the run, from the built-in agent namespace. Above the limit the run is
# DEGRADED, not failed: it tells the maintainer the micro is tight, which is the open question of the plan.
memory_peak() {
  local id peak
  id=$(instance_id malachi3)
  peak=$("${OCI[@]}" monitoring metric-data summarize-metrics-data --compartment-id "$CLUSTER_COMPARTMENT_ID" \
    --namespace oci_computeagent --query-text "MemoryUtilization[1m]{resourceId = \"$id\"}.max()" \
    --start-time "$RUN_START" --end-time "$(date -u +%FT%TZ)" \
    --query 'max(data[].aggregatedDatapoints[].value)' --raw-output 2>/dev/null || echo "unknown")
  MEMORY_PEAK="$peak"
  if [ "$peak" != "unknown" ] && [ "$(awk -v p="$peak" -v l="$MEMORY_LIMIT_PCT" 'BEGIN{print (p+0 > l+0)}')" = "1" ]; then
    MEMORY_STATUS="over-limit"
  else
    MEMORY_STATUS="within-limit"
  fi
  log "micro memory peak: $peak% ($MEMORY_STATUS, limit $MEMORY_LIMIT_PCT%)"
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

last_job_id() {
  "${OCI[@]}" resource-manager job list --stack-id "$STACK_ID" --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output
}

on_exit() {
  local rc=$?
  if [ "$DESTROYED" != "yes" ]; then
    destroy_cluster || { log "DESTROY FAILED: the cluster may still exist; see the stack in Resource Manager"; RESULT="destroy-failed"; }
  fi
  if ! sweep "after destroy"; then RESULT="leak"; log "LEAK: resources remain after destroy"; fi
  if [ "$RESULT" = "unknown" ]; then RESULT=$([ "$rc" -eq 0 ] && echo "pass" || echo "failed"); fi
  if [ "$RESULT" != "pass" ] && [ "$rc" -eq 0 ]; then rc=1; fi
  log "result: $RESULT | smoke: ${SMOKE:-not-run} | plaintext: ${PLAIN:-not-run} | chaos: ${CHAOS:-not-run} | micro memory: ${MEMORY_STATUS:-not-measured}"
  log "informative only, not a benchmark: this rig measures correctness under load and failure, never throughput"
  publish_report
  exit "$rc"
}

main() {
  mkdir -p "$WORK"; : >"$REPORT"
  RUN_START=$(date -u +%FT%TZ)
  trap on_exit EXIT
  sweep "before apply" || { RESULT="leftovers"; exit 1; }
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
