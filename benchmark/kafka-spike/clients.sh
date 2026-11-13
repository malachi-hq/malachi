#!/usr/bin/env bash
# Drives the Kafka spike (#166) with real clients, in Docker (Linux), one fresh node per case:
#   the Java client 3.9.2 and 4.4.0, with enable.idempotence left at its default and set to false,
#   and kcat (librdkafka) with idempotence at its default (off) and set to true,
# each against a node that hides InitProducerId and one that advertises it.
#
# Each case produces records (null keys, empty values, binary and repeated headers), fetches them back
# and compares them byte for byte. Writes results/clients-<stamp>/:
#   results.jsonl   one line per case: client, version, idempotence, spike mode, produce/fetch outcome
#   refused.log     the spike's log lines for requests it closed (APIs a client needed beyond the four)
#   versions.log    what each client negotiated, from the spike's capture of the first frames
# and the first request frame of every client, API and version under results/capture/ (golden frames).
#
# Usage: benchmark/kafka-spike/clients.sh [count]   (count of records per case, 200 by default)
# Needs the image: docker build -t malachi-166-kafka-spike:dev .  (from the repository root)
set -euo pipefail

cd "$(dirname "$0")"
COUNT="${1:-200}"
PROJECT="${COMPOSE_PROJECT_NAME:-malachi-166}-kafka-spike"
COMPOSE=(docker compose -f docker-compose.kafka-spike.yml -p "$PROJECT")
OUT="results/clients-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" results/capture
export SPIKE_CAPTURE_DIR="$PWD/results/capture"

cleanup() { "${COMPOSE[@]}" --profile clients down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${COMPOSE[@]}" --profile clients build java39 java44 >/dev/null

start_node() {
  SPIKE_IDEMPOTENCE="$1" "${COMPOSE[@]}" up -d --force-recreate --wait malachi >/dev/null
}

# kcat: produce COUNT lines key-i:value-i (every 7th with an empty key, sent as null by -Z), with two
# headers on every record, then consume them back from offset 0 as JSON, one object per line.
kcat_case() {
  local idempotence="$1" props=""
  [ "$idempotence" = "true" ] && props="-X enable.idempotence=true"
  local script="
    i=0; while [ \$i -lt $COUNT ]; do
      if [ \$((i % 7)) -eq 0 ]; then echo \":value-\$i\"; else echo \"key-\$i:value-\$i\"; fi
      i=\$((i+1))
    done | kcat -P -b malachi:9092 -t kafka-spike -p 0 -K : -Z -H trace=abc -H trace=again $props 2>/tmp/produce.err
    echo \"produce_exit=\$?\" >&2; cat /tmp/produce.err >&2
    kcat -C -b malachi:9092 -t kafka-spike -p 0 -o 0 -c $COUNT -e -J 2>/tmp/consume.err
    echo \"consume_exit=\$?\" >&2; cat /tmp/consume.err >&2
    kcat -V 2>&1 | grep -i version >&2"
  "${COMPOSE[@]}" run --rm -T kcat "$script" >"$OUT/kcat-$2-$idempotence.out" 2>"$OUT/kcat-$2-$idempotence.err" || true
  python3 -I - "$OUT/kcat-$2-$idempotence.out" "$OUT/kcat-$2-$idempotence.err" "$COUNT" "$idempotence" "$2" <<'PY' >>"$OUT/results.jsonl"
import json, sys
out, err, count, idem, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
records = [json.loads(l) for l in open(out) if l.startswith("{")]
errtext = open(err).read()
version = next((l for l in errtext.splitlines() if "ersion" in l and "librdkafka" in l), next((l for l in errtext.splitlines() if "ersion" in l), ""))
ok = 0
for r in records:
    i = r["offset"]
    key = None if i % 7 == 0 else f"key-{i}"
    good = r.get("key") == key and r.get("payload") == f"value-{i}" and r.get("headers") == ["trace", "abc", "trace", "again"] and r.get("ts", 0) > 0
    ok += good
print(json.dumps({"client": "kcat", "version": version.strip(), "idempotence": idem, "spike_idempotence": mode,
                  "fetched": len(records), "matched": ok, "count": count,
                  "produce_exit": next((l.split("=")[1] for l in errtext.splitlines() if l.startswith("produce_exit=")), "?"),
                  "stderr": " | ".join(l for l in errtext.splitlines() if l.startswith("%"))[:600]}))
PY
}

java_case() {
  local service="$1" idempotence="$2" mode="$3" line
  line=$("${COMPOSE[@]}" run --rm -T "$service" malachi:9092 kafka-spike "$COUNT" "$idempotence" 2>"$OUT/$service-$mode-$idempotence.err" | grep '^{' | tail -1 || true)
  [ -n "$line" ] || line='{"client":"java","produce":"no-output"}'
  echo "$line" | jq -c --arg mode "$mode" --arg service "$service" '. + {spike_idempotence: $mode, service: $service}' >>"$OUT/results.jsonl"
}

for mode in hide advertise; do
  for case in "java39 default" "java39 false" "java44 default" "java44 false" "kcat default" "kcat true"; do
    set -- $case
    echo "== spike idempotence=$mode, $1 idempotence=$2"
    start_node "$mode"
    if [ "$1" = kcat ]; then kcat_case "$2" "$mode"; else java_case "$1" "$2" "$mode"; fi
    "${COMPOSE[@]}" logs --no-color malachi 2>/dev/null | grep -E "Kafka spike closed" | sed "s/^/[$mode $1 $2] /" >>"$OUT/refused.log" || true
    tail -1 "$OUT/results.jsonl"
  done
done

ls results/capture >"$OUT/captured-frames.txt"
echo "results in benchmark/kafka-spike/$OUT"
