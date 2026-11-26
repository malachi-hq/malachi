#!/usr/bin/env bash
# Fetches the site's images from Git LFS for the docs build, after checking what they would cost (issue #373):
#
#   scripts/site-images-pull.sh [--check-only]
#
# The images are the blog's PNGs, charts and illustrations (site/blog/**/*.png), and the kit's
# (site/kit/**/*.png). They live in Git LFS, whose free quota counts every download, a fork's pushes included,
# and blocks the account once it is spent. So nothing is downloaded before every image tracked in those folders
# is checked from its pointer:
#
#   * it is a Git LFS pointer, not the image itself committed outside LFS;
#   * the size the pointer declares is within budget: 150 KB for a blog image, 300 KB for a kit image.
#
# Each pointer is read from the index, which holds the pointer whether or not the checkout replaced the file
# with its image (`git lfs install` does), so the check gives the same answer in CI and on a contributor's
# machine, and on a second run. With --check-only the check is all it does (a fork's pull request, whose images
# are never fetched). Otherwise it then runs `git lfs pull` for those folders alone. Run from the repository
# root.
#
# Exits 0 when every image passes (and was fetched), 1 when one does not or the fetch fails, 2 on a usage error.
set -uo pipefail

blog_max=$((150 * 1024))
kit_max=$((300 * 1024))
pointer_head='version https://git-lfs.github.com/spec/'

check_only=0
case "${1:-}" in
  --check-only) check_only=1 ;;
  "") ;;
  *)
    sed -n '4p' "$0" | sed 's/^# *//' >&2
    exit 2
    ;;
esac
[ $# -le 1 ] || {
  sed -n '4p' "$0" | sed 's/^# *//' >&2
  exit 2
}

failed=0
count=0
while IFS= read -r file; do
  count=$((count + 1))
  case "$file" in
    site/kit/*) max=$kit_max ;;
    *) max=$blog_max ;;
  esac
  if [ "$(git cat-file blob ":$file" | head -c ${#pointer_head})" != "$pointer_head" ]; then
    echo "site-images-pull: $file is committed outside Git LFS; track it (see .gitattributes) and commit it again" >&2
    failed=1
    continue
  fi
  size=$(git cat-file blob ":$file" | awk '$1 == "size" { print $2; exit }')
  if ! [[ $size =~ ^[0-9]+$ ]]; then
    echo "site-images-pull: $file is a Git LFS pointer without a size" >&2
    failed=1
  elif [ "$size" -gt "$max" ]; then
    echo "site-images-pull: $file is $((size / 1024)) KB; the budget is $((max / 1024)) KB" >&2
    failed=1
  fi
done < <(git ls-files -- ':(glob)site/blog/**/*.png' ':(glob)site/kit/**/*.png')

[ "$failed" -eq 0 ] || exit 1
echo "site-images-pull: $count image(s) within budget"
[ "$check_only" -eq 1 ] && exit 0
[ "$count" -eq 0 ] && exit 0
git lfs pull --include='site/blog/**/*.png,site/kit/**/*.png' || exit 1
