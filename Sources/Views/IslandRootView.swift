import SwiftUI
import AppKit

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @State private var hovering = false
    @State private var contentVisible = false
    @State private var pillsVisible = false
    @State private var pulseToken: UUID?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            // Only the rotating loading sweep needs per-frame re-renders
            // (its angle is a function of time). Everything else animates
            // via withAnimation springs paced by display sync, so wrapping
            // the whole tree in TimelineView would re-build every overlay
            // and every gesture closure 120 times per second — competing
            // with the spring for main-thread budget and showing up as
            // hover-spring jank.
            ZStack {
                GlowLayer(
                    isExpanded: model.state == .expanded,
                    hovering: hovering
                )

                if model.state == .expanded {
                    ExpandedView(model: model)
                        .opacity(contentVisible ? 1 : 0)
                        // Slide down from -8 → 0 on enter pairs with the
                        // 100ms→180ms opacity delay set in onHover. On
                        // exit the offset never matters because the
                        // content fully fades before the shape shrinks.
                        .offset(y: contentVisible ? 0 : -8)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .allowsHitTesting(contentVisible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: model.size.width, height: model.size.height)
            .background {
                    // Frosted halo. ultraThinMaterial is a backdrop blur of
                    // whatever desktop content is behind the window. Lives
                    // in .background AFTER .frame so it doesn't push the
                    // ZStack's layout box larger than model.size — earlier
                    // attempts that put the halo as a sibling inside the
                    // ZStack with its own oversized .frame ended up
                    // expanding the parent bounds, throwing the logo
                    // overlays off and breaking the compact pill alignment
                    // with the physical notch.
                    //
                    // .padding(-9) extends only the rendering by 9pt past
                    // the silhouette on every side, no layout impact.
                    // Opacity tied to contentVisible so it fades alongside
                    // the panel content (220ms after hover-in, immediately
                    // on hover-out) and the .frame here tracks model.size,
                    // so the halo grows/shrinks with the spring morph.
                    //
                    // Purely decorative, so Reduce Transparency drops it
                    // entirely — the solid black silhouette is the UI.
                    if !reduceTransparency {
                        IslandShape()
                            .fill(.ultraThinMaterial)
                            .padding(-9)
                            .blur(radius: 8)
                            .opacity(contentVisible ? 0.55 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.state != .expanded {
                        CompactProviderRail(
                            provider: .claude,
                            sideWidth: model.sideWidth,
                            showsSummary: pillsVisible
                        )
                        .frame(
                            width: model.sideWidth,
                            height: model.notch.height,
                            alignment: .trailing
                        )
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.state != .expanded {
                        CompactProviderRail(
                            provider: .codex,
                            sideWidth: model.sideWidth,
                            showsSummary: pillsVisible
                        )
                        .frame(
                            width: model.sideWidth,
                            height: model.notch.height,
                            alignment: .leading
                        )
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // Utility control, not dashboard status. Keep it in a
                    // quiet corner so the footer remains about live data.
                    if model.state == .expanded {
                        SettingsButton()
                            .opacity(contentVisible ? 1 : 0)
                            .padding(6)
                    }
                }
                .contentShape(IslandShape())
                .onTapGesture {
                    // Cmd-click cycles the visualization style of whichever
                    // page is active. Usage rotates Ring/Bar/Stepped/Numeric/
                    // Spark; cost rotates USD/VALUE/TOKENS/TREND. Overview
                    // is fixed to year-to-date.
                    if NSEvent.modifierFlags.contains(.command) {
                        switch ScreenPref.shared.screen {
                        case .usage: StylePref.shared.cycle()
                        case .cost:  CostStylePref.shared.cycle()
                        case .overview: return
                        }
                        return
                    }
                    // Plain click: enter the full panel. Works from .peek
                    // (the common case after hover) or .compact (cold click).
                    // Pills travel outward with the growing shape under the
                    // single openMorph spring, then quietly retire after the
                    // expanded content has settled.
                    guard model.state == .peek || model.state == .compact else { return }
                    withAnimation(.openMorph) {
                        model.setState(.expanded)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        guard model.state == .expanded else { return }
                        withAnimation(.strongEaseOut) {
                            contentVisible = true
                        }
                    }
                    // Guard against a hover-out landing inside the 250ms
                    // wait: under always-show it restores the pills at peek,
                    // and this stale callback would hide them again — leaving
                    // the rest state pill-less until the next hover cycle.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        guard model.state == .expanded else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            pillsVisible = false
                        }
                    }
                }
                .onHover { h in
                    hovering = h
                    if h {
                        // Hover is a precision reveal, not an alert. The
                        // silhouette extends symmetrically and exact values
                        // arrive just after the geometry starts moving.
                        if model.state == .compact {
                            withAnimation(.openMorph) {
                                model.setState(.peek)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                                guard model.state == .peek else { return }
                                withAnimation(.easeOut(duration: 0.18)) {
                                    pillsVisible = true
                                }
                            }
                        }
                    } else {
                        // Exact values retire before the extra hover width;
                        // both gauges remain visible in the 261pt rest
                        // instrument throughout the transition.
                        withAnimation(.easeOut(duration: 0.08)) {
                            pillsVisible = false
                        }
                        withAnimation(.easeOut(duration: 0.10)) {
                            contentVisible = false
                        }
                        // Start the shape morph after only 20ms — overlapping
                        // with the content fade — so the silhouette begins
                        // shrinking while the content is still fading out.
                        // The original 100ms wait caused a visible "flash black"
                        // because the full-size black shape was exposed for the
                        // entire fade before the closeMorph fired.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                            guard !hovering else { return }
                            if model.state != .compact {
                                withAnimation(.closeMorph) {
                                    model.setState(.compact)
                                }
                            }
                        }
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("CodexIsland panel"))
        .accessibilityHint(accessibilityHintForState)
        .onAppear {
            // The gauges are the resting product now. Launch compact and let
            // hover temporarily reveal exact values without a preference.
            if model.state != .compact { model.setState(.compact) }
            pillsVisible = false
        }
        .onReceive(AlertEngine.shared.$pulseEvent) { event in
            guard let event, event.id != pulseToken else { return }
            pulseToken = event.id
            handlePulse(event)
            // Consume the event so a re-emission with the same id doesn't
            // re-trigger; the engine writes a fresh PulseEvent for each new
            // crossing tick.
            AlertEngine.shared.pulseEvent = nil
        }
    }

    /// Force-extends the island into peek state for ~4s when the alert
    /// engine signals a fresh threshold crossing. Suppressed when the panel
    /// is already expanded — the user is already looking at the data.
    private func handlePulse(_ event: AlertEngine.PulseEvent) {
        guard model.state != .expanded else { return }

        if model.state == .compact {
            withAnimation(.openMorph) {
                model.setState(.peek)
            }
            // Match the hover-in cadence so the pulse looks identical to a
            // user-initiated peek: shape commits first, content follows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard model.state == .peek else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    pillsVisible = true
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            // If the user is hovering or has expanded the panel meanwhile,
            // don't fight their state — let their interaction own the peek
            // lifecycle from here. Otherwise return to the fixed compact
            // instrument after the temporary exact-value reveal.
            guard !hovering, model.state == .peek else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                pillsVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard !hovering, model.state == .peek else { return }
                withAnimation(.closeMorph) {
                    model.setState(.compact)
                }
            }
        }
    }

    private var accessibilityHintForState: String {
        switch model.state {
        case .compact:
            return L10n.tr("Hover for exact usage. Click to expand. Command-click to cycle visualization.")
        case .peek:     return L10n.tr("Click to expand. Command-click to cycle visualization.")
        case .expanded:
            return ScreenPref.shared.screen == .overview
                ? L10n.tr("Swipe to change pages.")
                : L10n.tr("Command-click to cycle visualization.")
        }
    }

}

/// Silhouette + halo + animated sweep. Bundles every layer whose
/// appearance depends on alert severity or the Low Power Mode event
/// predicate, so a UsageStore/AlertEngine/CostStore emission only
/// invalidates this child's body — not the root view's overlays,
/// gestures, or expanded-content branch.
private struct GlowLayer: View {
    let isExpanded: Bool
    let hovering: Bool

    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var costStore = CostStore.shared
    @ObservedObject private var lowPower = LowPowerModeStore.shared
    @ObservedObject private var alerts = AlertEngine.shared
    @ObservedObject private var occlusion = WindowOcclusionStore.shared

    var body: some View {
        ZStack {
            LoadingSweep(
                active: !occlusion.isOccluded
                    && (lowPower.effectiveEnabled ? glowEventActive : true),
                tint: glowColor
            )

            IslandShape()
                .fill(.black)
                .overlay {
                    IslandShape()
                        .strokeBorder(
                            .white.opacity(isExpanded ? 0.12 : 0),
                            lineWidth: 0.5
                        )
                }
                // Halo follows LPM's event predicate: under LPM it's
                // suppressed at rest and lights up only on refresh,
                // hover, or an active alert. Off-LPM it stays at the
                // ambient 0.35 the way it always has.
                .shadow(
                    color: glowColor.opacity(
                        lowPower.effectiveEnabled ? (glowEventActive ? 0.35 : 0) : 0.35
                    ),
                    radius: 14, y: 0
                )
                .animation(.easeInOut(duration: 0.25), value: glowEventActive)
                // 0.45s cross-fade so a threshold crossing (e.g. 79%→80%)
                // doesn't visibly snap the hue from cobalt to amber.
                .animation(.easeInOut(duration: 0.45), value: alerts.severity)
                .shadow(
                    color: isExpanded ? .black.opacity(0.5) : .clear,
                    radius: 20, y: 10
                )
        }
    }

    /// Under Low Power Mode the halo + sweep are gated on this predicate:
    /// the user sees glow only when something is happening (a fetch is in
    /// flight, the cursor is hovering, or an alert is active). Off-LPM it's
    /// ignored — both surfaces run continuously.
    private var glowEventActive: Bool {
        hovering
            || usageStore.loading
            || costStore.loading
            || alerts.severity != .none
    }

    /// Silhouette glow color. Cobalt is the ambient default; alert
    /// thresholds replace it with amber/red so the user gets the signal
    /// passively, even before hovering. All three share the same opacity
    /// so the glow's visual weight is constant — only the hue signals
    /// severity.
    private var glowColor: Color {
        switch alerts.severity {
        case .none:     return IslandColor.cobalt
        case .warning:  return IslandColor.alertAmber
        case .critical: return IslandColor.alertRed
        }
    }
}

/// One provider's compact rail. At rest only the 30pt gauge occupies the
/// 38pt side extension. Hover grows that same rail outward and reveals exact
/// percentages while the gauge stays anchored beside the physical notch.
private struct CompactProviderRail: View {
    let provider: AlertEngine.Provider
    let sideWidth: CGFloat
    let showsSummary: Bool

    var body: some View {
        HStack(spacing: 4) {
            if provider == .claude {
                if showsSummary {
                    CompactUsageSummary(provider: provider)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity.combined(with: .offset(x: 3)))
                }
                CompactProviderGauge(provider: provider)
            } else {
                CompactProviderGauge(provider: provider)
                if showsSummary {
                    CompactUsageSummary(provider: provider)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .offset(x: -3)))
                }
            }
        }
        .frame(
            width: max(30, sideWidth - 4),
            alignment: provider == .claude ? .trailing : .leading
        )
        .frame(
            width: sideWidth,
            alignment: provider == .claude ? .leading : .trailing
        )
        .clipped()
    }
}

/// Exact values are deliberately secondary to the glanceable rings. They
/// appear only in the transient hover width and use fixed-width numerals so
/// refreshes do not make the rail visibly jump.
private struct CompactUsageSummary: View {
    let provider: AlertEngine.Provider

    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var usageDisplay = UsageDisplayModeStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let rawUsage = provider == .claude ? usageStore.claude : usageStore.codex
            let usage = UsageSnapshotStore.sanitizedUsage(rawUsage, now: context.date)
            VStack(
                alignment: provider == .claude ? .trailing : .leading,
                spacing: 1
            ) {
                if provider == .claude {
                    Text("5h \(percent(usage.fiveHour))")
                    Text("W \(percent(usage.weekly)) · F \(percent(usage.scopedWeekly))")
                } else {
                    Text("WEEK \(percent(codexWeeklyWindow(in: usage)))")
                }
            }
        }
        .font(.system(size: 7, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private func percent(_ window: WindowUsage?) -> String {
        guard let window, window.hasKnownValue else { return "—" }
        return "\(window.displayedPercentInt(mode: usageDisplay.mode))%"
    }

    private func codexWeeklyWindow(in usage: AppUsage) -> WindowUsage {
        usage.weeklyWindowLabel == nil ? usage.headlineWindow : usage.weekly
    }
}

/// Provider usage compressed into the original 38pt logo slot. Claude uses
/// three concentric rings (outer Fable, middle week, inner 5h); Codex uses a
/// single weekly ring. Both centers mean the same thing: weekly reset time.
private struct CompactProviderGauge: View {
    let provider: AlertEngine.Provider

    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var usageDisplay = UsageDisplayModeStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let currentUsage = UsageSnapshotStore.sanitizedUsage(usage, now: context.date)
            ZStack {
                if provider == .claude {
                    CompactUsageRing(
                        window: currentUsage.scopedWeekly ?? .unknown,
                        diameter: 30,
                        color: tint
                    )
                    CompactUsageRing(
                        window: currentUsage.weekly,
                        diameter: 24,
                        color: tint.opacity(0.82)
                    )
                    CompactUsageRing(
                        window: currentUsage.fiveHour,
                        diameter: 18,
                        color: tint.opacity(0.64)
                    )
                } else {
                    CompactUsageRing(
                        window: codexWeeklyWindow(in: currentUsage),
                        diameter: 30,
                        color: tint
                    )
                }

                Text(resetText(for: weeklyResetWindow(in: currentUsage), at: context.date))
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 24)

                if providerStatus.failure != nil {
                    Circle()
                        .fill(IslandColor.alertAmber)
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: 11.5, y: -11.5)
                }
            }
            .frame(width: 30, height: 30)
            .opacity(isVisible ? (providerStatus.isStale ? 0.62 : 1) : 0)
            .animation(.openMorph, value: isVisible)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(providerLabel)
            .accessibilityValue(accessibilityValue(for: currentUsage, at: context.date))
            .accessibilityHidden(!isVisible)
        }
    }

    private var isVisible: Bool {
        visibility.effectiveVisible(provider: provider)
    }

    private var usage: AppUsage {
        switch provider {
        case .claude: return usageStore.claude
        case .codex:  return usageStore.codex
        }
    }

    private var providerStatus: UsageProviderStatus {
        usageStore.status(for: provider)
    }

    private func codexWeeklyWindow(in usage: AppUsage) -> WindowUsage {
        usage.weeklyWindowLabel == nil ? usage.headlineWindow : usage.weekly
    }

    private func weeklyResetWindow(in usage: AppUsage) -> WindowUsage {
        provider == .claude ? usage.weekly : codexWeeklyWindow(in: usage)
    }

    private var tint: Color {
        switch provider {
        case .claude: return IslandColor.claude
        case .codex:  return IslandColor.codex
        }
    }

    private var providerLabel: String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    private func resetText(for window: WindowUsage, at date: Date) -> String {
        guard let resetAt = window.resetAt else { return "—" }
        let remaining = resetAt.timeIntervalSince(date)
        guard remaining > 0 else { return "0m" }
        if remaining < 60 { return "<1m" }
        // The ring center is a 24pt slot. Expanded captions can afford
        // upstream's `6d 23h`, but the permanent notch instrument needs the
        // deliberately glanceable day-only form Tony chose (`6d`).
        if remaining >= 86_400 {
            return "\(Int(remaining / 86_400))d"
        }
        return Duration.compact(remaining)
    }

    private func accessibilityValue(for usage: AppUsage, at date: Date) -> String {
        let reset = resetText(for: weeklyResetWindow(in: usage), at: date)
        let freshness = providerStatus.isStale ? "cached or unavailable, " : ""
        switch provider {
        case .claude:
            return freshness + "5 hour \(accessiblePercent(usage.fiveHour)), "
                + "week \(accessiblePercent(usage.weekly)), "
                + "\(usage.scopedLabel ?? "Fable") \(accessiblePercent(usage.scopedWeekly)), "
                + "weekly reset \(reset)"
        case .codex:
            return freshness + "week \(accessiblePercent(codexWeeklyWindow(in: usage))), "
                + "weekly reset \(reset)"
        }
    }

    private func accessiblePercent(_ window: WindowUsage?) -> String {
        guard let window, window.hasKnownValue else { return "unavailable" }
        return "\(window.displayedPercentInt(mode: usageDisplay.mode)) percent"
    }
}

private struct CompactUsageRing: View {
    let window: WindowUsage
    let diameter: CGFloat
    let color: Color

    @ObservedObject private var usageDisplay = UsageDisplayModeStore.shared

    var body: some View {
        let fraction = window.displayedFraction(mode: usageDisplay.mode)
        ZStack {
            Circle()
                .stroke(.white.opacity(hasValue ? 0.09 : 0.05), lineWidth: 2)
            Circle()
                .trim(from: 0, to: ringFraction(fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.strongEaseOut, value: fraction)
        }
        .frame(width: diameter, height: diameter)
    }

    private var hasValue: Bool {
        window.hasKnownValue
    }

    private func ringFraction(_ fraction: Double) -> Double {
        guard hasValue else { return 0 }
        return max(0.001, min(1, fraction))
    }
}

/// Cobalt angular-gradient sweep that orbits the silhouette while data is
/// fetching. Owns its own TimelineView so the parent (IslandRootView) doesn't
/// re-render every overlay alongside the sweep — that was competing with the
/// hover spring for main-thread budget.
///
/// Tick rate is 30Hz (was 120Hz). 3.6s/revolution at 30Hz = 12° per frame,
/// indistinguishable from 120Hz to the eye for a slow continuous orbit but
/// 4× cheaper on the main thread. The bigger CPU saving comes from gating
/// `active` on `!isWindowOccluded` upstream — when a fullscreen app or
/// another window covers the menu bar entirely, the sweep stops rendering
/// (the user can't see it anyway), dropping idle CPU to ~0%.
///
/// Earlier attempts to push rotation into Core Animation (CAGradientLayer or
/// `.rotationEffect` over a static gradient) all subtly changed the glow
/// feel — SwiftUI's per-frame conic re-shading produces an alive,
/// atmospheric look that a rotated static texture loses. This is the
/// minimum-cost approach that preserves the exact original render.
private struct LoadingSweep: View {
    let active: Bool
    /// Color of the orbiting trail. Cobalt by default; switches to amber
    /// or red while the alert engine reports a tracked window above its
    /// warning/critical threshold so the entire glow shares one hue.
    let tint: Color

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let rotation = (t * 100).truncatingRemainder(dividingBy: 360)
                IslandShape()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: tint.opacity(0.0), location: 0.55),
                                .init(color: tint, location: 0.78),
                                .init(color: .white.opacity(0.95), location: 0.92),
                                .init(color: tint.opacity(0.0), location: 1.00),
                            ]),
                            center: .center,
                            angle: .degrees(rotation)
                        ),
                        lineWidth: 4
                    )
                    .blur(radius: 3)
            }
        }
    }
}
