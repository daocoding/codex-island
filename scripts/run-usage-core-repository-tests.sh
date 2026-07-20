#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/usage-core-repository-tests" \
  Sources/UsageCore/UsageDomain.swift \
  Sources/UsageCore/UsageReducer.swift \
  Sources/UsageCore/UsageStateRepository.swift \
  Tests/UsageCoreRepositoryTests.swift

"$OUT_DIR/usage-core-repository-tests"
