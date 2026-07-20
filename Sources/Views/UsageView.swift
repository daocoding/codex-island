import SwiftUI
import AppKit

/// Usage data row. The chrome (provider titles, footer chip + page dots +
/// sync status) lives in `PanelHeader` / `PanelFooter` so it stays fixed
/// while this row swipes between usage and cost screens.
///
/// Branches on `(claudeOn, codexOn)` from `ProviderVisibilityStore`:
///   - both on:  two `ChartsBlock`s with a hairline divider (default).
///   - one on:   the live block on its native side, hairline, then a
///               per-model token breakdown filling the freed half.
///   - both off: a centered `BothHiddenPlaceholder`.
struct UsageView: View {
    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var pref = StylePref.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared

    private var style: ChartStyle { pref.style }

    var body: some View {
        let claudeOn = visibility.claudeVisible
        let codexOn = visibility.codexVisible

        TimelineView(.periodic(from: .now, by: 60)) { context in
            let claude = UsageSnapshotStore.sanitizedUsage(store.claude, now: context.date)
            let codex = UsageSnapshotStore.sanitizedUsage(store.codex, now: context.date)

            HStack(spacing: 0) {
                switch (claudeOn, codexOn) {
                case (true, true):
                    ChartsBlock(color: IslandColor.claude, usage: claude,
                                status: store.claudeStatus,
                                style: style, seed: 1, provider: .claude)
                    hairline
                    ChartsBlock(color: IslandColor.codex, usage: codex,
                                status: store.codexStatus,
                                style: style, seed: 3, provider: .codex)
                case (true, false):
                    ChartsBlock(color: IslandColor.claude, usage: claude,
                                status: store.claudeStatus,
                                style: style, seed: 1, provider: .claude)
                    hairline
                    PerModelBreakdown(provider: .claude, metric: .tokens)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 12)
                        .transition(breakdownTransition)
                case (false, true):
                    PerModelBreakdown(provider: .codex, metric: .tokens)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 12)
                        .transition(breakdownTransition)
                    hairline
                    ChartsBlock(color: IslandColor.codex, usage: codex,
                                status: store.codexStatus,
                                style: style, seed: 3, provider: .codex)
                case (false, false):
                    BothHiddenPlaceholder()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
    }

    /// Slight scale + opacity gives the breakdown half a sense of "expanding
    /// into the freed space" rather than a hard crossfade. Same curve the
    /// chart-style swap uses; reads as a single morph paired with the
    /// `withAnimation(.openMorph)` on the Settings toggle.
    private var breakdownTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97))
    }

    private var hairline: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, .white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}

struct ChartsBlock: View {
    let color: Color
    let usage: AppUsage
    let status: UsageProviderStatus
    let style: ChartStyle
    let seed: Int
    let provider: AlertEngine.Provider

    /// Only a missing-scope failure requires a fresh interactive login. A
    /// short-lived access-token expiry is not sign-out: CCD or Claude Code can
    /// renew it without asking the user to authenticate again.
    private var needsReauth: Bool {
        guard provider == .claude, let kind = status.failure?.kind else { return false }
        return kind.requiresInteractiveReauthentication
    }

    var body: some View {
        VStack(spacing: 6) {
            if needsReauth {
                ReauthState(color: color, message: status.failure?.message)
                    .transition(.chartSwap.animation(.chartSwap))
            } else {
                HStack(spacing: 18) {
                    if provider == .claude {
                        // Claude has three stable semantic slots; Fable is a
                        // server-scoped weekly bucket, not a Codex-style
                        // duration-adaptive window.
                        ChartTile(style: style, color: color, labelKey: "5h",
                                  window: usage.fiveHour, seed: seed,
                                  provider: provider, windowKind: .fiveHour)
                        ChartTile(style: style, color: color, labelKey: "week",
                                  window: usage.weekly, seed: seed + 1,
                                  provider: provider, windowKind: .weekly)
                        if let scoped = usage.scopedWeekly {
                            ChartTile(style: style, color: color,
                                      labelKey: usage.scopedLabel ?? "model",
                                      window: scoped, seed: seed + 4,
                                      provider: provider, windowKind: .scopedWeekly)
                        }
                    } else {
                        if let label = usage.shortWindowLabel {
                            ChartTile(style: style, color: color, labelKey: label,
                                      window: usage.fiveHour, seed: seed,
                                      provider: provider, windowKind: .fiveHour)
                        }
                        if let label = usage.weeklyWindowLabel {
                            ChartTile(style: style, color: color, labelKey: label,
                                      window: usage.weekly, seed: seed + 1,
                                      provider: provider, windowKind: .weekly)
                        }
                    }
                }
                .transition(.chartSwap.animation(.chartSwap))
            }

            if let statusMessage {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.failure == nil ? .white.opacity(0.32) : IslandColor.alertAmber)
                        .frame(width: 4, height: 4)
                    Text(statusMessage)
                        .font(Typography.micro)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
    }

    private var statusMessage: String? {
        let cachedPrefix: String? = {
            guard status.lastSuccessAt != nil || usage.hasKnownValue else { return nil }
            if status.source == .mixedLocalFallback { return L10n.tr("5h local") }
            guard let lastSuccessAt = status.lastSuccessAt else {
                return [readingOrigin, L10n.tr("cached")]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            }
            let age = Duration.compact(max(0, Date().timeIntervalSince(lastSuccessAt)))
            return [readingOrigin, L10n.tr("cached %@ ago", age)]
                .compactMap { $0 }
                .joined(separator: " · ")
        }()

        guard let failure = status.failure else {
            if status.source == .live {
                return readingOrigin.map { L10n.tr("Live via %@", $0) }
            }
            return status.source == .cached ? cachedPrefix : nil
        }

        let issue: String = {
            switch failure.kind {
            case .authenticationExpired:
                return provider == .claude
                    ? L10n.tr("waiting for CCD activity or Claude Code")
                    : L10n.tr("waiting for Codex Desktop")
            case .reauthenticationRequired:
                return L10n.tr("Claude sign-in needs renewal")
            case .rateLimited:
                if let retryAt = status.retryAt {
                    return L10n.tr(
                        "retry in %@",
                        Duration.compact(max(0, retryAt.timeIntervalSinceNow))
                    )
                }
                return L10n.tr("rate limited")
            case .transport, .other:
                return failure.message
            }
        }()
        return [cachedPrefix, issue].compactMap { $0 }.joined(separator: " · ")
    }

    private var readingOrigin: String? {
        let sources = [usage.fiveHour.source, usage.weekly.source, usage.scopedWeekly?.source]
            .compactMap { $0 }
        if sources.contains(.claudeDesktopBridge) { return "CCD" }
        if sources.contains(.codexDesktopSharedAuth) { return "CD" }
        if sources.contains(.claudeSharedCredential) { return L10n.tr("Claude shared auth") }
        if sources.contains(.localSessionLimit) { return L10n.tr("local session") }
        return nil
    }
}

/// Shown in place of the Claude tiles only when a fresh login is genuinely
/// required (missing OAuth scope). Ordinary access expiry keeps cached values
/// visible and waits for CCD or Claude Code to renew the shared credential.
struct ReauthState: View {
    let color: Color
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(color.opacity(0.85))
            if ClaudeCredentials.canPromptReauth() {
                Text(L10n.tr("Claude sign-in needs renewal"))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.55))
                ReauthButton()
            } else {
                Text(message ?? ClaudeCredentials.reauthRequiredMessage)
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 8)
    }
}

/// Inline action shown below the Claude tiles when the keychain token is
/// missing the scope the usage endpoint now requires. Spawns
/// `claude auth login` and polls for the keychain to update — the chip
/// recovers on its own when the new scoped token lands.
struct ReauthButton: View {
    @ObservedObject private var store = UsageStore.shared
    @State private var hovered = false

    var body: some View {
        Button {
            store.reauthenticateClaude()
        } label: {
            Text(store.claudeReauthInProgress ? L10n.tr("waiting for browser…") : L10n.tr("Re-authenticate"))
                .font(Typography.label)
                .foregroundStyle(.white.opacity(hovered && !store.claudeReauthInProgress ? 0.95 : 0.72))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(hovered && !store.claudeReauthInProgress ? 0.08 : 0.04))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .disabled(store.claudeReauthInProgress)
        .onHover { hovered = $0 }
        .animation(.hoverFade, value: hovered)
        .animation(.hoverFade, value: store.claudeReauthInProgress)
    }
}

struct ChartTile: View {
    let style: ChartStyle
    let color: Color
    let labelKey: String
    let window: WindowUsage
    let seed: Int
    let provider: AlertEngine.Provider
    let windowKind: UsageWindow
    @ObservedObject private var usageDisplay = UsageDisplayModeStore.shared
    @ObservedObject private var historyStore = UsageHistoryStore.shared

    /// Locked tile height across all 5 styles so the panel size is
    /// identical regardless of what the user picks.
    private static let tileHeight: CGFloat = 96

    var body: some View {
        let value = window.displayedFraction(mode: usageDisplay.mode) * 100   // 0-100
        let sub = subCaption()
        let label = L10n.tr(labelKey)

        Group {
            if window.hasKnownValue {
                switch style {
                case .ring:    RingChart(value: value, color: color, label: label, sub: sub)
                case .bar:     BarChart(value: value, color: color, label: label, sub: sub)
                case .stepped: SteppedChart(value: value, color: color, label: label, sub: sub)
                case .numeric: NumericChart(value: value, color: color, label: label, sub: compactSubCaption())
                case .spark:   SparkChart(value: value, color: color, label: label, sub: sub,
                                          seed: seed, history: historyPoints())
                }
            } else {
                UnavailableChart(label: label)
            }
        }
        .id(style)
        // Blur + scale + opacity, all on the same strong ease-out at 220ms.
        // The blur masks the geometric mismatch between Ring and Bar so the
        // crossfade reads as one morph instead of two stacked objects.
        .transition(.chartSwap.animation(.chartSwap))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: Self.tileHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            window.hasKnownValue
                ? L10n.tr("%@, %d%%", label, Int(value))
                : L10n.tr("%@, unavailable", label)
        )
        .accessibilityValue(subCaption())
    }

    /// Recorded readings for this window, mapped through the active
    /// used/remaining mode into display percent (0-100), oldest first — the
    /// same transform `value` uses, so the history and the live point agree.
    private func historyPoints() -> [Double] {
        let mode = usageDisplay.mode
        return historyStore.samples(provider: provider, window: windowKind).map { sample in
            WindowUsage(usedPercent: sample.used, resetAt: nil, error: nil)
                .displayedFraction(mode: mode) * 100
        }
    }

    private func subCaption() -> String {
        if let r = window.resetAt {
            let delta = max(0, r.timeIntervalSinceNow)
            return L10n.tr("resets in %@", Duration.compact(delta))
        }
        // "no data" is our internal sentinel for "API returned null for this
        // window" — most commonly a brand-new 5h period before the first
        // OAuth call lands. Hide it so the tile reads as a passive
        // window-context cue (the "5h"/"week" header label communicates the
        // window type) instead of looking broken. Real errors still surface.
        // A missing-scope failure is handled by ReauthState (which replaces
        // the Claude tiles), so any error reaching a tile here is a genuine
        // per-window caption worth showing verbatim.
        if let err = window.error, err != "no data" {
            return err
        }
        return ""
    }

    private func compactSubCaption() -> String {
        if let r = window.resetAt {
            let delta = max(0, r.timeIntervalSinceNow)
            return "↻ " + Duration.compact(delta)
        }
        if let err = window.error, err != "no data" {
            return err
        }
        return ""
    }
}

private struct UnavailableChart: View {
    let label: String

    var body: some View {
        VStack(spacing: 7) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(.white.opacity(0.42))
                .textCase(.lowercase)
            Text("—")
                .font(Typography.chartValue)
                .foregroundStyle(.white.opacity(0.28))
            Text(L10n.tr("unavailable"))
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
