#!/usr/bin/env bash
# Paired A/B of the broker loop stall with one node frozen (issue #283, Part 2): the baseline tree against
# the branch tree on the three-node cluster, with an A-A control, interleaved by run, arm order shuffled per
# repetition (benchmark/support/ab_lib.sh). One sample is one fresh cluster (benchmark/loop_stall_cluster.sh)
# and is judged by benchmark/loop_stall_ab.exs. Linux only: Docker under Colima or a Linux host.
#
# Usage: benchmark/loop_stall_ab.sh BASELINE_TREE BRANCH_TREE OUT_DIR
#   STALL_REPS  repetitions per arm (default 5, the minimum ab_run.exs gives a verdict for)
# Both trees must sit on a path the Docker VM shares (under /Users with Colima), and no other cluster may be
# running: check `docker ps` first.
set -eu
BASELINE=$(cd "$1" && pwd)
BRANCH=$(cd "$2" && pwd)
OUT=$3
REPS=${STALL_REPS:-5}

. "$BRANCH/benchmark/support/ab_lib.sh"

for tree in "$BASELINE" "$BRANCH"; do
  mkdir -p "$tree/benchmark/support"
  [ "$tree" = "$BRANCH" ] && continue
  cp "$BRANCH/benchmark/loop_stall_cluster.sh" "$tree/benchmark/loop_stall_cluster.sh"
  cp "$BRANCH/benchmark/support/ready_probe.exs" "$tree/benchmark/support/ready_probe.exs"
done

# The first sample of each tree builds its image; the rest reuse it.
run_one() {
  kase=$1 rep=$2 arm=$3
  tree=$(tree_of "$arm")
  skip=0
  [ -e "$tree/.loop_stall_built" ] && skip=1
  SKIP_BUILD=$skip bash "$tree/benchmark/loop_stall_cluster.sh" "$OUT/$kase/$rep-$arm.out" >"$OUT/$kase/$rep-$arm.log" 2>&1 &&
    touch "$tree/.loop_stall_built"
}

rm -f "$BASELINE/.loop_stall_built" "$BRANCH/.loop_stall_built"
mkdir -p "$OUT"
run_case stall "$REPS"

say "analyzing"
cd "$BRANCH"
AB_RESULTS="$OUT" AB_OUT="$OUT/report.json" mix run --no-start benchmark/loop_stall_ab.exs
