#!/usr/bin/env bash
# Records what a release needs from each pull request merged since the previous release (issue #366):
#
#   scripts/release-prs.sh <prev_tag|""> <head> <out_dir>
#
# For every first-parent commit in <prev_tag>..<head> that names its pull request (`... (#N)` from a squash, or
# `Merge pull request #N from ...`), writes <out_dir>/N.json with the pull request's labels (names), its
# author's login, that author's permission on the repository (admin, maintain, write, triage, read or none)
# and its body. release-bump.sh reads the labels, release-notes.sh the body and the permission. With no
# previous tag (the first release) nothing is fetched: the whole history would be one call per pull request
# ever merged, and the first release has no use for them.
#
# The permission, and not the pull request's author_association: in a repository owned by an organization
# every member is MEMBER, whatever they may do in this repository, and nobody is OWNER.
#
# Needs GITHUB_REPOSITORY and an authenticated gh (GH_TOKEN). Every response goes straight to a file through
# gh's own jq filter: nothing in a title or a body is ever evaluated by a shell, and a login is used in a path
# only when it is made of the characters GitHub allows in one.
#
# A pull request that no longer exists (HTTP 404) is recorded as having no labels and no body, and an author
# GitHub knows no permission for (HTTP 404, a bot, a deleted account) as `none`. Anything else is retried
# RELEASE_PRS_ATTEMPTS times (default 3), RELEASE_PRS_RETRY_DELAY seconds apart (default 5), and then fails
# the run: a release built on a partial read could miss a label that decides its version.
#
# Exits 0 on success, 1 when a fetch keeps failing, 2 on a usage error.
set -uo pipefail

# shellcheck source=scripts/release_lib.sh
. "$(dirname "$0")/release_lib.sh"

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -eq 3 ] || usage
prev=$1
head=$2
out=$3
[ -n "${GITHUB_REPOSITORY:-}" ] || {
  echo "release-prs: GITHUB_REPOSITORY is not set" >&2
  exit 2
}
git rev-parse --verify -q "$head^{commit}" > /dev/null || {
  echo "release-prs: $head names no commit" >&2
  exit 2
}
mkdir -p "$out" || exit 2
[ -n "$prev" ] || exit 0

attempts=${RELEASE_PRS_ATTEMPTS:-3}
delay=${RELEASE_PRS_RETRY_DELAY:-5}
work=$(mktemp -d "${TMPDIR:-/tmp}/release-prs.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# api_get <path under the repository> <jq filter> <file>: 0 on success, 4 when GitHub answers 404, 1 when
# every attempt failed otherwise.
api_get() {
  local path=$1 filter=$2 file=$3 try
  for ((try = 1; try <= attempts; try++)); do
    if gh api "repos/$GITHUB_REPOSITORY/$path" --jq "$filter" > "$file" 2> "$work/err"; then
      return 0
    fi
    grep -q 'HTTP 404' "$work/err" && return 4
    echo "release-prs: reading $path failed (attempt $try/$attempts): $(head -c 300 "$work/err")" >&2
    [ "$try" -lt "$attempts" ] && sleep "$delay"
  done
  return 1
}

fetch() {
  local n=$1 login permission rc
  api_get "pulls/$n" '{labels: [.labels[]?.name], author: (.user.login // ""), body: .body}' "$work/pr.json"
  rc=$?
  if [ "$rc" -eq 4 ]; then
    echo "release-prs: #$n does not exist (HTTP 404); recorded with no labels and no body" >&2
    printf '%s\n' '{"labels":[],"author":"","body":null}' > "$work/pr.json"
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi

  login=$(jq -r '.author' "$work/pr.json")
  permission=none
  if [[ $login =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    api_get "collaborators/$login/permission" '.permission // "none"' "$work/permission"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      permission=$(cat "$work/permission")
    elif [ "$rc" -ne 4 ]; then
      return 1
    fi
  fi
  jq --arg permission "$permission" '. + {permission: $permission}' "$work/pr.json" > "$out/$n.json"
}

range=$(release_range "$prev" "$head")
git log --first-parent --format=%s "$range" | while IFS= read -r subject; do
  is_release_noise "$subject" && continue
  n=$(pr_number "$subject") || continue
  [ -f "$out/$n.json" ] && continue
  fetch "$n" || {
    rm -f "$out/$n.json"
    echo "release-prs: could not read #$n after $attempts attempts" >&2
    exit 1
  }
done
