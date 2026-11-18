#!/bin/bash
# Load test for Kapture SCR: builds the real app code (Sources/Kapture/main.swift without its start-up lines)
# together with Bench.swift and runs capture, edit, copy/save and soak phases.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/loadtest/run.sh [scale] [output-dir]
#   scale: multiplies the number of operations (default 1 ≈ 4,800 operations, a few minutes on an M-series Mac).
set -euo pipefail
cd "$(dirname "$0")/../.."
SCALE=${1:-1}
OUT=${2:-$(mktemp -d -t kapture-loadtest)}
WORK=$(mktemp -d -t kapture-loadtest-build)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
# Everything before the four lines that start NSApplication is the app's code, unchanged.
START=$(grep -n '^let app = NSApplication.shared$' Sources/Kapture/main.swift | cut -d: -f1)
head -n $((START - 1)) Sources/Kapture/main.swift > "$WORK/App.swift"
cp scripts/loadtest/Bench.swift "$WORK/main.swift"
echo "Building (release, -O)…"
/usr/bin/xcrun swiftc -O -target arm64-apple-macos14 "$WORK/App.swift" "$WORK/main.swift" -o "$WORK/kapture-loadtest" 2>&1 | grep -v warning || true
[[ -x "$WORK/kapture-loadtest" ]] || { echo "Build failed"; exit 1; }
"$WORK/kapture-loadtest" "$SCALE" "$OUT"
