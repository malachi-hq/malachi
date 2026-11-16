#!/usr/bin/env bash
# One sample of the loop stall of issue #283 on the three-node cluster, for the tree this script sits in.
#
# Starts a fresh RF=3 cluster on the per-node named volumes (scripts/chaos_lib.sh), seeds single-range
# topics through node 1, then samples node 1's `GET /ready` every 20ms (benchmark/support/ready_probe.exs)
# for 55s: 15s healthy, then node 3 frozen with `docker pause` for 40s, which is a peer that drops what it
# is sent rather than refusing it, so every call to it costs its whole timeout. 40s stays under the
# distribution tick (60s), past which the peers disconnect, calls fail at once and the stall would vanish
# from the measurement. Preallocation stays off (the cluster compose's default), so what is measured is the
# recovery's probes of unreachable primaries alone.
#
# Usage: benchmark/loop_stall_cluster.sh OUT_FILE
#   STALL_TOPICS (default 30), SKIP_BUILD=1 to reuse the images, SRV_CPUSET (1,2,3), LT_CPUSET (0)
# Chaos drills and cluster benchmarks are serial across worktrees: chaos_lib refuses a second cluster.
set -u
OUT_FILE=$1
cd "$(dirname "$0")/.."
export RF=${RF:-3} MALACHI_DATA_ROOT=/data SRV_CPUSET=${SRV_CPUSET:-1,2,3} LT_CPUSET=${LT_CPUSET:-0}
export SRV_ERL_FLAGS=${SRV_ERL_FLAGS:-+S 3:3}
. scripts/chaos_lib.sh

[ "${SKIP_BUILD:-0}" = 1 ] || build_images
start_cluster

$COMPOSE run --rm -T -v "$PWD/benchmark:/bench" -e PROBE_TOPICS="${STALL_TOPICS:-30}" -e PROBE_SECONDS=55 \
  --entrypoint sh loadtest -c "cd /app && mix run --no-start /bench/support/ready_probe.exs" >"$WORK/probe.out" 2>&1 &
probe=$!

for _ in $(seq 1 240); do
  grep -q READY_PROBE_STARTED "$WORK/probe.out" 2>/dev/null && break
  sleep 1
done
grep -q READY_PROBE_STARTED "$WORK/probe.out" || { cat "$WORK/probe.out"; $COMPOSE down -v >/dev/null 2>&1; exit 1; }

sleep 15
docker pause malachi-cluster-3 >/dev/null
sleep 40
docker unpause malachi-cluster-3 >/dev/null
wait "$probe"
cp "$WORK/probe.out" "$OUT_FILE"
$COMPOSE down -v >/dev/null 2>&1
grep -q '^READY_PROBE ' "$OUT_FILE"
