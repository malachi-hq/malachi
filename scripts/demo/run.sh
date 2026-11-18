#!/usr/bin/env bash
# A scripted demo of Malachi for a recording (issue #373): one node with Jaeger and Prometheus from the default
# docker-compose.yml, a produce and a consume, then the trace and the metric they left.
#
#   scripts/demo/run.sh [--keep]
#
# 1. Starts the node, Jaeger, Prometheus and the metrics token sidecar, and waits until they are healthy.
# 2. Produces 20 records to a new topic, as the producer user, then consumes them as the consumer group
#    `demo`, both with the Node.js clients in scripts/, run on this machine against the published port: the
#    node advertises that loopback address, so a client inside another container could not follow it.
# 3. Shows the trace of a produce from Jaeger's API, and the records produced from Prometheus's, each with the
#    URL of its UI.
# 4. Stops the stack and removes its volumes, unless --keep leaves it running to explore.
#
# It runs as its own compose project, `<COMPOSE_PROJECT_NAME or malachi>-demo`, so removing its volumes never
# touches a development stack's data. The host ports are the compose file's (worktree.env sets them per
# worktree), so stop a development stack on the same ports first. Needs Docker and Node.js 22 or newer.
# Malachi runs on Linux, in the container here. To record it: `asciinema rec -c scripts/demo/run.sh demo.cast` (scripts/demo/README.md).
#
# Exits 0 when the trace and the metric were both shown, 1 when a step failed, 2 on a usage error.
set -uo pipefail

# Read before the cd below, while $0 still names this file from where it was run.
keep=0
case "${1:-}" in
  --keep) keep=1 ;;
  "") ;;
  *)
    sed -n '5p' "$0" | sed 's/^# *//' >&2
    exit 2
    ;;
esac
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2

project="${COMPOSE_PROJECT_NAME:-malachi}-demo"
compose=(docker compose -p "$project" -f docker-compose.yml)
jaeger="http://127.0.0.1:${JAEGER_UI_PORT:-16686}"
prometheus="http://127.0.0.1:${PROMETHEUS_PORT:-9090}"
port=${MALACHI_TCP_PORT:-4040}
timeout=${DEMO_TIMEOUT:-90}
interval=${DEMO_INTERVAL:-2}

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() {
  echo "demo: $*" >&2
  exit 1
}

cleanup() {
  if [ "$keep" -eq 1 ]; then
    echo
    echo "The stack is still running. Stop it with: docker compose -p $project down -v"
  else
    "${compose[@]}" down -v --remove-orphans > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# wait_for <url> <jq condition>: polls the URL until its JSON meets the condition, and prints that JSON.
wait_for() {
  local url=$1 condition=$2 waited=0 body
  while [ "$waited" -lt "$timeout" ]; do
    if body=$(curl -fsS "$url" 2> /dev/null) && jq -e "$condition" > /dev/null 2>&1 <<< "$body"; then
      printf '%s\n' "$body"
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  return 1
}

command -v node > /dev/null || fail "Node.js is needed for the clients in scripts/; install Node 22 or newer"

say "Starting one Malachi node with Jaeger and Prometheus"
"${compose[@]}" up -d --wait malachi jaeger metrics-token prometheus || fail "the stack did not become healthy"

topic="demo_$(date +%s)"
say "Producing 20 records to $topic"
MALACHI_HOST=127.0.0.1 MALACHI_PORT=$port MALACHI_USER=producer \
  MALACHI_PASS=${MALACHI_PRODUCER_PASS:-malachi-local-only-producer} \
  node scripts/producer.js "$topic" 20 --create || fail "the produce failed"

say "Consuming them as the consumer group demo"
MALACHI_HOST=127.0.0.1 MALACHI_PORT=$port MALACHI_USER=consumer \
  MALACHI_PASS=${MALACHI_CONSUMER_PASS:-malachi-local-only-consumer} \
  node scripts/consumer.js "$topic" --group demo || fail "the consume failed"

say "The trace of a produce, from Jaeger"
# The newest traces hold the consume too; the one shown is a produce's, down through the broker.
produce='map(select(any(.spans[]; .operationName == "malachi.produce")))'
traces=$(wait_for "$jaeger/api/traces?service=malachi&limit=50&lookback=1h" ".data | $produce | length > 0") ||
  fail "Jaeger recorded no trace of a produce within ${timeout}s"
jq -r ".data | $produce | first"' | "trace \(.traceID): \(.spans | length) spans, \(.spans | map(.operationName) | unique | join(", "))"' \
  <<< "$traces"
echo "Open $jaeger/search?service=malachi"

say "The records produced, from Prometheus"
query='sum(malachi_records_produced_total)'
metric=$(wait_for "$prometheus/api/v1/query?query=$query" \
  '.data.result | length > 0 and (.[0].value[1] | tonumber) > 0') ||
  fail "Prometheus scraped no produced record within ${timeout}s"
jq -r --arg q "$query" '"\($q) = \(.data.result[0].value[1])"' <<< "$metric"
echo "Open $prometheus/graph?g0.expr=$query"
