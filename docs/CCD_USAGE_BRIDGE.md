# Claude Code Desktop usage bridge

Claude Code Desktop (CCD) gives each local Claude Code child process a private,
short-lived `CLAUDE_CODE_OAUTH_TOKEN`. A separately launched CodexIsland process
cannot inherit that environment. This optional bridge runs as a supported Claude
Code command hook and publishes only quota percentages, reset timestamps, a scoped
model label, and the plan label when the endpoint supplies one. It never writes or
prints the token.

## Install

Install the reviewed helper into a stable, owner-only application-support path
and merge its activity handlers into the user-level Claude settings:

```sh
./scripts/install-ccd-usage-bridge.sh
```

The merge is additive and idempotent: unrelated settings and existing hooks remain
untouched. The resulting handlers are equivalent to the following (with the
absolute helper path shell-quoted because `Application Support` contains a space):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/Users/YOU/Library/Application Support/CodexIsland/Bridge/ccd-usage-bridge.py'",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/Users/YOU/Library/Application Support/CodexIsland/Bridge/ccd-usage-bridge.py'",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/Users/YOU/Library/Application Support/CodexIsland/Bridge/ccd-usage-bridge.py'",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

Claude Code protects hook configuration changes with a review step. Use `/hooks`
in a local CCD session if it asks you to approve the three new user-level hooks.
The helper runs asynchronously, so quota fetching never delays a prompt or completion.
Session start supplies the first reading; prompt submission and turn completion
keep active sessions current. An internal file lock deduplicates concurrent CCD
sessions and enforces at least five minutes between all endpoint attempts.

The sanitized v1 snapshot is written atomically with mode `0600` at:

```text
~/Library/Caches/dev.codexisland.CodexIsland/ccd-usage-v1.json
```

CodexIsland accepts the file only when it is a regular file owned by the current
user with exact mode `0600`, the schema and source identifiers match, the snapshot
is at most 20 minutes old, percentages are finite and within 0...100, and reset
times are plausible and still in the future. Individual windows disappear at their
reset boundary; malformed snapshots are rejected as a unit.

## Security assumptions

- The hook must run inside a local CCD/Claude Code child that already owns
  `CLAUDE_CODE_OAUTH_TOKEN`. Missing tokens, remote sessions, network errors, and
  rate limits are silent no-ops; the prior snapshot is never rewritten as fresh.
- The token remains only in the hook process memory and one HTTPS Authorization
  header. It is never persisted, included in JSON, printed, or copied into the
  CodexIsland process.
- Hook stdin is discarded without parsing or persistence. Prompts, transcript
  paths, account identifiers, API error bodies, and raw API responses never cross
  the bridge.
- Command hooks execute with the user's permissions. Install only the reviewed
  helper, keep its application-support directory owner-only, and use the absolute
  exec-form path above. If `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` removes credentials
  from hook environments, the bridge intentionally remains inactive.
- CCD hooks are activity-driven, not a background credential service. If CCD is
  open but idle, the bridge does not run; usage cannot change while no requests are
  being made. CodexIsland should fall back to shared CLI credentials or a valid
  cache after the 20-minute live-source window.

Claude's official [hooks reference](https://code.claude.com/docs/en/hooks) documents
user-level settings, inherited hook environments, exec-form paths, asynchronous
command handlers, and the `/hooks` inspector.

## Verify

Run the isolated publisher and Swift-reader tests:

```sh
./scripts/run-ccd-bridge-tests.sh
```
