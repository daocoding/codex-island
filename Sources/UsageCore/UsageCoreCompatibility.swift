import Foundation

extension UsageCore {
    struct PresentationMetadata: Codable, Equatable, Sendable {
        var plan: String?
        var shortWindowLabel: String?
        var weeklyWindowLabel: String?
        var scopedLabel: String?

        init(
            plan: String? = nil,
            shortWindowLabel: String? = nil,
            weeklyWindowLabel: String? = nil,
            scopedLabel: String? = nil
        ) {
            self.plan = plan
            self.shortWindowLabel = shortWindowLabel
            self.weeklyWindowLabel = weeklyWindowLabel
            self.scopedLabel = scopedLabel
        }
    }

    struct ProviderSnapshot: Codable, Equatable, Sendable {
        let provider: ProviderID
        let readings: [WindowID: Reading]
        let presentation: PresentationMetadata
    }

    enum Freshness: String, Codable, Equatable, Sendable {
        case live
        case localEvidence = "local_evidence"
        case cached
        case stale
        case unavailable
    }

    struct WindowProjection: Equatable, Sendable {
        let observedAt: Date
        let source: ReadingSource
        let confidence: Confidence
        let freshness: Freshness
    }

    struct AppProjection {
        let usage: AppUsage
        let status: UsageProviderStatus
        let windows: [WindowID: WindowProjection]
    }

    enum Compatibility {
        static func snapshot(
            provider providerID: ProviderID,
            usage: AppUsage,
            observedAt: Date,
            source: ReadingSource,
            confidence: Confidence
        ) -> ProviderSnapshot {
            var readings: [WindowID: Reading] = [:]

            if providerID == .claude || usage.shortWindowLabel != nil {
                readings[.fiveHour] = reading(
                    from: usage.fiveHour,
                    fallbackObservedAt: observedAt,
                    fallbackSource: source,
                    fallbackConfidence: confidence
                )
            }
            readings[.weekly] = reading(
                from: usage.weekly,
                fallbackObservedAt: observedAt,
                fallbackSource: source,
                fallbackConfidence: confidence
            )
            if providerID == .claude, let scopedWeekly = usage.scopedWeekly {
                readings[.scopedWeekly] = reading(
                    from: scopedWeekly,
                    fallbackObservedAt: observedAt,
                    fallbackSource: source,
                    fallbackConfidence: confidence
                )
            }

            return ProviderSnapshot(
                provider: providerID,
                readings: readings,
                presentation: PresentationMetadata(
                    plan: usage.plan,
                    shortWindowLabel: usage.shortWindowLabel,
                    weeklyWindowLabel: usage.weeklyWindowLabel,
                    scopedLabel: usage.scopedLabel
                )
            )
        }

        static func health(from status: UsageProviderStatus) -> ProviderHealth {
            let retryAt = status.retryAt ?? status.failure.flatMap { failure in
                guard let retryAfter = failure.retryAfter,
                      let lastAttemptAt = status.lastAttemptAt else { return nil }
                return lastAttemptAt.addingTimeInterval(retryAfter)
            }
            return ProviderHealth(
                lastAttemptAt: status.lastAttemptAt,
                lastSuccessAt: status.lastSuccessAt,
                failure: status.failure.map(coreFailure),
                retryAt: retryAt
            )
        }

        static func project(
            provider providerID: ProviderID,
            state: ProviderState,
            presentation: PresentationMetadata = PresentationMetadata(),
            at now: Date
        ) -> AppProjection {
            var resolved = state
            resolved.readings = resolvedReadings(state.readings, at: now)

            let fiveHour = resolved[.fiveHour].map(legacyWindow) ?? .unknown
            let weekly = resolved[.weekly].map(legacyWindow) ?? .unknown
            let scopedWeekly = resolved[.scopedWeekly].map(legacyWindow)
            let hasShortWindow = resolved.readings[.fiveHour] != nil

            let usage: AppUsage
            switch providerID {
            case .claude:
                usage = AppUsage(
                    fiveHour: fiveHour,
                    weekly: weekly,
                    plan: presentation.plan,
                    shortWindowLabel: presentation.shortWindowLabel ?? "5h",
                    weeklyWindowLabel: presentation.weeklyWindowLabel ?? "week",
                    scopedWeekly: scopedWeekly,
                    scopedLabel: scopedWeekly == nil ? nil : presentation.scopedLabel
                )
            case .codex:
                usage = AppUsage(
                    fiveHour: fiveHour,
                    weekly: weekly,
                    plan: presentation.plan,
                    shortWindowLabel: hasShortWindow
                        ? (presentation.shortWindowLabel ?? "5h")
                        : nil,
                    weeklyWindowLabel: presentation.weeklyWindowLabel ?? "week"
                )
            }

            let windowMetadata = resolved.readings.mapValues { reading in
                WindowProjection(
                    observedAt: reading.observedAt,
                    source: reading.source,
                    confidence: reading.confidence,
                    freshness: freshness(of: reading, health: resolved.health)
                )
            }

            return AppProjection(
                usage: usage,
                status: legacyStatus(for: resolved, at: now),
                windows: windowMetadata
            )
        }

        private static func reading(
            from window: WindowUsage,
            fallbackObservedAt: Date,
            fallbackSource: ReadingSource,
            fallbackConfidence: Confidence
        ) -> Reading {
            let source: ReadingSource
            let confidence: Confidence
            switch window.source {
            case .api:
                source = fallbackSource
                confidence = fallbackConfidence
            case .claudeDesktopBridge:
                source = .claudeDesktopBridge
                confidence = fallbackConfidence
            case .claudeSharedCredential:
                source = .claudeSharedCredential
                confidence = fallbackConfidence
            case .codexDesktopSharedAuth:
                source = .codexDesktopSharedAuth
                confidence = fallbackConfidence
            case .localSessionLimit:
                source = .localSessionLimit
                confidence = .derived
            case .migratedCache:
                source = .restoredSnapshot
                confidence = .cached
            case nil:
                source = fallbackSource
                confidence = fallbackConfidence
            }

            return Reading(
                usedFraction: window.hasKnownValue ? window.usedPercent : nil,
                resetAt: window.resetAt,
                observedAt: window.observedAt ?? fallbackObservedAt,
                source: source,
                confidence: confidence
            )
        }

        private static func legacyWindow(_ reading: Reading) -> WindowUsage {
            WindowUsage(
                usedPercent: reading.usedFraction ?? 0,
                resetAt: reading.resetAt,
                error: reading.isKnown ? nil : "no data",
                observedAt: reading.observedAt,
                source: legacySource(reading.source)
            )
        }

        private static func legacySource(_ source: ReadingSource) -> UsageReadingSource {
            switch source {
            case .claudeDesktopBridge:
                return .claudeDesktopBridge
            case .claudeSharedCredential:
                return .claudeSharedCredential
            case .codexDesktopSharedAuth:
                return .codexDesktopSharedAuth
            case .localSessionLimit:
                return .localSessionLimit
            case .restoredSnapshot:
                return .migratedCache
            }
        }

        private static func freshness(
            of reading: Reading,
            health: ProviderHealth
        ) -> Freshness {
            guard reading.isKnown else { return .unavailable }
            if reading.source == .localSessionLimit { return .localEvidence }
            if health.failure != nil { return .stale }
            if reading.confidence == .cached || reading.source == .restoredSnapshot {
                return .cached
            }
            return .live
        }

        private static func legacyStatus(
            for state: ProviderState,
            at now: Date
        ) -> UsageProviderStatus {
            let known = state.readings.values.filter(\.isKnown)
            let hasLocalEvidence = known.contains { $0.source == .localSessionLimit }
            let hasOnlyCachedEvidence = !known.isEmpty && known.allSatisfy {
                $0.confidence == .cached || $0.source == .restoredSnapshot
            }

            let source: UsageProviderStatus.Source
            if state.health.failure != nil {
                if hasLocalEvidence {
                    source = .mixedLocalFallback
                } else {
                    source = known.isEmpty ? .idle : .cached
                }
            } else if hasLocalEvidence {
                source = .mixedLocalFallback
            } else if hasOnlyCachedEvidence {
                source = .cached
            } else if state.health.lastSuccessAt != nil {
                source = .live
            } else {
                source = known.isEmpty ? .idle : .cached
            }

            return UsageProviderStatus(
                source: source,
                lastAttemptAt: state.health.lastAttemptAt,
                lastSuccessAt: state.health.lastSuccessAt,
                failure: state.health.failure.map { legacyFailure($0, health: state.health, at: now) },
                retryAt: state.health.retryAt
            )
        }

        private static func coreFailure(_ failure: UsageFetchFailure) -> Failure {
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

        private static func legacyFailure(
            _ failure: Failure,
            health: ProviderHealth,
            at now: Date
        ) -> UsageFetchFailure {
            let kind: UsageFailureKind
            switch failure.code {
            case .authenticationExpired:
                kind = .authenticationExpired
            case .reauthenticationRequired:
                kind = .reauthenticationRequired
            case .rateLimited:
                kind = .rateLimited
            case .transport:
                kind = .transport
            case .malformedResponse, .unavailable:
                kind = .other
            }
            let retryAfter = health.retryAt.map { max(0, $0.timeIntervalSince(now)) }
            return UsageFetchFailure(
                kind: kind,
                message: failure.message,
                retryAfter: retryAfter
            )
        }
    }
}
