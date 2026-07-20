import Foundation
import Combine
import Network

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private static let claudeCooldownKey = "CodexIsland.claudeCooldownUntil"
    private var coordinator = UsageCore.Coordinator()
    private let stateRepository = try? UsageCore.StateRepository.live()

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

        // Prefer normalized, versioned state. Presentation labels still come
        // from the legacy snapshot during the migration window because the
        // secure repository deliberately stores quota facts only.
        if let restored = try? stateRepository?.load(at: now) {
            coordinator = UsageCore.Coordinator(
                state: restored,
                presentations: [
                    .claude: presentationMetadata(from: claude),
                    .codex: presentationMetadata(from: codex),
                ]
            )
            if let retryAt = claudeCooldownUntil, retryAt > now {
                _ = coordinator.acceptFailure(
                    provider: .claude,
                    failure: UsageFetchFailure(
                        kind: .rateLimited,
                        message: ClaudeCredentials.rateLimitedMessage
                    ),
                    attemptedAt: now,
                    retryAt: retryAt,
                    projectAt: now
                )
            }
            let projections = coordinator.projectAll(at: now)
            setProjection(projections.claude, provider: .claude)
            setProjection(projections.codex, provider: .codex)
        } else {
            // One-time v1 migration. From here provider events flow through
            // UsageCore, while AppUsage remains a compatibility projection
            // for views, alerts, history, and the fork broadcaster.
            if claude.hasKnownValue {
                let projection = coordinator.hydrate(
                    provider: .claude,
                    usage: claude,
                    status: claudeStatus,
                    observedAt: claudeStatus.lastSuccessAt ?? now,
                    now: now
                )
                setProjection(projection, provider: .claude)
            }
            if codex.hasKnownValue {
                let projection = coordinator.hydrate(
                    provider: .codex,
                    usage: codex,
                    status: codexStatus,
                    observedAt: codexStatus.lastSuccessAt ?? now,
                    now: now
                )
                setProjection(projection, provider: .codex)
            }
        }
        persistCoreState(at: now)
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
    private var claudeBridgeExpiryTask: Task<Void, Never>?
    private var usageExpiryTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var intervalCancellable: AnyCancellable?
    private var netMonitor: NWPathMonitor?
    private let netQueue = DispatchQueue(label: "UsageStore.network")
    private var lastNetStatus: NWPath.Status?
    /// One long-lived adapter keeps usage + reset-credit requests on the same
    /// immutable CD credential generation and retains the last known reset
    /// credits separately when only that secondary endpoint fails.
    private let codexProvider = CodexDesktopProvider()

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
            let demoClaude = AppUsage(
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
            )
            let demoCodex = AppUsage(
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
            )
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
            let claudeProjection = coordinator.acceptSuccess(
                provider: .claude,
                usage: demoClaude,
                source: .claudeSharedCredential,
                attemptedAt: now,
                observedAt: now
            )
            let codexProjection = coordinator.acceptSuccess(
                provider: .codex,
                usage: demoCodex,
                source: .codexDesktopSharedAuth,
                attemptedAt: now,
                observedAt: now
            )
            setProjection(claudeProjection, provider: .claude)
            setProjection(codexProjection, provider: .codex)
            self.lastUpdated = now
            self.lastRefreshAt = now
            armUsageExpiry(now: now)
            return
        }

        loading = true
        refreshTask?.cancel()
        refreshTask = Task {
            let attemptAt = Date()
            async let codexPoll = codexProvider.poll()
            let claudeDesktopBridgeTask = Task.detached(priority: .utility) {
                ClaudeDesktopUsageBridge.read(now: attemptAt)
            }
            var coolingDown = claudeCooldownUntil.map { attemptAt < $0 } ?? false

            // CCD owns its short-lived credential privately. A supported CCD
            // hook exports only the sanitized quota snapshot; when that is
            // fresh it is the authoritative path and we do not duplicate the
            // same usage request with the standalone shared credential.
            let claudeDesktopCandidate = await claudeDesktopBridgeTask.value
            let latestProviderObservation = coordinator.state[.claude].readings.values
                .filter { $0.source != .localSessionLimit }
                .map(\.observedAt)
                .max()
            var claudeDesktopReading = claudeDesktopCandidate
            if let reading = claudeDesktopReading,
               let latestProviderObservation,
               reading.observedAt < latestProviderObservation {
                claudeDesktopReading = nil
            }
            if claudeDesktopReading == nil, coolingDown,
               ClaudeCredentials.credentialIsLocallyExpired(now: attemptAt) {
                // This check deliberately happens after `UsageStore.shared`
                // has completed initialization. `/usr/bin/security` waits by
                // pumping the main run loop; doing that inside a static
                // singleton initializer lets SwiftUI recursively request the
                // same dispatch_once token and crashes at launch. A fresh CCD
                // bridge also bypasses this read entirely, avoiding needless
                // Keychain authorization prompts.
                self.claudeCooldownUntil = nil
                coolingDown = false
            }
            var claudeResult: UsageFetchResult?
            if claudeDesktopReading == nil, !coolingDown {
                claudeResult = await UsageFetcher.fetchClaude()
            }
            let fetchedCodex = await codexPoll

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
            let resolved = self.coordinator.resolveResets(at: now)
            self.setProjection(resolved.claude, provider: .claude)
            self.setProjection(resolved.codex, provider: .codex)

            var anyProviderSucceeded = false

            switch fetchedCodex.usage {
            case .failure(let providerFailure):
                let failure = UsageStore.failure(from: providerFailure)
                let projection = self.coordinator.acceptFailure(
                    provider: .codex,
                    failure: failure,
                    attemptedAt: fetchedCodex.attemptedAt,
                    projectAt: now
                )
                self.setProjection(projection, provider: .codex)

            case .success(let observation):
                let projection = self.coordinator.acceptSuccess(
                    provider: .codex,
                    usage: observation.value.usage,
                    source: .codexDesktopSharedAuth,
                    attemptedAt: fetchedCodex.attemptedAt,
                    observedAt: observation.observedAt,
                    completedAt: observation.observedAt,
                    projectAt: now
                )
                self.setProjection(projection, provider: .codex)
                let fresh = projection.usage
                UsageHistoryStore.shared.record(
                    provider: .codex,
                    usage: fresh,
                    at: observation.observedAt
                )
                UsageSnapshotStore.recordCodex(fresh, at: observation.observedAt)
                anyProviderSucceeded = true
            }

            if let claudeDesktopReading {
                let projection = self.coordinator.acceptSuccess(
                    provider: .claude,
                    usage: claudeDesktopReading.usage,
                    source: .claudeDesktopBridge,
                    attemptedAt: attemptAt,
                    observedAt: claudeDesktopReading.observedAt,
                    completedAt: claudeDesktopReading.observedAt,
                    projectAt: now
                )
                self.setProjection(projection, provider: .claude)
                let fresh = projection.usage
                UsageHistoryStore.shared.record(
                    provider: .claude,
                    usage: fresh,
                    at: claudeDesktopReading.observedAt
                )
                UsageSnapshotStore.recordClaude(fresh, at: claudeDesktopReading.observedAt)
                self.armClaudeBridgeExpiry(observedAt: claudeDesktopReading.observedAt)
                anyProviderSucceeded = true
            } else if let claudeResult {
                self.claudeBridgeExpiryTask?.cancel()
                self.claudeBridgeExpiryTask = nil
                switch claudeResult {
                case .success(let fetched):
                    self.claudeCooldownUntil = nil
                    let projection = self.coordinator.acceptSuccess(
                        provider: .claude,
                        usage: fetched,
                        source: .claudeSharedCredential,
                        attemptedAt: attemptAt,
                        observedAt: now,
                        completedAt: now,
                        projectAt: now
                    )
                    self.setProjection(projection, provider: .claude)
                    let fresh = projection.usage
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
                    let failed = self.coordinator.acceptFailure(
                        provider: .claude,
                        failure: failure,
                        attemptedAt: attemptAt,
                        retryAt: retryAt,
                        projectAt: now
                    )
                    self.setProjection(failed, provider: .claude)
                    let localSessionLimit = await Task.detached(priority: .utility) {
                        ClaudeSessionLimitFallback.latestActive(now: now)
                    }.value
                    _ = self.apply(localSessionLimit, now: now)
                }
            } else {
                let failure = UsageFetchFailure(
                    kind: .rateLimited,
                    message: ClaudeCredentials.rateLimitedMessage
                )
                let failed = self.coordinator.acceptFailure(
                    provider: .claude,
                    failure: failure,
                    attemptedAt: attemptAt,
                    retryAt: self.claudeCooldownUntil,
                    projectAt: now
                )
                self.setProjection(failed, provider: .claude)
                let localSessionLimit = await Task.detached(priority: .utility) {
                    ClaudeSessionLimitFallback.latestActive(now: now)
                }.value
                _ = self.apply(localSessionLimit, now: now)
            }

            switch fetchedCodex.resetCredits {
            case .fresh(let observation):
                self.codexResetCredits = observation.value
            case .stale(let observation, _, _):
                self.codexResetCredits = observation.value
            case .unavailable:
                break
            }
            self.persistCoreState(at: now)
            if anyProviderSucceeded { self.lastUpdated = now }
            self.lastRefreshAt = now
            self.loading = false
        }
    }

    private static func failure(from failure: CodexProviderFailure) -> UsageFetchFailure {
        switch failure {
        case .credentialUnavailable, .credentialMalformed, .authenticationExpired:
            return UsageFetchFailure(
                kind: .authenticationExpired,
                message: "waiting for Codex Desktop"
            )
        case .transport, .cancelled:
            return UsageFetchFailure(
                kind: .transport,
                message: "Codex usage network unavailable"
            )
        case .http(_, let statusCode) where statusCode == 429:
            return UsageFetchFailure(
                kind: .rateLimited,
                message: "Codex usage rate limited"
            )
        case .http(_, let statusCode):
            return UsageFetchFailure(
                kind: .other,
                message: "Codex service returned HTTP \(statusCode)"
            )
        case .schema:
            return UsageFetchFailure(
                kind: .other,
                message: "Codex usage response changed"
            )
        }
    }

    /// Apply only the locally proven 5h limit. Never re-timestamp or persist
    /// cached weekly/Fable data as part of this one-window fallback.
    @discardableResult
    private func apply(
        _ event: ClaudeSessionLimitFallback.Event?,
        now: Date = Date()
    ) -> Bool {
        guard let event else { return false }
        let localWindow = WindowUsage(
            usedPercent: 1,
            resetAt: event.resetAt,
            error: nil,
            observedAt: event.occurredAt,
            source: .localSessionLimit
        )
        let projection = coordinator.acceptClaudeLocalFiveHour(
            localWindow,
            fallbackObservedAt: event.occurredAt,
            projectAt: now
        )
        setProjection(projection, provider: .claude)
        UsageHistoryStore.shared.record(
            provider: .claude,
            window: .fiveHour,
            reading: projection.usage.fiveHour,
            at: event.occurredAt
        )
        armUsageExpiry(now: now)
        return true
    }

    private func setProjection(
        _ projection: UsageCore.AppProjection,
        provider: UsageCore.ProviderID
    ) {
        switch provider {
        case .claude:
            claude = projection.usage
            claudeStatus = projection.status
        case .codex:
            codex = projection.usage
            codexStatus = projection.status
        }
    }

    private func presentationMetadata(from usage: AppUsage) -> UsageCore.PresentationMetadata {
        UsageCore.PresentationMetadata(
            plan: usage.plan,
            shortWindowLabel: usage.shortWindowLabel,
            weeklyWindowLabel: usage.weeklyWindowLabel,
            scopedLabel: usage.scopedLabel
        )
    }

    private func persistCoreState(at date: Date) {
        armUsageExpiry(now: date)
        guard let stateRepository else { return }
        do {
            try stateRepository.save(coordinator.state, at: date)
        } catch {
            // Repository failures are health-neutral: keep live in-memory
            // readings and the legacy snapshot rather than turning a local
            // persistence problem into a provider outage.
            NSLog("CodexIsland: usage state persistence unavailable: %@", String(describing: error))
        }
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
        let previewClaude = AppUsage(
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
        )
        let previewCodex = AppUsage(
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
        )
        let claudeProjection = coordinator.acceptSuccess(
            provider: .claude,
            usage: previewClaude,
            source: .claudeSharedCredential,
            attemptedAt: now,
            observedAt: now
        )
        let codexProjection = coordinator.acceptSuccess(
            provider: .codex,
            usage: previewCodex,
            source: .codexDesktopSharedAuth,
            attemptedAt: now,
            observedAt: now
        )
        setProjection(claudeProjection, provider: .claude)
        setProjection(codexProjection, provider: .codex)
        self.lastUpdated = now
        self.lastRefreshAt = now
        armUsageExpiry(now: now)
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
                        guard let self else { return }
                        let now = Date()
                        let projection = self.coordinator.acceptSuccess(
                            provider: .claude,
                            usage: fetched,
                            source: .claudeSharedCredential,
                            attemptedAt: now,
                            observedAt: now,
                            completedAt: now,
                            projectAt: now
                        )
                        self.setProjection(projection, provider: .claude)
                        let fresh = projection.usage
                        self.claudeCooldownUntil = nil
                        UsageHistoryStore.shared.record(provider: .claude, usage: fresh, at: now)
                        UsageSnapshotStore.recordClaude(fresh, at: now)
                        self.persistCoreState(at: now)
                        self.lastUpdated = now
                        self.lastRefreshAt = now
                        self.claudeReauthInProgress = false
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
        claudeBridgeExpiryTask?.cancel()
        claudeBridgeExpiryTask = nil
        usageExpiryTask?.cancel()
        usageExpiryTask = nil
        lastNetStatus = nil
    }

    /// Expire the earliest reset (or conservative no-reset TTL) at its actual
    /// boundary instead of waiting for the next 5–30 minute provider poll.
    /// This keeps the core state, expanded charts, compact rings, alerts, and
    /// broadcaster on the same cycle transition.
    private func armUsageExpiry(now: Date = Date()) {
        usageExpiryTask?.cancel()
        usageExpiryTask = nil

        let deadlines = UsageCore.ProviderID.allCases.flatMap { providerID in
            coordinator.state[providerID].readings.compactMap { windowID, reading -> Date? in
                guard reading.isKnown else { return nil }
                return reading.resetAt
                    ?? reading.observedAt.addingTimeInterval(windowID.maximumAgeWithoutReset)
            }
        }
        guard let nextDeadline = deadlines.min() else { return }
        let delay = max(0.25, nextDeadline.timeIntervalSince(now) + 0.05)

        usageExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let resolvedAt = Date()
            let projections = self.coordinator.resolveResets(at: resolvedAt)
            self.setProjection(projections.claude, provider: .claude)
            self.setProjection(projections.codex, provider: .codex)
            self.persistCoreState(at: resolvedAt)
        }
    }

    private func armClaudeBridgeExpiry(observedAt: Date) {
        claudeBridgeExpiryTask?.cancel()
        let remaining = max(
            1,
            ClaudeDesktopUsageBridge.maximumSnapshotAge
                - Date().timeIntervalSince(observedAt)
                + 1
        )
        claudeBridgeExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh() }
        }
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
