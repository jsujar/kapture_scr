#!/bin/bash
# Runs the unit tests with code coverage and prints a per-file summary for the app source.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/coverage.sh
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/swift test --enable-code-coverage
BIN=$(/usr/bin/swift build --show-bin-path)
/usr/bin/xcrun llvm-cov report "$BIN/KaptureTests.xctest/Contents/MacOS/KaptureTests" \
    -instr-profile "$BIN/codecov/default.profdata" Sources/
