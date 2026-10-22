#!/bin/sh
# Releases a new version in two steps:
#
#   ./scripts/release.sh "What's new"   PREPARE (local only): builds the signed DMG and writes
#                                        build-cache/release/ (DMG, latest.json) — nothing is sent.
#   ./scripts/release.sh --publish      PUBLISH: pushes main, creates the GitHub release with the
#                                        DMG, then commits latest.json + models.json at the repo root
#                                        and pushes them. Installed apps update within a day.
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
NOTES=${1:-"MeetNouce $VERSION"}
OUT="$ROOT/build-cache/release"

if [ "$PUBLISH" = 0 ]; then
  if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first."; exit 1; fi
  [ -f signing/MeetScribe-signing.keychain-db ] || [ -n "$SIGN_ID" ] || {
    echo "No stable signing identity: installed apps would refuse the update."; exit 1; }
  ./scripts/build_app.sh
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/MeetNouce.app/Contents/Info.plist)
  DMG="MeetNouce-$VERSION.dmg"
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
  printf '%s' "$NOTES" > "$OUT/notes.txt"
  echo
  echo "✅ Prepared MeetNouce $VERSION (build $BUILD) in build-cache/release/ — nothing published."
  echo "   Publish with:  ./scripts/release.sh --publish"
  exit 0
fi

# --- publish (uses what PREPARE produced)
[ -f "$OUT/latest.json" ] || { echo "Run ./scripts/release.sh (prepare) first."; exit 1; }
VERSION=$(python3 -c "import json; print(json.load(open('$OUT/latest.json'))['version'])")
NOTES=$(cat "$OUT/notes.txt")
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Publish from the main branch."; exit 1; }

# 1. The code the release is built from.
echo "• Pushing main"
git push -q origin main

# 2. The release with the installer.
SHA=$(python3 -c "import json; print(json.load(open('$OUT/latest.json'))['sha256'])")
if "$GH" release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  REMOTE=$("$GH" api "repos/$RELEASES_REPO/releases/tags/v$VERSION" --jq '.assets[] | select(.name=="MeetNouce-'"$VERSION"'.dmg") | .digest' 2>/dev/null)
  if [ "$REMOTE" = "sha256:$SHA" ]; then
    echo "• Release v$VERSION already has this installer"
  else
    # Re-prepared after publishing: the installer must match latest.json or updates fail.
    echo "• Release v$VERSION exists with a different installer — replacing it"
    "$GH" release upload "v$VERSION" "$OUT/MeetNouce-$VERSION.dmg" --clobber --repo "$RELEASES_REPO"
  fi
else
  echo "• GitHub release v$VERSION"
  "$GH" release create "v$VERSION" "$OUT/MeetNouce-$VERSION.dmg" --repo "$RELEASES_REPO" \
    --target main --title "MeetNouce $VERSION" --notes "$NOTES"
fi
git fetch -q --tags origin

# 3. Last: latest.json (and the model list), so apps only see an update once its download exists.
echo "• latest.json, models.json"
cp "$OUT/latest.json" latest.json
cp catalog/models.json models.json
git add latest.json models.json
git diff --cached --quiet || git commit -qm "MeetNouce $VERSION"
git push -q origin main
echo "✅ Released MeetNouce $VERSION — installed apps will offer the update within a day."
