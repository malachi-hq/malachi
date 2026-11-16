#!/usr/bin/env sh
# Paired A/B of a broker restart's recovery (issue #283): the baseline tree against the branch tree, with an
# A-A control, interleaved by run over a grid of cells. See benchmark/restart_recovery_ab.exs for what is
# measured and the verdict rule. Linux only, on a real filesystem: run it through
# benchmark/restart_recovery_ab_docker.sh, which gives it a named volume and the container's overlay.
#
# Usage: benchmark/restart_recovery_ab.sh BASELINE_TREE BRANCH_TREE OUT_DIR
#   AB_CELLS  space separated cells, each CASE:RANGES:PREALLOC_BYTES:DIR_LABEL:REPS
#             (DIR_LABEL is volume or overlay; see AB_VOLUME_DIR and AB_OVERLAY_DIR)
#   AB_VOLUME_DIR   scratch on the named volume (default /data/restart_ab)
#   AB_OVERLAY_DIR  scratch on the container's own filesystem (default /scratch/restart_ab)
set -eu

BASELINE=$(cd "$1" && pwd)
BRANCH=$(cd "$2" && pwd)
OUT=$3
VOLUME_DIR=${AB_VOLUME_DIR:-/data/restart_ab}
OVERLAY_DIR=${AB_OVERLAY_DIR:-/scratch/restart_ab}

. "$BRANCH/benchmark/support/ab_lib.sh"

# The harness is new with #283, so the baseline tree gets the branch's copy with the support files it loads.
# It only calls APIs both trees have (`ReplicationServer`, `BrokerServer`, `MetadataServer`).
mkdir -p "$BASELINE/benchmark/support"
cp "$BRANCH/benchmark/restart_recovery_ab.exs" "$BASELINE/benchmark/restart_recovery_ab.exs"
for file in paired_stats.exs ab_run.exs; do
  cp "$BRANCH/benchmark/support/$file" "$BASELINE/benchmark/support/$file"
done

# One sample of the current cell for `arm`. A fresh BEAM per sample, so no arm inherits another's page cache
# state through the VM, and a fresh data directory (the .exs removes it).
run_one() {
  cell=$1 rep=$2 arm=$3
  (cd "$(tree_of "$arm")" &&
    AB_MODE=sample AB_CASE="$CELL_CASE" AB_RANGES="$CELL_RANGES" AB_PREALLOC="$CELL_PREALLOC" AB_DIR="$CELL_DIR" \
      MALACHI_AUDIT_LOG_PATH="$CELL_DIR.audit.log" \
      elixir --name "ab_$$@127.0.0.1" -S mix run benchmark/restart_recovery_ab.exs) >"$OUT/$cell/$rep-$arm.out" 2>&1
  # The writeback of what a sample wrote (64MB of zeros per range on the baseline) must not land inside the
  # next one. The first smoke run, before this line, reported a 40% SIGNAL between two identical trees on
  # the named volume while the A-A control called the same spread noise.
  sync
}

rm -rf "$OUT"
mkdir -p "$OUT" "$VOLUME_DIR" "$OVERLAY_DIR"
build "$BASELINE"
build "$BRANCH"

EXPECTED=""
for spec in $AB_CELLS; do
  IFS=: read -r CELL_CASE CELL_RANGES CELL_PREALLOC label reps <<EOF
$spec
EOF
  case "$label" in
    volume) CELL_DIR=$VOLUME_DIR/run ;;
    overlay) CELL_DIR=$OVERLAY_DIR/run ;;
    *) echo "unknown DIR_LABEL $label in $spec" >&2 && exit 64 ;;
  esac
  cell="$CELL_CASE-n$CELL_RANGES-p$CELL_PREALLOC-$label"
  run_case "$cell" "$reps"
  EXPECTED="$EXPECTED $cell"
done

say "analyzing"
cd "$BRANCH"
AB_MODE=analyze AB_RESULTS="$OUT" AB_OUT="$OUT/report.json" AB_EXPECTED="$EXPECTED" \
  mix run --no-start benchmark/restart_recovery_ab.exs
