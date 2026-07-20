// AiosBroadcaster — Tony's fork integration boundary.
//
// Subscribes to UsageStore and POSTs each refresh to an external aiOS
// sidecar so its agent-avatar quota rings stay live across the team's
// hosts. Keeps codex-island as the single point of probing on a Mac;
// the sidecar just receives.
//
// Payload shape matches aiOS sidecar's POST /api/quota/ingest:
//   {
//     subscriptionId, owner, tier,
//     weekly:   { used: 0..1, resetAt: ms_epoch | null },
//     fiveHour: { used: 0..1, resetAt: ms_epoch | null },
//     host, ts, error?
//   }
//
// Defaults live in `AiosBroadcasterDefaults`; can be overridden via
// `defaults write com.codexisland.app AiosBroadcasterEndpoint <url>` etc.

import Foundation
import Combine

enum AiosBroadcasterDefaults {
    /// Empty string disables the broadcaster. The shipped fork has this set
    /// to the Apex Learn aiOS sidecar; other forks should override.
    static let endpoint = "https://aios.becoach.ai/api/quota/ingest"
    /// Owner identifier — matches the aiOS sidecar's OWNER_COLORS map.
    /// Each user of this fork sets their own (`defaults write …`).
    static let owner = "tony"
}

@MainActor
final class AiosBroadcaster {
    static let shared = AiosBroadcaster()
    private init() {}

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Reading happens lazily so tests / previews can override before start.
    private var endpoint: String {
        let v = UserDefaults.standard.string(forKey: "AiosBroadcasterEndpoint")
        return (v?.isEmpty == false ? v : AiosBroadcasterDefaults.endpoint) ?? ""
    }
    private var owner: String {
        let v = UserDefaults.standard.string(forKey: "AiosBroadcasterOwner")
        return (v?.isEmpty == false ? v : AiosBroadcasterDefaults.owner) ?? "tony"
    }

    func start() {
        guard !started else { return }
        started = true
        NSLog(
            "AiosBroadcaster.start endpoint=%@ owner=%@",
            endpoint,
            owner
        )
        UsageStore.shared.$lastRefreshAt
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] _ in self?.broadcast() }
            .store(in: &cancellables)
        // If UsageStore already finished its first refresh before we
        // subscribed (likely — App.swift starts the store first), broadcast
        // immediately. Otherwise the first user-visible broadcast waits a
        // full poll interval (default 5 min).
        if UsageStore.shared.lastRefreshAt != nil {
            NSLog("AiosBroadcaster.start: catching up an already-fresh refresh")
            broadcast()
        }
    }

    private func broadcast() {
        let endpoint = self.endpoint
        guard !endpoint.isEmpty, URL(string: endpoint) != nil else {
            NSLog("AiosBroadcaster.broadcast skipped — empty/invalid endpoint")
            return
        }
        NSLog("AiosBroadcaster.broadcast → %@", endpoint)

        let owner = self.owner
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let claude = UsageStore.shared.claude
        let codex = UsageStore.shared.codex
        let claudeStatus = UsageStore.shared.claudeStatus
        let codexStatus = UsageStore.shared.codexStatus

        Task.detached { [endpoint, owner, host] in
            await Self.send(
                endpoint: endpoint,
                subscriptionId: "\(owner)-claude",
                owner: owner,
                tier: "claude-\(claude.plan ?? "max")",
                label: "\(owner.capitalized) · Claude \((claude.plan ?? "max").capitalized)",
                app: claude,
                status: claudeStatus,
                host: host
            )
            await Self.send(
                endpoint: endpoint,
                subscriptionId: "\(owner)-codex",
                owner: owner,
                tier: "codex-\(codex.plan ?? "plus")",
                label: "\(owner.capitalized) · Codex \((codex.plan ?? "plus").capitalized)",
                app: codex,
                status: codexStatus,
                host: host
            )
        }
    }

    private static func send(
        endpoint: String,
        subscriptionId: String,
        owner: String,
        tier: String,
        label: String,
        app: AppUsage,
        status: UsageProviderStatus,
        host: String
    ) async {
        guard let url = URL(string: endpoint) else { return }
        let windowJSON = { (w: WindowUsage) -> [String: Any] in
            // The current aiOS v1 validator still requires a numeric `used`.
            // Keep that compatibility field while publishing `available` so
            // the v2 consumer can distinguish unknown from confirmed 0%.
            var out: [String: Any] = [
                "used": w.usedPercent,
                "available": w.hasKnownValue,
            ]
            if let r = w.resetAt {
                out["resetAt"] = Int(r.timeIntervalSince1970 * 1000)
            } else {
                out["resetAt"] = NSNull()
            }
            if let observedAt = w.observedAt {
                out["observedAt"] = Int(observedAt.timeIntervalSince1970 * 1000)
            }
            if let source = w.source {
                out["source"] = source.rawValue
            }
            return out
        }
        let providerTimestamp = status.lastSuccessAt ?? status.lastAttemptAt ?? Date()
        var body: [String: Any] = [
            "subscriptionId": subscriptionId,
            "owner": owner,
            "tier": tier,
            "label": label,
            "weekly": windowJSON(app.weekly),
            "fiveHour": windowJSON(app.fiveHour),
            "host": host,
            "schemaVersion": 2,
            "windowShape": app.shortWindowLabel == nil ? "weekly_only" : "dual",
            // Keep a failed poll from making cached values look newly observed
            // downstream. Individual windows also carry their own timestamp.
            "ts": Int(providerTimestamp.timeIntervalSince1970 * 1000),
            "fresh": status.isLive,
        ]
        if let scopedWeekly = app.scopedWeekly {
            body["scopedWeekly"] = windowJSON(scopedWeekly)
            body["scopedLabel"] = app.scopedLabel ?? "model"
        }
        let readings = [app.fiveHour, app.weekly] + (app.scopedWeekly.map { [$0] } ?? [])
        if let source = readings.compactMap(\.source).first {
            body["source"] = source.rawValue
        }
        // Propagate error so the sidecar / frontend can dim the rings as stale.
        let err = status.failure?.message
            ?? (app.hasKnownValue ? nil : (app.weekly.error ?? app.fiveHour.error))
        if let err { body["error"] = err }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                NSLog(
                    "AiosBroadcaster.send %@ → HTTP %d",
                    subscriptionId,
                    http.statusCode
                )
            }
        } catch {
            NSLog("AiosBroadcaster.send %@ FAILED: %@", subscriptionId, error.localizedDescription)
        }
    }
}
