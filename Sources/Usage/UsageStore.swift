import Foundation
import Combine
import Network

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private static let claudeCooldownKey = "CodexIsland.claudeCooldownUntil"

    private init() {
        let now = Date()
        let snapshot = UsageSnapshotStore.load(now: now)
        if let record = snapshot.claude {
            claude = record.usage
            claudeStatus = .cached(at: record.at)
        } else if let cachedClaude = UsageHistoryStore.shared.latestUsage(provider: .claude, now: now) {
            claude = cachedClaude
            claudeStatus = .cached(at: nil)
        }
        if let record = snapshot.codex {
            codex = record.usage
            codexStatus = .cached(at: record.at)
        } else if let cachedCodex = UsageHistoryStore.shared.latestUsage(provider: .codex, now: now) {
            codex = cachedCodex
            codexStatus = .cached(at: nil)
        }

        if let stored = UserDefaults.standard.object(forKey: Self.claudeCooldownKey) as? Date,
           stored > now {
            claudeCooldownUntil = stored
            claudeStatus.failure = UsageFetchFailure(
                kind: .rateLimited,
                message: ClaudeCredentials.rateLimitedMessage
            )
            claudeStatus.retryAt = stored
        } else {
            claudeCooldownUntil = nil
            UserDefaults.standard.removeObject(forKey: Self.claudeCooldownKey)
        }
    }

    @Published var claude: AppUsage = .empty
    @Published var codex: AppUsage = .empty
    @Published var claudeStatus: UsageProviderStatus = .idle
    @Published var codexStatus: UsageProviderStatus = .idle
    @Published var codexResetCredits: CodexResetCredits = .empty
    /// Most recent completed poll, successful or not. Provider-specific
    /// `lastSuccessAt` values remain the source of truth for freshness.
    @Published var lastRefreshAt: Date?
    @Published var lastUpdated: Date?
    @Published var loading = false
    /// Set while a `claude auth login` flow is in progress (spawned + still
    /// polling for the keychain to update). The UI hides the re-auth button
    /// during this window so users don't double-tap and spawn duplicate CLI
    /// processes; the click ends up no-ops anyway because the spawn check
    /// gates on this.
    @Published var claudeReauthInProgress = false

    private var refreshTask: Task<Void, Never>?
    private var reauthPollTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var intervalCancellable: AnyCancellable?
    private var netMonitor: NWPathMonitor?
    private let netQueue = DispatchQueue(label: "UsageStore.network")
    private var lastNetStatus: NWPath.Status?

    /// Anthropic's /api/oauth/usage is aggressively rate-limited per token.
    /// `RefreshIntervalStore` enforces a 5-minute floor (300/900/1800).
    private var pollInterval: TimeInterval {
        TimeInterval(RefreshIntervalStore.shared.seconds)
    }

    /// The /api/oauth/usage limiter is sticky once tripped: it returns 429
    /// with `retry-after: 0` until the account has gone quiet for a while
    /// (anthropics/claude-code#30930), so polling through it never recovers.
    /// Use one hour when Anthropic omits Retry-After or sends its observed
    /// sticky-limiter sentinel (`0`). Retrying sooner restarts the quiet
    /// period and can keep an account throttled indefinitely.
    private static let fallbackRateLimitCooldown: TimeInterval = 3600
    private var claudeCooldownUntil: Date? {
        didSet {
            if let claudeCooldownUntil {
                UserDefaults.standard.set(claudeCooldownUntil, forKey: Self.claudeCooldownKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.claudeCooldownKey)
            }
        }
    }

    func status(for provider: AlertEngine.Provider) -> UsageProviderStatus {
        switch provider {
        case .claude: return claudeStatus
        case .codex: return codexStatus
        }
    }

    func refresh() {
        if loading { return }
        // Demo mode for screen recordings: skip the network entirely and
        // inject hand-tuned values that read as "real, healthy heavy-user
        // data". Reset times are recomputed each refresh so the countdowns
        // tick down naturally on camera. Off by default — only fires when
        // CODEXISLAND_DEMO=1 is set in the launching env.
        if AppEnvironment.isDemo {
            let now = Date()
            self.claude = AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: 0.73,
                    resetAt: now.addingTimeInterval(1 * 3600 + 47 * 60),
                    error: nil
                ),
                weekly: WindowUsage(
                    usedPercent: 0.81,
                    resetAt: now.addingTimeInterval(4 * 86400 + 11 * 3600),
                    error: nil
                ),
                plan: "max"
            ).observed(at: now, source: .api)
            self.codex = AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: 0.67,
                    resetAt: now.addingTimeInterval(2 * 3600 + 23 * 60),
                    error: nil
                ),
                weekly: WindowUsage(
                    usedPercent: 0.76,
                    resetAt: now.addingTimeInterval(4 * 86400 + 18 * 3600),
                    error: nil
                ),
                plan: "pro"
            ).observed(at: now, source: .api)
            self.codexResetCredits = CodexResetCredits(
                availableCount: 2,
                credits: [
                    CodexResetCredit(
                        id: "demo-reset-1",
                        status: "available",
                        expiresAt: now.addingTimeInterval(3 * 86400 + 4 * 3600),
                        title: "One free rate limit reset",
                        description: "Thanks for using Codex! You've been granted one free rate limit reset."
                    ),
                    CodexResetCredit(
                        id: "demo-reset-2",
                        status: "available",
                        expiresAt: now.addingTimeInterval(9 * 86400 + 3600),
                        title: "One free rate limit reset",
                        description: "Thanks for using Codex! You've been granted one free rate limit reset."
                    )
                ]
            )
            self.claudeStatus = UsageProviderStatus(
                source: .live,
                lastAttemptAt: now,
                lastSuccessAt: now,
                failure: nil,
                retryAt: nil
            )
            self.codexStatus = UsageProviderStatus(
                source: .live,
                lastAttemptAt: now,
                lastSuccessAt: now,
                failure: nil,
                retryAt: nil
            )
            self.lastUpdated = now
            self.lastRefreshAt = now
            return
        }

        loading = true
        refreshTask?.cancel()
        refreshTask = Task {
            let attemptAt = Date()
            async let codexResult = UsageFetcher.fetchCodex()
            async let codexResetCreditsResult = UsageFetcher.fetchCodexResetCredits()
            var coolingDown = claudeCooldownUntil.map { attemptAt < $0 } ?? false
            if coolingDown, ClaudeCredentials.credentialIsLocallyExpired(now: attemptAt) {
                // This check deliberately happens after `UsageStore.shared`
                // has completed initialization. `/usr/bin/security` waits by
                // pumping the main run loop; doing that inside a static
                // singleton initializer lets SwiftUI recursively request the
                // same dispatch_once token and crashes at launch.
                self.claudeCooldownUntil = nil
                coolingDown = false
            }
            var claudeResult: UsageFetchResult?
            if !coolingDown {
                claudeResult = await UsageFetcher.fetchClaude()
            }
            let fetchedCodex = await codexResult
            let codexResetCredits = await codexResetCreditsResult

            // Cancellation = network monitor saw the path come up while we
            // were mid-flight on a dead one. The fetched values are the
            // dead-path errors — drop them so the supersedes refresh
            // doesn't have a brief "cancelled" caption flash to overwrite.
            if Task.isCancelled {
                self.loading = false
                return
            }

            let now = Date()
            // Reset-cycle validity is part of every reconciliation, including
            // failure/cooldown polls. Old percentages can never survive their
            // reset boundary merely because the app stayed running.
            self.claude = UsageSnapshotStore.sanitizedUsage(self.claude, now: now)
            self.codex = UsageSnapshotStore.sanitizedUsage(self.codex, now: now)

            var anyProviderSucceeded = false

            if UsageStore.isErrorOnly(fetchedCodex) {
                let message = fetchedCodex.fiveHour.error
                    ?? fetchedCodex.weekly.error
                    ?? "unavailable"
                self.codexStatus = UsageProviderStatus(
                    source: self.codex.hasKnownValue ? .cached : .idle,
                    lastAttemptAt: attemptAt,
                    lastSuccessAt: self.codexStatus.lastSuccessAt,
                    failure: UsageFetchFailure(
                        kind: message.contains("auth") ? .authenticationExpired : .other,
                        message: message
                    ),
                    retryAt: nil
                )
            } else {
                let fresh = UsageSnapshotStore.sanitizedUsage(
                    fetchedCodex.observed(at: now, source: .api),
                    now: now
                )
                self.codex = fresh
                self.codexStatus = UsageProviderStatus(
                    source: .live,
                    lastAttemptAt: attemptAt,
                    lastSuccessAt: now,
                    failure: nil,
                    retryAt: nil
                )
                UsageHistoryStore.shared.record(provider: .codex, usage: fresh, at: now)
                UsageSnapshotStore.recordCodex(fresh, at: now)
                anyProviderSucceeded = true
            }

            if let claudeResult {
                switch claudeResult {
                case .success(let fetched):
                    self.claudeCooldownUntil = nil
                    let fresh = UsageSnapshotStore.sanitizedUsage(
                        fetched.observed(at: now, source: .api),
                        now: now
                    )
                    self.claude = fresh
                    self.claudeStatus = UsageProviderStatus(
                        source: .live,
                        lastAttemptAt: attemptAt,
                        lastSuccessAt: now,
                        failure: nil,
                        retryAt: nil
                    )
                    UsageHistoryStore.shared.record(provider: .claude, usage: fresh, at: now)
                    UsageSnapshotStore.recordClaude(fresh, at: now)
                    anyProviderSucceeded = true

                case .failure(let failure):
                    var retryAt: Date?
                    if failure.kind == .rateLimited {
                        let requested = failure.retryAfter ?? UsageStore.fallbackRateLimitCooldown
                        let cooldown = max(UsageStore.fallbackRateLimitCooldown, requested + 5)
                        retryAt = now.addingTimeInterval(cooldown)
                        self.claudeCooldownUntil = retryAt
                        NSLog(
                            "CodexIsland: Claude usage rate-limited; skipping Claude fetches for %.0fs",
                            cooldown
                        )
                    } else {
                        self.claudeCooldownUntil = nil
                    }
                    let localSessionLimit = await Task.detached(priority: .utility) {
                        ClaudeSessionLimitFallback.latestActive(now: now)
                    }.value
                    let usedLocalFallback = self.apply(localSessionLimit)
                    self.claudeStatus = UsageProviderStatus(
                        source: usedLocalFallback
                            ? .mixedLocalFallback
                            : (self.claude.hasKnownValue ? .cached : .idle),
                        lastAttemptAt: attemptAt,
                        lastSuccessAt: self.claudeStatus.lastSuccessAt,
                        failure: failure,
                        retryAt: retryAt
                    )
                }
            } else {
                let failure = UsageFetchFailure(
                    kind: .rateLimited,
                    message: ClaudeCredentials.rateLimitedMessage
                )
                let localSessionLimit = await Task.detached(priority: .utility) {
                    ClaudeSessionLimitFallback.latestActive(now: now)
                }.value
                let usedLocalFallback = self.apply(localSessionLimit)
                self.claudeStatus = UsageProviderStatus(
                    source: usedLocalFallback
                        ? .mixedLocalFallback
                        : (self.claude.hasKnownValue ? .cached : .idle),
                    lastAttemptAt: attemptAt,
                    lastSuccessAt: self.claudeStatus.lastSuccessAt,
                    failure: failure,
                    retryAt: self.claudeCooldownUntil
                )
            }

            if let codexResetCredits {
                self.codexResetCredits = codexResetCredits
            }
            if anyProviderSucceeded { self.lastUpdated = now }
            self.lastRefreshAt = now
            self.loading = false
        }
    }

    /// Fetchers use `.unknown` for missing windows; a valid scoped/Fable-only
    /// response still counts as success.
    private static func isErrorOnly(_ u: AppUsage) -> Bool {
        !u.hasKnownValue
    }

    /// Apply only the locally proven 5h limit. Never re-timestamp or persist
    /// cached weekly/Fable data as part of this one-window fallback.
    @discardableResult
    private func apply(_ event: ClaudeSessionLimitFallback.Event?) -> Bool {
        guard let event else { return false }
        claude.fiveHour = WindowUsage(
            usedPercent: 1,
            resetAt: event.resetAt,
            error: nil,
            observedAt: event.occurredAt,
            source: .localSessionLimit
        )
        claude.shortWindowLabel = "5h"
        UsageHistoryStore.shared.record(
            provider: .claude,
            window: .fiveHour,
            reading: claude.fiveHour,
            at: event.occurredAt
        )
        return true
    }

    /// Replace current usage values with hand-tuned percentages so the
    /// alert engine's pulse + tint behavior can be exercised without
    /// waiting for a real provider crossing. Auto-refresh continues — the
    /// next scheduled poll will overwrite these values with real data.
    /// Each call uses fresh `resetAt` timestamps so the alert engine
    /// treats it as a new reset window and re-evaluates crossings.
    func injectPreviewUsage(claudeFiveHour: Double, codexFiveHour: Double) {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 86400 + 6 * 3600)
        self.claude = AppUsage(
            fiveHour: WindowUsage(
                usedPercent: claudeFiveHour,
                resetAt: fiveHourReset,
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.45,
                resetAt: weeklyReset,
                error: nil
            ),
            plan: claude.plan ?? "max"
        ).observed(at: now, source: .api)
        self.codex = AppUsage(
            fiveHour: WindowUsage(
                usedPercent: codexFiveHour,
                resetAt: fiveHourReset,
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.30,
                resetAt: weeklyReset,
                error: nil
            ),
            plan: codex.plan ?? "pro"
        ).observed(at: now, source: .api)
        self.claudeStatus = UsageProviderStatus(
            source: .live,
            lastAttemptAt: now,
            lastSuccessAt: now,
            failure: nil,
            retryAt: nil
        )
        self.codexStatus = UsageProviderStatus(
            source: .live,
            lastAttemptAt: now,
            lastSuccessAt: now,
            failure: nil,
            retryAt: nil
        )
        self.lastUpdated = now
        self.lastRefreshAt = now
    }

    /// Spawn `claude auth login` and poll for the keychain to update.
    ///
    /// We can't `await` the OAuth flow directly — it happens in a separate
    /// process that owns a browser tab and a localhost listener — so we kick
    /// off retries every few seconds and stop as soon as one returns success
    /// (or after a generous deadline so the button doesn't stay disabled
    /// forever if the user closes the browser without completing).
    func reauthenticateClaude() {
        guard !claudeReauthInProgress else { return }
        guard ClaudeCredentials.spawnReauth() else { return }
        claudeReauthInProgress = true
        reauthPollTask?.cancel()
        reauthPollTask = Task { [weak self] in
            // ~2 minutes total — generous enough that even a slow OAuth
            // round-trip (browser cold start, SSO redirect, 2FA prompt)
            // resolves in time, short enough to not strand the UI.
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                // The whole point of this loop is to catch the keychain item
                // `claude auth login` just rewrote — never serve the cache.
                ClaudeCredentials.clearCache()
                let result = await UsageFetcher.fetchClaude()
                if Task.isCancelled { return }
                if case .success(let fetched) = result {
                    await MainActor.run {
                        let now = Date()
                        let fresh = UsageSnapshotStore.sanitizedUsage(
                            fetched.observed(at: now, source: .api),
                            now: now
                        )
                        self?.claude = fresh
                        self?.claudeStatus = UsageProviderStatus(
                            source: .live,
                            lastAttemptAt: now,
                            lastSuccessAt: now,
                            failure: nil,
                            retryAt: nil
                        )
                        self?.claudeCooldownUntil = nil
                        UsageHistoryStore.shared.record(provider: .claude, usage: fresh, at: now)
                        UsageSnapshotStore.recordClaude(fresh, at: now)
                        self?.lastUpdated = now
                        self?.lastRefreshAt = now
                        self?.claudeReauthInProgress = false
                    }
                    return
                }
            }
            await MainActor.run { self?.claudeReauthInProgress = false }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refresh()
        armTimer()
        // Re-arm whenever the user changes the refresh interval. We
        // dropFirst() the initial @Published replay so we don't re-fire
        // refresh() on subscription.
        intervalCancellable = RefreshIntervalStore.shared.$seconds
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.armTimer() }
            }
        startNetworkMonitor()
    }

    func stopAutoRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        intervalCancellable?.cancel()
        intervalCancellable = nil
        netMonitor?.cancel()
        netMonitor = nil
        lastNetStatus = nil
    }

    private func armTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Trigger an immediate refresh whenever the network transitions from
    /// unsatisfied to satisfied — closes the launch-at-login race where
    /// Wi-Fi is still associating when our first refresh fires. Without
    /// this, the panel sits at the empty cold-start state until the next
    /// scheduled poll (5–30 minutes away). The initial path callback fires
    /// with the current state and is deliberately ignored (lastNetStatus
    /// starts nil) — startAutoRefresh's own refresh() already covers
    /// cold-start, and acting on the initial callback would double-fire.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.lastNetStatus
                self.lastNetStatus = path.status
                guard path.status == .satisfied,
                      let prior = was, prior != .satisfied else { return }
                // Cancel any in-flight refresh — its URLSession call was
                // started on the dead path and is going to return an
                // error. Wait for it to finalize so its loading=false
                // lands before we start the replacement, otherwise our
                // refresh() hits the `if loading { return }` guard.
                self.refreshTask?.cancel()
                await self.refreshTask?.value
                self.refresh()
            }
        }
        monitor.start(queue: netQueue)
        netMonitor = monitor
    }
}
