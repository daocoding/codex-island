#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/run-tests.sh
./scripts/run-usage-core-tests.sh
./scripts/run-usage-core-compatibility-tests.sh
./scripts/run-usage-coordinator-tests.sh
./scripts/run-usage-core-repository-tests.sh
./scripts/run-codex-provider-tests.sh
./scripts/run-ccd-bridge-tests.sh

echo "All CodexIsland test suites passed."
