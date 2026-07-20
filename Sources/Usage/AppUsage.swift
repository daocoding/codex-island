import Foundation

enum UsageReadingSource: String, Codable {
    case api
    case localSessionLimit
    case migratedCache
}

/// One rate-limit window (e.g. Claude's 5h, Codex's 7d). usedPercent is
/// normalized to 0...1 regardless of what the upstream API returns.
struct WindowUsage: Codable {
    let usedPercent: Double
    let resetAt: Date?
    let error: String?
    /// Time this specific value was observed. Optional for snapshots written
    /// by older builds; snapshot hydration fills it from the record timestamp.
    let observedAt: Date?
    let source: UsageReadingSource?

    init(
        usedPercent: Double,
        resetAt: Date?,
        error: String?,
        observedAt: Date? = nil,
        source: UsageReadingSource? = nil
    ) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.error = error
        self.observedAt = observedAt
        self.source = source
    }

    static let unknown = WindowUsage(usedPercent: 0, resetAt: nil, error: "no data")

    var percentInt: Int { Int((usedPercent * 100).rounded()) }

    /// A real 0% reading is known (`error == nil`); the internal `.unknown`
    /// sentinel is not. Keeping this distinction centralized prevents
    /// remaining-mode from turning unknown into a convincing 100% value.
    var hasKnownValue: Bool { error == nil || usedPercent > 0 }

    func displayedFraction(mode: UsageDisplayMode) -> Double {
        guard hasKnownValue else { return 0 }
        switch mode {
        case .used:
            return usedPercent
        case .remaining:
            return max(0, 1 - usedPercent)
        }
    }

    func displayedPercentInt(mode: UsageDisplayMode) -> Int {
        Int((displayedFraction(mode: mode) * 100).rounded())
    }

    func observed(at date: Date, source: UsageReadingSource) -> WindowUsage {
        guard hasKnownValue else { return self }
        return WindowUsage(
            usedPercent: usedPercent,
            resetAt: resetAt,
            error: error,
            observedAt: date,
            source: source
        )
    }
}

enum UsageFailureKind: Equatable {
    case authenticationExpired
    case reauthenticationRequired
    case rateLimited
    case transport
    case other
}

struct UsageFetchFailure: Equatable {
    let kind: UsageFailureKind
    let message: String
    let retryAfter: TimeInterval?

    init(kind: UsageFailureKind, message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }
}

enum UsageFetchResult {
    case success(AppUsage)
    case failure(UsageFetchFailure)
}

struct UsageProviderStatus: Equatable {
    enum Source: Equatable {
        case idle
        case cached
        case live
        /// The 5h value came from a local Claude session-limit event while
        /// weekly values remain cached from the last API success.
        case mixedLocalFallback
    }

    var source: Source
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var failure: UsageFetchFailure?
    var retryAt: Date?

    static let idle = UsageProviderStatus(
        source: .idle,
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        failure: nil,
        retryAt: nil
    )

    static func cached(at date: Date?) -> UsageProviderStatus {
        UsageProviderStatus(
            source: .cached,
            lastAttemptAt: nil,
            lastSuccessAt: date,
            failure: nil,
            retryAt: nil
        )
    }

    var isLive: Bool { source == .live && failure == nil }
    var isStale: Bool { !isLive }
}

struct AppUsage: Codable {
    var fiveHour: WindowUsage
    var weekly: WindowUsage
    /// Server-derived labels for the two display slots. Claude still uses
    /// the stable 5h/week pair, while Codex can now omit the short window
    /// entirely and report its weekly bucket as `primary_window`.
    var shortWindowLabel: String?
    var weeklyWindowLabel: String?
    /// Provider-reported plan tier — Claude's `subscriptionType` (free/pro/max)
    /// or Codex's `plan_type` (free/plus/pro). nil when unknown.
    var plan: String?
    /// Model-scoped weekly window on plans that carry one (Claude Max's
    /// Fable/Opus bucket, from the usage endpoint's `limits[]` weekly_scoped
    /// entry). nil when the plan has no scoped limit — the UI shows no tile.
    var scopedWeekly: WindowUsage?
    /// Display name of the scoped model ("Fable"), server-provided so a
    /// renamed or additional flagship model needs no app update.
    var scopedLabel: String?
    /// Provider-requested quiet period after a rate-limit response. Keeping
    /// this structured avoids encoding retry scheduling in a UI error string.
    var retryAfter: TimeInterval?

    init(
        fiveHour: WindowUsage,
        weekly: WindowUsage,
        plan: String? = nil,
        shortWindowLabel: String? = "5h",
        weeklyWindowLabel: String? = "week",
        scopedWeekly: WindowUsage? = nil,
        scopedLabel: String? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
        self.shortWindowLabel = shortWindowLabel
        self.weeklyWindowLabel = weeklyWindowLabel
        self.scopedWeekly = scopedWeekly
        self.scopedLabel = scopedLabel
        self.retryAfter = retryAfter
    }

    /// Window used by the compact peek pill and approaching-limit alerts.
    /// Prefer the short bucket when one exists; weekly-only Codex plans fall
    /// back to the weekly bucket instead of showing a fabricated 5h value.
    var headlineWindow: WindowUsage {
        shortWindowLabel == nil ? weekly : fiveHour
    }

    var headlineWindowLabel: String {
        shortWindowLabel ?? weeklyWindowLabel ?? "usage"
    }

    var hasKnownValue: Bool {
        fiveHour.hasKnownValue || weekly.hasKnownValue || scopedWeekly?.hasKnownValue == true
    }

    func observed(at date: Date, source: UsageReadingSource) -> AppUsage {
        var usage = self
        usage.fiveHour = fiveHour.observed(at: date, source: source)
        usage.weekly = weekly.observed(at: date, source: source)
        if let scopedWeekly {
            usage.scopedWeekly = scopedWeekly.observed(at: date, source: source)
        }
        return usage
    }

    static let empty = AppUsage(fiveHour: .unknown, weekly: .unknown)

    /// Placeholder values shown when a provider is toggled off. Non-zero
    /// so the chart vocabulary stays visible (a 0% ring reads as broken,
    /// a 45% ring reads as "data we're choosing not to surface").
    static let dummy = AppUsage(
        fiveHour: WindowUsage(usedPercent: 0.45, resetAt: nil, error: nil),
        weekly: WindowUsage(usedPercent: 0.28, resetAt: nil, error: nil)
    )
}
