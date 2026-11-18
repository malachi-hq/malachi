#!/usr/bin/env bash
# Opens the communication checklist issue of a release (issue #373):
#
#   scripts/release-checklist-issue.sh <version> <template>
#
# The title is `Release v<version> communication`. The body is <template> (.github/ISSUE_TEMPLATE/
# release-communication.md) without its front matter, with every `vX.Y.Z` replaced by the release's tag. The
# version is the only value that reaches the issue, and it is checked to be one first: nothing from a pull
# request is read here.
#
# An issue with exactly that title, open or closed, means the release already has one (a re-run of the
# workflow), and nothing is opened.
#
# Needs GITHUB_REPOSITORY and an authenticated gh (GH_TOKEN). Exits 0 when the issue is opened or already
# exists, 1 when gh fails, 2 on a usage error.
set -uo pipefail

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -eq 2 ] || usage
version=$1
template=$2
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "release-checklist-issue: $version is not a version" >&2
  exit 2
}
[ -r "$template" ] || {
  echo "release-checklist-issue: $template cannot be read" >&2
  exit 2
}
[ -n "${GITHUB_REPOSITORY:-}" ] || {
  echo "release-checklist-issue: GITHUB_REPOSITORY is not set" >&2
  exit 2
}

title="Release v$version communication"
work=$(mktemp -d "${TMPDIR:-/tmp}/release-checklist-issue.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# The search is GitHub's and matches loosely, so its results are compared with the title here, whole.
gh issue list --repo "$GITHUB_REPOSITORY" --state all --search "\"$title\" in:title" \
  --json number,title --limit 100 > "$work/found" || exit 1
existing=$(jq -r --arg title "$title" 'map(select(.title == $title)) | first | .number // empty' "$work/found") ||
  exit 1
if [ -n "$existing" ]; then
  echo "release-checklist-issue: #$existing is already $title; nothing opened"
  exit 0
fi

# The body: the lines after the closing `---` of the front matter, the template's own leading blank lines
# dropped. A template without front matter is used whole.
awk -v tag="v$version" '
  NR == 1 && $0 == "---" { front = 1; next }
  front && $0 == "---" { front = 0; next }
  front { next }
  !started && $0 == "" { next }
  { started = 1; gsub(/vX\.Y\.Z/, tag); print }
' "$template" > "$work/body" || exit 2
[ -s "$work/body" ] || {
  echo "release-checklist-issue: $template has no body" >&2
  exit 2
}

gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$work/body" || exit 1
