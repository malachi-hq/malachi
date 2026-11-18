#!/usr/bin/env bash
# Sends a release post to dev.to as a draft (issue #373):
#
#   scripts/devto-draft.sh <article.json>
#
# <article.json> is the article `mix malachi.release.post --devto <post.md>` builds (Malachi.Release.Devto),
# and that task is how this runs: the post's Markdown adapted to dev.to, `published: false`, and its
# `canonical_url` set to the post on this site.
#
# The draft is created once. A later run finds the article whose canonical_url is the same, among all of the
# account's articles (published or not, page by page), and updates it rather than making a second one, while it
# is still a draft. It never publishes and never unpublishes: the maintainer reviews the draft on dev.to and
# publishes it there, and an article already published is refused, since sending it published: false would take
# it down. Edit a live article on dev.to.
#
# Locally only, never in CI. The key is read from DEVTO_API_KEY and reaches curl through its standard input,
# never its arguments, so it does not show in the process list. DEVTO_API_BASE is https://dev.to unless set,
# and may only be that or a server on this machine (the tests' fake), so a stray value cannot send the key
# elsewhere.
#
# Exits 0 when the draft is created or updated, 1 when dev.to refuses or fails, 2 on a usage error.
set -uo pipefail

usage() {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -eq 1 ] && [ -r "$1" ] || usage
article=$1
[ -n "${DEVTO_API_KEY:-}" ] || {
  echo "devto-draft: DEVTO_API_KEY is not set; create one at https://dev.to/settings/extensions" >&2
  exit 2
}
base=${DEVTO_API_BASE:-https://dev.to}
[[ $base =~ ^(https://dev\.to|http://(127\.0\.0\.1|localhost):[0-9]{1,5})$ ]] || {
  echo "devto-draft: DEVTO_API_BASE may be https://dev.to or a server on this machine, not $base" >&2
  exit 2
}
canonical=$(jq -er '.article.canonical_url | select(type == "string" and startswith("https://"))' "$article") || {
  echo "devto-draft: $article has no https canonical_url" >&2
  exit 2
}
jq -e '.article.published == false' "$article" > /dev/null || {
  echo "devto-draft: $article would publish; only drafts (published: false) are sent" >&2
  exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/devto-draft.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# api <method> <path> [<body file>]: the response body in $work/body and the HTTP status on stdout.
api() {
  local method=$1 path=$2 data=()
  [ $# -ge 3 ] && data=(--data-binary "@$3")
  printf 'header = "api-key: %s"\n' "$DEVTO_API_KEY" |
    curl --silent --show-error --config - --request "$method" \
      --header 'Content-Type: application/json' --header 'Accept: application/vnd.forem.api-v1+json' \
      --output "$work/body" --write-out '%{http_code}' ${data[@]+"${data[@]}"} "$base$path"
}

# fail <status>: says what dev.to's answer means, and exits 1.
fail() {
  case "$1" in
    401) echo "devto-draft: dev.to refused DEVTO_API_KEY (HTTP 401)" >&2 ;;
    422) echo "devto-draft: dev.to refused the article (HTTP 422): $(jq -r '.error // .' "$work/body" 2> /dev/null | head -c 500)" >&2 ;;
    429) echo "devto-draft: dev.to is rate limiting this key (HTTP 429); try again in a minute" >&2 ;;
    *) echo "devto-draft: dev.to answered HTTP $1: $(head -c 300 "$work/body" 2> /dev/null)" >&2 ;;
  esac
  exit 1
}

existing=""
page=1
while [ -z "$existing" ]; do
  status=$(api GET "/api/articles/me/all?per_page=100&page=$page") || exit 1
  [ "$status" = 200 ] || fail "$status"
  [ "$(jq 'length' "$work/body")" -gt 0 ] || break
  # The id, and whether that article is live, as "<id> <published>".
  existing=$(jq -r --arg url "$canonical" \
    'map(select(.canonical_url == $url)) | first | select(. != null) | "\(.id) \(.published)"' "$work/body")
  page=$((page + 1))
done

if [ -n "$existing" ]; then
  published=${existing#* }
  existing=${existing%% *}
  [[ $existing =~ ^[0-9]+$ ]] || fail "unexpected article id"
  if [ "$published" = true ]; then
    echo "devto-draft: article $existing with this canonical URL is already published on dev.to; edit it there" >&2
    exit 1
  fi
  status=$(api PUT "/api/articles/$existing" "$article") || exit 1
  [ "$status" = 200 ] || fail "$status"
  echo "devto-draft: updated draft $existing: $(jq -r '.url // empty' "$work/body")"
else
  status=$(api POST /api/articles "$article") || exit 1
  [ "$status" = 201 ] || [ "$status" = 200 ] || fail "$status"
  echo "devto-draft: created draft $(jq -r '.id' "$work/body"): $(jq -r '.url // empty' "$work/body")"
fi
