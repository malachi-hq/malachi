#!/usr/bin/env bash
# Asserts that every elixir base image pinned in the given Dockerfiles ships exactly the Erlang/OTP and
# Elixir versions in the given versions file.
#
#   scripts/check-image-runtime.sh <versions file> <Dockerfile>...
#
# CI installs Erlang/OTP and Elixir from .github/beam-versions, while the images take them from the elixir
# base image pinned by digest in Dockerfile (the release) and benchmark/Dockerfile.loadtest (the brokers of
# the chaos drills and the published benchmarks). The base tag floats to the latest OTP 28 patch under its
# digest, and nothing tied the two together, so the tests ran OTP 28.1 while the image shipped 28.5 without
# anyone noticing (#332). This fails whenever a digest bump in either Dockerfile moves its image to a runtime
# the tests do not run, until the versions file moves with it.
#
# What is compared is the full OTP version from the base image's OTP_VERSION file and the vsn of its
# elixir.app, read from disk without starting a VM. The erts version would not do: an OTP patch such as
# 28.5.0.7 changes ssl, stdlib and public_key and leaves erts alone. The base image rather than the built
# release is read because a release carries no OTP_VERSION; its erts and OTP applications are copied from
# this same image by the builder stage. Images are read as linux/amd64, the platform of the CI runners the
# versions file is installed on: the same digest ships other patches on arm64.
#
# Exits 0 when every image matches, 1 when one differs, a Dockerfile pins no elixir image or pins one
# without a digest, or an image cannot be read, and 2 on a usage error: fewer than two arguments or an
# empty one, a versions file that is missing or does not hold exactly one erlang and one elixir line with
# an Elixir built for that OTP major, a timeout that is not a whole number of seconds from 1 to 99999
# written without leading zeros, or no coreutils timeout on PATH.
#
# Each image read is bounded by RUNTIME_CHECK_TIMEOUT (seconds, default 300, which covers the pull), so an
# image that never answers fails the check instead of holding the CI job until its own limit. Requires
# coreutils timeout.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <versions file> <Dockerfile>..." >&2
  exit 2
fi
for arg in "$@"; do
  if [ -z "$arg" ]; then
    echo "usage: $0 <versions file> <Dockerfile>..." >&2
    exit 2
  fi
done

# Parameter expansion rather than dirname, which lives on the PATH this check may be run without.
case "$0" in
  */*) script_dir="${0%/*}" ;;
  *) script_dir=. ;;
esac
# shellcheck source=scripts/docker_check_lib.sh
source "$script_dir/docker_check_lib.sh"

versions_file="$1"
shift

# The default applies only when the variable is unset: set but empty is a mistake, refused below.
check_timeout="${RUNTIME_CHECK_TIMEOUT-300}"
require_positive_seconds RUNTIME_CHECK_TIMEOUT "$check_timeout"
require_coreutils_timeout

# Prints the version of the single line `<app> <version>` in the versions file, or exits 2. Comment lines
# start with #, as setup-beam ignores them too.
pinned_version() {
  local app="$1" lines
  lines="$(grep -E "^${app}[[:space:]]" "$versions_file" || true)"

  if [ -z "$lines" ] || [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "$versions_file must hold exactly one '$app <version>' line" >&2
    exit 2
  fi

  printf '%s\n' "$lines" | awk '{ print $2 }'
}

if [ ! -f "$versions_file" ]; then
  echo "versions file $versions_file does not exist" >&2
  exit 2
fi

otp="$(pinned_version erlang)"
elixir_pin="$(pinned_version elixir)"
# setup-beam needs an Elixir built for the OTP major it installs, written as <version>-otp-<major>.
elixir="${elixir_pin%-otp-*}"
if [ "$elixir" = "$elixir_pin" ] || [ "${elixir_pin##*-otp-}" != "${otp%%.*}" ]; then
  echo "$versions_file pins elixir $elixir_pin, which is not <version>-otp-${otp%%.*} for erlang $otp" >&2
  exit 2
fi

# Run inside each image by sh. One OTP= line per OTP installation, so an image with two fails as ambiguous
# instead of passing on the one that matches. Single quoted on purpose: it expands inside the image.
# shellcheck disable=SC2016
probe='for f in /usr/local/lib/erlang/releases/*/OTP_VERSION; do printf "OTP=%s\n" "$(cat "$f")"; done
sed -n "s/.*{vsn,\"\([^\"]*\)\"}.*/ELIXIR=\1/p" /usr/local/lib/elixir/lib/elixir/ebin/elixir.app'

# Prints the value of the single <key>= line in $3, or fails naming the image ($1) and showing the output.
sentinel_value() {
  local image="$1" key="$2" output="$3" lines
  lines="$(printf '%s\n' "$output" | grep -E "^$key=[^[:space:]]+$" || true)"

  if [ -z "$lines" ] || [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "FAIL: $image printed no single $key=<version> line; its output was:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  printf '%s\n' "${lines#"$key="}"
}

failed=0
checked=" "

for dockerfile in "$@"; do
  if [ ! -f "$dockerfile" ]; then
    echo "FAIL: $dockerfile does not exist" >&2
    failed=1
    continue
  fi

  # Every stage built from the elixir image, as `FROM [--platform=...] elixir:<tag>[@<digest>] [AS name]`.
  images="$(awk 'toupper($1) == "FROM" { for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; break } }' "$dockerfile" |
    grep -E '^(docker\.io/)?(library/)?elixir[:@]' || true)"

  if [ -z "$images" ]; then
    echo "FAIL: $dockerfile has no FROM elixir stage to compare" >&2
    failed=1
    continue
  fi

  while IFS= read -r image; do
    if [[ "$image" != *@sha256:* ]]; then
      echo "FAIL: $dockerfile builds from $image, which is not pinned by digest, so what it ships can move under the check" >&2
      failed=1
      continue
    fi

    # Both Dockerfiles pin the same digest today: read it once, and say so for every Dockerfile after the first.
    case "$checked" in *" $image "*)
      echo "$dockerfile: $image, compared above"
      continue
      ;;
    esac
    checked="$checked$image "

    status=0
    output="$(timeout "$check_timeout" docker run --rm --platform linux/amd64 --entrypoint sh "$image" -c "$probe" 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "FAIL: $image (from $dockerfile) exited with status $status (124 is the ${check_timeout}s timeout); its output was:" >&2
      printf '%s\n' "$output" >&2
      failed=1
      continue
    fi

    shipped_otp="$(sentinel_value "$image" OTP "$output")" || { failed=1; continue; }
    shipped_elixir="$(sentinel_value "$image" ELIXIR "$output")" || { failed=1; continue; }

    if [ "$shipped_otp" != "$otp" ] || [ "$shipped_elixir" != "$elixir" ]; then
      echo "FAIL: $dockerfile builds from $image, which ships OTP $shipped_otp and Elixir $shipped_elixir, but $versions_file pins OTP $otp and Elixir $elixir." >&2
      echo "Move $versions_file to the image's runtime (or the digest back), so the tests run what ships." >&2
      failed=1
      continue
    fi

    echo "$dockerfile: $image ships OTP $otp and Elixir $elixir, as $versions_file pins"
  done <<< "$images"
done

exit "$failed"
