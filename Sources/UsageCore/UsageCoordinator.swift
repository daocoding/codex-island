import Foundation

extension UsageCore {
    /// Stateful compatibility seam between provider adapters and the current
    /// `AppUsage`-based UI. `UsageStore` can own one of these on the main actor
    /// and apply a provider result with one synchronous mutation.
    struct Coordinator {
        private(set) var state: State
        private(set) var presentations: [ProviderID: PresentationMetadata]

        init(
            state: State = State(),
            presentations: [ProviderID: PresentationMetadata] = [:]
        ) {
            self.state = state
            self.presentations = presentations
            for providerID in ProviderID.allCases where self.presentations[providerID] == nil {
                self.presentations[providerID] = PresentationMetadata()
            }
        }

        func presentation(for providerID: ProviderID) -> PresentationMetadata {
            presentations[providerID] ?? PresentationMetadata()
        }

        /// Imports one provider from the existing snapshot/status vocabulary.
        /// The default source deliberately marks hydration as restored data;
        /// callers importing a live observation can pass its exact source and
        /// confidence instead.
        @discardableResult
        mutating func hydrate(
            provider providerID: ProviderID,
            usage: AppUsage,
            status: UsageProviderStatus,
            observedAt: Date,
            source: ReadingSource = .restoredSnapshot,
            confidence: Confidence = .cached,
            now: Date = Date()
        ) -> AppProjection {
            let snapshot = Compatibility.snapshot(
                provider: providerID,
                usage: usage,
                observedAt: observedAt,
                source: source,
                confidence: confidence
            )
            let readings = resolvedReadings(snapshot.readings, at: now)
            state[providerID] = ProviderState(
                readings: readings,
                health: Compatibility.health(from: status)
            )
            presentations[providerID] = snapshot.presentation
            return project(provider: providerID, at: now)
        }

        /// Applies an authoritative provider observation. The legacy usage
        /// value is normalized at this boundary; after this call the core
        /// state is the source of truth.
        @discardableResult
        mutating func acceptSuccess(
            provider providerID: ProviderID,
            usage: AppUsage,
            source: ReadingSource,
            confidence: Confidence = .authoritative,
            attemptedAt: Date,
            observedAt: Date,
            completedAt: Date? = nil,
            projectAt: Date? = nil
        ) -> AppProjection {
            let completion = completedAt ?? observedAt
            let projectionDate = projectAt ?? completion
            let snapshot = Compatibility.snapshot(
                provider: providerID,
                usage: usage,
                observedAt: observedAt,
                source: source,
                confidence: confidence
            )

            if canAccept(
                provider: providerID,
                attemptedAt: attemptedAt,
                observedAt: observedAt
            ) {
                state = Reducer.reduce(state, .apiSucceeded(
                    provider: providerID,
                    readings: snapshot.readings,
                    attemptedAt: attemptedAt,
                    completedAt: completion
                ))
                presentations[providerID] = snapshot.presentation
            }

            return project(provider: providerID, at: projectionDate)
        }

        /// Applies a typed failure from the existing provider layer. Values
        /// remain intact; only provider health changes. `retryAfter` is
        /// converted once into an absolute deadline so repeated projections
        /// cannot accidentally extend a cooldown.
        @discardableResult
        mutating func acceptFailure(
            provider providerID: ProviderID,
            failure: UsageFetchFailure,
            attemptedAt: Date,
            retryAt: Date? = nil,
            projectAt: Date = Date()
        ) -> AppProjection {
            let resolvedRetryAt = retryAt ?? failure.retryAfter.map {
                attemptedAt.addingTimeInterval(max(0, $0))
            }
            state = Reducer.reduce(state, .apiFailed(
                provider: providerID,
                failure: coreFailure(from: failure),
                attemptedAt: attemptedAt,
                retryAt: resolvedRetryAt
            ))
            return project(provider: providerID, at: projectAt)
        }

        /// Applies the one value that can be proven without an API response:
        /// Claude's local session-limit event. Weekly and scoped-weekly data,
        /// provider health, and their observation times are left untouched.
        @discardableResult
        mutating func acceptClaudeLocalFiveHour(
            usedFraction: Double,
            resetAt: Date?,
            observedAt: Date,
            projectAt: Date? = nil
        ) -> AppProjection {
            state = Reducer.reduce(state, .localClaudeFiveHour(
                usedFraction: usedFraction,
                resetAt: resetAt,
                observedAt: observedAt
            ))
            var claudePresentation = presentation(for: .claude)
            if claudePresentation.shortWindowLabel == nil {
                claudePresentation.shortWindowLabel = "5h"
                presentations[.claude] = claudePresentation
            }
            return project(provider: .claude, at: projectAt ?? observedAt)
        }

        /// Convenience overload for the `WindowUsage` already created by the
        /// local Claude session-limit parser. Unknown evidence is a no-op.
        @discardableResult
        mutating func acceptClaudeLocalFiveHour(
            _ window: WindowUsage,
            fallbackObservedAt: Date = Date(),
            projectAt: Date? = nil
        ) -> AppProjection {
            let observationDate = window.observedAt ?? fallbackObservedAt
            guard window.hasKnownValue else {
                return project(provider: .claude, at: projectAt ?? observationDate)
            }
            return acceptClaudeLocalFiveHour(
                usedFraction: window.usedPercent,
                resetAt: window.resetAt,
                observedAt: observationDate,
                projectAt: projectAt
            )
        }

        /// Invalidates readings whose reset boundary has passed and returns
        /// both legacy projections ready for assignment by `UsageStore`.
        @discardableResult
        mutating func resolveResets(at now: Date = Date()) -> LegacyProjections {
            state = state.resolved(at: now)
            return projectAll(at: now)
        }

        func project(
            provider providerID: ProviderID,
            at now: Date = Date()
        ) -> AppProjection {
            Compatibility.project(
                provider: providerID,
                state: state[providerID],
                presentation: presentation(for: providerID),
                at: now
            )
        }

        func projectAll(at now: Date = Date()) -> LegacyProjections {
            LegacyProjections(
                claude: project(provider: .claude, at: now),
                codex: project(provider: .codex, at: now)
            )
        }

        private func canAccept(
            provider providerID: ProviderID,
            attemptedAt: Date,
            observedAt: Date
        ) -> Bool {
            guard state[providerID].health.lastAttemptAt.map({ attemptedAt >= $0 }) ?? true else {
                return false
            }
            // A fresh poll can discover an older CCD bridge file. Prefer the
            // newer reading already in memory instead of making percentages
            // visibly move backward merely because the older source has
            // higher priority. Local 5h evidence is excluded: it must not
            // prevent a later provider poll from refreshing weekly windows.
            let latestProviderObservation = state[providerID].readings.values
                .filter { $0.source != .localSessionLimit }
                .map(\.observedAt)
                .max()
            return latestProviderObservation.map { observedAt >= $0 } ?? true
        }

        private func coreFailure(from failure: UsageFetchFailure) -> Failure {
            let code: Failure.Code
            switch failure.kind {
            case .authenticationExpired:
                code = .authenticationExpired
            case .reauthenticationRequired:
                code = .reauthenticationRequired
            case .rateLimited:
                code = .rateLimited
            case .transport:
                code = .transport
            case .other:
                code = .unavailable
            }
            return Failure(code: code, message: failure.message)
        }
    }

    /// Non-optional two-provider result for the current `UsageStore` fields.
    struct LegacyProjections {
        let claude: AppProjection
        let codex: AppProjection

        subscript(providerID: ProviderID) -> AppProjection {
            switch providerID {
            case .claude:
                return claude
            case .codex:
                return codex
            }
        }
    }
}
