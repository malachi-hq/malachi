# shellcheck shell=bash
# The release rule, in one place (issue #366). Sourced by scripts/release-prs.sh, release-bump.sh and
# release-notes.sh, so the pull request title check, the release gate and the grouped notes read a subject
# the same way.
#
# main takes squash merges, so a first-parent subject on it is a pull request's title with the number GitHub
# appends, `type(scope)!: summary (#N)`. A merge commit (`Merge pull request #N from ...`) still names its pull
# request, so its labels are read, but it has no type: only a label releases it. That subject is what decides a release: it is written
# by whoever merged, and it never changes afterwards, unlike the pull request's title.
#
#   type(scope)!: ...  or the label `major`        major
#   feat                                           minor
#   fix, perf, revert, chore(deps), chore(docker)  patch   (deps: the Hex packages and the base image the
#                                                           container ships with)
#   docs chore ci test refactor style build        none    (carried into the next release's notes)
#   none plus the label `release`                  patch
#   anything else                                  unknown (callers decide; see release-bump.sh)
#
# Labels are compared whole, one per line: `majority` is not `major`.

RELEASE_TYPES=" feat fix docs style refactor perf test chore ci build revert "
# A scope is anything but parentheses, so `fix(a) (b): x` is not read as the scope `a) (b`.
RELEASE_SUBJECT_RE='^([a-z]+)(\(([^()]+)\))?(!)?: (.+)$'
RELEASE_PR_RE='\(#([0-9]+)\)$'
RELEASE_MERGE_RE='^Merge pull request #([0-9]+) from '

# parse_subject <subject>: sets CT_TYPE, CT_SCOPE, CT_BANG (`!` or empty) and CT_SUMMARY, and returns 1
# when the subject is not `type(scope)!: summary` with a known type. CT_SUMMARY is read by release-notes.sh.
# shellcheck disable=SC2034
parse_subject() {
  CT_TYPE='' CT_SCOPE='' CT_BANG='' CT_SUMMARY=''
  [[ $1 =~ $RELEASE_SUBJECT_RE ]] || return 1
  case "$RELEASE_TYPES" in
    *" ${BASH_REMATCH[1]} "*) ;;
    *) return 1 ;;
  esac
  CT_TYPE=${BASH_REMATCH[1]}
  CT_SCOPE=${BASH_REMATCH[3]}
  CT_BANG=${BASH_REMATCH[4]}
  CT_SUMMARY=${BASH_REMATCH[5]}
}

# pr_number <subject>: the pull request a first-parent subject names, or nothing: the number GitHub appends at
# the very end of a squash subject, or the one a merge commit's subject starts with. Only the last `(#N)`
# counts: a title that already ends in `(#123)` is squashed as `... (#123) (#400)`.
pr_number() {
  if [[ $1 =~ $RELEASE_PR_RE ]] || [[ $1 =~ $RELEASE_MERGE_RE ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# has_label <labels> <name>: whether one line of <labels> is exactly <name>.
has_label() {
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

# bump_for <subject> <labels>: major, minor, patch, none or unknown, from the table above.
bump_for() {
  local subject=$1 labels=$2 bump
  if has_label "$labels" major; then
    echo major
    return
  fi
  if parse_subject "$subject"; then
    if [ -n "$CT_BANG" ]; then
      bump=major
    else
      case "$CT_TYPE" in
        feat) bump=minor ;;
        fix | perf | revert) bump='patch' ;;
        chore) case "$CT_SCOPE" in deps | docker) bump='patch' ;; *) bump='none' ;; esac ;;
        *) bump=none ;;
      esac
    fi
  else
    bump=unknown
  fi
  if [ "$bump" = none ] || [ "$bump" = unknown ]; then
    has_label "$labels" release && bump='patch'
  fi
  echo "$bump"
}

# bump_rank <bump>: the order max_bump compares in; unknown ranks as none.
bump_rank() {
  case "$1" in
    major) echo 3 ;;
    minor) echo 2 ;;
    patch) echo 1 ;;
    *) echo 0 ;;
  esac
}

# max_bump <a> <b>: the larger of two bumps, none when both are none or unknown.
max_bump() {
  if [ "$(bump_rank "$1")" -ge "$(bump_rank "$2")" ]; then
    [ "$(bump_rank "$1")" -eq 0 ] && echo none || echo "$1"
  else
    echo "$2"
  fi
}

# is_release_noise <subject>: the commits no reader acts on, which never count nor appear in the notes: the
# version bump the release job pushes, and the results the Publish results workflow pushes.
is_release_noise() {
  case "$1" in
    "chore: bump version"* | "chore(results):"*) return 0 ;;
    *) return 1 ;;
  esac
}

# release_range <prev_tag> <head>: the git range of a release, the whole history when there is no tag yet.
release_range() {
  if [ -n "$1" ]; then printf '%s..%s\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}

# pr_labels <prs_dir> <number>: the labels release-prs.sh recorded for a pull request, one per line.
pr_labels() {
  local file="$1/$2.json"
  [ -n "$2" ] && [ -f "$file" ] || return 0
  jq -r '.labels[]?' "$file"
}
