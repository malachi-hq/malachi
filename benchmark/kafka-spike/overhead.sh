#!/usr/bin/env bash
# The Kafka spike's overhead against the native protocol (#166), with the same generator on both sides
# (mix malachi.loadtest, --wire malachi against --wire kafka), in Docker (Linux), a fresh node per run.
#
# Each repetition runs both wires back to back, in alternating order (malachi first on odd repetitions,
# kafka first on even ones), so drift in the host lands on both sides equally. Cases:
#   latency:    1 connection, batch 1, pipeline 1  (one request at a time: the per-request cost)
#   throughput: 16 connections, batch 10, pipeline 4
# each as a produce run and as a fetch run over a prepopulated backlog. Records of 256 bytes.
#
# Then the codec alone (codec_bench.exs beside this script, run in the generator's image): how long decoding
# a Produce and encoding a Fetch response take, which is the part of the overhead that is the gateway's
# own and not the broker's.
#
# Writes results/overhead-<stamp>/runs.jsonl (one report per run, with its wire, case, scenario,
# repetition and order), summary.txt (medians per wire and case, and the kafka/malachi ratio), codec.txt.
#
# Usage: benchmark/kafka-spike/overhead.sh   (REPS=5 DUR=10 WARM=2 SCENARIOS="produce fetch" by default)
# Needs the image: docker build -t malachi-166-kafka-spike:dev .  (from the repository root)
set -euo pipefail

cd "$(dirname "$0")"
REPS="${REPS:-5}"
DUR="${DUR:-10}"
WARM="${WARM:-2}"
SCENARIOS="${SCENARIOS:-produce fetch}"
PROJECT="${COMPOSE_PROJECT_NAME:-malachi-166}-kafka-spike-overhead"
COMPOSE=(docker compose -f docker-compose.kafka-spike.yml -p "$PROJECT")
OUT="results/overhead-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" results/capture
export SPIKE_CAPTURE_DIR="$PWD/results/capture"

cleanup() { "${COMPOSE[@]}" --profile overhead down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${COMPOSE[@]}" --profile overhead build loadtest >/dev/null

declare -A CASES=(
  [latency]="--connections 1 --batch 1 --pipeline 1"
  [throughput]="--connections 16 --batch 10 --pipeline 4"
)

run_one() { # rep order wire case scenario
  local rep="$1" order="$2" wire="$3" case="$4" scenario="$5" args
  "${COMPOSE[@]}" up -d --force-recreate --wait malachi >/dev/null
  args="--host malachi --scenario $scenario ${CASES[$case]} --record-size 256 --duration $DUR --warmup $WARM --json"
  [ "$scenario" = fetch ] && args="$args --prepopulate 20000 --max 100"
  if [ "$wire" = kafka ]; then
    args="$args --wire kafka --kafka-port 9092 --topic kafka-spike"
  else
    args="$args --pass malachi-local-only-admin --topic native-$rep-$scenario"
  fi
  local line
  line=$("${COMPOSE[@]}" --profile overhead run --rm -T loadtest $args 2>"$OUT/$wire-$case-$scenario-$rep.err" | grep '^{' | tail -1 || true)
  [ -n "$line" ] || line='{"error":"no report"}'
  echo "$line" | jq -c --arg wire "$wire" --arg case "$case" --arg scenario "$scenario" --argjson rep "$rep" --arg order "$order" \
    '{wire: $wire, case: $case, scenario: $scenario, rep: $rep, order: $order} + .' >>"$OUT/runs.jsonl"
  tail -1 "$OUT/runs.jsonl" | jq -r '"  \(.wire) \(.case) \(.scenario) rep \(.rep): \(.records_per_s // "?") rec/s, p50 \(.latency_ms.p50 // "?") ms, p99 \(.latency_ms.p99 // "?") ms, err \(.errors // "?") drop \(.dropped // "?")"'
}

for rep in $(seq 1 "$REPS"); do
  if [ $((rep % 2)) -eq 1 ]; then order="malachi-first"; wires="malachi kafka"; else order="kafka-first"; wires="kafka malachi"; fi
  for case in latency throughput; do
    for scenario in $SCENARIOS; do
      for wire in $wires; do run_one "$rep" "$order" "$wire" "$case" "$scenario"; done
    done
  done
done

python3 -I - "$OUT/runs.jsonl" >"$OUT/summary.txt" <<'PY'
import json, statistics, sys
runs = [json.loads(l) for l in open(sys.argv[1])]
groups = {}
for r in runs:
    groups.setdefault((r["case"], r["scenario"], r["wire"]), []).append(r)
def med(rs, f):
    vals = [f(r) for r in rs if f(r) is not None]
    return statistics.median(vals) if vals else None
print(f"{'case':<11}{'scenario':<9}{'wire':<9}{'n':>3}{'rec/s':>12}{'ops/s':>10}{'p50 ms':>9}{'p99 ms':>9}{'err':>6}{'drop':>6}")
for (case, scenario, wire), rs in sorted(groups.items()):
    ok = [r for r in rs if "records_per_s" in r]
    print(f"{case:<11}{scenario:<9}{wire:<9}{len(ok):>3}{med(ok, lambda r: r['records_per_s']) or 0:>12.0f}"
          f"{med(ok, lambda r: r['ops_per_s']) or 0:>10.0f}{med(ok, lambda r: r['latency_ms']['p50']) or 0:>9.3f}"
          f"{med(ok, lambda r: r['latency_ms']['p99']) or 0:>9.3f}{sum(r.get('errors', 0) for r in ok):>6}{sum(r.get('dropped', 0) for r in ok):>6}")
print()
print("kafka / malachi, medians:")
for case in ("latency", "throughput"):
    for scenario in ("produce", "fetch"):
        k = [r for r in groups.get((case, scenario, "kafka"), []) if "records_per_s" in r]
        n = [r for r in groups.get((case, scenario, "malachi"), []) if "records_per_s" in r]
        if k and n:
            print(f"  {case} {scenario}: throughput x{med(k, lambda r: r['records_per_s']) / med(n, lambda r: r['records_per_s']):.2f}, "
                  f"p50 x{med(k, lambda r: r['latency_ms']['p50']) / med(n, lambda r: r['latency_ms']['p50']):.2f}, "
                  f"p99 x{med(k, lambda r: r['latency_ms']['p99']) / med(n, lambda r: r['latency_ms']['p99']):.2f}")
PY
cat "$OUT/summary.txt"

echo "== codec alone"
"${COMPOSE[@]}" --profile overhead run --rm -T -v "$PWD/codec_bench.exs:/app/codec_bench.exs:ro" --entrypoint mix loadtest \
  run --no-start codec_bench.exs >"$OUT/codec.txt" 2>&1 || true
cat "$OUT/codec.txt"
echo "results in benchmark/kafka-spike/$OUT"
