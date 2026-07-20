import Foundation

struct UsageSnapshotRecord: Codable {
    let at: Date
    let usage: AppUsage
}

struct UsageSnapshot: Codable {
    var claude: UsageSnapshotRecord?
    var codex: UsageSnapshotRecord?
}

enum UsageSnapshotStore {
    private enum WindowKind {
        case fiveHour
        case weekly
        case scopedWeekly
    }

    private static let storageKey = "CodexIsland.latestUsageSnapshot.v1"
    private static let maxSnapshotAge: TimeInterval = 8 * 86400

    static func load(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> UsageSnapshot {
        var snapshot = rawLoad(defaults: defaults)
        snapshot.claude = sanitized(snapshot.claude, now: now)
        snapshot.codex = sanitized(snapshot.codex, now: now)
        return snapshot
    }

    static func recordClaude(
        _ usage: AppUsage,
        at: Date,
        defaults: UserDefaults = .standard
    ) {
        record(provider: \.claude, usage: usage, at: at, defaults: defaults)
    }

    static func recordCodex(
        _ usage: AppUsage,
        at: Date,
        defaults: UserDefaults = .standard
    ) {
        record(provider: \.codex, usage: usage, at: at, defaults: defaults)
    }

    private static func record(
        provider: WritableKeyPath<UsageSnapshot, UsageSnapshotRecord?>,
        usage: AppUsage,
        at: Date,
        defaults: UserDefaults
    ) {
        let sanitizedUsage = sanitizedUsage(usage, now: at, fallbackObservedAt: at)
        var snapshot = rawLoad(defaults: defaults)
        snapshot[keyPath: provider] = UsageSnapshotRecord(at: at, usage: sanitizedUsage)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func rawLoad(defaults: UserDefaults) -> UsageSnapshot {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else { return UsageSnapshot() }
        return snapshot
    }

    private static func sanitized(
        _ record: UsageSnapshotRecord?,
        now: Date
    ) -> UsageSnapshotRecord? {
        guard let record,
              now.timeIntervalSince(record.at) <= maxSnapshotAge
        else { return nil }
        let usage = sanitizedUsage(record.usage, now: now, fallbackObservedAt: record.at)
        return UsageSnapshotRecord(at: record.at, usage: usage)
    }

    /// Resolve the values that are still valid at `now`. This is used both at
    /// snapshot hydration and by the live store on every poll, so an app that
    /// stays open across a reset boundary cannot keep showing the prior cycle.
    static func sanitizedUsage(
        _ usage: AppUsage,
        now: Date,
        fallbackObservedAt: Date? = nil
    ) -> AppUsage {
        var usage = usage
        usage.fiveHour = sanitized(
            usage.fiveHour,
            window: .fiveHour,
            now: now,
            fallbackObservedAt: fallbackObservedAt
        )
        usage.weekly = sanitized(
            usage.weekly,
            window: .weekly,
            now: now,
            fallbackObservedAt: fallbackObservedAt
        )
        if let scoped = usage.scopedWeekly {
            // Preserve the known plan slot and label after its cycle expires;
            // `.unknown` renders as a dash/empty ring instead of making Fable
            // silently disappear from a Max user's three-ring vocabulary.
            usage.scopedWeekly = sanitized(
                scoped,
                window: .scopedWeekly,
                now: now,
                fallbackObservedAt: fallbackObservedAt
            )
        }
        return usage
    }

    private static func sanitized(
        _ window: WindowUsage,
        window kind: WindowKind,
        now: Date,
        fallbackObservedAt: Date?
    ) -> WindowUsage {
        guard window.hasKnownValue else { return .unknown }
        if let resetAt = window.resetAt, resetAt <= now { return .unknown }

        let observedAt = window.observedAt ?? fallbackObservedAt
        if window.resetAt == nil,
           let observedAt,
           now.timeIntervalSince(observedAt) > maxAgeWithoutReset(for: kind) {
            return .unknown
        }

        return WindowUsage(
            usedPercent: window.usedPercent,
            resetAt: window.resetAt,
            error: nil,
            observedAt: observedAt,
            source: window.source ?? (fallbackObservedAt == nil ? nil : .migratedCache)
        )
    }

    private static func maxAgeWithoutReset(for window: WindowKind) -> TimeInterval {
        switch window {
        case .fiveHour: return 6 * 3600
        case .weekly, .scopedWeekly: return 36 * 3600
        }
    }
}
