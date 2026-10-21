#!/bin/sh
# Releases a new version in two steps:
#
#   ./scripts/release.sh "What's new"            PREPARE (local only): builds the signed DMG and
#                                                 writes build-cache/release/ (DMG, latest.json,
#                                                 models.json, README, INSTALL) — nothing is sent.
#   ./scripts/release.sh --publish "What's new"  PUBLISH: GitHub release with the DMG, pushes
#                                                 latest.json/models.json to the releases repo,
#                                                 tags the source repo. Installed apps update
#                                                 within a day.
#
# Bump `version` in pyproject.toml and commit first. Needs `gh auth login` once.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
RELEASES_REPO=Gbally/MeetScribe-releases
GH=$(command -v gh || echo "$HOME/development/bin/gh")
PUBLISH=0
[ "$1" = "--publish" ] && { PUBLISH=1; shift; }
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
NOTES=${1:-"MeetScribe $VERSION"}
OUT="$ROOT/build-cache/release"

if [ "$PUBLISH" = 0 ]; then
  if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first."; exit 1; fi
  [ -f signing/MeetScribe-signing.keychain-db ] || [ -n "$SIGN_ID" ] || {
    echo "No stable signing identity: installed apps would refuse the update."; exit 1; }
  ./scripts/build_app.sh
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/MeetScribe.app/Contents/Info.plist)
  DMG="MeetScribe-$VERSION.dmg"
  rm -rf "$OUT" && mkdir -p "$OUT"
  cp "dist/$DMG" "$OUT/"
  SHA=$(shasum -a 256 "$OUT/$DMG" | cut -d' ' -f1)
  URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/$DMG"
  python3 - "$OUT/latest.json" "$VERSION" "$BUILD" "$URL" "$SHA" "$NOTES" <<'PY'
import json, sys
path, version, build, url, sha, notes = sys.argv[1:]
json.dump({"version": version, "build": int(build), "url": url, "sha256": sha, "notes": notes},
          open(path, "w"), indent=1)
PY
  cp catalog/models.json "$OUT/models.json"
  cp mac/INSTALL.txt "$OUT/INSTALL.txt"
  cp catalog/RELEASES_README.md "$OUT/README.md"
  printf '%s' "$NOTES" > "$OUT/notes.txt"
  echo
  echo "✅ Prepared MeetScribe $VERSION (build $BUILD) in build-cache/release/ — nothing published."
  echo "   Publish with:  ./scripts/release.sh --publish"
  exit 0
fi

# --- publish (uses what PREPARE produced)
[ -f "$OUT/latest.json" ] || { echo "Run ./scripts/release.sh (prepare) first."; exit 1; }
VERSION=$(python3 -c "import json; print(json.load(open('$OUT/latest.json'))['version'])")
NOTES=$(cat "$OUT/notes.txt")
if ! "$GH" repo view "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "• Creating the public repo $RELEASES_REPO"
  "$GH" repo create "$RELEASES_REPO" --public --description "MeetScribe installers and updates"
fi
WORK="$ROOT/build-cache/releases-repo"
rm -rf "$WORK" && mkdir -p "$WORK"
git -C "$WORK" init -q -b main
git -C "$WORK" remote add origin "https://github.com/$RELEASES_REPO.git"
git -C "$WORK" config user.name "$(git config user.name)"
git -C "$WORK" config user.email "$(git config user.email)"
git -C "$WORK" fetch -q origin main 2>/dev/null && git -C "$WORK" checkout -q -B main origin/main || true

# 1. Page files first (a release can't be created in an empty repository).
echo "• README, INSTALL, models.json"
cp "$OUT/models.json" "$OUT/INSTALL.txt" "$OUT/README.md" "$WORK/"
cp -R "$ROOT/website/." "$WORK/" && touch "$WORK/.nojekyll"   # the website (GitHub Pages)
git -C "$WORK" add -A
git -C "$WORK" diff --cached --quiet || git -C "$WORK" commit -qm "MeetScribe $VERSION: page and models"
git -C "$WORK" push -q -u origin main

# 2. The release with the installer (skipped if it already exists).
SHA=$(python3 -c "import json; print(json.load(open('$OUT/latest.json'))['sha256'])")
if "$GH" release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  REMOTE=$("$GH" api "repos/$RELEASES_REPO/releases/tags/v$VERSION" --jq '.assets[] | select(.name=="MeetScribe-'"$VERSION"'.dmg") | .digest' 2>/dev/null)
  if [ "$REMOTE" = "sha256:$SHA" ]; then
    echo "• Release v$VERSION already has this installer"
  else
    # Re-prepared after publishing: the installer must match latest.json or updates fail.
    echo "• Release v$VERSION exists with a different installer — replacing it"
    "$GH" release upload "v$VERSION" "$OUT/MeetScribe-$VERSION.dmg" --clobber --repo "$RELEASES_REPO"
  fi
else
  echo "• GitHub release v$VERSION"
  "$GH" release create "v$VERSION" "$OUT/MeetScribe-$VERSION.dmg" --repo "$RELEASES_REPO" \
    --target main --title "MeetScribe $VERSION" --notes "$NOTES"
fi

# 3. Last: latest.json, so apps only see an update once its download exists.
echo "• latest.json"
cp "$OUT/latest.json" "$WORK/"
git -C "$WORK" add latest.json
git -C "$WORK" diff --cached --quiet || git -C "$WORK" commit -qm "MeetScribe $VERSION"
git -C "$WORK" push -q origin main
if git remote get-url origin >/dev/null 2>&1; then
  git tag -f "v$VERSION" && git push -q --force origin "v$VERSION"
fi
echo "✅ Released MeetScribe $VERSION — installed apps will offer the update within a day."
