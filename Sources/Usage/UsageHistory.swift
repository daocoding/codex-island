import Foundation
import Combine

/// One observed reading of a single rate-limit window. `used` is the 0...1
/// fraction the API reported at `at`.
struct UsageSample: Codable {
    let at: Date
    let used: Double
}

enum UsageWindow: String, Codable {
    case fiveHour
    case weekly
    /// Model-scoped weekly bucket (Claude Max's Fable/Opus limit). Additive:
    /// the raw value only ever appears in series keys, so old persisted
    /// history decodes unchanged.
    case scopedWeekly
}

/// Records the usage percentages the app already polls so the SparkChart can
/// plot the user's real trajectory instead of a synthesized curve. Neither
/// provider exposes a usage time-series, but we sample one ourselves on every
/// successful refresh and persist it across launches. A failed poll, a
/// rate-limit cooldown, or a closed app leaves a gap rather than a fabricated
/// point — the chart only ever shows readings that actually happened.
@MainActor
final class UsageHistoryStore: ObservableObject {
    static let shared = UsageHistoryStore()

    /// Bumped whenever a sample lands so SwiftUI tiles observing the store
    /// re-read. The samples themselves stay private — callers ask per series.
    @Published private(set) var revision = 0

    /// Keep a week of readings. At the 5-minute polling floor that is ~2000
    /// points per window, so a count cap also guards against a tighter
    /// interval filling memory.
    private static let maxAge: TimeInterval = 7 * 86400
    private static let maxSamples = 1000
    private static let storageKey = "CodexIsland.usageHistory.v1"

    private var series: [String: [UsageSample]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: [UsageSample]].self, from: data) {
            series = decoded
        } else {
            series = [:]
        }
    }

    /// Append the non-errored windows of a fresh fetch. Errored windows are
    /// skipped so a failed poll leaves a gap rather than a fabricated point.
    func record(provider: AlertEngine.Provider, usage: AppUsage, at: Date) {
        var changed = append(provider, .fiveHour, usage.fiveHour, at)
        changed = append(provider, .weekly, usage.weekly, at) || changed
        if let scoped = usage.scopedWeekly {
            changed = append(provider, .scopedWeekly, scoped, at) || changed
        }
        if changed {
            persist()
            revision &+= 1
        }
    }

    /// Record one independently observed window (currently Claude's local 5h
    /// session-limit fallback). This must not append cached weekly/Fable values
    /// as if the whole provider had just refreshed.
    func record(
        provider: AlertEngine.Provider,
        window: UsageWindow,
        reading: WindowUsage,
        at: Date
    ) {
        guard append(provider, window, reading, at) else { return }
        persist()
        revision &+= 1
    }

    /// Readings for one series, oldest first. The latest entry is the most
    /// recent successful poll.
    func samples(provider: AlertEngine.Provider, window: UsageWindow) -> [UsageSample] {
        series[key(provider, window)] ?? []
    }

    /// Best-effort startup seed for builds installed before full usage
    /// snapshots existed. The chart history only stores percentages, so reset
    /// times remain unknown until the next successful provider fetch.
    func latestUsage(provider: AlertEngine.Provider, now: Date = Date()) -> AppUsage? {
        let fiveHour = latestWindow(provider, .fiveHour, now: now, maxAge: 6 * 3600)
        let weekly = latestWindow(provider, .weekly, now: now, maxAge: 36 * 3600)
        let scoped = latestWindow(provider, .scopedWeekly, now: now, maxAge: 36 * 3600)

        guard fiveHour != nil || weekly != nil || scoped != nil else { return nil }
        return AppUsage(
            fiveHour: fiveHour ?? .unknown,
            weekly: weekly ?? .unknown,
            shortWindowLabel: fiveHour == nil ? nil : "5h",
            weeklyWindowLabel: weekly == nil ? nil : "week",
            scopedWeekly: scoped,
            scopedLabel: scoped == nil ? nil : "Fable"
        )
    }

    private func append(
        _ provider: AlertEngine.Provider,
        _ window: UsageWindow,
        _ reading: WindowUsage,
        _ at: Date
    ) -> Bool {
        guard reading.error == nil else { return false }
        let k = key(provider, window)
        var arr = series[k] ?? []
        if arr.contains(where: { $0.at == at && abs($0.used - reading.usedPercent) < 0.000_001 }) {
            return false
        }
        arr.append(UsageSample(at: at, used: max(0, min(1, reading.usedPercent))))
        arr.sort { $0.at < $1.at }
        let cutoff = at.addingTimeInterval(-Self.maxAge)
        arr.removeAll { $0.at < cutoff }
        if arr.count > Self.maxSamples { arr.removeFirst(arr.count - Self.maxSamples) }
        series[k] = arr
        return true
    }

    private func latestWindow(
        _ provider: AlertEngine.Provider,
        _ window: UsageWindow,
        now: Date,
        maxAge: TimeInterval
    ) -> WindowUsage? {
        guard let sample = series[key(provider, window)]?.last,
              now.timeIntervalSince(sample.at) <= maxAge
        else { return nil }
        return WindowUsage(usedPercent: sample.used, resetAt: nil, error: nil)
    }

    private func key(_ p: AlertEngine.Provider, _ w: UsageWindow) -> String {
        "\(p.rawValue).\(w.rawValue)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(series) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
