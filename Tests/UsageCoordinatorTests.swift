import Foundation

@main
struct UsageCoordinatorTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    static func window(
        _ fraction: Double,
        resetAt: TimeInterval,
        observedAt: TimeInterval? = nil,
        source: UsageReadingSource? = nil
    ) -> WindowUsage {
        WindowUsage(
            usedPercent: fraction,
            resetAt: date(resetAt),
            error: nil,
            observedAt: observedAt.map(date),
            source: source
        )
    }

    static func main() {
        var coordinator = UsageCore.Coordinator()

        let empty = coordinator.projectAll(at: date(100))
        expect(!empty.claude.usage.hasKnownValue && empty.claude.status.source == .idle,
               "a new coordinator projects Claude as unavailable and idle")
        expect(empty.codex.usage.shortWindowLabel == nil
            && empty.codex.usage.weeklyWindowLabel == "week",
               "a new coordinator projects Codex as one weekly ring")

        let cachedClaude = AppUsage(
            fiveHour: window(0.20, resetAt: 400),
            weekly: window(0.30, resetAt: 800),
            plan: "max",
            scopedWeekly: window(0.40, resetAt: 800),
            scopedLabel: "Fable"
        )
        let hydrated = coordinator.hydrate(
            provider: .claude,
            usage: cachedClaude,
            status: .cached(at: date(90)),
            observedAt: date(90),
            now: date(100)
        )
        expect(hydrated.usage.weekly.percentInt == 30
            && hydrated.usage.scopedLabel == "Fable",
               "hydration imports legacy values and presentation metadata")
        expect(hydrated.status.source == .cached
            && hydrated.windows[.weekly]?.source == .restoredSnapshot
            && hydrated.windows[.weekly]?.confidence == .cached,
               "hydration records restored source, confidence, and cached health")

        let liveClaude = AppUsage(
            fiveHour: window(0.51, resetAt: 450),
            weekly: window(0.61, resetAt: 900),
            plan: "max",
            shortWindowLabel: "5h",
            weeklyWindowLabel: "week",
            scopedWeekly: window(0.71, resetAt: 900),
            scopedLabel: "Fable 5"
        )
        let live = coordinator.acceptSuccess(
            provider: .claude,
            usage: liveClaude,
            source: .claudeDesktopBridge,
            attemptedAt: date(110),
            observedAt: date(115)
        )
        expect(live.usage.fiveHour.percentInt == 51
            && live.usage.scopedLabel == "Fable 5",
               "success replaces readings and presentation atomically")
        expect(live.status.source == .live
            && live.windows[.weekly]?.source == .claudeDesktopBridge
            && live.windows[.weekly]?.confidence == .authoritative,
               "success retains exact provider source and confidence")

        let olderBridge = coordinator.acceptSuccess(
            provider: .claude,
            usage: AppUsage(
                fiveHour: window(0.01, resetAt: 450),
                weekly: window(0.02, resetAt: 900)
            ),
            source: .claudeDesktopBridge,
            attemptedAt: date(116),
            observedAt: date(114),
            completedAt: date(116)
        )
        expect(olderBridge.usage.weekly.percentInt == 61,
               "a newer poll cannot replace provider data with an older CCD observation")

        let failed = coordinator.acceptFailure(
            provider: .claude,
            failure: UsageFetchFailure(
                kind: .rateLimited,
                message: "quiet period",
                retryAfter: 60
            ),
            attemptedAt: date(120),
            projectAt: date(125)
        )
        expect(failed.usage.weekly.percentInt == 61,
               "typed provider failure preserves the last good readings")
        expect(failed.status.source == .cached
            && failed.status.failure?.kind == .rateLimited
            && failed.status.retryAt == date(180)
            && failed.status.failure?.retryAfter == 55,
               "typed failure maps once to stable health and retry timing")

        let staleSuccess = AppUsage(
            fiveHour: window(0.01, resetAt: 460),
            weekly: window(0.02, resetAt: 910),
            plan: "stale-plan",
            scopedLabel: "Stale Model"
        )
        let afterStale = coordinator.acceptSuccess(
            provider: .claude,
            usage: staleSuccess,
            source: .claudeSharedCredential,
            attemptedAt: date(119),
            observedAt: date(126)
        )
        expect(afterStale.usage.weekly.percentInt == 61
            && afterStale.usage.plan == "max"
            && afterStale.usage.scopedLabel == "Fable 5",
               "out-of-order success cannot replace readings or presentation")
        expect(afterStale.status.failure?.kind == .rateLimited,
               "out-of-order success cannot clear newer provider health")

        let local = coordinator.acceptClaudeLocalFiveHour(
            usedFraction: 1,
            resetAt: date(500),
            observedAt: date(130),
            projectAt: date(131)
        )
        expect(local.usage.fiveHour.percentInt == 100
            && local.usage.fiveHour.source == .localSessionLimit,
               "local Claude evidence updates only the five-hour reading")
        expect(local.usage.weekly.percentInt == 61
            && local.usage.weekly.observedAt == date(115)
            && local.usage.scopedWeekly?.percentInt == 71,
               "local Claude evidence preserves weekly and scoped observations")
        expect(local.status.source == .mixedLocalFallback
            && local.windows[.weekly]?.freshness == .stale
            && local.windows[.fiveHour]?.freshness == .localEvidence,
               "local evidence stays distinct from failed provider health")

        let oldLocal = coordinator.acceptClaudeLocalFiveHour(
            usedFraction: 0.25,
            resetAt: date(480),
            observedAt: date(129)
        )
        expect(oldLocal.usage.fiveHour.percentInt == 100,
               "older local evidence cannot replace a newer five-hour event")

        let codexUsage = AppUsage(
            fiveHour: .unknown,
            weekly: window(0.44, resetAt: 700),
            plan: "plus",
            shortWindowLabel: nil,
            weeklyWindowLabel: "week"
        )
        let codex = coordinator.acceptSuccess(
            provider: .codex,
            usage: codexUsage,
            source: .codexDesktopSharedAuth,
            confidence: .authoritative,
            attemptedAt: date(140),
            observedAt: date(145)
        )
        expect(codex.usage.shortWindowLabel == nil
            && codex.usage.weekly.percentInt == 44
            && codex.windows[.weekly]?.source == .codexDesktopSharedAuth,
               "Codex success keeps its weekly-only CD shape")
        expect(coordinator.project(provider: .claude, at: date(145)).usage.weekly.percentInt == 61,
               "provider mutations stay isolated")

        let authFailure = coordinator.acceptFailure(
            provider: .codex,
            failure: UsageFetchFailure(
                kind: .reauthenticationRequired,
                message: "sign in again"
            ),
            attemptedAt: date(150),
            projectAt: date(151)
        )
        expect(authFailure.status.failure?.kind == .reauthenticationRequired
            && authFailure.status.failure?.kind.requiresInteractiveReauthentication == true,
               "interactive reauthentication remains a typed failure")

        let reset = coordinator.resolveResets(at: date(701))
        expect(!reset.codex.usage.weekly.hasKnownValue
            && reset.codex.windows[.weekly]?.freshness == .unavailable,
               "reset resolution invalidates elapsed Codex data")
        expect(reset.claude.usage.fiveHour.hasKnownValue == false
            && reset.claude.usage.weekly.hasKnownValue,
               "reset resolution expires each Claude window independently")

        let unknownLocal = coordinator.acceptClaudeLocalFiveHour(
            .unknown,
            fallbackObservedAt: date(710),
            projectAt: date(710)
        )
        expect(!unknownLocal.usage.fiveHour.hasKnownValue,
               "unknown local evidence is a no-op rather than a false zero")

        let all = coordinator.projectAll(at: date(710))
        expect(all[.claude].usage.weekly.percentInt == all.claude.usage.weekly.percentInt
            && all[.codex].status == all.codex.status,
               "two-provider projection supports named and keyed access")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all usage coordinator tests passed")
    }
}
