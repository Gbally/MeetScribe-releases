#!/bin/sh
# Releases a new version in two steps:
#
#   ./scripts/release.sh "What's new"   PREPARE (local only): builds the signed DMG and writes
#                                        build-cache/release/ (DMG, latest.json) — nothing is sent.
#   ./scripts/release.sh --publish      PUBLISH: pushes main, creates the GitHub release with the
#                                        DMG, then commits latest.json + models.json at the repo root
#                                        and pushes them. Installed apps update within a day.
#
#   --beta (with either step)           a TEST version instead: "0.6.3-test.102", a GitHub pre-release
#                                        and latest-beta.json, offered only to apps with Settings →
#                                        About → "Receive test versions" on. The next release (a
#                                        higher build) replaces it there too.
#
# Bump `version` in pyproject.toml and commit first (not needed for a test version). Needs
# `gh auth login` once.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
RELEASES_REPO=Gbally/MeetScribe-releases
GH=$(command -v gh || echo "$HOME/development/bin/gh")
PUBLISH=0
BETA=0
while :; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --beta) BETA=1; shift ;;
    *) break ;;
  esac
done
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
NOTES=${1:-"MeetScribe $VERSION"}
if [ "$BETA" = 1 ]; then OUT="$ROOT/build-cache/beta"; FEED=latest-beta.json; else OUT="$ROOT/build-cache/release"; FEED=latest.json; fi

if [ "$PUBLISH" = 0 ]; then
  if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first."; exit 1; fi
  [ -f signing/MeetScribe-signing.keychain-db ] || [ -n "$SIGN_ID" ] || {
    echo "No stable signing identity: installed apps would refuse the update."; exit 1; }
  ./scripts/build_app.sh
  [ -n "$SIGN_ID" ] && ./scripts/notarize.sh "dist/MeetScribe-$VERSION.dmg"
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/MeetScribe.app/Contents/Info.plist)
  LABEL=$VERSION
  [ "$BETA" = 1 ] && LABEL="$VERSION-test.$BUILD"
  DMG="MeetScribe-$LABEL.dmg"
  rm -rf "$OUT" && mkdir -p "$OUT"
  cp "dist/MeetScribe-$VERSION.dmg" "$OUT/$DMG"
  SHA=$(shasum -a 256 "$OUT/$DMG" | cut -d' ' -f1)
  URL="https://github.com/$RELEASES_REPO/releases/download/v$LABEL/$DMG"
  python3 - "$OUT/$FEED" "$LABEL" "$BUILD" "$URL" "$SHA" "$NOTES" <<'PY'
import json, sys
path, version, build, url, sha, notes = sys.argv[1:]
json.dump({"version": version, "build": int(build), "url": url, "sha256": sha, "notes": notes},
          open(path, "w"), indent=1)
PY
  printf '%s' "$NOTES" > "$OUT/notes.txt"
  echo
  if [ "$BETA" = 1 ]; then
    echo "✅ Prepared test version MeetScribe $LABEL (build $BUILD) in build-cache/beta/ — nothing published."
    echo "   Publish with:  ./scripts/release.sh --beta --publish"
  else
    echo "✅ Prepared MeetScribe $VERSION (build $BUILD) in build-cache/release/ — nothing published."
    echo "   Publish with:  ./scripts/release.sh --publish"
  fi
  exit 0
fi

# --- publish (uses what PREPARE produced)
[ -f "$OUT/$FEED" ] || { echo "Run ./scripts/release.sh$( [ "$BETA" = 1 ] && echo ' --beta') (prepare) first."; exit 1; }
VERSION=$(python3 -c "import json; print(json.load(open('$OUT/$FEED'))['version'])")
NOTES=$(cat "$OUT/notes.txt")
DMG="MeetScribe-$VERSION.dmg"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Publish from the main branch."; exit 1; }

# 1. The code the release is built from.
echo "• Pushing main"
git push -q origin main

# 2. The release with the installer.
SHA=$(python3 -c "import json; print(json.load(open('$OUT/$FEED'))['sha256'])")
if "$GH" release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  REMOTE=$("$GH" api "repos/$RELEASES_REPO/releases/tags/v$VERSION" --jq '.assets[] | select(.name=="'"$DMG"'") | .digest' 2>/dev/null)
  if [ "$REMOTE" = "sha256:$SHA" ]; then
    echo "• Release v$VERSION already has this installer"
  else
    # Re-prepared after publishing: the installer must match the feed or updates fail.
    echo "• Release v$VERSION exists with a different installer — replacing it"
    "$GH" release upload "v$VERSION" "$OUT/$DMG" --clobber --repo "$RELEASES_REPO"
  fi
elif [ "$BETA" = 1 ]; then
  echo "• GitHub pre-release v$VERSION"
  "$GH" release create "v$VERSION" "$OUT/$DMG" --repo "$RELEASES_REPO" --prerelease \
    --target main --title "MeetScribe $VERSION (test version)" --notes "$NOTES"
else
  echo "• GitHub release v$VERSION"
  "$GH" release create "v$VERSION" "$OUT/$DMG" --repo "$RELEASES_REPO" \
    --target main --title "MeetScribe $VERSION" --notes "$NOTES"
fi
git fetch -q --tags origin

# 3. Last: the feed (and, for a release, the model list), so apps only see an update once its
#    download exists.
cp "$OUT/$FEED" "$FEED"
if [ "$BETA" = 1 ]; then
  echo "• latest-beta.json"
  git add latest-beta.json
else
  echo "• latest.json, models.json"
  cp catalog/models.json models.json
  git add latest.json models.json
fi
git diff --cached --quiet || git commit -qm "MeetScribe $VERSION"
git push -q origin main
if [ "$BETA" = 1 ]; then
  echo "✅ Published test version MeetScribe $VERSION — apps receiving test versions will offer it within a day."
else
  echo "✅ Released MeetScribe $VERSION — installed apps will offer the update within a day."
fi
