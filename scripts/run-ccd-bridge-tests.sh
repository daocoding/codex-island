#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

/usr/bin/python3 -m unittest Tests/test_ccd_usage_bridge.py

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/ccd-usage-bridge-tests" \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/Usage/ClaudeDesktopUsageBridge.swift \
  Tests/ClaudeDesktopUsageBridgeTests.swift

"$OUT_DIR/ccd-usage-bridge-tests"
