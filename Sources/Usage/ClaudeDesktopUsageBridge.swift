import Darwin
import Foundation

enum ClaudeDesktopUsageBridge {
    static let schemaVersion = 1
    static let maximumSnapshotAge: TimeInterval = 20 * 60

    struct Reading {
        let usage: AppUsage
        let observedAt: Date
    }

    enum ReadError: Error, Equatable {
        case missing
        case insecureFile
        case oversizedFile
        case malformedPayload
        case unsupportedSchema
        case unexpectedSource
        case futureSnapshot
        case staleSnapshot
        case invalidWindow
        case noCurrentWindows
    }

    static func snapshotURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.codexisland.CodexIsland", isDirectory: true)
            .appendingPathComponent("ccd-usage-v1.json", isDirectory: false)
    }

    static func read(now: Date = Date(), from url: URL? = nil) -> Reading? {
        try? load(now: now, from: url)
    }

    static func load(now: Date = Date(), from suppliedURL: URL? = nil) throws -> Reading {
        guard let url = suppliedURL ?? snapshotURL() else { throw ReadError.missing }
        let data = try readSecureFile(at: url)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ReadError.malformedPayload
        }
        guard payload.schemaVersion == schemaVersion else { throw ReadError.unsupportedSchema }
        guard payload.provider == "claude", payload.source == "claude_code_desktop" else {
            throw ReadError.unexpectedSource
        }

        let observedAt = try date(payload.generatedAt)
        let age = now.timeIntervalSince(observedAt)
        guard age >= -60 else { throw ReadError.futureSnapshot }
        guard age <= maximumSnapshotAge else { throw ReadError.staleSnapshot }

        let fiveHour = try window(
            payload.windows.fiveHour,
            now: now,
            observedAt: observedAt,
            maximumResetDistance: 6 * 60 * 60
        )
        let weekly = try window(
            payload.windows.sevenDay,
            now: now,
            observedAt: observedAt,
            maximumResetDistance: 8 * 24 * 60 * 60
        )
        let scoped = try window(
            payload.windows.scopedWeekly,
            now: now,
            observedAt: observedAt,
            maximumResetDistance: 8 * 24 * 60 * 60
        )
        guard fiveHour != nil || weekly != nil || scoped != nil else {
            throw ReadError.noCurrentWindows
        }

        let plan = try validatedLabel(payload.plan)
        let scopedLabel = try validatedLabel(payload.windows.scopedWeekly?.label)
        if scoped != nil, scopedLabel == nil { throw ReadError.invalidWindow }

        return Reading(
            usage: AppUsage(
                fiveHour: fiveHour ?? .unknown,
                weekly: weekly ?? .unknown,
                plan: plan,
                scopedWeekly: scoped,
                scopedLabel: scopedLabel
            ),
            observedAt: observedAt
        )
    }

    private static let maximumFileBytes = 64 * 1024

    private static func readSecureFile(at url: URL) throws -> Data {
        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0 else { throw ReadError.missing }
        guard pathInfo.st_uid == geteuid(),
              pathInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_mode & 0o777 == 0o600
        else { throw ReadError.insecureFile }
        guard pathInfo.st_size >= 0, pathInfo.st_size <= maximumFileBytes else {
            throw ReadError.oversizedFile
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ReadError.insecureFile }
        defer { Darwin.close(descriptor) }

        var openInfo = stat()
        guard fstat(descriptor, &openInfo) == 0,
              openInfo.st_dev == pathInfo.st_dev,
              openInfo.st_ino == pathInfo.st_ino,
              openInfo.st_uid == geteuid(),
              openInfo.st_mode & S_IFMT == S_IFREG,
              openInfo.st_mode & 0o777 == 0o600
        else { throw ReadError.insecureFile }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ReadError.malformedPayload }
            guard data.count + count <= maximumFileBytes else { throw ReadError.oversizedFile }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func window(
        _ raw: RawWindow?,
        now: Date,
        observedAt: Date,
        maximumResetDistance: TimeInterval
    ) throws -> WindowUsage? {
        guard let raw else { return nil }
        guard raw.usedPercent.isFinite, (0...100).contains(raw.usedPercent) else {
            throw ReadError.invalidWindow
        }
        let resetAt = try date(raw.resetsAt)
        guard resetAt.timeIntervalSince(observedAt) <= maximumResetDistance + 60 else {
            throw ReadError.invalidWindow
        }
        guard resetAt > now else { return nil }
        return WindowUsage(
            usedPercent: raw.usedPercent / 100,
            resetAt: resetAt,
            error: nil
        )
    }

    private static func date(_ timestamp: Double) throws -> Date {
        guard timestamp.isFinite, timestamp > 0 else { throw ReadError.malformedPayload }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func validatedLabel(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 32,
              label.unicodeScalars.allSatisfy(isSafeLabelScalar)
        else { throw ReadError.malformedPayload }
        return label
    }

    private static func isSafeLabelScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let provider: String
        let source: String
        let generatedAt: Double
        let plan: String?
        let windows: RawWindows

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case provider
            case source
            case generatedAt = "generated_at"
            case plan
            case windows
        }
    }

    private struct RawWindows: Decodable {
        let fiveHour: RawWindow?
        let sevenDay: RawWindow?
        let scopedWeekly: RawWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case scopedWeekly = "scoped_weekly"
        }
    }

    private struct RawWindow: Decodable {
        let usedPercent: Double
        let resetsAt: Double
        let label: String?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
            case label
        }
    }
}
