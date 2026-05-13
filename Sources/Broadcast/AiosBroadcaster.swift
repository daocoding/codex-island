// AiosBroadcaster — Apex Learn fork addition.
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
    /// Minimum seconds between broadcasts to avoid spamming the sidecar
    /// (UsageStore refreshes can fire faster than this in some edge cases).
    static let minIntervalSeconds: TimeInterval = 30
}

@MainActor
final class AiosBroadcaster {
    static let shared = AiosBroadcaster()
    private init() {}

    private var cancellables = Set<AnyCancellable>()
    private var lastBroadcastAt: Date = .distantPast
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
        UsageStore.shared.$lastUpdated
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] _ in self?.maybeBroadcast() }
            .store(in: &cancellables)
    }

    private func maybeBroadcast() {
        let endpoint = self.endpoint
        guard !endpoint.isEmpty, URL(string: endpoint) != nil else { return }
        let now = Date()
        if now.timeIntervalSince(lastBroadcastAt)
            < AiosBroadcasterDefaults.minIntervalSeconds {
            return
        }
        lastBroadcastAt = now

        let owner = self.owner
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let claude = UsageStore.shared.claude
        let codex = UsageStore.shared.codex

        Task.detached { [endpoint, owner, host] in
            await Self.send(
                endpoint: endpoint,
                subscriptionId: "\(owner)-claude",
                owner: owner,
                tier: "claude-\(claude.plan ?? "max")",
                label: "\(owner.capitalized) · Claude \((claude.plan ?? "max").capitalized)",
                app: claude,
                host: host
            )
            await Self.send(
                endpoint: endpoint,
                subscriptionId: "\(owner)-codex",
                owner: owner,
                tier: "codex-\(codex.plan ?? "plus")",
                label: "\(owner.capitalized) · Codex \((codex.plan ?? "plus").capitalized)",
                app: codex,
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
        host: String
    ) async {
        guard let url = URL(string: endpoint) else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let windowJSON = { (w: WindowUsage) -> [String: Any] in
            var out: [String: Any] = ["used": w.usedPercent]
            if let r = w.resetAt {
                out["resetAt"] = Int(r.timeIntervalSince1970 * 1000)
            } else {
                out["resetAt"] = NSNull()
            }
            return out
        }
        var body: [String: Any] = [
            "subscriptionId": subscriptionId,
            "owner": owner,
            "tier": tier,
            "label": label,
            "weekly": windowJSON(app.weekly),
            "fiveHour": windowJSON(app.fiveHour),
            "host": host,
            "ts": nowMs,
        ]
        // Propagate error so the sidecar / frontend can dim the rings as stale.
        let err = app.weekly.error ?? app.fiveHour.error
        if let err { body["error"] = err }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                NSLog(
                    "AiosBroadcaster: %@ → HTTP %d",
                    subscriptionId,
                    http.statusCode
                )
            }
        } catch {
            NSLog("AiosBroadcaster: %@ failed: %@", subscriptionId, error.localizedDescription)
        }
    }
}
