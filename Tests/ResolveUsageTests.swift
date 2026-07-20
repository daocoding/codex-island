import Foundation

/// Regression tests for ClaudeCredentials.resolveUsage, run by
/// scripts/run-tests.sh (no XCTest — the app builds with bare swiftc, so the
/// harness does too). The runner sets CLAUDE_CODE_OAUTH_TOKEN to a stub value
/// so the env-token path drives the injected probe deterministically on any
/// machine, with or without a real "Claude Code-credentials" keychain item.
///
/// Why the rate-limited case is locked down (issue #35): Anthropic's
/// /api/oauth/usage limiter is account-keyed and sticky once tripped
/// (anthropics/claude-code#30930). resolveUsage must short-circuit on the
/// first rate-limited probe — if a regression reintroduces the old
/// fall-through, every poll cycle re-probes against a throttled account.
@main
struct ResolveUsageTests {
    final class ProbeCounter {
        var calls = 0
    }

    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func main() async {
        guard ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "test-stub-token" else {
            print("FAIL harness must run via scripts/run-tests.sh (env token stub missing)")
            exit(1)
        }

        // Prime the creds cache so resolveUsage never reads the developer's
        // real keychain — an actual read would pop the keychain ACL prompt on
        // every test run and make results depend on the machine's login state.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub", accessToken: "stub-keychain-token", subscriptionType: nil)

        // T1 — a rate-limited probe short-circuits the whole resolution:
        // exactly one probe (no fallback to the next token source) and the
        // exact error string the UI and UsageStore cooldown match on.
        let t1 = ProbeCounter()
        let r1 = await ClaudeCredentials.resolveUsage { _, _ in
            t1.calls += 1
            return .rateLimited(retryAfter: 3577)
        }
        if case .failed(let msg, let retryAfter) = r1 {
            expect(msg == ClaudeCredentials.rateLimitedMessage, "T1 resolution is .failed(rateLimitedMessage)")
            expect(retryAfter == 3577, "T1 carries the provider Retry-After value")
        } else {
            expect(false, "T1 resolution is .failed(rateLimitedMessage)")
        }
        expect(t1.calls == 1, "T1 probes exactly once (got \(t1.calls))")

        // T2 — a successful probe passes usage through untouched.
        let t2 = ProbeCounter()
        let fetched = AppUsage(
            fiveHour: WindowUsage(usedPercent: 0.13, resetAt: nil, error: nil),
            weekly: WindowUsage(usedPercent: 0.14, resetAt: nil, error: nil)
        )
        let r2 = await ClaudeCredentials.resolveUsage { _, _ in
            t2.calls += 1
            return .success(fetched)
        }
        if case .usage(let u) = r2 {
            expect(u.fiveHour.usedPercent == 0.13 && u.weekly.usedPercent == 0.14, "T2 usage passes through")
        } else {
            expect(false, "T2 usage passes through")
        }
        expect(t2.calls == 1, "T2 probes exactly once (got \(t2.calls))")

        // T3 — multi-item keychain selection. Claude Code writes several items
        // under one service name; a stray acct="unknown" item holds only
        // mcpOAuth. Selection must skip it (and any logged-out empty-token
        // item) and pick the item that actually carries claudeAiOauth.
        let candidates = [
            ClaudeCredentials.KeychainCandidate(account: "unknown", blob: ["mcpOAuth": ["server": "x"]]),
            ClaudeCredentials.KeychainCandidate(account: "loggedout", blob: ["claudeAiOauth": ["accessToken": "", "refreshToken": ""]]),
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "mcpOAuth": ["server": "x"],
                "claudeAiOauth": ["accessToken": "at", "refreshToken": "rt", "subscriptionType": "max"],
            ]),
        ]
        let picked = ClaudeCredentials.selectClaudeCreds(from: candidates)
        expect(picked?.account == "ericpark", "T3 selects the claudeAiOauth item, not the mcpOAuth/empty ones")
        expect(picked?.subscriptionType == "max", "T3 carries subscriptionType from the picked item")
        expect(ClaudeCredentials.selectClaudeCreds(from: [
            ClaudeCredentials.KeychainCandidate(account: "unknown", blob: ["mcpOAuth": [:]]),
        ]) == nil, "T3 returns nil when no item carries claudeAiOauth")

        // T4 — an unauthorized keychain-token probe must clear the creds
        // cache, or a token Claude Code rotated externally stays stale in
        // the cache forever and the chip never recovers past "token expired".
        // Priming the cache short-circuits the real keychain read, keeping
        // this deterministic on any machine.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "primed", accessToken: "stale-token", subscriptionType: "max")
        let t4 = ProbeCounter()
        let r4 = await ClaudeCredentials.resolveUsage { _, _ in
            t4.calls += 1
            return .unauthorized
        }
        // Env stub token probes first (unauthorized → falls through), then
        // the primed keychain creds probe (unauthorized → clears cache).
        expect(t4.calls == 2, "T4 probes env then cached keychain token (got \(t4.calls))")
        expect(ClaudeCredentials.cachedClaudeCreds == nil, "T4 unauthorized keychain probe clears the creds cache")
        if case .failed(let msg, _) = r4 {
            expect(msg == ClaudeCredentials.tokenExpiredMessage, "T4 resolution is .failed(tokenExpiredMessage)")
        } else {
            expect(false, "T4 resolution is .failed(tokenExpiredMessage)")
        }
        ClaudeCredentials.clearCache()

        // T5 — file credential store (issue #54). Users who migrated to
        // ~/.claude/.credentials.json and deleted the keychain item must
        // still get usage. Point CLAUDE_CONFIG_DIR at a fixture and assert
        // the decoded candidate feeds the same selection as keychain items.
        let fixtureDir = NSTemporaryDirectory() + "codexisland-tests-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: fixtureDir, withIntermediateDirectories: true)
        let fixture = """
        {"claudeAiOauth": {"accessToken": "file-at", "refreshToken": "file-rt", "subscriptionType": "pro"}}
        """
        FileManager.default.createFile(atPath: fixtureDir + "/.credentials.json", contents: Data(fixture.utf8))
        setenv("CLAUDE_CONFIG_DIR", fixtureDir, 1)
        let fileCandidates = ClaudeCredentials.readClaudeFileCandidates()
        let filePicked = ClaudeCredentials.selectClaudeCreds(from: fileCandidates)
        expect(filePicked?.accessToken == "file-at", "T5 file store candidate decodes and is selectable")
        expect(filePicked?.subscriptionType == "pro", "T5 file store carries subscriptionType")
        // File store outranks a coexisting (stale) keychain item — Claude
        // Code itself prefers the file when it exists.
        let mixed = ClaudeCredentials.selectClaudeCreds(from: fileCandidates + [
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "claudeAiOauth": ["accessToken": "stale-keychain-at"],
            ]),
        ])
        expect(mixed?.accessToken == "file-at", "T5 file store wins over a coexisting keychain item")
        var keychainRead = false
        let lazyPick = ClaudeCredentials.selectClaudeCreds(
            fileCandidates: fileCandidates,
            keychainCandidates: {
                keychainRead = true
                return [ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                    "claudeAiOauth": ["accessToken": "stale-keychain-at"],
                ])]
            }
        )
        expect(lazyPick?.accessToken == "file-at", "T5 lazy file precedence returns file credential")
        expect(!keychainRead, "T5 usable file credential does not touch keychain")
        // Keep CLAUDE_CONFIG_DIR pinned to the (now deleted) fixture dir so
        // this assertion never touches a real ~/.claude on the dev machine.
        try? FileManager.default.removeItem(atPath: fixtureDir)
        expect(ClaudeCredentials.readClaudeFileCandidates().isEmpty, "T5 missing file yields no candidates")
        unsetenv("CLAUDE_CONFIG_DIR")

        // T6 — model-scoped weekly parse (the Fable tile). The fixture is the
        // exact response shape captured from /api/oauth/usage on a Max
        // account (2026-07-10): the scoped bucket lives in `limits[]` keyed
        // by kind == "weekly_scoped" with `percent` (not `utilization`), and
        // the legacy seven_day_opus field is null.
        let scopedFixture = """
        {
          "five_hour": {"utilization": 3.0, "resets_at": "2026-07-11T04:49:59.870074+00:00"},
          "seven_day": {"utilization": 15.0, "resets_at": "2026-07-12T21:59:59.870096+00:00"},
          "seven_day_opus": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 3, "severity": "normal",
             "resets_at": "2026-07-11T04:49:59.870074+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 15, "severity": "normal",
             "resets_at": "2026-07-12T21:59:59.870096+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 23, "severity": "normal",
             "resets_at": "2026-07-12T21:59:59.870379+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": true}
          ]
        }
        """
        let scopedObj = try! JSONSerialization.jsonObject(with: Data(scopedFixture.utf8)) as! [String: Any]
        let scoped = UsageFetcher.parseClaudeScopedWeekly(scopedObj)
        expect(scoped != nil, "T6 scoped weekly parses from limits[]")
        expect(scoped?.label == "Fable", "T6 scoped label is the server display_name")
        expect(scoped.map { abs($0.window.usedPercent - 0.23) < 0.0001 } == true, "T6 scoped percent normalizes to 0.23")
        expect(scoped?.window.resetAt != nil, "T6 scoped resets_at parses (fractional-seconds ISO8601)")

        // No scoped limit anywhere (free/pro plans) → nil, so the UI renders
        // no third tile.
        let unscoped = UsageFetcher.parseClaudeScopedWeekly([
            "five_hour": [:], "seven_day_opus": NSNull(),
        ])
        expect(unscoped == nil, "T6 no scoped limit yields nil")

        // Legacy accounts still on the seven_day_opus shape fall back with
        // the fixed Opus label.
        let legacy = UsageFetcher.parseClaudeScopedWeekly([
            "seven_day_opus": ["utilization": 40.0, "resets_at": "2026-07-12T21:59:59+00:00"],
        ])
        expect(legacy?.label == "Opus", "T6 legacy seven_day_opus falls back with Opus label")
        expect(legacy.map { abs($0.window.usedPercent - 0.4) < 0.0001 } == true, "T6 legacy percent normalizes")

        // T7 — Codex window classification. Plus accounts can now return a
        // weekly-only bucket as primary_window, so key order no longer tells
        // us which duration is being reported.
        let weeklyOnly = UsageFetcher.parseCodexUsage([
            "allowed": true,
            "primary_window": [
                "used_percent": 52,
                "limit_window_seconds": 604_800,
                "reset_at": 1_784_487_940,
            ],
            "secondary_window": NSNull(),
        ], plan: "plus")
        expect(weeklyOnly.shortWindowLabel == nil, "T7 weekly-only Codex omits the short tile")
        expect(weeklyOnly.weeklyWindowLabel == "week", "T7 7d Codex window gets the week label")
        expect(abs(weeklyOnly.weekly.usedPercent - 0.52) < 0.0001, "T7 weekly-only usage maps to weekly")
        expect(weeklyOnly.headlineWindow.percentInt == 52, "T7 weekly-only usage drives the peek headline")

        let dualWindow = UsageFetcher.parseCodexUsage([
            "primary_window": [
                "used_percent": 21,
                "limit_window_seconds": 18_000,
                "reset_at": 1_784_000_000,
            ],
            "secondary_window": [
                "used_percent": 34,
                "limit_window_seconds": 604_800,
                "reset_at": 1_784_500_000,
            ],
        ])
        expect(dualWindow.shortWindowLabel == "5h", "T7 legacy 5h duration keeps the 5h label")
        expect(dualWindow.weeklyWindowLabel == "week", "T7 dual response keeps the week label")
        expect(dualWindow.headlineWindow.percentInt == 21, "T7 short window remains the preferred headline")

        let durationless = UsageFetcher.parseCodexUsage([
            "primary_window": ["used_percent": 13],
            "secondary_window": ["used_percent": 47],
        ])
        expect(durationless.shortWindowLabel == "5h" && durationless.weeklyWindowLabel == "week",
               "T7 durationless response preserves legacy key mapping")

        // T8 — unsigned/ad-hoc builds have a content-hash identity that
        // changes whenever the app is rebuilt. Route those through Apple's
        // stable security helper so an Always Allow grant actually persists;
        // a certificate-signed build keeps native in-process attribution.
        expect(ClaudeCredentials.shouldUseSecurityCLI(hasStableSigningIdentity: false),
               "T8 unsigned build uses stable security CLI identity")
        expect(!ClaudeCredentials.shouldUseSecurityCLI(hasStableSigningIdentity: true),
               "T8 signed build keeps in-process keychain access")

        // T9 — Anthropic's retry header and Claude's local session-limit row
        // are the two recovery paths that prevent a stale 0% reading.
        expect(UsageFetcher.parseRetryAfter("3577") == 3577,
               "T9 Retry-After delta-seconds parses")
        let epoch = Date(timeIntervalSince1970: 0)
        expect(UsageFetcher.parseRetryAfter(
            "Thu, 01 Jan 1970 01:00:00 GMT", now: epoch
        ) == 3600, "T9 Retry-After HTTP-date parses")

        let eventAt = ISO8601DateFormatter().date(from: "2026-07-16T23:40:57Z")!
        let reset = ClaudeSessionLimitFallback.parseResetDate(
            from: "You've hit your session limit · resets 8pm (America/New_York)",
            eventAt: eventAt
        )
        expect(reset == ISO8601DateFormatter().date(from: "2026-07-17T00:00:00Z"),
               "T9 local session-limit reset parses in its named timezone")

        // Upstream's dedicated auth panel is retained, but it must follow our
        // typed provider health: ordinary access expiry is recoverable by CCD
        // or Claude Code and must not demand a fresh interactive login.
        expect(!UsageFailureKind.authenticationExpired.requiresInteractiveReauthentication,
               "T9 access expiry does not trigger interactive reauthentication")
        expect(UsageFailureKind.reauthenticationRequired.requiresInteractiveReauthentication,
               "T9 missing OAuth scope triggers the dedicated reauthentication panel")

        // The store and views match these exact strings; a reword is a
        // breaking change for them, not a copy edit.
        expect(ClaudeCredentials.rateLimitedMessage == "rate limited", "rateLimitedMessage literal is stable")
        expect(ClaudeCredentials.reauthRequiredMessage == "re-login: claude /login", "reauthRequiredMessage literal is stable")
        expect(ClaudeCredentials.tokenExpiredMessage == "token expired — run claude", "tokenExpiredMessage literal is stable")

        // T10 — startup hydration. The notch should not boot as an all-zero
        // model just because Claude is cooling down; keep the last complete
        // provider snapshot, including reset times and scoped model label.
        let suiteName = "CodexIslandSnapshotTests-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let snapshotNow = Date(timeIntervalSince1970: 10_000)
        UsageSnapshotStore.recordClaude(AppUsage(
            fiveHour: WindowUsage(
                usedPercent: 0.22,
                resetAt: Date(timeIntervalSince1970: 11_000),
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.49,
                resetAt: Date(timeIntervalSince1970: 20_000),
                error: nil
            ),
            plan: "max",
            scopedWeekly: WindowUsage(
                usedPercent: 0.80,
                resetAt: Date(timeIntervalSince1970: 20_000),
                error: nil
            ),
            scopedLabel: "Fable"
        ), at: snapshotNow, defaults: defaults)
        let hydrated = UsageSnapshotStore.load(
            now: Date(timeIntervalSince1970: 10_500),
            defaults: defaults
        )
        expect(hydrated.claude?.usage.weekly.percentInt == 49,
               "T10 snapshot restores Claude weekly percent")
        expect(hydrated.claude?.usage.scopedLabel == "Fable",
               "T10 snapshot restores scoped model label")
        expect(hydrated.claude?.usage.weekly.resetAt == Date(timeIntervalSince1970: 20_000),
               "T10 snapshot restores reset time")
        expect(hydrated.claude?.usage.weekly.observedAt == snapshotNow,
               "T10 legacy snapshot inherits its provider observation time")
        expect(hydrated.claude?.usage.weekly.source == .migratedCache,
               "T10 legacy snapshot is explicitly marked as migrated cache")

        UsageSnapshotStore.recordCodex(AppUsage(
            fiveHour: WindowUsage(
                usedPercent: 0.99,
                resetAt: Date(timeIntervalSince1970: 10_900),
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.44,
                resetAt: Date(timeIntervalSince1970: 20_000),
                error: nil
            )
        ), at: snapshotNow, defaults: defaults)
        let sanitizedSnapshot = UsageSnapshotStore.load(
            now: Date(timeIntervalSince1970: 11_100),
            defaults: defaults
        )
        expect(sanitizedSnapshot.codex?.usage.fiveHour.error != nil,
               "T10 expired snapshot short window is not revived")
        expect(sanitizedSnapshot.codex?.usage.weekly.percentInt == 44,
               "T10 valid snapshot weekly window survives")

        let afterAllClaudeResets = UsageSnapshotStore.load(
            now: Date(timeIntervalSince1970: 20_100),
            defaults: defaults
        )
        expect(afterAllClaudeResets.claude?.usage.fiveHour.hasKnownValue == false,
               "T10 elapsed Claude 5h cycle cannot retain its old percent")
        expect(afterAllClaudeResets.claude?.usage.weekly.hasKnownValue == false,
               "T10 elapsed Claude weekly cycle cannot retain its old percent")
        expect(afterAllClaudeResets.claude?.usage.scopedWeekly?.hasKnownValue == false,
               "T10 elapsed scoped cycle cannot retain its old percent")
        expect(afterAllClaudeResets.claude?.usage.scopedLabel == "Fable",
               "T10 expired scoped cycle keeps its known display slot")
        defaults.removePersistentDomain(forName: suiteName)

        // T11 — local credential expiry and rejected-token suppression. The
        // app must remain read-only and avoid turning a deterministic expired
        // token into a 401-every-5m storm. A rotated token fingerprint resumes
        // probing without requiring an app restart.
        let authNow = Date(timeIntervalSince1970: 50_000)
        unsetenv("CLAUDE_CODE_OAUTH_TOKEN")
        ClaudeCredentials.clearRejectedCredential()
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub",
            accessToken: "expired-token",
            subscriptionType: "max",
            expiresAt: authNow.addingTimeInterval(-1)
        )
        let expiredCounter = ProbeCounter()
        let expiredResolution = await ClaudeCredentials.resolveUsage(now: authNow) { _, _ in
            expiredCounter.calls += 1
            return .success(fetched)
        }
        expect(expiredCounter.calls == 0, "T11 locally expired token makes no HTTP probe")
        if case .failed(let message, _) = expiredResolution {
            expect(message == ClaudeCredentials.tokenExpiredMessage,
                   "T11 locally expired token reports tokenExpiredMessage")
        } else {
            expect(false, "T11 locally expired token reports tokenExpiredMessage")
        }

        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub",
            accessToken: "rejected-token-A",
            subscriptionType: "max",
            expiresAt: authNow.addingTimeInterval(3600)
        )
        let rejectedCounter = ProbeCounter()
        _ = await ClaudeCredentials.resolveUsage(now: authNow) { _, _ in
            rejectedCounter.calls += 1
            return .unauthorized
        }
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub",
            accessToken: "rejected-token-A",
            subscriptionType: "max",
            expiresAt: authNow.addingTimeInterval(3600)
        )
        _ = await ClaudeCredentials.resolveUsage(now: authNow) { _, _ in
            rejectedCounter.calls += 1
            return .success(fetched)
        }
        expect(rejectedCounter.calls == 1,
               "T11 unchanged rejected token is not probed twice")

        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub",
            accessToken: "rejected-token-A",
            subscriptionType: "max",
            expiresAt: authNow.addingTimeInterval(7200)
        )
        let renewedResolution = await ClaudeCredentials.resolveUsage(now: authNow) { _, _ in
            rejectedCounter.calls += 1
            return .success(fetched)
        }
        expect(rejectedCounter.calls == 2,
               "T11 same token with renewed expiry resumes probing")
        if case .usage = renewedResolution {
            expect(true, "T11 renewed credential generation can recover usage")
        } else {
            expect(false, "T11 renewed credential generation can recover usage")
        }

        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub",
            accessToken: "rotated-token-B",
            subscriptionType: "max",
            expiresAt: authNow.addingTimeInterval(7200)
        )
        let rotatedResolution = await ClaudeCredentials.resolveUsage(now: authNow) { _, _ in
            rejectedCounter.calls += 1
            return .success(fetched)
        }
        expect(rejectedCounter.calls == 3, "T11 rotated token resumes probing")
        if case .usage = rotatedResolution {
            expect(true, "T11 rotated token can recover usage")
        } else {
            expect(false, "T11 rotated token can recover usage")
        }
        ClaudeCredentials.clearCache()
        ClaudeCredentials.clearRejectedCredential()
        setenv("CLAUDE_CODE_OAUTH_TOKEN", "test-stub-token", 1)

        let parsedExpiry = ClaudeCredentials.parseCredentialExpiry(1_784_404_512_681 as NSNumber)
        expect(parsedExpiry == Date(timeIntervalSince1970: 1_784_404_512.681),
               "T11 millisecond credential expiry parses")
        expect(!UsageFailureKind.authenticationExpired.requiresInteractiveReauthentication,
               "T11 access expiry does not claim the user is signed out")
        expect(UsageFailureKind.reauthenticationRequired.requiresInteractiveReauthentication,
               "T11 missing OAuth scope still requires interactive reauthentication")

        // T12 — schema drift and unknown-display behavior. Missing utilization
        // is unavailable, never fabricated as 0%; remaining mode must not turn
        // that sentinel into a full 100% ring.
        let malformedWindow = UsageFetcher.parseClaudeWindow([
            "resets_at": "2026-07-20T00:00:00Z",
        ])
        expect(!malformedWindow.hasKnownValue,
               "T12 Claude window without utilization is unknown")
        expect(malformedWindow.displayedPercentInt(mode: .remaining) == 0,
               "T12 unknown remains unavailable in remaining mode")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
