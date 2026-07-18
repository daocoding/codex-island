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
        guard let sanitizedUsage = sanitized(usage, now: at) else { return }
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
              now.timeIntervalSince(record.at) <= maxSnapshotAge,
              let usage = sanitized(record.usage, now: now)
        else { return nil }
        return UsageSnapshotRecord(at: record.at, usage: usage)
    }

    private static func sanitized(_ usage: AppUsage, now: Date) -> AppUsage? {
        var usage = usage
        usage.fiveHour = sanitized(usage.fiveHour, now: now)
        usage.weekly = sanitized(usage.weekly, now: now)
        if let scoped = usage.scopedWeekly {
            let sanitizedScoped = sanitized(scoped, now: now)
            usage.scopedWeekly = sanitizedScoped.error == nil ? sanitizedScoped : nil
            if usage.scopedWeekly == nil {
                usage.scopedLabel = nil
            }
        }

        let hasWindow = usage.fiveHour.error == nil
            || usage.weekly.error == nil
            || usage.scopedWeekly != nil
        return hasWindow ? usage : nil
    }

    private static func sanitized(_ window: WindowUsage, now: Date) -> WindowUsage {
        guard window.error == nil else { return .unknown }
        if let resetAt = window.resetAt, resetAt <= now { return .unknown }
        return window
    }
}
