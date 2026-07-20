#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/usage-core-tests" \
  Sources/UsageCore/UsageDomain.swift \
  Sources/UsageCore/UsageReducer.swift \
  Tests/UsageCoreTests.swift

"$OUT_DIR/usage-core-tests"
