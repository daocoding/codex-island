import Foundation

enum CodexProviderEndpoint: String, Equatable {
    case usage
    case resetCredits
}

enum CodexProviderSchemaIssue: Equatable {
    case missingObject(String)
    case missingWindow(String)
    case missingUsedPercent(window: String)
    case invalidUsedPercent(window: String)
    case invalidResetAt(window: String)
    case invalidAvailableCount
    case missingCredits
    case invalidResetCredit(index: Int)
}

enum CodexProviderFailure: Error, Equatable {
    case credentialUnavailable
    case credentialMalformed
    case authenticationExpired(endpoint: CodexProviderEndpoint)
    case transport(endpoint: CodexProviderEndpoint)
    case http(endpoint: CodexProviderEndpoint, statusCode: Int)
    case schema(endpoint: CodexProviderEndpoint, issues: [CodexProviderSchemaIssue])
    case cancelled(endpoint: CodexProviderEndpoint)
}

struct CodexProviderObservation<Value> {
    let value: Value
    let observedAt: Date
}

extension CodexProviderObservation: Equatable where Value: Equatable {}

enum CodexProviderResult<Value> {
    case success(CodexProviderObservation<Value>)
    case failure(CodexProviderFailure)
}

extension CodexProviderResult: Equatable where Value: Equatable {}

struct CodexUsageReading {
    let usage: AppUsage
    let schemaIssues: [CodexProviderSchemaIssue]
}

enum CodexResetCreditsState: Equatable {
    case fresh(CodexProviderObservation<CodexResetCredits>)
    case stale(
        last: CodexProviderObservation<CodexResetCredits>,
        failure: CodexProviderFailure,
        attemptedAt: Date
    )
    case unavailable(failure: CodexProviderFailure, attemptedAt: Date)

    var lastSuccessfulObservation: CodexProviderObservation<CodexResetCredits>? {
        switch self {
        case .fresh(let observation):
            return observation
        case .stale(let observation, _, _):
            return observation
        case .unavailable:
            return nil
        }
    }

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

struct CodexProviderPollResult {
    let attemptedAt: Date
    let credentialChangedDuringPoll: Bool
    let usage: CodexProviderResult<CodexUsageReading>
    let resetCredits: CodexResetCreditsState
}

struct CodexProviderHTTPResponse {
    let statusCode: Int
    let data: Data
}

struct CodexProviderDependencies {
    let environment: () -> [String: String]
    let homeDirectory: () -> URL
    let readFile: (URL) throws -> Data
    let send: (URLRequest) async throws -> CodexProviderHTTPResponse
    let now: () -> Date

    static let live = CodexProviderDependencies(
        environment: { ProcessInfo.processInfo.environment },
        homeDirectory: { FileManager.default.homeDirectoryForCurrentUser },
        readFile: { try Data(contentsOf: $0) },
        send: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return CodexProviderHTTPResponse(statusCode: statusCode, data: data)
        },
        now: Date.init
    )
}
