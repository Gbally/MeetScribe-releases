#!/bin/sh
# Publishes catalog/models.json alone (new tested models), without releasing a new app version.
set -e
cd "$(dirname "$0")/.."
GH=$(command -v gh || echo "$HOME/development/bin/gh")
WORK=build-cache/releases-repo
rm -rf "$WORK"
"$GH" repo clone Gbally/MeetScribe-releases "$WORK" -- --depth 1 -q
cp catalog/models.json "$WORK/models.json"
git -C "$WORK" add models.json
git -C "$WORK" commit -qm "Model catalog $(date +%Y-%m-%d)" && git -C "$WORK" push -q
echo "✅ Catalog published — apps pick it up within a week (or on next launch)."
