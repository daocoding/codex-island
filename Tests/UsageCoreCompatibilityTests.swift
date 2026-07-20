import Foundation

@main
struct UsageCoreCompatibilityTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func reading(
        _ fraction: Double?,
        resetAt: TimeInterval,
        observedAt: TimeInterval,
        source: UsageCore.ReadingSource,
        confidence: UsageCore.Confidence = .authoritative
    ) -> UsageCore.Reading {
        UsageCore.Reading(
            usedFraction: fraction,
            resetAt: Date(timeIntervalSince1970: resetAt),
            observedAt: Date(timeIntervalSince1970: observedAt),
            source: source,
            confidence: confidence
        )
    }

    static func state(
        provider: UsageCore.ProviderID,
        readings: [UsageCore.WindowID: UsageCore.Reading],
        attemptedAt: TimeInterval = 105,
        completedAt: TimeInterval = 110
    ) -> UsageCore.ProviderState {
        UsageCore.Reducer.reduce(.init(), .apiSucceeded(
            provider: provider,
            readings: readings,
            attemptedAt: Date(timeIntervalSince1970: attemptedAt),
            completedAt: Date(timeIntervalSince1970: completedAt)
        ))[provider]
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 150)
        let claude = state(provider: .claude, readings: [
            .fiveHour: reading(0.125, resetAt: 300, observedAt: 100, source: .claudeDesktopBridge),
            .weekly: reading(0.41, resetAt: 700, observedAt: 100, source: .claudeDesktopBridge),
            .scopedWeekly: reading(0.72, resetAt: 700, observedAt: 100, source: .claudeDesktopBridge),
        ])
        let claudeProjection = UsageCore.Compatibility.project(
            provider: .claude,
            state: claude,
            presentation: .init(plan: "max", scopedLabel: "Fable"),
            at: now
        )
        expect(claudeProjection.usage.fiveHour.usedPercent == 0.125,
               "Claude five-hour value projects without rounding loss")
        expect(claudeProjection.usage.weekly.percentInt == 41,
               "Claude weekly value maps to the legacy weekly slot")
        expect(claudeProjection.usage.scopedWeekly?.percentInt == 72
            && claudeProjection.usage.scopedLabel == "Fable",
               "Claude scoped weekly value maps to the Fable slot")
        expect(claudeProjection.usage.plan == "max"
            && claudeProjection.usage.shortWindowLabel == "5h"
            && claudeProjection.usage.weeklyWindowLabel == "week",
               "Claude presentation metadata keeps the current labels")
        expect(claudeProjection.windows[.weekly]?.source == .claudeDesktopBridge
            && claudeProjection.windows[.weekly]?.confidence == .authoritative
            && claudeProjection.windows[.weekly]?.freshness == .live,
               "exact CCD source, confidence, and freshness survive projection")
        expect(claudeProjection.usage.weekly.source == .claudeDesktopBridge
            && claudeProjection.status.source == .live,
               "CCD data keeps its exact compatible source vocabulary")

        let weeklyOnly = AppUsage(
            fiveHour: .unknown,
            weekly: WindowUsage(usedPercent: 0.47, resetAt: Date(timeIntervalSince1970: 800), error: nil),
            plan: "plus",
            shortWindowLabel: nil,
            weeklyWindowLabel: "week"
        )
        let codexSnapshot = UsageCore.Compatibility.snapshot(
            provider: .codex,
            usage: weeklyOnly,
            observedAt: Date(timeIntervalSince1970: 120),
            source: .codexDesktopSharedAuth,
            confidence: .authoritative
        )
        expect(codexSnapshot.readings[.fiveHour] == nil,
               "Codex weekly-only import does not fabricate a five-hour slot")
        expect(codexSnapshot.readings[.weekly]?.usedPercent == 47,
               "Codex weekly-only import preserves its real zero-to-one value")
        let codexProjection = UsageCore.Compatibility.project(
            provider: .codex,
            state: state(provider: .codex, readings: codexSnapshot.readings),
            presentation: codexSnapshot.presentation,
            at: now
        )
        expect(codexProjection.usage.shortWindowLabel == nil
            && codexProjection.usage.weeklyWindowLabel == "week",
               "Codex weekly-only projection retains its one-ring shape")
        expect(codexProjection.usage.headlineWindow.percentInt == 47,
               "Codex weekly-only projection keeps weekly as the headline")

        let unknownAndZero = AppUsage(
            fiveHour: .unknown,
            weekly: WindowUsage(
                usedPercent: 0,
                resetAt: Date(timeIntervalSince1970: 700),
                error: nil
            )
        )
        let distinctSnapshot = UsageCore.Compatibility.snapshot(
            provider: .claude,
            usage: unknownAndZero,
            observedAt: Date(timeIntervalSince1970: 100),
            source: .claudeSharedCredential,
            confidence: .authoritative
        )
        expect(distinctSnapshot.readings[.fiveHour]?.usedFraction == nil,
               "legacy unknown imports as nil")
        expect(distinctSnapshot.readings[.weekly]?.isKnown == true
            && distinctSnapshot.readings[.weekly]?.usedFraction == 0,
               "legacy confirmed zero remains a known zero")
        let distinctProjection = UsageCore.Compatibility.project(
            provider: .claude,
            state: state(provider: .claude, readings: distinctSnapshot.readings),
            at: now
        )
        expect(!distinctProjection.usage.fiveHour.hasKnownValue,
               "core nil projects back to legacy unknown")
        expect(distinctProjection.usage.weekly.hasKnownValue
            && distinctProjection.usage.weekly.usedPercent == 0,
               "core confirmed zero projects back as a real zero")

        var failedClaude = claude
        let providerFailure = UsageCore.Failure(code: .rateLimited, message: "rate limited")
        failedClaude.health.failure = providerFailure
        failedClaude.health.lastAttemptAt = Date(timeIntervalSince1970: 140)
        failedClaude.health.retryAt = Date(timeIntervalSince1970: 210)
        let staleProjection = UsageCore.Compatibility.project(
            provider: .claude,
            state: failedClaude,
            presentation: .init(scopedLabel: "Fable"),
            at: now
        )
        expect(staleProjection.usage.weekly.percentInt == 41,
               "provider failure does not erase a valid projected reading")
        expect(staleProjection.status.source == .cached
            && staleProjection.status.failure?.kind == .rateLimited,
               "provider failure projects as cached provider health")
        expect(staleProjection.status.failure?.retryAfter == 60
            && staleProjection.windows[.weekly]?.freshness == .stale,
               "retry timing and stale freshness remain explicit")

        let withLocal = UsageCore.Reducer.reduce(
            UsageCore.State(providers: [.claude: failedClaude]),
            .localClaudeFiveHour(
                usedFraction: 1,
                resetAt: Date(timeIntervalSince1970: 350),
                observedAt: Date(timeIntervalSince1970: 145)
            )
        )[.claude]
        let mixedProjection = UsageCore.Compatibility.project(
            provider: .claude,
            state: withLocal,
            presentation: .init(scopedLabel: "Fable"),
            at: now
        )
        expect(mixedProjection.status.source == .mixedLocalFallback,
               "local five-hour evidence plus provider failure projects as mixed")
        expect(mixedProjection.usage.fiveHour.source == .localSessionLimit
            && mixedProjection.windows[.fiveHour]?.source == .localSessionLimit
            && mixedProjection.windows[.fiveHour]?.freshness == .localEvidence,
               "local evidence keeps exact and compatible source metadata")
        expect(mixedProjection.windows[.weekly]?.freshness == .stale,
               "local five-hour evidence cannot make weekly data fresh")

        let cachedWindow = WindowUsage(
            usedPercent: 0.22,
            resetAt: Date(timeIntervalSince1970: 700),
            error: nil,
            observedAt: Date(timeIntervalSince1970: 90),
            source: .migratedCache
        )
        let cachedSnapshot = UsageCore.Compatibility.snapshot(
            provider: .claude,
            usage: AppUsage(fiveHour: cachedWindow, weekly: cachedWindow),
            observedAt: Date(timeIntervalSince1970: 100),
            source: .claudeSharedCredential,
            confidence: .authoritative
        )
        expect(cachedSnapshot.readings[.weekly]?.observedAt == Date(timeIntervalSince1970: 90)
            && cachedSnapshot.readings[.weekly]?.source == .restoredSnapshot
            && cachedSnapshot.readings[.weekly]?.confidence == .cached,
               "per-window cache observation metadata outranks import defaults")

        let legacyStatus = UsageProviderStatus(
            source: .cached,
            lastAttemptAt: Date(timeIntervalSince1970: 140),
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            failure: UsageFetchFailure(
                kind: .authenticationExpired,
                message: "waiting for provider",
                retryAfter: 30
            ),
            retryAt: nil
        )
        let importedHealth = UsageCore.Compatibility.health(from: legacyStatus)
        expect(importedHealth.failure?.code == .authenticationExpired
            && importedHealth.retryAt == Date(timeIntervalSince1970: 170),
               "legacy provider health imports without losing failure or retry timing")

        let afterResetProjection = UsageCore.Compatibility.project(
            provider: .claude,
            state: claude,
            presentation: .init(scopedLabel: "Fable"),
            at: Date(timeIntervalSince1970: 701)
        )
        expect(!afterResetProjection.usage.weekly.hasKnownValue
            && afterResetProjection.windows[.weekly]?.freshness == .unavailable,
               "projection resolves elapsed windows before creating AppUsage")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all usage core compatibility tests passed")
    }
}
