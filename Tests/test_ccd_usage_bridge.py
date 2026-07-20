from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "ccd-usage-bridge.py"
SPEC = importlib.util.spec_from_file_location("ccd_usage_bridge", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class ClaudeDesktopUsageBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = 1_800_000_000.0
        self.response = {
            "five_hour": {
                "utilization": 12.5,
                "resets_at": self.now + 3_600,
            },
            "seven_day": {
                "utilization": 41,
                "resets_at": self.now + 4 * 86_400,
            },
            "limits": [
                {
                    "kind": "weekly_scoped",
                    "percent": 72,
                    "resets_at": self.now + 4 * 86_400,
                    "scope": {"model": {"display_name": "Fable"}},
                }
            ],
            "subscription_type": "max",
            "account": "must-not-cross-the-bridge",
        }

    def test_snapshot_contains_only_allowlisted_fields(self) -> None:
        snapshot = BRIDGE._snapshot_from_response(self.response, self.now)
        self.assertIsNotNone(snapshot)
        self.assertEqual(set(snapshot), {
            "schema_version", "provider", "source", "generated_at", "plan", "windows"
        })
        encoded = json.dumps(snapshot)
        self.assertNotIn("account", encoded)
        self.assertEqual(snapshot["windows"]["scoped_weekly"]["label"], "Fable")

    def test_expired_and_impossible_windows_are_dropped(self) -> None:
        self.response["five_hour"]["resets_at"] = self.now - 1
        self.response["seven_day"]["resets_at"] = self.now + 9 * 86_400
        self.response["limits"] = []
        self.assertIsNone(BRIDGE._snapshot_from_response(self.response, self.now))

    def test_malformed_percent_is_not_coerced_to_zero(self) -> None:
        self.response["five_hour"]["utilization"] = "0"
        self.response["seven_day"]["utilization"] = float("nan")
        self.response["limits"] = []
        self.assertIsNone(BRIDGE._snapshot_from_response(self.response, self.now))

    def test_atomic_output_is_owner_only(self) -> None:
        snapshot = BRIDGE._snapshot_from_response(self.response, self.now)
        self.assertIsNotNone(snapshot)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.json"
            BRIDGE._atomic_write(path, snapshot)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(json.loads(path.read_text()), snapshot)

    def test_token_validation_rejects_controls(self) -> None:
        self.assertIsNone(BRIDGE._valid_token(None))
        self.assertIsNone(BRIDGE._valid_token("x" * 31))
        self.assertIsNone(BRIDGE._valid_token("x" * 40 + "\n"))
        self.assertEqual(BRIDGE._valid_token("x" * 40), "x" * 40)

    def test_first_throttle_open_is_not_rate_limited(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "throttle"
            descriptor, created = BRIDGE._open_throttle(path)
            os.close(descriptor)
            self.assertTrue(created)

            descriptor, created = BRIDGE._open_throttle(path)
            os.close(descriptor)
            self.assertFalse(created)

    def test_missing_token_is_a_silent_noop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache"
            with mock.patch.dict(os.environ, {}, clear=True), \
                 mock.patch.object(BRIDGE, "CACHE_DIRECTORY", cache), \
                 mock.patch.object(BRIDGE, "SNAPSHOT_PATH", cache / "snapshot.json"), \
                 mock.patch.object(BRIDGE, "THROTTLE_PATH", cache / "throttle"), \
                 mock.patch.object(BRIDGE, "_drain_hook_input"):
                self.assertEqual(BRIDGE.main(), 0)
            self.assertFalse(cache.exists())

    def test_main_deduplicates_attempts_for_five_minutes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache"
            snapshot = BRIDGE._snapshot_from_response(self.response, self.now)
            attempts = []

            def fetch(_token, attempted_at):
                attempts.append(attempted_at)
                return snapshot

            common = [
                mock.patch.object(BRIDGE, "CACHE_DIRECTORY", cache),
                mock.patch.object(BRIDGE, "SNAPSHOT_PATH", cache / "snapshot.json"),
                mock.patch.object(BRIDGE, "THROTTLE_PATH", cache / "throttle"),
                mock.patch.object(BRIDGE, "_drain_hook_input"),
                mock.patch.object(BRIDGE, "_fetch_snapshot", side_effect=fetch),
                mock.patch.dict(os.environ, {"CLAUDE_CODE_OAUTH_TOKEN": "x" * 40}, clear=True),
            ]
            for patcher in common:
                patcher.start()
            try:
                with mock.patch.object(BRIDGE.time, "time", return_value=self.now):
                    BRIDGE.main()
                with mock.patch.object(BRIDGE.time, "time", return_value=self.now + 299):
                    BRIDGE.main()
                with mock.patch.object(BRIDGE.time, "time", return_value=self.now + 300):
                    BRIDGE.main()
            finally:
                for patcher in reversed(common):
                    patcher.stop()

            self.assertEqual(attempts, [self.now, self.now + 300])
            self.assertEqual(stat.S_IMODE((cache / "snapshot.json").stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
