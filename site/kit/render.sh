#!/usr/bin/env bash
# Renders the kit's images from their SVG sources beside this script (issue #373):
#
#   site/kit/render.sh
#
#   logo.svg            -> logo.png            300x300    the LinkedIn Page's logo
#   linkedin-cover.svg  -> linkedin-cover.png  1128x191   the LinkedIn Page's cover
#   social-preview.svg  -> social-preview.png  1280x640   the repository's social preview and the site's
#                                                          og:image (Malachi.Site stages it)
#
# Each is drawn by site/checks/render.mjs, the Playwright already pinned in site/checks (JavaScript off, every
# request refused); install it once with `cd site/checks && npm ci && npx playwright install --only-shell
# chromium`. The PNGs are stored in Git LFS (.gitattributes) and checked against a 300 KB budget by
# scripts/site-images-pull.sh. Run it again after editing a source, and commit the PNGs with their sources.
#
# Exits 0 when every image was rendered, and non-zero (node's own status) when one was not.
set -euo pipefail

kit=$(cd "$(dirname "$0")" && pwd)
render="$kit/../checks/render.mjs"

# name and size, one image per line; the size must be the SVG's own width and height.
images="logo 300x300
linkedin-cover 1128x191
social-preview 1280x640"

while read -r name size; do
  node "$render" "$size" "$kit/$name.svg" "$kit/$name.png"
done <<< "$images"
