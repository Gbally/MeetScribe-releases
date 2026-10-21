#!/bin/sh
# Builds the recorder into ../bin/meeting-recorder (needs Xcode Command Line Tools).
set -e
cd "$(dirname "$0")"
mkdir -p ../bin
swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  Recorder.swift -o ../bin/meeting-recorder
echo "Built bin/meeting-recorder"
