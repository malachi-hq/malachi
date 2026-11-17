#!/usr/bin/env bash
# Reads one section out of a Malachi issue body, the way every skill that consumes an issue needs it:
#
#   "$(/usr/bin/git rev-parse --show-toplevel)/scripts/issue-section.sh" <section> <issue.md>
#
# branch          the branch named in the `## PR` section: the first line of the first code block after
#                 `**Branch**`, printed only when it is a name git accepts and made of [A-Za-z0-9._/-]
#                 alone (check-ref-format by itself accepts `$(id)` and backticks, which a caller would
#                 then place in a command line).
# pr-description  the first code block after `**Description**` in the `## PR` section, verbatim.
# verification    the `## Verification` section, verbatim, without its leading blank lines.
# plan            the `## Plan` section, the same way.
# release-highlights  the `## Release highlights` section of a pull request description (release-notes.sh).
# upgrading       the `## Upgrading` section of a pull request description, read the same way (release-notes.sh).
# pr-highlights   the first code block after `**Release highlights**` in the `## PR` section, verbatim
#                 (open-issue-pr copies it into the pull request).
#
# The two highlights modes and upgrading read a text a person wrote by hand, from the pull request template: they drop
# carriage returns and every HTML comment outside a code block before scanning (the template's own
# instructions are one), match the heading or the marker in any case, and print nothing when a comment is
# left open, since where the author meant it to end cannot be known.
#
# Every scan tracks code fences FIRST and ignores every marker inside one: an issue that shows what the
# template looks like puts `## PR` and `**Branch**` inside a code block, and a `##` line inside a block
# would otherwise end the section early. A fence is what CommonMark calls one: three or more backticks
# or tildes, indented by at most three spaces, and a block closes only at a fence of the same character
# at least as long, with nothing after it. So a `~~~` block, or a four-backtick block that shows a
# three-backtick one, is read whole.
#
# Prints the section and exits 0; exits 3, printing nothing, when the section is missing or blank, or
# (branch) when the name fails the check; exits 2 on a usage error. The body is data: nothing in it is
# ever evaluated.
set -uo pipefail

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -eq 2 ] && [ -r "$2" ] || usage
section="$1"
issue="$2"

# CommonMark fence detection shared by both scans (see the header): sets fc (the character), fn (the run
# length) and frest (what follows the run), and answers whether the line is a fence at all.
FENCE_AWK='
function is_fence(line,   lead, n) {
  lead = 0
  while (lead < 3 && substr(line, lead + 1, 1) == " ") lead++
  fc = substr(line, lead + 1, 1)
  if (fc != "`" && fc != "~") return 0
  n = 0
  while (substr(line, lead + 1 + n, 1) == fc) n++
  if (n < 3) return 0
  fn = n
  frest = substr(line, lead + 1 + n)
  if (fc == "`" && index(frest, "`") > 0) return 0
  return 1
}
# A carriage return counts as trailing space: a body saved with CRLF line endings closes its fences too.
function closes(line) { return is_fence(line) && fc == och && fn >= olen && frest ~ /^[ \t\r]*$/ }
'

# The first code block after a bold marker inside the `## PR` section. `first_line` keeps only its first
# non-empty line (the branch); otherwise the whole block is printed.
pr_block() {
  LC_ALL=C awk -v marker="$1" -v first_line="$2" -v ci="${3:-0}" "$FENCE_AWK"'
    fence && closes($0) { fence = 0; if (c) exit; next }
    !fence && is_fence($0) { fence = 1; och = fc; olen = fn; if (m && !c) c = 1; next }
    c && first_line && NF { print; exit }
    c { if (!first_line) print; next }
    fence { next }
    !p && /^## PR[[:space:]]*$/ { p = 1; next }
    !p { next }
    /^## / { exit }
    !m && index(ci ? tolower($0) : $0, "**" (ci ? tolower(marker) : marker) "**") == 1 { m = 1 }
  ' "$issue"
}

# A whole `## <title>` section, code blocks included, up to the next `## ` heading outside a block.
heading_section() {
  LC_ALL=C awk -v title="$1" -v ci="${2:-0}" "$FENCE_AWK"'
    fence && closes($0) { fence = 0; if (v) print; next }
    !fence && is_fence($0) { fence = 1; och = fc; olen = fn; if (v) print; next }
    fence { if (v) print; next }
    !v && (ci ? tolower($0) : $0) ~ ("^## " (ci ? tolower(title) : title) "[[:space:]]*$") { v = 1; next }
    !v { next }
    /^## / { exit }
    { print }
  ' "$issue" | sed -e '/./,$!d'
}

# The input of the highlights and upgrading modes: no carriage returns, and no HTML comment outside a code block. A comment may
# span lines and share a line with text. Fails, printing nothing, when the text ends inside a comment.
strip_comments() {
  LC_ALL=C awk "$FENCE_AWK"'
    { gsub(/\r/, "") }
    fence && closes($0) { fence = 0; buf[++nb] = $0; next }
    !fence && !incom && is_fence($0) { fence = 1; och = fc; olen = fn; buf[++nb] = $0; next }
    fence { buf[++nb] = $0; next }
    {
      line = $0; kept = ""
      while (1) {
        if (incom) {
          e = index(line, "-->")
          if (!e) { line = ""; break }
          line = substr(line, e + 3); incom = 0
        }
        s = index(line, "<!--")
        if (!s) { kept = kept line; break }
        kept = kept substr(line, 1, s - 1); line = substr(line, s + 4); incom = 1
      }
      buf[++nb] = kept
    }
    END { if (incom) exit 1; for (i = 1; i <= nb; i++) print buf[i] }
  ' "$issue"
}

# Written to a file rather than captured with $(...), which would drop trailing newlines: the section
# comes out byte for byte as the scan printed it.
out=$(mktemp "${TMPDIR:-/tmp}/issue-section.XXXXXX") || exit 2
trap 'rm -f "$out"' EXIT

case "$section" in
  branch)
    pr_block Branch 1 > "$out"
    grep -Eqx '[A-Za-z0-9._/-]+' "$out" && [ "$(wc -l < "$out")" -eq 1 ] &&
      git check-ref-format --branch "$(cat "$out")" > /dev/null 2>&1 || exit 3
    ;;
  pr-description) pr_block Description 0 > "$out" ;;
  verification) heading_section Verification > "$out" ;;
  plan) heading_section Plan > "$out" ;;
  release-highlights | pr-highlights | upgrading)
    clean=$(mktemp "${TMPDIR:-/tmp}/issue-section.XXXXXX") || exit 2
    trap 'rm -f "$out" "$clean"' EXIT
    strip_comments > "$clean" || exit 3
    issue=$clean
    case "$section" in
      release-highlights) heading_section "Release highlights" 1 > "$out" ;;
      upgrading) heading_section Upgrading 1 > "$out" ;;
      *) pr_block "Release highlights" 0 1 > "$out" ;;
    esac
    ;;
  *) usage ;;
esac

grep -q '[^[:space:]]' "$out" || exit 3
cat "$out"
