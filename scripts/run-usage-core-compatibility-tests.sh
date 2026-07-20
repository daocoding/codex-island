#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/usage-core-compatibility-tests" \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/UsageCore/UsageDomain.swift \
  Sources/UsageCore/UsageReducer.swift \
  Sources/UsageCore/UsageCoreCompatibility.swift \
  Tests/UsageCoreCompatibilityTests.swift

"$OUT_DIR/usage-core-compatibility-tests"
