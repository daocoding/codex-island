#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION_DIR="$HOME/Library/Application Support/CodexIsland/Bridge"
DESTINATION="$DESTINATION_DIR/ccd-usage-bridge.py"
SETTINGS_DIR="$HOME/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"

umask 077
install -d -m 700 "$DESTINATION_DIR"
install -m 700 scripts/ccd-usage-bridge.py "$DESTINATION"
install -d -m 700 "$SETTINGS_DIR"

# Merge one identifiable handler into each activity event while preserving
# every unrelated Claude setting and existing hook. Python's shlex.quote
# produces a valid command string for the Application Support path's space.
/usr/bin/python3 - "$SETTINGS" "$DESTINATION" <<'PY'
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile

settings_path = Path(sys.argv[1])
helper_path = sys.argv[2]

if settings_path.exists():
    with settings_path.open("r", encoding="utf-8") as source:
        settings = json.load(source)
else:
    settings = {}

if not isinstance(settings, dict):
    raise SystemExit("Claude settings root must be a JSON object")
hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("Claude settings 'hooks' must be a JSON object")

command = shlex.quote(helper_path)
handler = {
    "hooks": [
        {
            "type": "command",
            "command": command,
            "async": True,
            "timeout": 15,
        }
    ]
}

for event in ("SessionStart", "UserPromptSubmit", "Stop"):
    event_handlers = hooks.setdefault(event, [])
    if not isinstance(event_handlers, list):
        raise SystemExit(f"Claude hook event {event!r} must be an array")
    already_installed = any(
        isinstance(group, dict)
        and any(
            isinstance(item, dict) and item.get("command") == command
            for item in group.get("hooks", [])
        )
        for group in event_handlers
    )
    if not already_installed:
        event_handlers.append(handler)

descriptor, temporary_name = tempfile.mkstemp(
    prefix=".settings.json.codexisland.",
    dir=settings_path.parent,
)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(settings, output, indent=2, ensure_ascii=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary_name, settings_path)
    os.chmod(settings_path, 0o600)
finally:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
PY

echo "Installed CCD usage bridge at:"
echo "$DESTINATION"
echo "Merged CCD activity hooks into:"
echo "$SETTINGS"
echo "Claude may ask you to review new hooks once in /hooks before activating them."
