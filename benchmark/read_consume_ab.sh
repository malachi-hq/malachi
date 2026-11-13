#!/usr/bin/env sh
# Paired A/B of the consume read (#198): the baseline tree against the branch tree, with an A-A control,
# interleaved by run. See benchmark/read_consume_ab.exs for what is measured and support/paired_stats.exs
# for the verdict rule. Needs Elixir on PATH; only a Linux run counts.
#
# Usage: benchmark/read_consume_ab.sh BASELINE_TREE BRANCH_TREE [OUT_DIR]
#   AB_REPS  repetitions per arm (default 5, a verdict needs at least 5)
#   AB_DIR   scratch directory for the broker's data (default $TMPDIR/read_consume_ab)
set -eu

BASELINE=$(cd "$1" && pwd)
BRANCH=$(cd "$2" && pwd)
OUT=${3:-${TMPDIR:-/tmp}/read_consume_ab_results}
REPS=${AB_REPS:-5}
export AB_DIR=${AB_DIR:-${TMPDIR:-/tmp}/read_consume_ab}

. "$BRANCH/benchmark/support/ab_lib.sh"

# The harness is new with the purge, so the baseline tree gets the branch's copy, with the support files
# it loads. It only calls APIs both trees have (`BrokerServer.start_link/2`, `create_topic/3`, `produce/3`,
# `metadata/1`, `read_consume/4`), so the baseline measures its own read.
mkdir -p "$BASELINE/benchmark/support"
for file in read_consume_ab.exs support/ab_run.exs support/paired_stats.exs; do
  cp "$BRANCH/benchmark/$file" "$BASELINE/benchmark/$file"
done

# Each sample boots the application on its own empty data directories: the trees run different machine
# versions, and a baseline booting on a log the branch wrote at a newer version refuses to start.
run_one() {
  kase=$1 rep=$2 arm=$3
  data="$AB_DIR-app/$kase-$rep-$arm"
  rm -rf "$data"
  (cd "$(tree_of "$arm")" &&
    MALACHI_RA_DATA_DIR="$data/ra" MALACHI_LOG_DATA_DIR="$data/log" AB_MODE=sample mix run benchmark/read_consume_ab.exs) \
    >"$OUT/$kase/$rep-$arm.out" 2>&1
  rm -rf "$data"
}

rm -rf "$OUT"
mkdir -p "$OUT"
build "$BASELINE"
build "$BRANCH"
run_case read "$REPS"

say "analyzing"
cd "$BRANCH"
AB_MODE=analyze AB_RESULTS="$OUT" AB_OUT="$OUT/report.json" mix run --no-start benchmark/read_consume_ab.exs
