#!/bin/bash
# Build and atomically install the maintained app under /Applications.
# Launch at Login must target this durable bundle, never the replaceable
# build/CodexIsland.app used by verify.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CodexIsland"
SOURCE_APP="$(pwd)/build/$APP_NAME.app"
INSTALL_DIR="${CODEXISLAND_INSTALL_DIR:-/Applications}"
DEST_APP="$INSTALL_DIR/$APP_NAME.app"

./build.sh

STAGING_ROOT="$(mktemp -d "$INSTALL_DIR/.codexisland-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
BACKUP_APP="$INSTALL_DIR/.$APP_NAME.previous.$$.app"

cleanup() {
  rm -rf -- "$STAGING_ROOT"
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$STAGED_APP"
codesign --force --deep --sign - "$STAGED_APP"
xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true

osascript -e 'tell application id "dev.codexisland.CodexIsland" to quit' 2>/dev/null || true
sleep 1

if [[ -e "$DEST_APP" ]]; then
  mv "$DEST_APP" "$BACKUP_APP"
fi

if mv "$STAGED_APP" "$DEST_APP"; then
  rm -rf -- "$BACKUP_APP"
else
  if [[ -e "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$DEST_APP"
  fi
  echo "error: failed to install $DEST_APP" >&2
  exit 1
fi

open "$DEST_APP"
echo "✓ installed and launched $DEST_APP"
