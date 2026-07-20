import Foundation

extension UsageCore {
    enum Event: Equatable, Sendable {
        case apiSucceeded(
            provider: ProviderID,
            readings: [WindowID: Reading],
            attemptedAt: Date,
            completedAt: Date
        )
        case apiFailed(
            provider: ProviderID,
            failure: Failure,
            attemptedAt: Date,
            retryAt: Date?
        )
        case localClaudeFiveHour(
            usedFraction: Double,
            resetAt: Date?,
            observedAt: Date
        )
        case resolveResets(at: Date)
    }

    enum Reducer {
        static func reduce(_ state: State, _ event: Event) -> State {
            var next = state

            switch event {
            case .apiSucceeded(let providerID, let readings, let attemptedAt, let completedAt):
                var provider = next[providerID]
                guard provider.health.lastAttemptAt.map({ attemptedAt >= $0 }) ?? true else {
                    return state
                }
                provider.readings = resolvedReadings(readings, at: completedAt)
                provider.health = ProviderHealth(
                    lastAttemptAt: attemptedAt,
                    lastSuccessAt: completedAt,
                    failure: nil,
                    retryAt: nil
                )
                next[providerID] = provider

            case .apiFailed(let providerID, let failure, let attemptedAt, let retryAt):
                var provider = next[providerID]
                guard provider.health.lastAttemptAt.map({ attemptedAt >= $0 }) ?? true else {
                    return state
                }
                provider.health.lastAttemptAt = attemptedAt
                provider.health.failure = failure
                provider.health.retryAt = retryAt
                next[providerID] = provider

            case .localClaudeFiveHour(let usedFraction, let resetAt, let observedAt):
                var provider = next[.claude]
                if let current = provider[.fiveHour], current.observedAt > observedAt {
                    return state
                }
                provider.readings[.fiveHour] = Reading(
                    usedFraction: usedFraction,
                    resetAt: resetAt,
                    observedAt: observedAt,
                    source: .localSessionLimit,
                    confidence: .derived
                ).resolved(at: observedAt, for: .fiveHour)
                next[.claude] = provider

            case .resolveResets(let now):
                for providerID in ProviderID.allCases {
                    var provider = next[providerID]
                    provider.readings = resolvedReadings(provider.readings, at: now)
                    next[providerID] = provider
                }
            }

            return next
        }
    }
}

extension UsageCore.State {
    func resolved(at now: Date) -> UsageCore.State {
        UsageCore.Reducer.reduce(self, .resolveResets(at: now))
    }
}
