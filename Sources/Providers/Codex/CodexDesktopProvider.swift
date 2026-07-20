import CryptoKit
import CoreFoundation
import Foundation

final class CodexDesktopProvider {
    private struct CredentialSnapshot {
        let accessToken: String
        let generation: Data
    }

    private struct RawResponse {
        let endpoint: CodexProviderEndpoint
        let statusCode: Int?
        let data: Data
        let transportFailed: Bool
        let cancelled: Bool

        var isUnauthorized: Bool { statusCode == 401 }
    }

    private struct ResponsePair {
        let usage: RawResponse
        let resetCredits: RawResponse

        var containsUnauthorized: Bool {
            usage.isUnauthorized || resetCredits.isUnauthorized
        }
    }

    private let dependencies: CodexProviderDependencies
    private let cacheLock = NSLock()
    private var lastResetCredits: CodexProviderObservation<CodexResetCredits>?

    init(dependencies: CodexProviderDependencies = .live) {
        self.dependencies = dependencies
    }

    static func authFileURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base: URL
        if let configured, !configured.isEmpty {
            if configured == "~" {
                base = homeDirectory
            } else if configured.hasPrefix("~/") {
                base = homeDirectory.appendingPathComponent(String(configured.dropFirst(2)))
            } else {
                base = URL(fileURLWithPath: configured, isDirectory: true)
            }
        } else {
            base = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return base.standardizedFileURL.appendingPathComponent("auth.json", isDirectory: false)
    }

    func poll() async -> CodexProviderPollResult {
        let attemptedAt = dependencies.now()
        let authURL = Self.authFileURL(
            environment: dependencies.environment(),
            homeDirectory: dependencies.homeDirectory()
        )
        switch await readCredential(at: authURL) {
        case .failure(let failure):
            return CodexProviderPollResult(
                attemptedAt: attemptedAt,
                credentialChangedDuringPoll: false,
                usage: .failure(failure),
                resetCredits: resetCreditsState(for: failure, attemptedAt: attemptedAt)
            )
        case .success(let initialCredential):
            var pair = await fetchPair(using: initialCredential)
            var changedDuringPoll = false

            if pair.containsUnauthorized {
                let current = await readCredential(at: authURL)
                if case .success(let currentCredential) = current,
                   currentCredential.generation != initialCredential.generation {
                    pair = await fetchPair(using: currentCredential)
                    changedDuringPoll = true
                }
            }

            let observedAt = dependencies.now()
            let usage = decodeUsage(pair.usage, observedAt: observedAt)
            let resetResult = decodeResetCredits(pair.resetCredits, observedAt: observedAt)
            let resetState: CodexResetCreditsState
            switch resetResult {
            case .success(let observation):
                storeLastResetCredits(observation)
                resetState = .fresh(observation)
            case .failure(let failure):
                resetState = resetCreditsState(for: failure, attemptedAt: attemptedAt)
            }

            return CodexProviderPollResult(
                attemptedAt: attemptedAt,
                credentialChangedDuringPoll: changedDuringPoll,
                usage: usage,
                resetCredits: resetState
            )
        }
    }

    private func readCredential(
        at url: URL
    ) async -> Result<CredentialSnapshot, CodexProviderFailure> {
        var lastFailure: CodexProviderFailure = .credentialUnavailable

        for attempt in 0..<2 {
            if attempt > 0 { await Task.yield() }
            let data: Data
            do {
                data = try dependencies.readFile(url)
            } catch {
                lastFailure = .credentialUnavailable
                continue
            }

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = object["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String,
                  !token.isEmpty else {
                lastFailure = .credentialMalformed
                continue
            }

            let generation = Data(SHA256.hash(data: Data(token.utf8)))
            return .success(CredentialSnapshot(accessToken: token, generation: generation))
        }

        return .failure(lastFailure)
    }

    private func fetchPair(using credential: CredentialSnapshot) async -> ResponsePair {
        async let usage = fetch(.usage, using: credential)
        async let resetCredits = fetch(.resetCredits, using: credential)
        return await ResponsePair(usage: usage, resetCredits: resetCredits)
    }

    private func fetch(
        _ endpoint: CodexProviderEndpoint,
        using credential: CredentialSnapshot
    ) async -> RawResponse {
        let url: URL
        switch endpoint {
        case .usage:
            url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        case .resetCredits:
            url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let response = try await dependencies.send(request)
            return RawResponse(
                endpoint: endpoint,
                statusCode: response.statusCode,
                data: response.data,
                transportFailed: false,
                cancelled: false
            )
        } catch is CancellationError {
            return RawResponse(
                endpoint: endpoint,
                statusCode: nil,
                data: Data(),
                transportFailed: false,
                cancelled: true
            )
        } catch {
            return RawResponse(
                endpoint: endpoint,
                statusCode: nil,
                data: Data(),
                transportFailed: true,
                cancelled: false
            )
        }
    }

    private func decodeUsage(
        _ response: RawResponse,
        observedAt: Date
    ) -> CodexProviderResult<CodexUsageReading> {
        if let failure = responseFailure(response) { return .failure(failure) }

        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let rateLimit = object["rate_limit"] as? [String: Any] else {
            return .failure(.schema(
                endpoint: .usage,
                issues: [.missingObject("rate_limit")]
            ))
        }

        let parsed = parseUsage(rateLimit, plan: object["plan_type"] as? String)
        guard parsed.usage.hasKnownValue else {
            let issues = parsed.schemaIssues.isEmpty
                ? [.missingWindow("primary_window"), .missingWindow("secondary_window")]
                : parsed.schemaIssues
            return .failure(.schema(endpoint: .usage, issues: issues))
        }

        let reading = CodexUsageReading(
            usage: parsed.usage.observed(at: observedAt, source: .api),
            schemaIssues: parsed.schemaIssues
        )
        return .success(CodexProviderObservation(value: reading, observedAt: observedAt))
    }

    private func decodeResetCredits(
        _ response: RawResponse,
        observedAt: Date
    ) -> CodexProviderResult<CodexResetCredits> {
        if let failure = responseFailure(response) { return .failure(failure) }

        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            return .failure(.schema(
                endpoint: .resetCredits,
                issues: [.missingObject("response")]
            ))
        }

        guard let countNumber = Self.number(object["available_count"]),
              countNumber.doubleValue >= 0,
              countNumber.doubleValue.rounded(.towardZero) == countNumber.doubleValue else {
            return .failure(.schema(endpoint: .resetCredits, issues: [.invalidAvailableCount]))
        }
        guard let rawCredits = object["credits"] as? [[String: Any]] else {
            return .failure(.schema(endpoint: .resetCredits, issues: [.missingCredits]))
        }
        let count = countNumber.intValue

        var credits: [CodexResetCredit] = []
        var issues: [CodexProviderSchemaIssue] = []
        for (index, item) in rawCredits.enumerated() {
            guard let id = item["id"] as? String,
                  let status = item["status"] as? String,
                  let rawExpiration = item["expires_at"] as? String,
                  let expiration = Self.parseISO8601(rawExpiration) else {
                issues.append(.invalidResetCredit(index: index))
                continue
            }
            credits.append(CodexResetCredit(
                id: id,
                status: status,
                expiresAt: expiration,
                title: item["title"] as? String ?? "",
                description: item["description"] as? String ?? ""
            ))
        }

        guard issues.isEmpty else {
            return .failure(.schema(endpoint: .resetCredits, issues: issues))
        }

        return .success(CodexProviderObservation(
            value: CodexResetCredits(availableCount: count, credits: credits),
            observedAt: observedAt
        ))
    }

    private func responseFailure(_ response: RawResponse) -> CodexProviderFailure? {
        if response.cancelled { return .cancelled(endpoint: response.endpoint) }
        if response.transportFailed { return .transport(endpoint: response.endpoint) }
        guard let statusCode = response.statusCode else {
            return .transport(endpoint: response.endpoint)
        }
        if statusCode == 401 { return .authenticationExpired(endpoint: response.endpoint) }
        if statusCode != 200 {
            return .http(endpoint: response.endpoint, statusCode: statusCode)
        }
        return nil
    }

    private func resetCreditsState(
        for failure: CodexProviderFailure,
        attemptedAt: Date
    ) -> CodexResetCreditsState {
        if let last = loadLastResetCredits() {
            return .stale(last: last, failure: failure, attemptedAt: attemptedAt)
        }
        return .unavailable(failure: failure, attemptedAt: attemptedAt)
    }

    private func storeLastResetCredits(
        _ observation: CodexProviderObservation<CodexResetCredits>
    ) {
        cacheLock.lock()
        lastResetCredits = observation
        cacheLock.unlock()
    }

    private func loadLastResetCredits() -> CodexProviderObservation<CodexResetCredits>? {
        cacheLock.lock()
        let observation = lastResetCredits
        cacheLock.unlock()
        return observation
    }

    private struct ParsedWindow {
        let usage: WindowUsage
        let limitSeconds: Int?
        let issues: [CodexProviderSchemaIssue]
    }

    private func parseUsage(_ rateLimit: [String: Any], plan: String?) -> CodexUsageReading {
        let primary = parseWindow(rateLimit["primary_window"], name: "primary_window")
        let secondary = parseWindow(rateLimit["secondary_window"], name: "secondary_window")
        let windows = [primary, secondary].compactMap { $0 }
        let issues = windows.flatMap(\.issues)

        guard windows.contains(where: { $0.limitSeconds != nil }) else {
            return CodexUsageReading(
                usage: AppUsage(
                    fiveHour: primary?.usage ?? .unknown,
                    weekly: secondary?.usage ?? .unknown,
                    plan: plan
                ),
                schemaIssues: issues
            )
        }

        let short = windows.first { ($0.limitSeconds ?? 0) < 86_400 }
        let weekly = windows.first { ($0.limitSeconds ?? 0) >= 86_400 }
        return CodexUsageReading(
            usage: AppUsage(
                fiveHour: short?.usage ?? .unknown,
                weekly: weekly?.usage ?? .unknown,
                plan: plan,
                shortWindowLabel: short.flatMap { Self.durationLabel(seconds: $0.limitSeconds) },
                weeklyWindowLabel: weekly.flatMap { Self.durationLabel(seconds: $0.limitSeconds) }
            ),
            schemaIssues: issues
        )
    }

    private func parseWindow(_ value: Any?, name: String) -> ParsedWindow? {
        guard let object = value as? [String: Any] else { return nil }

        let limitSeconds = Self.number(object["limit_window_seconds"])?.intValue
        guard let rawUsed = object["used_percent"] else {
            return ParsedWindow(
                usage: .unknown,
                limitSeconds: limitSeconds,
                issues: [.missingUsedPercent(window: name)]
            )
        }
        guard let used = Self.number(rawUsed)?.doubleValue,
              used.isFinite,
              (0...100).contains(used) else {
            return ParsedWindow(
                usage: .unknown,
                limitSeconds: limitSeconds,
                issues: [.invalidUsedPercent(window: name)]
            )
        }

        var issues: [CodexProviderSchemaIssue] = []
        let resetAt: Date?
        if let rawReset = object["reset_at"] {
            if let seconds = Self.number(rawReset)?.doubleValue,
               seconds.isFinite {
                resetAt = Date(timeIntervalSince1970: seconds)
            } else {
                resetAt = nil
                issues.append(.invalidResetAt(window: name))
            }
        } else {
            resetAt = nil
        }

        return ParsedWindow(
            usage: WindowUsage(usedPercent: used / 100, resetAt: resetAt, error: nil),
            limitSeconds: limitSeconds,
            issues: issues
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

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? ordinary.date(from: raw)
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}
