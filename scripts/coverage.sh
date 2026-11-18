#!/bin/bash
# Runs the unit tests with code coverage and prints a per-file summary for the app source.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/coverage.sh
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/swift test --enable-code-coverage
BIN=$(/usr/bin/swift build --show-bin-path)
# The test bundle is KaptureTests.xctest or KapturePackageTests.xctest depending on the SwiftPM version.
BUNDLE=$(ls -d "$BIN"/*.xctest | head -n 1)
/usr/bin/xcrun llvm-cov report "$BUNDLE/Contents/MacOS/$(basename "$BUNDLE" .xctest)" \
    -instr-profile "$BIN/codecov/default.profdata" Sources/
