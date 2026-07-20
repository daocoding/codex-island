# Fork maintenance

This fork keeps upstream CodexIsland recognizable while treating Tony's CD/CCD
quota instrument as an additive product layer.

## Integration boundaries

- `Sources/UsageCore/` owns normalized quota state, ordering, reset resolution,
  compatibility projection, and versioned sanitized persistence.
- `Sources/Providers/Codex/` owns the read-only Codex Desktop shared-auth adapter.
- `Sources/Usage/ClaudeDesktopUsageBridge.swift` and
  `scripts/ccd-usage-bridge.py` form the sanitized CCD boundary.
- `Sources/Fork/` contains integrations that are intentionally not upstream
  product behavior, currently the aiOS broadcaster.
- `Sources/Usage/UsageStore.swift` is the temporary composition root. Keep new
  provider behavior behind the boundaries above instead of adding more parsing
  or reconciliation logic directly to the store.
- `Sources/Views/IslandRootView.swift` owns the fork's 261pt resting instrument.

## Data-source contract

- CD: read `${CODEX_HOME:-~/.codex}/auth.json`; never refresh or persist its
  credential. One immutable credential generation serves usage and reset-credit
  requests in each poll.
- CCD: prefer a fresh sanitized hook snapshot. The bridge may publish only
  percentages, reset schedules, plan, model label, source, and observation time.
  It must never publish credentials, account identity, prompts, transcripts, raw
  responses, or provider error bodies.
- Claude shared auth: read-only fallback when the CCD snapshot is absent or
  stale. CodexIsland never calls Anthropic's token-refresh endpoint.
- Unknown is `nil`, not `0`. Provider health is separate from readings; a failed
  poll may make a reading stale but must not erase it or re-date it.

## Syncing upstream

```sh
git fetch upstream
git switch main
git merge --ff-only upstream/main
git switch feat/aios-broadcaster
git merge main
./scripts/run-all-tests.sh
./build.sh
```

Resolve conflicts by preserving upstream structure first, then reconnecting the
small seams above. The likely conflict files are `IslandRootView.swift`,
`UsageStore.swift`, `SettingsView.swift`, and `IslandModel.swift`; provider parsers,
the reducer, repository, bridge, and aiOS sink should remain independently
reviewable.

Do not change the bundle identifier, Sparkle public key, or release feed as part
of an ordinary upstream sync. Never stage an unrelated local design edit simply
because it is present in the worktree.

## Verification

`./scripts/run-all-tests.sh` covers the legacy resolver, notch rules, normalized
reducer, compatibility layer, coordinator, secure repository, CD adapter, and CCD
bridge. `./build.sh` then compiles both universal app slices. For UI changes,
install with `./scripts/install-local.sh` and inspect compact, hover, expanded,
provider-hidden, stale, and unknown states on the actual notch display.
