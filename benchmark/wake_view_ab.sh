#!/usr/bin/env sh
# Paired A/B of the consume stream wake: the baseline tree against the branch tree, with an A-A control,
# interleaved by run. See benchmark/wake_view_ab.exs for what is measured and support/paired_stats.exs
# for the verdict rule. Needs Elixir on PATH; only a Linux run counts.
#
# Usage: benchmark/wake_view_ab.sh BASELINE_TREE BRANCH_TREE [OUT_DIR]
#   AB_REPS  repetitions per arm (default 5, a verdict needs at least 5)
#   AB_DIR   scratch directory for the broker's data (default $TMPDIR/wake_view_ab)
set -eu

BASELINE=$(cd "$1" && pwd)
BRANCH=$(cd "$2" && pwd)
OUT=${3:-${TMPDIR:-/tmp}/wake_view_ab_results}
REPS=${AB_REPS:-5}
export AB_DIR=${AB_DIR:-${TMPDIR:-/tmp}/wake_view_ab}

. "$BRANCH/benchmark/support/ab_lib.sh"

# The harness is new with the view epoch, so the baseline tree gets the branch's copy, with the support
# files it loads. It only calls APIs both trees have (`BrokerServer.start_link/2`, `create_topic/3`,
# `produce/3`, `open_consume/4`, `arm_consume/3`, `close_stream/2`), so the baseline measures its own wake.
mkdir -p "$BASELINE/benchmark/support"
for file in wake_view_ab.exs support/ab_run.exs support/paired_stats.exs; do
  cp "$BRANCH/benchmark/$file" "$BASELINE/benchmark/$file"
done

# One sample for `arm`, captured whole: the analyzer finds the numbers in it.
run_one() {
  kase=$1 rep=$2 arm=$3
  (cd "$(tree_of "$arm")" && AB_MODE=sample mix run benchmark/wake_view_ab.exs) >"$OUT/$kase/$rep-$arm.out" 2>&1
}

rm -rf "$OUT"
mkdir -p "$OUT"
build "$BASELINE"
build "$BRANCH"
run_case wake "$REPS"

say "analyzing"
cd "$BRANCH"
AB_MODE=analyze AB_RESULTS="$OUT" AB_OUT="$OUT/report.json" mix run --no-start benchmark/wake_view_ab.exs
