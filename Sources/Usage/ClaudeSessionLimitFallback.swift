import Foundation

/// High-confidence local fallback for Claude's short/session window.
///
/// Anthropic's usage endpoint is account-rate-limited and shared with Claude
/// Code itself. When it is unavailable, Claude still writes a synthetic
/// `rate_limit` row such as "You've hit your session limit · resets 8pm
/// (America/New_York)" to the local project JSONL. That row proves the short
/// window is at 100% and supplies the provider's reset time.
enum ClaudeSessionLimitFallback {
    struct Event {
        let occurredAt: Date
        let resetAt: Date
    }

    private static let lookback: TimeInterval = 12 * 3600
    private static let maxTailBytes: UInt64 = 2 * 1024 * 1024

    static func latestActive(now: Date = Date()) -> Event? {
        let cutoff = now.addingTimeInterval(-lookback)
        var latest: Event?

        for root in projectRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                )
                guard values?.isRegularFile == true,
                      let modified = values?.contentModificationDate,
                      modified >= cutoff,
                      let candidate = latestEvent(inTailOf: url),
                      candidate.occurredAt >= cutoff,
                      candidate.resetAt > now
                else { continue }
                if latest == nil || candidate.occurredAt > latest!.occurredAt {
                    latest = candidate
                }
            }
        }
        return latest
    }

    private static func projectRoots() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configured.isEmpty {
            return configured.split(separator: ",").map {
                URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces))
                    .appendingPathComponent("projects", isDirectory: true)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Limit rows are appended when Claude rejects a turn, so reading the
    /// tail avoids scanning project transcripts that can be hundreds of MB.
    private static func latestEvent(inTailOf url: URL) -> Event? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > maxTailBytes ? size - maxTailBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if offset > 0, !data.isEmpty, data.first != 0x0A, !lines.isEmpty {
            lines.removeFirst() // partial row at the start of the tail
        }
        for line in lines.reversed() {
            if let event = parseLine(Data(line)) { return event }
        }
        return nil
    }

    private static func parseLine(_ data: Data) -> Event? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (raw["type"] as? String) == "assistant",
              (raw["error"] as? String) == "rate_limit",
              (raw["apiErrorStatus"] as? NSNumber)?.intValue == 429,
              let message = raw["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String })
                .first(where: { $0.localizedCaseInsensitiveContains("session limit") }),
              let timestamp = parseTimestamp(raw["timestamp"] as? String),
              let resetAt = parseResetDate(from: text, eventAt: timestamp)
        else { return nil }
        return Event(occurredAt: timestamp, resetAt: resetAt)
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// Internal for regression tests. Accepts `8pm`, `8:30 PM`, and an
    /// optional IANA zone in parentheses.
    static func parseResetDate(from text: String, eventAt: Date) -> Date? {
        let pattern = #"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: fullRange),
              let hourValue = Int(nsText.substring(with: match.range(at: 1)))
        else { return nil }

        let minute: Int = match.range(at: 2).location == NSNotFound
            ? 0
            : (Int(nsText.substring(with: match.range(at: 2))) ?? 0)
        let meridiem = nsText.substring(with: match.range(at: 3)).lowercased()
        var hour = hourValue % 12
        if meridiem == "pm" { hour += 12 }

        let zone: TimeZone = {
            guard match.range(at: 4).location != NSNotFound else { return .current }
            return TimeZone(identifier: nsText.substring(with: match.range(at: 4))) ?? .current
        }()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day], from: eventAt)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var reset = calendar.date(from: components) else { return nil }
        if reset < eventAt.addingTimeInterval(-60) {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: reset) else { return nil }
            reset = nextDay
        }
        return reset
    }
}
