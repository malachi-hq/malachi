#!/usr/bin/env bash
# The release gate (issue #366): which version, if any, the commits since the previous release publish.
#
#   scripts/release-bump.sh --check | --range <prev_tag|""> <head> <prs_dir> [--trigger <sha>]
#
# --check   validates the pull request title in PR_TITLE (pr-checks.yml): `type(scope)!: summary` with a
#           known type. Exits 0, or 3 with the accepted forms.
# --range   prints major, minor, patch or none: the largest bump among the first-parent commits in
#           <prev_tag>..<head>, each read by release_lib.sh's table from its subject and the labels
#           release-prs.sh recorded in <prs_dir>. The largest, and not the one merge that started the run:
#           releases run one at a time, so a merge whose own run was cancelled while queued, or one merged
#           just before another release took the tip of main, must still publish the version it needs.
#           A subject with no recognised type counts as none, except the commit named by --trigger (the
#           merge this run is for): that one exits 3, unless its labels decide (`release` or `major`).
#
# Exits 2 on a usage error. The title and the subjects are data: nothing in them is evaluated.
set -uo pipefail

# shellcheck source=scripts/release_lib.sh
. "$(dirname "$0")/release_lib.sh"

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

check_title() {
  if parse_subject "${PR_TITLE:-}"; then
    echo "The title follows Conventional Commits: type $CT_TYPE${CT_SCOPE:+, scope $CT_SCOPE}${CT_BANG:+, breaking}."
    return 0
  fi
  {
    echo "The pull request title must be type(scope)!: summary, with type one of:${RELEASE_TYPES% }."
    echo "The scope and the ! (a breaking change) are optional. Examples:"
    echo "  feat: add range reads"
    echo "  fix(storage): close the segment on rollover"
    echo "  feat!: drop the v1 wire protocol"
    echo "  docs: describe retention"
  } >&2
  return 3
}

range_bump() {
  local prev=$1 head=$2 prs=$3 trigger=$4 bump=none sha subject n b range ref
  # Checked here because a git log inside the process substitution below fails silently.
  for ref in ${prev:+"$prev"} "$head"; do
    git rev-parse --verify -q "$ref^{commit}" > /dev/null || {
      echo "release-bump: $ref names no commit" >&2
      return 2
    }
  done
  [ -d "$prs" ] || {
    echo "release-bump: $prs is not a directory" >&2
    return 2
  }
  range=$(release_range "$prev" "$head")
  while IFS=' ' read -r sha subject; do
    is_release_noise "$subject" && continue
    n=$(pr_number "$subject")
    b=$(bump_for "$subject" "$(pr_labels "$prs" "$n")")
    if [ "$b" = unknown ]; then
      if [ -n "$trigger" ] && [ "$sha" = "$trigger" ]; then
        local target="its pull request"
        [ -n "$n" ] && target="pull request #$n"
        {
          echo "The merge $sha has no Conventional Commits type in its subject: $subject"
          echo "Apply the label \`release\` (a patch) or \`major\` to $target and re-run"
          echo "this workflow, or leave it: it is listed under Other in the next release."
        } >&2
        return 3
      fi
      echo "release-bump: $sha has no recognised type, counted as none: $subject" >&2
    fi
    bump=$(max_bump "$bump" "$b")
  done < <(git log --first-parent --format='%H %s' "$range")
  echo "$bump"
}

case "${1:-}" in
  --check)
    [ $# -eq 1 ] || usage
    check_title
    ;;
  --range)
    [ $# -eq 4 ] || { [ $# -eq 6 ] && [ "$5" = --trigger ] && [ -n "$6" ]; } || usage
    trigger=""
    if [ $# -eq 6 ]; then
      trigger=$(git rev-parse --verify -q "$6^{commit}") || {
        echo "release-bump: $6 names no commit" >&2
        exit 2
      }
    fi
    range_bump "$2" "$3" "$4" "$trigger"
    ;;
  *) usage ;;
esac
