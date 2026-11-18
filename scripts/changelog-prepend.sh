#!/usr/bin/env bash
# Puts one release's section at the top of the changelog (issue #373):
#
#   scripts/changelog-prepend.sh <prev_tag|""> <head> <version> <prs_dir> <changelog>
#
# The section is `release-notes.sh --changes-only` for the same arguments, so the changelog and the GitHub
# release list the same changes, and the release post generator reads a version's changes from the
# changelog without the API. It goes above the newest section, below the file's heading; a changelog that
# does not exist yet is created with that heading.
#
# Refuses (exit 1) a version the changelog already holds, so a section is never written twice, and leaves the
# file as it was when the notes cannot be written. The file is replaced by a rename, never left half-written.
# Exits 0, 1 as above, or 2 on a usage error.
set -uo pipefail

here=$(dirname "$0")

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -eq 5 ] || usage
version=$3
changelog=$5
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "changelog-prepend: $version is not a version" >&2
  exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/changelog-prepend.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

"$here/release-notes.sh" --changes-only "$1" "$2" "$version" "$4" > "$work/section" || exit $?

if [ -f "$changelog" ]; then
  cp "$changelog" "$work/old" || exit 2
else
  cat > "$work/old" << 'EOF'
# Changelog

Every release of Malachi, newest first. The release workflow writes each section from
`scripts/release-notes.sh --changes-only` in the commit that bumps the version.
EOF
fi

# The heading of a version, matched whole: 1.2.3 is not 1.2.30.
if grep -Eq "^## v${version//./\\.} \(" "$work/old"; then
  echo "changelog-prepend: $changelog already has v$version" >&2
  exit 1
fi

# Everything before the first section, the new section, then the rest. With no section yet, the new one
# follows the heading.
awk -v section="$work/section" '
  function put() {
    while ((getline line < section) > 0) print line
    print ""
    done = 1
  }
  !done && /^## v[0-9]/ { put() }
  { print }
  END {
    if (!done) {
      print ""
      while ((getline line < section) > 0) print line
    }
  }
' "$work/old" > "$work/new" || exit 2

# Moved beside the changelog first, so the last rename stays on one file system.
if ! { mv "$work/new" "$changelog.tmp" && mv "$changelog.tmp" "$changelog"; }; then
  rm -f "$changelog.tmp"
  exit 2
fi
