#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/codex-provider-tests" \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/Usage/CodexResetCredits.swift \
  Sources/Providers/Codex/CodexProviderTypes.swift \
  Sources/Providers/Codex/CodexDesktopProvider.swift \
  Tests/CodexProviderTests.swift

"$OUT_DIR/codex-provider-tests"
