import Darwin
import Foundation

@main
struct UsageCoreRepositoryTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func expectError(
        _ expected: UsageCore.StateRepository.RepositoryError,
        _ label: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            print("FAIL \(label) (no error)")
            failures += 1
        } catch let error as UsageCore.StateRepository.RepositoryError {
            expect(error == expected, "\(label) [\(error)]")
        } catch {
            print("FAIL \(label) (unexpected \(error))")
            failures += 1
        }
    }

    static func withRepository(
        maximumPayloadBytes: Int = UsageCore.StateRepository.defaultMaximumPayloadBytes,
        _ body: (URL, UsageCore.StateRepository) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-core-repository-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let repositoryDirectory = root.appendingPathComponent("repository", isDirectory: true)
        let repository = try UsageCore.StateRepository(
            directoryURL: repositoryDirectory,
            maximumPayloadBytes: maximumPayloadBytes
        )
        try body(repositoryDirectory, repository)
    }

    static func fixtureState(now: Date, resetAt: Date) -> UsageCore.State {
        var state = UsageCore.State()
        state[.claude] = UsageCore.ProviderState(
            readings: [
                .fiveHour: UsageCore.Reading(
                    usedFraction: 0.42,
                    resetAt: resetAt,
                    observedAt: now.addingTimeInterval(-60),
                    source: .claudeDesktopBridge,
                    confidence: .authoritative
                ),
                .weekly: UsageCore.Reading(
                    usedFraction: 0.73,
                    resetAt: now.addingTimeInterval(4 * 24 * 60 * 60),
                    observedAt: now.addingTimeInterval(-60),
                    source: .claudeDesktopBridge,
                    confidence: .authoritative
                ),
            ],
            health: UsageCore.ProviderHealth(
                lastAttemptAt: now.addingTimeInterval(-30),
                lastSuccessAt: now.addingTimeInterval(-30),
                failure: UsageCore.Failure(
                    code: .transport,
                    message: "raw response with SECRET_ACCESS_TOKEN"
                ),
                retryAt: now.addingTimeInterval(90)
            )
        )
        return state
    }

    static func stateFile(in directory: URL) -> URL {
        directory.appendingPathComponent("usage-core-state.json")
    }

    static func writeSecure(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func roundTripAndResetTest() throws {
        try withRepository { directory, repository in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try repository.save(fixtureState(now: now, resetAt: now.addingTimeInterval(60)), at: now)

            let fileURL = stateFile(in: directory)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                   "saved state is owner-only 0600")
            expect((attributes[.type] as? FileAttributeType) == .typeRegular,
                   "saved state is a regular file")

            let bytes = try Data(contentsOf: fileURL)
            let text = String(decoding: bytes, as: UTF8.self)
            expect(text.contains("\"schemaVersion\":1"), "payload carries an explicit schema version")
            expect(!text.contains("SECRET_ACCESS_TOKEN"), "provider diagnostics are not persisted")
            expect(!text.lowercased().contains("credential"), "schema cannot persist credentials")

            let restored = try repository.load(at: now.addingTimeInterval(120))
            let expired = restored?.reading(provider: .claude, window: .fiveHour)
            expect(expired?.usedFraction == nil && expired?.resetAt == nil,
                   "load resolves an elapsed reset boundary to unknown")
            let weekly = restored?.reading(provider: .claude, window: .weekly)
            expect(weekly?.usedPercent == 73, "load preserves an unexpired normalized value")
            expect(weekly?.source == .restoredSnapshot && weekly?.confidence == .cached,
                   "restored values are labeled as cached snapshots")
            expect(restored?[.claude].health.failure?.message == "Service temporarily unreachable",
                   "restored health uses a fixed safe message")

            let residue = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".tmp") }
            expect(residue.isEmpty, "atomic save leaves no temporary file")
        }
    }

    static func missingTest() throws {
        try withRepository { _, repository in
            let loaded = try repository.load()
            expect(loaded == nil, "missing state loads as nil")
        }
    }

    static func symlinkTest() throws {
        try withRepository { directory, repository in
            // Create the repository directory securely before adding the link.
            let loaded = try repository.load()
            expect(loaded == nil, "repository creates its secure directory")
            let destination = directory.deletingLastPathComponent().appendingPathComponent("elsewhere")
            try writeSecure(Data("{}".utf8), to: destination)
            try FileManager.default.createSymbolicLink(
                at: stateFile(in: directory),
                withDestinationURL: destination
            )

            expectError(.fileIsSymbolicLink, "load rejects a symbolic-link state file") {
                _ = try repository.load()
            }
            expectError(.fileIsSymbolicLink, "save refuses to replace a symbolic-link state file") {
                try repository.save(.init())
            }
        }
    }

    static func insecurePermissionTest() throws {
        try withRepository { directory, repository in
            let loaded = try repository.load()
            expect(loaded == nil, "repository directory is available")
            let fileURL = stateFile(in: directory)
            try writeSecure(Data("{}".utf8), to: fileURL)
            chmod(fileURL.path, mode_t(0o644))
            expectError(.fileHasInsecurePermissions(actual: 0o644), "load rejects non-0600 state") {
                _ = try repository.load()
            }
        }
    }

    static func malformedAndSchemaTests() throws {
        try withRepository { directory, repository in
            let loaded = try repository.load()
            expect(loaded == nil, "repository starts empty")
            let fileURL = stateFile(in: directory)

            try writeSecure(Data("not-json".utf8), to: fileURL)
            expectError(.malformedPayload, "malformed JSON is rejected") {
                _ = try repository.load()
            }
            expectError(.malformedPayload, "save does not silently replace malformed state") {
                try repository.save(.init())
            }

            try writeSecure(Data("{\"schemaVersion\":999}".utf8), to: fileURL)
            expectError(.futureSchema(999), "future schema is rejected explicitly") {
                _ = try repository.load()
            }
            expectError(.futureSchema(999), "older save does not overwrite a future schema") {
                try repository.save(.init())
            }

            try writeSecure(Data("{\"schemaVersion\":0}".utf8), to: fileURL)
            expectError(.unsupportedSchema(0), "obsolete schema is rejected explicitly") {
                _ = try repository.load()
            }
        }
    }

    static func oversizedTest() throws {
        try withRepository(maximumPayloadBytes: 1_024) { directory, repository in
            let loaded = try repository.load()
            expect(loaded == nil, "small repository starts empty")
            try writeSecure(Data(repeating: 65, count: 1_025), to: stateFile(in: directory))
            expectError(.payloadTooLarge(limit: 1_024), "oversized state is rejected before decoding") {
                _ = try repository.load()
            }
        }
    }

    static func hardLinkTest() throws {
        try withRepository { directory, repository in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try repository.save(fixtureState(now: now, resetAt: now.addingTimeInterval(60)), at: now)
            let secondLink = directory.appendingPathComponent("second-link")
            guard link(stateFile(in: directory).path, secondLink.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            expectError(.fileHasMultipleLinks, "hard-linked state is rejected") {
                _ = try repository.load(at: now)
            }
        }
    }

    static func insecureDirectoryTest() throws {
        try withRepository { directory, repository in
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            chmod(directory.path, mode_t(0o755))
            expectError(.insecureDirectory, "insecure repository directory is rejected") {
                _ = try repository.load()
            }
        }
    }

    static func symbolicLinkDirectoryTest() throws {
        try withRepository { directory, repository in
            let actualDirectory = directory.deletingLastPathComponent()
                .appendingPathComponent("actual-repository", isDirectory: true)
            try FileManager.default.createDirectory(
                at: actualDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createSymbolicLink(
                at: directory,
                withDestinationURL: actualDirectory
            )
            expectError(.insecureDirectory, "symbolic-link repository directory is rejected") {
                _ = try repository.load()
            }
        }
    }

    static func sanitizationTest() throws {
        try withRepository { directory, repository in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try repository.save(fixtureState(now: now, resetAt: now.addingTimeInterval(60)), at: now)

            let fileURL = stateFile(in: directory)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as! [String: Any]
            var providers = object["providers"] as! [String: Any]
            var claude = providers["claude"] as! [String: Any]
            var readings = claude["readings"] as! [String: Any]
            readings["../unsafe"] = readings["weekly"]
            claude["readings"] = readings
            providers["claude"] = claude
            object["providers"] = providers
            try writeSecure(try JSONSerialization.data(withJSONObject: object), to: fileURL)

            let restored = try repository.load(at: now)
            expect(restored?[.claude].readings[UsageCore.WindowID("../unsafe")] == nil,
                   "unsafe window identifiers are dropped during load")
            expect(restored?.reading(provider: .claude, window: .weekly)?.usedPercent == 73,
                   "sanitization preserves valid readings")
        }
    }

    static func invalidConfigurationTest() {
        expectError(.invalidConfiguration("state filename is not a basename"),
                    "path traversal filename is rejected") {
            _ = try UsageCore.StateRepository(
                directoryURL: URL(fileURLWithPath: "/tmp/example"),
                fileName: "../state.json"
            )
        }
    }

    static func main() {
        do {
            try roundTripAndResetTest()
            try missingTest()
            try symlinkTest()
            try insecurePermissionTest()
            try malformedAndSchemaTests()
            try oversizedTest()
            try hardLinkTest()
            try insecureDirectoryTest()
            try symbolicLinkDirectoryTest()
            try sanitizationTest()
            invalidConfigurationTest()
        } catch {
            print("FAIL test harness threw \(error)")
            failures += 1
        }

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all usage core repository tests passed")
    }
}
