#!/usr/bin/env sh
# Runs benchmark/restart_recovery_ab.sh on Linux, in a container, with its scratch on a Docker named volume
# (`volume` cells, the filesystem CI's nodes write to) and on the container's own overlay (`overlay` cells,
# where the numbers of issue #283 were first taken). Malachi is measured only on Linux.
#
# Usage: benchmark/restart_recovery_ab_docker.sh BASELINE_REF WORK_DIR
#   BASELINE_REF  a git ref of this repository (the branch tree is this checkout's working tree)
#   WORK_DIR      where the two trees and the results go. It must be a path the Docker VM shares (under
#                 /Users with Docker Desktop or Colima), never /tmp or /var/folders.
#   AB_CELLS      as in restart_recovery_ab.sh (default: one restart cell, for a smoke run)
#   SRV_CPUSET    the cores the run is pinned to (default 1,2,3)
#   AB_IMAGE      the Elixir image (default: the one benchmark/Dockerfile.loadtest pins)
set -eu

REF=$1
WORK=$(mkdir -p "$2" && cd "$2" && pwd)
REPO=$(cd "$(dirname "$0")/.." && pwd)
VOLUME=${AB_VOLUME:-malachi_restart_ab}
IMAGE=${AB_IMAGE:-$(sed -n 's/^FROM //p' "$REPO/benchmark/Dockerfile.loadtest" | head -1)}
CELLS=${AB_CELLS:-restart:10:67108864:volume:5}

case "$WORK" in
  /tmp/* | /private/* | /var/*) echo "WORK_DIR $WORK is not shared with the Docker VM" >&2 && exit 64 ;;
esac

# Both trees are copies: the container compiles its own Linux _build and deps into them, which must never
# land in the checkout (wrong architecture for the host's own builds).
rm -rf "$WORK/baseline" "$WORK/branch"
mkdir -p "$WORK/baseline" "$WORK/branch"
git -C "$REPO" archive "$REF" | tar -x -C "$WORK/baseline"
(cd "$REPO" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf - | tar -x -C "$WORK/branch")

docker volume create "$VOLUME" >/dev/null

# The default open file limit of a container (1024 under Colima) is below what a node with 1000 active ranges
# opens at recovery: the first full grid stopped there with emfile on the baseline, before any arm was timed.
docker run --rm \
  --ulimit nofile=65536:65536 \
  --cpuset-cpus "${SRV_CPUSET:-1,2,3}" \
  --memory 3g \
  -e ERL_FLAGS="+S 3:3" \
  -e MIX_ENV=dev \
  -e AB_CELLS="$CELLS" \
  -v "$VOLUME:/data" \
  -v "$WORK:/work" \
  "$IMAGE" \
  sh -c 'apk add --no-cache git build-base >/dev/null &&
    mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null &&
    mkdir -p /scratch &&
    sh /work/branch/benchmark/restart_recovery_ab.sh /work/baseline /work/branch /work/out'
