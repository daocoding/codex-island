import Foundation

enum UsageCore {
    enum ProviderID: String, CaseIterable, Codable, Hashable, Sendable {
        case claude
        case codex
    }

    struct WindowID: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(_ rawValue: String) {
            self.init(rawValue: rawValue)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(try container.decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        static let fiveHour = WindowID("five_hour")
        static let weekly = WindowID("weekly")
        static let scopedWeekly = WindowID("scoped_weekly")

        /// Some provider responses omit a reset timestamp. Keep those values
        /// useful for a bounded period, then retire them rather than allowing a
        /// once-valid percentage to survive indefinitely through failures and
        /// app restarts.
        var maximumAgeWithoutReset: TimeInterval {
            self == .fiveHour ? 6 * 60 * 60 : 36 * 60 * 60
        }
    }

    enum ReadingSource: String, Codable, Hashable, Sendable {
        case claudeDesktopBridge = "claude_desktop_bridge"
        case claudeSharedCredential = "claude_shared_credential"
        case codexDesktopSharedAuth = "codex_desktop_shared_auth"
        case localSessionLimit = "local_session_limit"
        case restoredSnapshot = "restored_snapshot"
    }

    enum Confidence: String, Codable, Hashable, Sendable {
        case authoritative
        case derived
        case cached
        case unknown
    }

    struct Reading: Codable, Equatable, Sendable {
        let usedFraction: Double?
        let resetAt: Date?
        let observedAt: Date
        let source: ReadingSource
        let confidence: Confidence

        init(
            usedFraction: Double?,
            resetAt: Date?,
            observedAt: Date,
            source: ReadingSource,
            confidence: Confidence
        ) {
            if let usedFraction, usedFraction.isFinite {
                self.usedFraction = min(max(usedFraction, 0), 1)
            } else {
                self.usedFraction = nil
            }
            self.resetAt = resetAt
            self.observedAt = observedAt
            self.source = source
            self.confidence = self.usedFraction == nil ? .unknown : confidence
        }

        var isKnown: Bool {
            usedFraction != nil
        }

        var usedPercent: Int? {
            usedFraction.map { Int(($0 * 100).rounded()) }
        }

        func resolved(at now: Date) -> Reading {
            guard let resetAt, resetAt <= now else { return self }
            return invalidated
        }

        func resolved(at now: Date, for windowID: WindowID) -> Reading {
            let resetResolved = resolved(at: now)
            guard resetResolved.isKnown,
                  resetResolved.resetAt == nil,
                  now.timeIntervalSince(resetResolved.observedAt) > windowID.maximumAgeWithoutReset
            else { return resetResolved }
            return resetResolved.invalidated
        }

        private var invalidated: Reading {
            return Reading(
                usedFraction: nil,
                resetAt: nil,
                observedAt: observedAt,
                source: source,
                confidence: .unknown
            )
        }
    }

    static func resolvedReadings(
        _ readings: [WindowID: Reading],
        at now: Date
    ) -> [WindowID: Reading] {
        Dictionary(uniqueKeysWithValues: readings.map { windowID, reading in
            (windowID, reading.resolved(at: now, for: windowID))
        })
    }

    struct Failure: Codable, Equatable, Sendable {
        enum Code: String, Codable, Hashable, Sendable {
            case authenticationExpired = "authentication_expired"
            case reauthenticationRequired = "reauthentication_required"
            case rateLimited = "rate_limited"
            case transport
            case malformedResponse = "malformed_response"
            case unavailable
        }

        let code: Code
        let message: String

        init(code: Code, message: String) {
            self.code = code
            self.message = message
        }
    }

    struct ProviderHealth: Codable, Equatable, Sendable {
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var failure: Failure?
        var retryAt: Date?

        static let idle = ProviderHealth(
            lastAttemptAt: nil,
            lastSuccessAt: nil,
            failure: nil,
            retryAt: nil
        )

        var isHealthy: Bool {
            lastSuccessAt != nil && failure == nil
        }
    }

    struct ProviderState: Codable, Equatable, Sendable {
        var readings: [WindowID: Reading]
        var health: ProviderHealth

        static let empty = ProviderState(readings: [:], health: .idle)

        subscript(windowID: WindowID) -> Reading? {
            readings[windowID]
        }
    }

    struct State: Codable, Equatable, Sendable {
        private(set) var providers: [ProviderID: ProviderState]

        init(providers: [ProviderID: ProviderState] = [:]) {
            var complete = Dictionary(
                uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderState.empty) }
            )
            for (providerID, providerState) in providers {
                complete[providerID] = providerState
            }
            self.providers = complete
        }

        subscript(providerID: ProviderID) -> ProviderState {
            get { providers[providerID] ?? .empty }
            set { providers[providerID] = newValue }
        }

        func reading(provider providerID: ProviderID, window windowID: WindowID) -> Reading? {
            self[providerID][windowID]
        }
    }
}
