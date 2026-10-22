#!/bin/sh
# Publishes catalog/models.json alone (new tested models), without releasing a new app version:
# installed apps read models.json at the root of this repository.
set -e
cd "$(dirname "$0")/.."
cp catalog/models.json models.json
git add models.json
git diff --cached --quiet && { echo "models.json already up to date."; exit 0; }
git commit -qm "Model catalog $(date +%Y-%m-%d)"
git push -q origin main
echo "✅ Catalog published — apps pick it up within a day (or on next launch)."
