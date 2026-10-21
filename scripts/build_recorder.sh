#!/bin/sh
# Builds the command-line recorder into bin/meeting-recorder (used by `meetscribe record`).
set -e
cd "$(dirname "$0")/.."
mkdir -p bin
swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  mac/Shared/*.swift mac/CLI/*.swift -o bin/meeting-recorder
echo "Built bin/meeting-recorder"
