#!/bin/sh
# Publishes website/ to the public releases repo, served by GitHub Pages at
# https://gbally.github.io/MeetScribe-releases/ (index.html sits next to latest.json, so the
# download button always points at the newest installer).
set -e
cd "$(dirname "$0")/.."
GH=$(command -v gh || echo "$HOME/development/bin/gh")
REPO=Gbally/MeetScribe-releases
WORK=build-cache/site-repo
rm -rf "$WORK" && mkdir -p "$WORK"
git -C "$WORK" init -q -b main
git -C "$WORK" remote add origin "https://github.com/$REPO.git"
git -C "$WORK" config user.name "$(git config user.name)"
git -C "$WORK" config user.email "$(git config user.email)"
git -C "$WORK" fetch -q origin main && git -C "$WORK" checkout -q -B main origin/main
cp -R website/. "$WORK/"
touch "$WORK/.nojekyll"   # serve files as they are
git -C "$WORK" add -A
git -C "$WORK" diff --cached --quiet && { echo "Site already up to date."; exit 0; }
git -C "$WORK" commit -qm "Website $(date +%Y-%m-%d)"
git -C "$WORK" push -q origin main
# Turn on GitHub Pages the first time (main branch, root folder).
"$GH" api "repos/$REPO/pages" >/dev/null 2>&1 || \
  "$GH" api -X POST "repos/$REPO/pages" -f "source[branch]=main" -f "source[path]=/" >/dev/null
echo "✅ Site published — https://gbally.github.io/MeetScribe-releases/ (first time: live within ~2 minutes)"
