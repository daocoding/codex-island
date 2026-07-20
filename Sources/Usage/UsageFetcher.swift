import Foundation

enum UsageFetcher {
    // MARK: - Codex

    /// Codex usage lives at chatgpt.com/backend-api/wham/usage and accepts
    /// the access_token from ~/.codex/auth.json. The endpoint is reliable
    /// and rarely rate-limited, so this is the easy half of the integration.
    static func fetchCodex() async -> AppUsage {
        guard let token = readCodexAccessToken() else {
            return errorPair("no codex auth")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 401 means the access_token in ~/.codex/auth.json has expired.
            // Codex Desktop's bundled app-server and the standalone CLI both
            // use this shared store and rotate it during active use. We stay
            // read-only and wait for either official surface to refresh it.
            if status == 401 {
                return errorPair("auth expired — open Codex Desktop")
            }
            if status != 200 {
                return errorPair("http \(status)")
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rl = obj["rate_limit"] as? [String: Any] else {
                return errorPair("parse error")
            }
            return parseCodexUsage(rl, plan: obj["plan_type"] as? String)
        } catch {
            return errorPair(error.localizedDescription)
        }
    }

    private static func errorPair(_ message: String, retryAfter: TimeInterval? = nil) -> AppUsage {
        AppUsage(
            fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: message),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: message),
            retryAfter: retryAfter
        )
    }

    private static func readCodexAccessToken() -> String? {
        let path = NSString("~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return token
    }

    private struct ParsedCodexWindow {
        let usage: WindowUsage
        let limitSeconds: Int?
    }

    /// Codex historically returned a 5h `primary_window` plus a weekly
    /// `secondary_window`. The endpoint now also returns weekly-only plans,
    /// with the 7d bucket in `primary_window`. Classify by the server's
    /// `limit_window_seconds` instead of assigning meaning from key order.
    static func parseCodexUsage(_ rateLimit: [String: Any], plan: String? = nil) -> AppUsage {
        let primary = parseCodexWindow(rateLimit["primary_window"])
        let secondary = parseCodexWindow(rateLimit["secondary_window"])
        let windows = [primary, secondary].compactMap { $0 }

        // Preserve the legacy mapping for older responses that do not expose
        // durations. This keeps existing accounts working during a staggered
        // server rollout.
        guard windows.contains(where: { $0.limitSeconds != nil }) else {
            return AppUsage(
                fiveHour: primary?.usage ?? .unknown,
                weekly: secondary?.usage ?? .unknown,
                plan: plan
            )
        }

        let short = windows.first { ($0.limitSeconds ?? 0) < 86_400 }
        let weekly = windows.first { ($0.limitSeconds ?? 0) >= 86_400 }
        return AppUsage(
            fiveHour: short?.usage ?? .unknown,
            weekly: weekly?.usage ?? .unknown,
            plan: plan,
            shortWindowLabel: short.flatMap { durationLabel(seconds: $0.limitSeconds) },
            weeklyWindowLabel: weekly.flatMap { durationLabel(seconds: $0.limitSeconds) }
        )
    }

    private static func parseCodexWindow(_ obj: Any?) -> ParsedCodexWindow? {
        guard let d = obj as? [String: Any] else { return nil }
        let used = (d["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let resetAt = (d["reset_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        let limitSeconds = (d["limit_window_seconds"] as? NSNumber)?.intValue
        return ParsedCodexWindow(
            usage: WindowUsage(usedPercent: used / 100, resetAt: resetAt, error: nil),
            limitSeconds: limitSeconds
        )
    }

    private static func durationLabel(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds == 7 * 86_400 { return "week" }
        if seconds.isMultiple(of: 7 * 86_400) { return "\(seconds / (7 * 86_400))w" }
        if seconds.isMultiple(of: 86_400) { return "\(seconds / 86_400)d" }
        if seconds.isMultiple(of: 3_600) { return "\(seconds / 3_600)h" }
        return "\(seconds / 60)m"
    }

    static func fetchCodexResetCredits() async -> CodexResetCredits? {
        guard let token = readCodexAccessToken() else { return nil }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let availableCount = (obj["available_count"] as? Int) ?? 0
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            let rawCredits: [[String: Any]] = (obj["credits"] as? [[String: Any]]) ?? []
            let credits: [CodexResetCredit] = rawCredits.compactMap { item -> CodexResetCredit? in
                guard let id = item["id"] as? String,
                      let status = item["status"] as? String,
                      let expiresRaw = item["expires_at"] as? String,
                      let expiresAt = formatter.date(from: expiresRaw)
                        ?? fallbackFormatter.date(from: expiresRaw)
                else { return nil }

                return CodexResetCredit(
                    id: id,
                    status: status,
                    expiresAt: expiresAt,
                    title: item["title"] as? String ?? "",
                    description: item["description"] as? String ?? ""
                )
            }

            return CodexResetCredits(availableCount: availableCount, credits: credits)
        } catch {
            return nil
        }
    }

    // MARK: - Claude

    /// Anthropic doesn't ship a usage endpoint for end users — Claude Code
    /// itself talks to api.anthropic.com/api/oauth/usage with a beta header
    /// and a User-Agent that identifies as the CLI. We replicate that.
    ///
    /// Token acquisition (env → keychain, strictly read-only) lives behind
    /// `ClaudeCredentials`. We hand it the usage probe and render its
    /// resolution: a parsed `AppUsage`, or an error caption (re-auth or last
    /// error) via `errorPair`.
    static func fetchClaude() async -> UsageFetchResult {
        let resolution = await ClaudeCredentials.resolveUsage { token, plan in
            await fetchClaudeUsage(token: token, plan: plan)
        }
        switch resolution {
        case .usage(let usage):
            return .success(usage)
        case .reauthRequired(let message):
            return .failure(UsageFetchFailure(
                kind: .reauthenticationRequired,
                message: message
            ))
        case .failed(let msg, let retryAfter):
            let kind: UsageFailureKind
            switch msg {
            case ClaudeCredentials.tokenExpiredMessage:
                kind = .authenticationExpired
            case ClaudeCredentials.rateLimitedMessage:
                kind = .rateLimited
            case ClaudeCredentials.reauthRequiredMessage:
                kind = .reauthenticationRequired
            default:
                kind = .other
            }
            return .failure(UsageFetchFailure(
                kind: kind,
                message: msg,
                retryAfter: retryAfter
            ))
        }
    }

    private static func fetchClaudeUsage(token: String, plan: String?) async -> ClaudeCredentials.ProbeOutcome {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic gates this endpoint on a CLI User-Agent. Without it the
        // request 401s even with a valid token.
        req.setValue("claude-code/2.1.121", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .otherError("bad response")
            }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 403 { return .scopeInsufficient }
            if http.statusCode == 429 {
                return .rateLimited(retryAfter: retryAfter(from: http))
            }
            guard http.statusCode == 200 else {
                return .otherError("HTTP \(http.statusCode)")
            }
            // The endpoint also returns 200 with a rate_limit_error body
            // sometimes; don't trust the status code alone.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = obj["error"] as? [String: Any],
                   let type = err["type"] as? String, type == "rate_limit_error" {
                    return .rateLimited(retryAfter: retryAfter(from: http))
                }
                let fiveHour = parseClaudeWindow(obj["five_hour"])
                let weekly = parseClaudeWindow(obj["seven_day"])
                let scoped = parseClaudeScopedWeekly(obj)
                let usage = AppUsage(
                    fiveHour: fiveHour,
                    weekly: weekly,
                    plan: plan,
                    scopedWeekly: scoped?.window,
                    scopedLabel: scoped?.label
                )
                guard usage.hasKnownValue else {
                    // A 200 with an unfamiliar/missing percentage schema is
                    // not a real 0% reading. Preserve the last useful snapshot
                    // and surface one provider parse failure instead.
                    return .otherError("parse error")
                }
                return .success(usage)
            }
            return .otherError("parse error")
        } catch {
            return .otherError(error.localizedDescription)
        }
    }

    /// Anthropic currently sends delta-seconds (for example `3577`), while
    /// RFC 9110 also permits an HTTP date. Support both forms.
    static func parseRetryAfter(_ raw: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
    }

    static func parseClaudeWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        // Anthropic returns `utilization` as a percentage in [0, 100], not a
        // normalized [0, 1] fraction. An earlier `raw > 1 ? raw / 100 : raw`
        // heuristic broke the moment the 5h window reset: utilization values
        // in (0, 1] (e.g. 0.5% used → 0.5) were treated as already-normalized
        // and rendered as 50%–100%. Always divide by 100; clamp below.
        guard let raw = (d["utilization"] as? NSNumber)?.doubleValue
            ?? (d["used_percent"] as? NSNumber)?.doubleValue
        else { return .unknown }
        let normalized = raw / 100.0
        return WindowUsage(
            usedPercent: min(1, max(0, normalized)),
            resetAt: parseClaudeResetDate(d["resets_at"]),
            error: nil
        )
    }

    /// Model-scoped weekly bucket (Max plans' separate flagship-model limit).
    /// The modern shape is the `limits[]` array: the `weekly_scoped` entry
    /// carries `percent` plus the model's display name ("Fable") under
    /// `scope.model` — the legacy `seven_day_opus` field is null on Claude
    /// 5-family plans. Fall back to it for accounts still on the old shape.
    /// Internal (not private) so ResolveUsageTests can lock the parse against
    /// a captured real response.
    static func parseClaudeScopedWeekly(_ obj: [String: Any]) -> (window: WindowUsage, label: String)? {
        if let limits = obj["limits"] as? [[String: Any]] {
            for entry in limits where (entry["kind"] as? String) == "weekly_scoped" {
                guard let percent = entry["percent"] as? Double else { continue }
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let window = WindowUsage(
                    usedPercent: min(1, max(0, percent / 100.0)),
                    resetAt: parseClaudeResetDate(entry["resets_at"]),
                    error: nil
                )
                return (window, (model?["display_name"] as? String) ?? "model")
            }
        }
        if let legacy = obj["seven_day_opus"] as? [String: Any] {
            return (parseClaudeWindow(legacy), "Opus")
        }
        return nil
    }

    private static func parseClaudeResetDate(_ value: Any?) -> Date? {
        if let r = value as? Double {
            return Date(timeIntervalSince1970: r)
        }
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}
