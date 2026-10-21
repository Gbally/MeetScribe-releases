#!/bin/sh
# Publishes a new version for everyone:
#   1. builds the signed app + DMG,
#   2. uploads the DMG as a GitHub release in the public releases repo,
#   3. updates latest.json (what apps check daily) and models.json there,
#   4. tags the source repo.
#
#   ./scripts/release.sh "What's new in this version"
#
# Bump `version` in pyproject.toml first, commit, then run this. Needs `gh auth login` once.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
RELEASES_REPO=Gbally/MeetScribe-releases
GH=$(command -v gh || echo "$HOME/development/bin/gh")
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
NOTES=${1:-"MeetScribe $VERSION"}

if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first."; exit 1; fi
if "$GH" release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "v$VERSION is already released — bump the version in pyproject.toml."; exit 1
fi
[ -f signing/MeetScribe-signing.keychain-db ] || [ -n "$SIGN_ID" ] || {
  echo "No stable signing identity: updates would be refused by installed apps."; exit 1; }

./scripts/build_app.sh
DMG="dist/MeetScribe-$VERSION.dmg"
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/MeetScribe.app/Contents/Info.plist)
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/MeetScribe-$VERSION.dmg"

echo "• GitHub release v$VERSION (build $BUILD)"
"$GH" release create "v$VERSION" "$DMG" --repo "$RELEASES_REPO" --title "MeetScribe $VERSION" --notes "$NOTES"

echo "• latest.json + models.json"
WORK="$ROOT/build-cache/releases-repo"
rm -rf "$WORK"
"$GH" repo clone "$RELEASES_REPO" "$WORK" -- --depth 1 -q
python3 - "$WORK/latest.json" "$VERSION" "$BUILD" "$URL" "$SHA" "$NOTES" <<'PY'
import json, sys
path, version, build, url, sha, notes = sys.argv[1:]
json.dump({"version": version, "build": int(build), "url": url, "sha256": sha, "notes": notes},
          open(path, "w"), indent=1)
PY
cp catalog/models.json "$WORK/models.json"
cp mac/INSTALL.txt "$WORK/INSTALL.txt"
git -C "$WORK" add latest.json models.json INSTALL.txt
git -C "$WORK" commit -qm "MeetScribe $VERSION" && git -C "$WORK" push -q

git tag "v$VERSION" && git push -q origin "v$VERSION" 2>/dev/null || true
echo "✅ Released MeetScribe $VERSION — installed apps will offer the update within a day."
