#!/usr/bin/env sh
# Paired A/B of the sealed-copy integrity probe (issue #241): the baseline tree against the branch tree, with
# an A-A control, interleaved by run, at 1,000 and 10,000 sealed segments on three replicas. Then, on the branch
# tree only, the sweep that chooses the default chunk. See benchmark/integrity_probe_ab.exs for what is measured.
# Needs Elixir on PATH and a real filesystem under AB_DIR (Linux, not tmpfs, not macOS).
#
# Usage: benchmark/integrity_probe_ab.sh BASELINE_TREE BRANCH_TREE [OUT_DIR]
#   AB_REPS    repetitions per arm and case (default 5, the fewest that gives a verdict)
#   AB_SIZES   sealed segment counts (default 1000 10000)
#   AB_DIR     scratch directory for the fixtures (default $TMPDIR/integrity_probe_ab)
set -eu

BASELINE=$(cd "$1" && pwd)
BRANCH=$(cd "$2" && pwd)
OUT=${3:-${TMPDIR:-/tmp}/integrity_probe_ab_results}
REPS=${AB_REPS:-5}
SIZES=${AB_SIZES:-1000 10000}
export AB_DIR=${AB_DIR:-${TMPDIR:-/tmp}/integrity_probe_ab}

. "$BRANCH/benchmark/support/ab_lib.sh"

# The harness is new with #241, so the baseline tree gets the branch's copy. A sample only calls what both
# trees have (`SelfHealing.heal_sealed/4`, `ReplicationServer.start_link/1`), so the baseline measures its own
# probe. The sweep passes options only the branch knows, and runs on the branch alone.
mkdir -p "$BASELINE/benchmark/support"
cp "$BRANCH/benchmark/integrity_probe_ab.exs" "$BASELINE/benchmark/integrity_probe_ab.exs"
cp "$BRANCH/benchmark/support/paired_stats.exs" "$BASELINE/benchmark/support/paired_stats.exs"
cp "$BRANCH/benchmark/support/ab_run.exs" "$BASELINE/benchmark/support/ab_run.exs"

run_one() {
  kase=$1 rep=$2 arm=$3
  (cd "$(tree_of "$arm")" && AB_MODE=sample AB_N="${kase#n}" mix run --no-start benchmark/integrity_probe_ab.exs) \
    >"$OUT/$kase/$rep-$arm.out" 2>&1
}

rm -rf "$OUT"
mkdir -p "$OUT"
build "$BASELINE"
build "$BRANCH"

expected=""
for n in $SIZES; do
  say "fixture: $n sealed segments"
  (cd "$BRANCH" && AB_MODE=fixture AB_N="$n" mix run --no-start benchmark/integrity_probe_ab.exs)
  # Writing the fixture keeps one log open per segment per replica, so a low descriptor limit fails it (run
  # with `ulimit -n` well above 3 x the largest size). A crash there can still leave mix exiting 0.
  if [ ! -f "$AB_DIR/fixture-$n/metadata.bin" ]; then
    say "fixture $n was not written; is ulimit -n ($(ulimit -n)) above 3 x $n?"
    exit 1
  fi
  run_case "n$n" "$REPS"
  expected="$expected n$n"
done

say "analysis"
# Never through a pipe: POSIX sh has no pipefail, so `| tee` would hand back tee's status and a REGRESSION (1) or
# NO VERDICT (2) from the analyzer would end this script with 0.
status=0
(cd "$BRANCH" && AB_MODE=analyze AB_RESULTS="$OUT" AB_OUT="$OUT/verdict.json" AB_EXPECTED="$expected" \
  mix run --no-start benchmark/integrity_probe_ab.exs) >"$OUT/verdict.txt" 2>&1 || status=$?
cat "$OUT/verdict.txt"

say "calls per pass (one sample of each arm)"
for kase in $expected; do
  for arm in main_a1 branch; do
    printf '%s %s: ' "$kase" "$arm"
    sed -n 's/^AB_SAMPLE //p' "$OUT/$kase/1-$arm.out"
  done
done >"$OUT/calls.txt"
cat "$OUT/calls.txt"

for n in $SIZES; do
  say "chunk sweep at $n sealed segments (branch)"
  # Captured to a file rather than piped, so a crashed sweep stops the script (set -e) instead of leaving a
  # truncated table behind a 0 exit.
  (cd "$BRANCH" && AB_MODE=sweep AB_N="$n" mix run --no-start benchmark/integrity_probe_ab.exs) >"$OUT/sweep-$n.txt" 2>&1
  cat "$OUT/sweep-$n.txt"
done

exit "$status"
