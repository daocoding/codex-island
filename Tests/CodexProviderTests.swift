import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private enum TestTransportError: Error {
    case offline
}

private final class AuthReader {
    private let lock = NSLock()
    private var values: [Data]
    private(set) var paths: [URL] = []

    init(_ values: [Data]) {
        self.values = values
    }

    func read(_ url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        paths.append(url)
        guard let value = values.first else { throw TestTransportError.offline }
        if values.count > 1 { values.removeFirst() }
        return value
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }
}

private final class HTTPRecorder {
    typealias Handler = (URLRequest) throws -> CodexProviderHTTPResponse

    private let lock = NSLock()
    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> CodexProviderHTTPResponse {
        record(request)
        return try handler(request)
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private final class MutableClock {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class MutableFlag {
    private let lock = NSLock()
    private var value = false

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@main
private struct CodexProviderTests {
    static func main() async {
        do {
            try testAuthPathResolution()
            try await testTransientCredentialRewriteUsesOneSnapshot()
            try await testUnchangedCredentialDoesNotRetry401()
            try await testChangedCredentialReplaysBothEndpoints()
            try await testMissingPercentageIsUnknownWithSchemaIssue()
            try await testAllMissingPercentagesFailSchema()
            try await testResetCreditsRetainFreshnessOnFailure()
            print("Codex provider tests passed (7)")
        } catch {
            fputs("Codex provider test failure: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testAuthPathResolution() throws {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let defaultURL = CodexDesktopProvider.authFileURL(
            environment: [:],
            homeDirectory: home
        )
        try expect(defaultURL.path == "/Users/fixture/.codex/auth.json", "default CODEX_HOME")

        let configuredURL = CodexDesktopProvider.authFileURL(
            environment: ["CODEX_HOME": "/tmp/codex-profile"],
            homeDirectory: home
        )
        try expect(configuredURL.path == "/tmp/codex-profile/auth.json", "configured CODEX_HOME")

        let tildeURL = CodexDesktopProvider.authFileURL(
            environment: ["CODEX_HOME": "~/Profiles/CD"],
            homeDirectory: home
        )
        try expect(tildeURL.path == "/Users/fixture/Profiles/CD/auth.json", "tilde CODEX_HOME")
    }

    private static func testTransientCredentialRewriteUsesOneSnapshot() async throws {
        let reader = AuthReader([Data("{".utf8), authData(token: "generation-a")])
        let usage = try fixture("usage-weekly.json")
        let credits = try fixture("reset-credits.json")
        let http = HTTPRecorder { request in
            try expect(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer generation-a",
                "both endpoints must use the recovered immutable snapshot"
            )
            return response(for: request, usage: usage, credits: credits)
        }
        let provider = makeProvider(reader: reader, http: http)

        let result = await provider.poll()

        try expect(reader.readCount == 2, "one transient auth parse should be retried once")
        try expect(http.requests.count == 2, "one request per endpoint")
        guard case .success(let observation) = result.usage else {
            throw TestFailure.failed("recovered credential should produce usage")
        }
        try expect(observation.value.usage.weekly.percentInt == 47, "weekly fixture should parse")
    }

    private static func testUnchangedCredentialDoesNotRetry401() async throws {
        let reader = AuthReader([authData(token: "unchanged")])
        let credits = try fixture("reset-credits.json")
        let http = HTTPRecorder { request in
            if endpoint(for: request) == .usage {
                return CodexProviderHTTPResponse(statusCode: 401, data: Data())
            }
            return CodexProviderHTTPResponse(statusCode: 200, data: credits)
        }
        let provider = makeProvider(reader: reader, http: http)

        let result = await provider.poll()

        try expect(reader.readCount == 2, "401 should re-read shared auth once")
        try expect(http.requests.count == 2, "unchanged generation must not retry HTTP")
        try expect(!result.credentialChangedDuringPoll, "unchanged generation marker")
        guard case .failure(.authenticationExpired(endpoint: .usage)) = result.usage else {
            throw TestFailure.failed("usage 401 should remain a typed auth failure")
        }
        try expect(result.resetCredits.isFresh, "the other endpoint may still succeed")
    }

    private static func testChangedCredentialReplaysBothEndpoints() async throws {
        let reader = AuthReader([
            authData(token: "generation-old"),
            authData(token: "generation-new")
        ])
        let usage = try fixture("usage-weekly.json")
        let credits = try fixture("reset-credits.json")
        let http = HTTPRecorder { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer generation-old", endpoint(for: request) == .usage {
                return CodexProviderHTTPResponse(statusCode: 401, data: Data())
            }
            return response(for: request, usage: usage, credits: credits)
        }
        let provider = makeProvider(reader: reader, http: http)

        let result = await provider.poll()

        let authorizations = http.requests.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }
        try expect(authorizations.filter { $0 == "Bearer generation-old" }.count == 2, "initial pair")
        try expect(authorizations.filter { $0 == "Bearer generation-new" }.count == 2, "replayed pair")
        try expect(result.credentialChangedDuringPoll, "rotation should be explicit")
        guard case .success(let observation) = result.usage else {
            throw TestFailure.failed("rotated credential should recover usage")
        }
        try expect(observation.value.usage.weekly.percentInt == 47, "replayed usage")
        try expect(result.resetCredits.isFresh, "replayed reset credits")
    }

    private static func testMissingPercentageIsUnknownWithSchemaIssue() async throws {
        let reader = AuthReader([authData(token: "fixture")])
        let usage = try fixture("usage-partial-missing-percent.json")
        let credits = try fixture("reset-credits.json")
        let http = HTTPRecorder {
            response(for: $0, usage: usage, credits: credits)
        }
        let provider = makeProvider(reader: reader, http: http)

        let result = await provider.poll()

        guard case .success(let observation) = result.usage else {
            throw TestFailure.failed("one valid window should preserve partial usage")
        }
        let reading = observation.value
        try expect(!reading.usage.fiveHour.hasKnownValue, "missing used_percent must be unknown")
        try expect(reading.usage.weekly.percentInt == 63, "valid weekly window remains available")
        try expect(
            reading.schemaIssues == [.missingUsedPercent(window: "primary_window")],
            "partial response should carry a typed schema issue"
        )
    }

    private static func testAllMissingPercentagesFailSchema() async throws {
        let reader = AuthReader([authData(token: "fixture")])
        let usage = try fixture("usage-invalid.json")
        let credits = try fixture("reset-credits.json")
        let http = HTTPRecorder {
            response(for: $0, usage: usage, credits: credits)
        }
        let provider = makeProvider(reader: reader, http: http)

        let result = await provider.poll()

        guard case .failure(.schema(endpoint: .usage, let issues)) = result.usage else {
            throw TestFailure.failed("an entirely unknown payload must fail schema")
        }
        try expect(
            issues.contains(.missingUsedPercent(window: "primary_window")),
            "schema failure should identify missing used_percent"
        )
    }

    private static func testResetCreditsRetainFreshnessOnFailure() async throws {
        let firstDate = Date(timeIntervalSince1970: 1_784_000_000)
        let secondDate = firstDate.addingTimeInterval(300)
        let clock = MutableClock(firstDate)
        let failCredits = MutableFlag()
        let reader = AuthReader([authData(token: "fixture")])
        let usage = try fixture("usage-weekly.json")
        let credits = try fixture("reset-credits.json")
        let http = HTTPRecorder { request in
            if endpoint(for: request) == .resetCredits, failCredits.get() {
                throw TestTransportError.offline
            }
            return response(for: request, usage: usage, credits: credits)
        }
        let provider = makeProvider(reader: reader, http: http, clock: clock)

        let first = await provider.poll()
        guard case .fresh(let firstObservation) = first.resetCredits else {
            throw TestFailure.failed("first reset-credit poll should be fresh")
        }
        try expect(firstObservation.observedAt == firstDate, "fresh observation timestamp")

        failCredits.set(true)
        clock.set(secondDate)
        let second = await provider.poll()
        guard case .stale(let last, .transport(endpoint: .resetCredits), let attemptedAt) = second.resetCredits else {
            throw TestFailure.failed("failed reset-credit poll should retain stale observation")
        }
        try expect(last.observedAt == firstDate, "failure must not re-date reset credits")
        try expect(attemptedAt == secondDate, "failed attempt timestamp should remain separate")
    }

    private static func makeProvider(
        reader: AuthReader,
        http: HTTPRecorder,
        clock: MutableClock = MutableClock(Date(timeIntervalSince1970: 1_783_000_000))
    ) -> CodexDesktopProvider {
        CodexDesktopProvider(dependencies: CodexProviderDependencies(
            environment: { ["CODEX_HOME": "/fixture/codex"] },
            homeDirectory: { URL(fileURLWithPath: "/Users/fixture", isDirectory: true) },
            readFile: reader.read,
            send: http.send,
            now: clock.now
        ))
    }

    private static func authData(token: String) -> Data {
        Data("{\"tokens\":{\"access_token\":\"\(token)\"}}".utf8)
    }

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(
            fileURLWithPath: "Tests/Fixtures/CodexProvider/\(name)",
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ))
    }

    private static func endpoint(for request: URLRequest) -> CodexProviderEndpoint {
        request.url?.path.hasSuffix("rate-limit-reset-credits") == true
            ? .resetCredits
            : .usage
    }

    private static func response(
        for request: URLRequest,
        usage: Data,
        credits: Data
    ) -> CodexProviderHTTPResponse {
        CodexProviderHTTPResponse(
            statusCode: 200,
            data: endpoint(for: request) == .usage ? usage : credits
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw TestFailure.failed(message) }
    }
}
