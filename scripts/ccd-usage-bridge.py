#!/usr/bin/python3
"""Publish Claude Code Desktop quota data without exporting its credential."""

from __future__ import annotations

import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request


SCHEMA_VERSION = 1
MIN_INTERVAL_SECONDS = 5 * 60
MAX_RESPONSE_BYTES = 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 12
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "claude-code/2.1.121"

CACHE_DIRECTORY = (
    Path.home() / "Library" / "Caches" / "dev.codexisland.CodexIsland"
)
SNAPSHOT_PATH = CACHE_DIRECTORY / "ccd-usage-v1.json"
THROTTLE_PATH = CACHE_DIRECTORY / ".ccd-usage-v1.throttle"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def _finite_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _reset_timestamp(value: object) -> float | None:
    number = _finite_number(value)
    if number is not None:
        if number > 10_000_000_000:
            number /= 1000
        return number if number > 0 else None

    if not isinstance(value, str) or len(value) > 64:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    timestamp = parsed.timestamp()
    return timestamp if math.isfinite(timestamp) and timestamp > 0 else None


def _short_label(value: object, maximum_length: int = 32) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = unicodedata.normalize("NFKC", value).strip()
    if not normalized or len(normalized) > maximum_length:
        return None
    if any(unicodedata.category(character).startswith("C") for character in normalized):
        return None
    return normalized


def _window(
    raw: object,
    *,
    now: float,
    maximum_reset_distance: float,
    percent_key: str | None = None,
) -> dict[str, float] | None:
    if not isinstance(raw, dict):
        return None
    value = raw.get(percent_key) if percent_key else raw.get("utilization")
    if value is None and percent_key is None:
        value = raw.get("used_percent")
    percent = _finite_number(value)
    reset_at = _reset_timestamp(raw.get("resets_at"))
    if percent is None or not 0 <= percent <= 100 or reset_at is None:
        return None
    if reset_at <= now or reset_at > now + maximum_reset_distance:
        return None
    return {"used_percent": percent, "resets_at": reset_at}


def _plan(response: dict[str, object]) -> str | None:
    for key in ("subscription_type", "subscriptionType", "plan_type", "plan"):
        if (label := _short_label(response.get(key))) is not None:
            return label
    return None


def _scoped_window(response: dict[str, object], now: float) -> dict[str, object] | None:
    limits = response.get("limits")
    if isinstance(limits, list):
        for entry in limits:
            if not isinstance(entry, dict) or entry.get("kind") != "weekly_scoped":
                continue
            window = _window(
                entry,
                now=now,
                maximum_reset_distance=8 * 24 * 60 * 60,
                percent_key="percent",
            )
            scope = entry.get("scope")
            model = scope.get("model") if isinstance(scope, dict) else None
            label = _short_label(model.get("display_name")) if isinstance(model, dict) else None
            if window is not None and label is not None:
                return {**window, "label": label}

    legacy = _window(
        response.get("seven_day_opus"),
        now=now,
        maximum_reset_distance=8 * 24 * 60 * 60,
    )
    return {**legacy, "label": "Opus"} if legacy is not None else None


def _snapshot_from_response(response: object, now: float) -> dict[str, object] | None:
    if not isinstance(response, dict):
        return None
    if isinstance(response.get("error"), dict):
        return None

    windows: dict[str, object] = {}
    if (five_hour := _window(
        response.get("five_hour"),
        now=now,
        maximum_reset_distance=6 * 60 * 60,
    )) is not None:
        windows["five_hour"] = five_hour
    if (seven_day := _window(
        response.get("seven_day"),
        now=now,
        maximum_reset_distance=8 * 24 * 60 * 60,
    )) is not None:
        windows["seven_day"] = seven_day
    if (scoped := _scoped_window(response, now)) is not None:
        windows["scoped_weekly"] = scoped
    if not windows:
        return None

    snapshot: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "provider": "claude",
        "source": "claude_code_desktop",
        "generated_at": now,
        "windows": windows,
    }
    if (plan := _plan(response)) is not None:
        snapshot["plan"] = plan
    return snapshot


def _fetch_snapshot(token: str, now: float) -> dict[str, object] | None:
    request = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="GET",
    )
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                return None
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except (OSError, urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
        return None
    if len(body) > MAX_RESPONSE_BYTES:
        return None
    try:
        decoded = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return _snapshot_from_response(decoded, now)


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise OSError("cache path is not a directory")
    os.chmod(path, 0o700)


def _atomic_write(path: Path, snapshot: dict[str, object]) -> None:
    payload = (json.dumps(snapshot, separators=(",", ":"), sort_keys=True) + "\n").encode()
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
        os.chmod(path, 0o600)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def _valid_token(value: str | None) -> str | None:
    if value is None or not 32 <= len(value) <= 16_384:
        return None
    if any(ord(character) < 0x21 or ord(character) > 0x7E for character in value):
        return None
    return value


def _open_throttle(path: Path) -> tuple[int, bool]:
    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
        created = True
    except FileExistsError:
        descriptor = os.open(path, flags)
        created = False

    info = os.fstat(descriptor)
    if (
        info.st_uid != os.geteuid()
        or not stat.S_ISREG(info.st_mode)
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        os.close(descriptor)
        raise OSError("insecure throttle file")
    return descriptor, created


def _drain_hook_input() -> None:
    if not sys.stdin.isatty():
        try:
            sys.stdin.buffer.read()
        except OSError:
            pass


def main() -> int:
    _drain_hook_input()
    if os.environ.get("CLAUDE_CODE_REMOTE") == "true":
        return 0
    token = _valid_token(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"))
    if token is None:
        return 0

    try:
        _ensure_private_directory(CACHE_DIRECTORY)
        descriptor, created = _open_throttle(THROTTLE_PATH)
        try:
            os.fchmod(descriptor, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            now = time.time()
            modified_at = os.fstat(descriptor).st_mtime
            if not created and modified_at > 0:
                elapsed = now - modified_at
                if -60 <= elapsed < MIN_INTERVAL_SECONDS:
                    return 0
            os.utime(descriptor, (now, now))
            snapshot = _fetch_snapshot(token, now)
            if snapshot is not None:
                _atomic_write(SNAPSHOT_PATH, snapshot)
        finally:
            os.close(descriptor)
    except (OSError, ValueError):
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
