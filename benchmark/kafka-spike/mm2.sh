#!/usr/bin/env bash
# Which Kafka APIs MirrorMaker 2 calls to copy a topic and its consumer group offsets (#166), measured in
# Docker (Linux) rather than read from its source:
#
#   1. Two single-node Kafka 4.4.0 clusters, src and dst, log every request (kafka.request.logger=DEBUG).
#      Topic orders (3 partitions) gets 1000 records on src and group app commits after 500 of them, then
#      MirrorMaker 2 (4.4.0) copies src to dst for MM2_SECONDS. The distinct API, version and client of
#      every request MirrorMaker 2 made, on each cluster, is the list (the harness's own tools use client
#      ids starting with harness- and are left out). Whether dst ended up with src.orders and the group's
#      translated offsets is recorded beside it.
#   2. The same MirrorMaker 2 with the Malachi spike as its target: the spike logs the first API it does
#      not answer before closing the connection, which is where a gateway without it would stop.
#
# Writes results/mm2-<stamp>/: apis-src.tsv, apis-dst.tsv (api_key, name, versions, client), dst-state.txt,
# spike-refused.log, mm2-phase2-errors.txt, and the raw logs gzipped.
#
# A Java client checks ApiVersions before it sends: an API the spike does not advertise fails inside the
# client and never reaches the spike, so spike-refused.log stays empty for MirrorMaker 2 and the reason it
# stopped is in mm2-phase2-errors.txt.
#
# Usage: benchmark/kafka-spike/mm2.sh   (MM2_SECONDS=90 by default; MM2_PHASES=2 runs the second phase alone)
# Needs the image: docker build -t malachi-166-kafka-spike:dev .  (from the repository root)
set -euo pipefail

cd "$(dirname "$0")"
MM2_SECONDS="${MM2_SECONDS:-90}"
MM2_PHASES="${MM2_PHASES:-1 2}"
PROJECT="${COMPOSE_PROJECT_NAME:-malachi-166}-kafka-spike-mm2"
COMPOSE=(docker compose -f docker-compose.kafka-spike.yml -f docker-compose.mm2.yml -p "$PROJECT")
OUT="results/mm2-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" results/capture
export SPIKE_CAPTURE_DIR="$PWD/results/capture"

cleanup() { "${COMPOSE[@]}" --profile mm2 down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

kafka() { "${COMPOSE[@]}" exec -T "$1" bash -c "cd /opt/kafka/bin && $2"; }

if [[ " $MM2_PHASES " == *" 1 "* ]]; then
echo "== phase 1: MirrorMaker 2 between two Kafka clusters"
"${COMPOSE[@]}" up -d --wait src dst >/dev/null
kafka src "./kafka-topics.sh --bootstrap-server src:9092 --create --topic orders --partitions 3 --replication-factor 1 --command-config <(echo client.id=harness-admin)" >/dev/null
kafka src "./kafka-producer-perf-test.sh --topic orders --num-records 1000 --record-size 100 --throughput -1 --producer-props bootstrap.servers=src:9092 client.id=harness-producer" >/dev/null
kafka src "./kafka-console-consumer.sh --bootstrap-server src:9092 --topic orders --group app --from-beginning --max-messages 500 --consumer-property client.id=harness-consumer --timeout-ms 20000" >/dev/null 2>&1 || true

"${COMPOSE[@]}" --profile mm2 up -d mm2 >/dev/null
echo "   MirrorMaker 2 running for ${MM2_SECONDS}s"
sleep "$MM2_SECONDS"
"${COMPOSE[@]}" --profile mm2 logs --no-color mm2 >"$OUT/mm2-phase1.log" 2>&1 || true
"${COMPOSE[@]}" --profile mm2 stop mm2 >/dev/null

{
  echo "# topics on dst"
  kafka dst "./kafka-topics.sh --bootstrap-server dst:9092 --list --command-config <(echo client.id=harness-admin)"
  echo "# group app on src"
  kafka src "./kafka-consumer-groups.sh --bootstrap-server src:9092 --describe --group app --command-config <(echo client.id=harness-admin)" 2>&1
  echo "# group app on dst (offsets MirrorMaker 2 translated)"
  kafka dst "./kafka-consumer-groups.sh --bootstrap-server dst:9092 --describe --group app --command-config <(echo client.id=harness-admin)" 2>&1
} >"$OUT/dst-state.txt"

for cluster in src dst; do
  "${COMPOSE[@]}" logs --no-color "$cluster" >"$OUT/$cluster.log" 2>&1
  python3 -I - "$OUT/$cluster.log" >"$OUT/apis-$cluster.tsv" <<'PY'
import re, sys
names = {0: "Produce", 1: "Fetch", 2: "ListOffsets", 3: "Metadata", 8: "OffsetCommit", 9: "OffsetFetch",
         10: "FindCoordinator", 11: "JoinGroup", 12: "Heartbeat", 13: "LeaveGroup", 14: "SyncGroup",
         15: "DescribeGroups", 16: "ListGroups", 17: "SaslHandshake", 18: "ApiVersions", 19: "CreateTopics",
         20: "DeleteTopics", 21: "DeleteRecords", 22: "InitProducerId", 23: "OffsetForLeaderEpoch",
         24: "AddPartitionsToTxn", 25: "AddOffsetsToTxn", 26: "EndTxn", 28: "TxnOffsetCommit",
         29: "DescribeAcls", 30: "CreateAcls", 31: "DeleteAcls", 32: "DescribeConfigs", 33: "AlterConfigs",
         35: "DescribeLogDirs", 36: "SaslAuthenticate", 37: "CreatePartitions", 42: "DeleteGroups",
         44: "IncrementalAlterConfigs", 47: "OffsetDelete", 48: "DescribeClientQuotas", 50: "DescribeUserScramCredentials",
         60: "DescribeCluster", 61: "DescribeProducers", 65: "DescribeTransactions", 66: "ListTransactions",
         68: "ConsumerGroupHeartbeat", 69: "ConsumerGroupDescribe", 71: "GetTelemetrySubscriptions", 72: "PushTelemetry",
         75: "DescribeTopicPartitions"}
pattern = re.compile(r'"requestApiKey":(\d+),"requestApiVersion":(\d+),"correlationId":-?\d+,"clientId":"([^"]*)"')
seen = {}
for line in open(sys.argv[1], errors="replace"):
    m = pattern.search(line)
    if not m:
        continue
    key, vsn, client = int(m.group(1)), int(m.group(2)), m.group(3)
    # the harness's own tools, and the broker's own controller traffic (client id: its node id)
    if client.startswith("harness-") or client.startswith("broker-") or client in ("", "1"):
        continue
    # one row per API and kind of client, the client id stripped of its numbering
    kind = re.sub(r"-\d+$", "", client)
    seen.setdefault((key, kind), set()).add(vsn)
print("api_key\tname\tversions\tclient")
for (key, kind), vsns in sorted(seen.items()):
    print(f"{key}\t{names.get(key, '?')}\t{','.join(map(str, sorted(vsns)))}\t{kind}")
PY
  echo "   $cluster: $(($(wc -l <"$OUT/apis-$cluster.tsv") - 1)) API and client pairs"
done

fi

if [[ " $MM2_PHASES " == *" 2 "* ]]; then
echo "== phase 2: MirrorMaker 2 with the spike as its target"
"${COMPOSE[@]}" up -d --wait src >/dev/null
SPIKE_IDEMPOTENCE=advertise "${COMPOSE[@]}" up -d --wait malachi >/dev/null
MM2_PROPERTIES=mm2-spike.properties "${COMPOSE[@]}" --profile mm2 up -d --force-recreate mm2 >/dev/null
echo "   MirrorMaker 2 running for ${MM2_SECONDS}s"
sleep "$MM2_SECONDS"
"${COMPOSE[@]}" --profile mm2 logs --no-color mm2 >"$OUT/mm2-phase2.log" 2>&1 || true
"${COMPOSE[@]}" logs --no-color malachi 2>/dev/null | grep -E "Kafka spike closed" | sort | uniq -c | sort -rn >"$OUT/spike-refused.log" || true
grep -E "ERROR|WARN" "$OUT/mm2-phase2.log" | grep -vE "Unsafe|deprecated" | sed -E 's/^mm2-1 *\| //' | cut -c1-300 | sort | uniq -c | sort -rn | head -20 >"$OUT/mm2-phase2-errors.txt" || true
head -10 "$OUT/spike-refused.log" "$OUT/mm2-phase2-errors.txt"
fi

gzip -9 "$OUT"/*.log 2>/dev/null || true
echo "results in benchmark/kafka-spike/$OUT"
