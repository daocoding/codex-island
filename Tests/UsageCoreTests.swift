import Foundation

@main
struct UsageCoreTests {
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
        _ usedFraction: Double?,
        resetAt: TimeInterval,
        observedAt: TimeInterval,
        source: UsageCore.ReadingSource
    ) -> UsageCore.Reading {
        UsageCore.Reading(
            usedFraction: usedFraction,
            resetAt: Date(timeIntervalSince1970: resetAt),
            observedAt: Date(timeIntervalSince1970: observedAt),
            source: source,
            confidence: usedFraction == nil ? .unknown : .authoritative
        )
    }

    static func succeeded(
        _ state: UsageCore.State,
        provider: UsageCore.ProviderID,
        readings: [UsageCore.WindowID: UsageCore.Reading],
        attemptedAt: TimeInterval,
        completedAt: TimeInterval
    ) -> UsageCore.State {
        UsageCore.Reducer.reduce(state, .apiSucceeded(
            provider: provider,
            readings: readings,
            attemptedAt: Date(timeIntervalSince1970: attemptedAt),
            completedAt: Date(timeIntervalSince1970: completedAt)
        ))
    }

    static func main() {
        let claudeSource = UsageCore.ReadingSource.claudeDesktopBridge
        let codexSource = UsageCore.ReadingSource.codexDesktopSharedAuth

        let beforeReset = succeeded(
            .init(),
            provider: .claude,
            readings: [
                .weekly: reading(0.62, resetAt: 200, observedAt: 100, source: claudeSource),
            ],
            attemptedAt: 105,
            completedAt: 110
        )
        let stillCurrent = beforeReset.resolved(at: Date(timeIntervalSince1970: 199))
        expect(stillCurrent.reading(provider: .claude, window: .weekly)?.usedPercent == 62,
               "reset resolution preserves a reading before its boundary")
        let afterReset = beforeReset.resolved(at: Date(timeIntervalSince1970: 200))
        let expired = afterReset.reading(provider: .claude, window: .weekly)
        expect(expired?.usedFraction == nil,
               "reset crossing turns the old value into unknown")
        expect(expired?.resetAt == nil,
               "reset crossing removes the elapsed schedule")
        expect(expired?.observedAt == Date(timeIntervalSince1970: 100),
               "reset crossing does not re-date the old observation")
        expect(afterReset[.claude].health == beforeReset[.claude].health,
               "reset resolution does not change provider health")

        let priorReading = beforeReset[.claude].readings
        let failure = UsageCore.Failure(code: .transport, message: "offline")
        let failed = UsageCore.Reducer.reduce(beforeReset, .apiFailed(
            provider: .claude,
            failure: failure,
            attemptedAt: Date(timeIntervalSince1970: 120),
            retryAt: Date(timeIntervalSince1970: 180)
        ))
        expect(failed[.claude].readings == priorReading,
               "provider failure preserves every cached reading")
        expect(failed[.claude].health.failure == failure,
               "provider failure is recorded only in provider health")
        expect(failed[.claude].health.lastSuccessAt == Date(timeIntervalSince1970: 110),
               "provider failure preserves the last success time")

        let threeClaudeWindows = succeeded(
            .init(),
            provider: .claude,
            readings: [
                .fiveHour: reading(0.10, resetAt: 300, observedAt: 100, source: claudeSource),
                .weekly: reading(0.20, resetAt: 700, observedAt: 100, source: claudeSource),
                .scopedWeekly: reading(0.30, resetAt: 700, observedAt: 100, source: claudeSource),
            ],
            attemptedAt: 105,
            completedAt: 110
        )
        let priorHealth = threeClaudeWindows[.claude].health
        let localFallback = UsageCore.Reducer.reduce(threeClaudeWindows, .localClaudeFiveHour(
            usedFraction: 1,
            resetAt: Date(timeIntervalSince1970: 350),
            observedAt: Date(timeIntervalSince1970: 150)
        ))
        expect(localFallback.reading(provider: .claude, window: .fiveHour)?.usedPercent == 100,
               "local session evidence updates Claude five-hour usage")
        expect(localFallback.reading(provider: .claude, window: .fiveHour)?.source == .localSessionLimit,
               "local session evidence retains its source")
        expect(localFallback.reading(provider: .claude, window: .fiveHour)?.confidence == .derived,
               "local session evidence is marked derived")
        expect(localFallback.reading(provider: .claude, window: .weekly)
            == threeClaudeWindows.reading(provider: .claude, window: .weekly),
               "local session evidence cannot re-date Claude weekly usage")
        expect(localFallback.reading(provider: .claude, window: .scopedWeekly)
            == threeClaudeWindows.reading(provider: .claude, window: .scopedWeekly),
               "local session evidence cannot re-date scoped usage")
        expect(localFallback[.claude].health == priorHealth,
               "local session evidence does not disguise provider health")

        let withClaude = succeeded(
            .init(),
            provider: .claude,
            readings: [
                .weekly: reading(0.31, resetAt: 700, observedAt: 100, source: claudeSource),
            ],
            attemptedAt: 105,
            completedAt: 110
        )
        let withBoth = succeeded(
            withClaude,
            provider: .codex,
            readings: [
                .weekly: reading(0.47, resetAt: 800, observedAt: 120, source: codexSource),
            ],
            attemptedAt: 125,
            completedAt: 130
        )
        let claudeBeforeCodexFailure = withBoth[.claude]
        let codexFailed = UsageCore.Reducer.reduce(withBoth, .apiFailed(
            provider: .codex,
            failure: failure,
            attemptedAt: Date(timeIntervalSince1970: 140),
            retryAt: nil
        ))
        expect(codexFailed[.claude] == claudeBeforeCodexFailure,
               "one provider failure cannot change the other provider")
        expect(codexFailed.reading(provider: .codex, window: .weekly)?.usedPercent == 47,
               "Codex failure preserves its prior reading independently")
        expect(codexFailed[.claude].health.failure == nil && codexFailed[.codex].health.failure != nil,
               "provider health remains independently scoped")

        let unknown = UsageCore.Reading(
            usedFraction: nil,
            resetAt: nil,
            observedAt: Date(timeIntervalSince1970: 100),
            source: .restoredSnapshot,
            confidence: .cached
        )
        let confirmedZero = UsageCore.Reading(
            usedFraction: 0,
            resetAt: Date(timeIntervalSince1970: 200),
            observedAt: Date(timeIntervalSince1970: 100),
            source: claudeSource,
            confidence: .authoritative
        )
        expect(!unknown.isKnown && unknown.usedPercent == nil && unknown.confidence == .unknown,
               "unknown remains nil instead of becoming a zero reading")
        expect(confirmedZero.isKnown && confirmedZero.usedPercent == 0,
               "a confirmed zero remains distinct from unknown")

        var missingResetState = UsageCore.State()
        missingResetState[.claude] = UsageCore.ProviderState(
            readings: [
                .fiveHour: UsageCore.Reading(
                    usedFraction: 0.42,
                    resetAt: nil,
                    observedAt: Date(timeIntervalSince1970: 100),
                    source: claudeSource,
                    confidence: .authoritative
                ),
                .weekly: UsageCore.Reading(
                    usedFraction: 0.43,
                    resetAt: nil,
                    observedAt: Date(timeIntervalSince1970: 100),
                    source: claudeSource,
                    confidence: .authoritative
                ),
            ],
            health: .idle
        )
        let afterShortTTL = missingResetState.resolved(
            at: Date(timeIntervalSince1970: 100 + 6 * 60 * 60 + 1)
        )
        expect(afterShortTTL.reading(provider: .claude, window: .fiveHour)?.usedFraction == nil,
               "a 5h reading without reset expires after its conservative TTL")
        expect(afterShortTTL.reading(provider: .claude, window: .weekly)?.usedPercent == 43,
               "weekly no-reset data survives the shorter 5h TTL")
        let afterWeeklyTTL = missingResetState.resolved(
            at: Date(timeIntervalSince1970: 100 + 36 * 60 * 60 + 1)
        )
        expect(afterWeeklyTTL.reading(provider: .claude, window: .weekly)?.usedFraction == nil,
               "a weekly reading without reset cannot survive indefinitely")

        let staleFailure = UsageCore.Reducer.reduce(codexFailed, .apiFailed(
            provider: .codex,
            failure: .init(code: .rateLimited, message: "late response"),
            attemptedAt: Date(timeIntervalSince1970: 135),
            retryAt: nil
        ))
        expect(staleFailure == codexFailed,
               "an out-of-order provider event cannot replace newer state")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all usage core tests passed")
    }
}
