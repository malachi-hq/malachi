#!/usr/bin/env bash
# Sets this checkout's git identity to a GitHub App's bot user, so that a commit an App pushes to main names the
# App that wrote it. The release and the results publishers both push to main this way, through the
# malachi-release App, the one actor main's protection lets skip a pull request.
#
# Usage: scripts/app-bot-git-identity.sh <app-slug>
# GH_TOKEN must hold a token that can read public user data (the App's own token does).
set -euo pipefail

slug="${1:-}"
case "$slug" in
  '' | *[!a-z0-9-]*)
    echo "app-bot-git-identity: not a GitHub App slug: '$slug'" >&2
    exit 2
    ;;
esac

# The bot user's id is part of the noreply address GitHub links commits by. An id that is not a number means the
# lookup returned something else, and a commit must not be written under a wrong identity.
id="$(gh api "/users/${slug}%5Bbot%5D" --jq .id)"
case "$id" in
  '' | *[!0-9]*)
    echo "app-bot-git-identity: no bot user id for ${slug}[bot]: '$id'" >&2
    exit 1
    ;;
esac

git config user.name "${slug}[bot]"
git config user.email "${id}+${slug}[bot]@users.noreply.github.com"
echo "git identity: ${slug}[bot] <${id}+${slug}[bot]@users.noreply.github.com>"
