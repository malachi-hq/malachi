#!/usr/bin/env bash
# The body of a GitHub release (issue #366), printed to stdout:
#
#   scripts/release-notes.sh <prev_tag|""> <head> <version> <prs_dir>
#
# 1. A title line with the version.
# 2. Highlights: the `## Release highlights` section of each pull request in the release, in merge order, read
#    from <prs_dir> (release-prs.sh). Only from an author with write access to the repository (permission
#    admin, maintain or write): a description can be edited after the merge, and what a release publishes
#    must come from someone who could have merged it.
# 3. The first-parent commits of <prev_tag>..<head> grouped as Features, Fixes, Performance, Dependencies,
#    Documentation and Other, in that order and in merge order within each, an empty group left out. A line
#    is the subject without its type, with its scope in bold and breaking changes marked. A subject with no
#    recognised type, such as a merge commit, is listed whole under Other. The version bump and the published
#    results are left out: nobody acts on them.
# 4. How to pull the image and check out the tag.
#
# Exits 0, or 2 on a usage error. Titles and descriptions are data: nothing in them is evaluated.
set -uo pipefail

here=$(dirname "$0")
# shellcheck source=scripts/release_lib.sh
. "$here/release_lib.sh"

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -eq 4 ] || usage
prev=$1
head=$2
version=$3
prs=$4
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "release-notes: $version is not a version" >&2
  exit 2
}
[ -d "$prs" ] || {
  echo "release-notes: $prs is not a directory" >&2
  exit 2
}
for ref in ${prev:+"$prev"} "$head"; do
  git rev-parse --verify -q "$ref^{commit}" > /dev/null || {
    echo "release-notes: $ref names no commit" >&2
    exit 2
  }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/release-notes.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

groups="features fixes performance dependencies documentation other"
heading() {
  case "$1" in
    features) echo Features ;;
    fixes) echo Fixes ;;
    performance) echo Performance ;;
    dependencies) echo Dependencies ;;
    documentation) echo Documentation ;;
    other) echo Other ;;
  esac
}

# Prints a file without its trailing blank lines.
trim_trailing() { awk '{ line[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print line[i] }' "$1"; }

: > "$work/highlights"
range=$(release_range "$prev" "$head")
git log --reverse --first-parent --format=%s "$range" > "$work/subjects"
while IFS= read -r subject; do
  is_release_noise "$subject" && continue

  if parse_subject "$subject"; then
    case "$CT_TYPE" in
      feat) group=features ;;
      fix) group=fixes ;;
      perf) group=performance ;;
      docs) group=documentation ;;
      chore) case "$CT_SCOPE" in deps | docker) group=dependencies ;; *) group=other ;; esac ;;
      *) group=other ;;
    esac
    line="- ${CT_BANG:+**Breaking:** }${CT_SCOPE:+**$CT_SCOPE:** }$CT_SUMMARY"
  else
    group=other
    line="- $subject"
  fi
  printf '%s\n' "$line" >> "$work/$group"

  n=$(pr_number "$subject") || continue
  pr="$prs/$n.json"
  [ -f "$pr" ] || continue
  case "$(jq -r '.permission // ""' "$pr")" in
    admin | maintain | write) ;;
    *) continue ;;
  esac
  jq -r '.body // ""' "$pr" > "$work/body"
  "$here/issue-section.sh" release-highlights "$work/body" > "$work/one" 2> /dev/null || continue
  separator=""
  [ -s "$work/highlights" ] && separator=$'\n'
  {
    printf '%s' "$separator"
    trim_trailing "$work/one"
    echo
    echo "(#$n)"
  } >> "$work/highlights"
done < "$work/subjects"

echo "## 🚀 Malachi v$version"
if [ -s "$work/highlights" ]; then
  printf '\n### Highlights\n\n'
  cat "$work/highlights"
fi
listed=0
for group in $groups; do
  [ -s "$work/$group" ] || continue
  listed=1
  printf '\n### %s\n\n' "$(heading "$group")"
  cat "$work/$group"
done
[ "$listed" -eq 1 ] || printf '\nNo user-facing changes since the previous release.\n'
cat << EOF

### 🐳 Docker

\`\`\`bash
docker pull hectorcardoso/malachi:$version
\`\`\`

### 📦 Installation

\`\`\`bash
git clone https://github.com/malachi-hq/malachi.git
cd malachi
git checkout v$version
\`\`\`
EOF
