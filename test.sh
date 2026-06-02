#!/bin/bash
# Smoke tests + value-range tests. Usage: ./test.sh [value-test-seconds]
# (default 30). Compiles the reader sources directly (no XCTest/SwiftPM).
set -euo pipefail

cd "$(dirname "$0")"
SECONDS_ARG="${1:-30}"
OUT=".build/tests"
mkdir -p "$OUT"

echo "▸ Compiling tests…"
swiftc -O -o "$OUT/tests" \
    Sources/SysMonitor/Metrics.swift \
    Sources/SysMonitor/Readers.swift \
    Sources/SysMonitor/Sensors.swift \
    Sources/SysMonitor/Logger.swift \
    Tests/main.swift \
    -framework Foundation -framework IOKit -framework Combine \
    -target arm64-apple-macosx13.0

echo "▸ Reader + value tests…"
"$OUT/tests" "$SECONDS_ARG"

echo "▸ App smoke test (launch and survive)…"
./build.sh >/dev/null
./SysMonitor.app/Contents/MacOS/SysMonitor >/tmp/sm_test.log 2>&1 &
PID=$!
sleep 3
if kill -0 "$PID" 2>/dev/null; then
    echo "  ok    app launched and stayed up 3s"
    { kill "$PID" && wait "$PID"; } 2>/dev/null || true
else
    echo "  FAIL  app exited early:"; cat /tmp/sm_test.log; rm -f /tmp/sm_test.log; exit 1
fi
rm -f /tmp/sm_test.log
echo "✓ all tests passed"
