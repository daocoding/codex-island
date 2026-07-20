import Darwin
import Foundation

extension UsageCore {
    /// A small, synchronous persistence boundary for normalized usage state.
    ///
    /// The on-disk schema deliberately contains only quota readings and health
    /// metadata. Provider credentials, response bodies, and diagnostic messages
    /// are not representable and therefore cannot be persisted accidentally.
    final class StateRepository {
        enum StorageLocation: Sendable {
            case applicationSupport
            case caches
        }

        enum RepositoryError: Error, Equatable, CustomStringConvertible {
            case invalidConfiguration(String)
            case io(operation: String, code: Int32)
            case insecureDirectory
            case fileIsSymbolicLink
            case fileIsNotRegular
            case fileHasUnexpectedOwner
            case fileHasInsecurePermissions(actual: UInt16)
            case fileHasMultipleLinks
            case payloadEmpty
            case payloadTooLarge(limit: Int)
            case malformedPayload
            case unsupportedSchema(Int)
            case futureSchema(Int)

            var description: String {
                switch self {
                case .invalidConfiguration(let detail):
                    return "Invalid UsageCore repository configuration: \(detail)"
                case .io(let operation, let code):
                    return "UsageCore repository I/O failed during \(operation) (errno \(code))"
                case .insecureDirectory:
                    return "UsageCore repository directory must be an owner-only real directory"
                case .fileIsSymbolicLink:
                    return "UsageCore state file must not be a symbolic link"
                case .fileIsNotRegular:
                    return "UsageCore state file must be a regular file"
                case .fileHasUnexpectedOwner:
                    return "UsageCore state file is not owned by the current user"
                case .fileHasInsecurePermissions(let actual):
                    return String(format: "UsageCore state file permissions must be 0600 (found %04o)", actual)
                case .fileHasMultipleLinks:
                    return "UsageCore state file must not have additional hard links"
                case .payloadEmpty:
                    return "UsageCore state file is empty"
                case .payloadTooLarge(let limit):
                    return "UsageCore state file exceeds the \(limit)-byte limit"
                case .malformedPayload:
                    return "UsageCore state file is malformed"
                case .unsupportedSchema(let version):
                    return "UsageCore state schema \(version) is no longer supported"
                case .futureSchema(let version):
                    return "UsageCore state schema \(version) was written by a newer app"
                }
            }
        }

        static let currentSchemaVersion = 1
        static let defaultMaximumPayloadBytes = 256 * 1_024

        let directoryURL: URL
        let fileName: String
        let maximumPayloadBytes: Int

        private let lock = NSLock()

        /// Returns the production repository without touching the filesystem.
        /// The app-owned directory is created and verified on first load/save.
        static func live(
            location: StorageLocation = .applicationSupport,
            fileManager: FileManager = .default
        ) throws -> StateRepository {
            let searchDirectory: FileManager.SearchPathDirectory
            switch location {
            case .applicationSupport:
                searchDirectory = .applicationSupportDirectory
            case .caches:
                searchDirectory = .cachesDirectory
            }

            let root: URL
            do {
                root = try fileManager.url(
                    for: searchDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            } catch {
                throw RepositoryError.io(operation: "locate user storage", code: Int32(EIO))
            }

            return try StateRepository(
                directoryURL: root.appendingPathComponent(
                    "dev.codexisland.CodexIsland",
                    isDirectory: true
                )
            )
        }

        /// Injectable initializer used by focused tests and future migrations.
        /// `directoryURL` must name one app-owned child of an existing directory.
        init(
            directoryURL: URL,
            fileName: String = "usage-core-state.json",
            maximumPayloadBytes: Int = StateRepository.defaultMaximumPayloadBytes
        ) throws {
            guard directoryURL.isFileURL else {
                throw RepositoryError.invalidConfiguration("storage URL is not a file URL")
            }
            guard !fileName.isEmpty,
                  fileName != ".",
                  fileName != "..",
                  !fileName.contains("/"),
                  !fileName.contains("\0") else {
                throw RepositoryError.invalidConfiguration("state filename is not a basename")
            }
            guard maximumPayloadBytes >= 1_024 else {
                throw RepositoryError.invalidConfiguration("payload limit is too small")
            }

            self.directoryURL = directoryURL.standardizedFileURL
            self.fileName = fileName
            self.maximumPayloadBytes = maximumPayloadBytes
        }

        /// Loads a normalized snapshot. Missing state is not an error.
        ///
        /// Values whose reset boundary has passed become unknown, future clock
        /// skew is bounded, and restored values are explicitly marked cached.
        func load(at now: Date = Date()) throws -> State? {
            lock.lock()
            defer { lock.unlock() }

            return try withSecureDirectoryDescriptor { directoryFD in
                guard let data = try readStateFile(from: directoryFD) else {
                    return nil
                }

                let envelope = try Self.decodeEnvelope(data)
                return try Self.restore(envelope, at: Self.safeNow(now))
            }
        }

        /// Atomically replaces the snapshot with a 0600 regular file.
        func save(_ state: State, at now: Date = Date()) throws {
            lock.lock()
            defer { lock.unlock() }

            let safeNow = Self.safeNow(now)
            let envelope = Self.persistedEnvelope(from: state, at: safeNow)
            let data: Data
            do {
                data = try Self.makeEncoder().encode(envelope)
            } catch {
                throw RepositoryError.malformedPayload
            }
            guard !data.isEmpty else {
                throw RepositoryError.payloadEmpty
            }
            guard data.count <= maximumPayloadBytes else {
                throw RepositoryError.payloadTooLarge(limit: maximumPayloadBytes)
            }

            try withSecureDirectoryDescriptor { directoryFD in
                if let existingData = try readStateFile(from: directoryFD) {
                    // Never let an older build destroy state it cannot safely
                    // understand. Malformed state also requires an explicit
                    // operator decision instead of being silently replaced.
                    let existingEnvelope = try Self.decodeEnvelope(existingData)
                    _ = try Self.restore(existingEnvelope, at: safeNow)
                }
                try atomicallyWrite(data, in: directoryFD)
            }
        }
    }
}

// MARK: - Versioned schema

private extension UsageCore.StateRepository {
    struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    struct EnvelopeV1: Codable {
        let schemaVersion: Int
        let writtenAt: Date
        let providers: [String: PersistedProvider]
    }

    struct PersistedProvider: Codable {
        let readings: [String: PersistedReading]
        let health: PersistedHealth
    }

    struct PersistedReading: Codable {
        let usedFraction: Double?
        let resetAt: Date?
        let observedAt: Date
        let source: UsageCore.ReadingSource
        let confidence: UsageCore.Confidence
    }

    struct PersistedHealth: Codable {
        let lastAttemptAt: Date?
        let lastSuccessAt: Date?
        let failureCode: UsageCore.Failure.Code?
        let retryAt: Date?
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func decodeEnvelope(_ data: Data) throws -> EnvelopeV1 {
        let decoder = makeDecoder()
        let header: SchemaHeader
        do {
            header = try decoder.decode(SchemaHeader.self, from: data)
        } catch {
            throw RepositoryError.malformedPayload
        }

        if header.schemaVersion > currentSchemaVersion {
            throw RepositoryError.futureSchema(header.schemaVersion)
        }
        guard header.schemaVersion == currentSchemaVersion else {
            throw RepositoryError.unsupportedSchema(header.schemaVersion)
        }

        let envelope: EnvelopeV1
        do {
            envelope = try decoder.decode(EnvelopeV1.self, from: data)
        } catch {
            throw RepositoryError.malformedPayload
        }
        guard envelope.schemaVersion == currentSchemaVersion,
              isFinite(envelope.writtenAt) else {
            throw RepositoryError.malformedPayload
        }
        return envelope
    }

    static func persistedEnvelope(from state: UsageCore.State, at now: Date) -> EnvelopeV1 {
        var providers: [String: PersistedProvider] = [:]

        for providerID in UsageCore.ProviderID.allCases {
            let provider = state[providerID]
            var readings: [String: PersistedReading] = [:]
            let currentReadings = UsageCore.resolvedReadings(provider.readings, at: now)
            for (windowID, reading) in currentReadings where isSafeWindowID(windowID.rawValue) {
                let normalized = normalizedReading(reading, at: now)
                readings[windowID.rawValue] = PersistedReading(
                    usedFraction: normalized.usedFraction,
                    resetAt: normalized.resetAt,
                    observedAt: normalized.observedAt,
                    source: normalized.source,
                    confidence: normalized.confidence
                )
            }

            let health = normalizedHealth(provider.health, at: now)
            providers[providerID.rawValue] = PersistedProvider(
                readings: readings,
                health: PersistedHealth(
                    lastAttemptAt: health.lastAttemptAt,
                    lastSuccessAt: health.lastSuccessAt,
                    failureCode: health.failure?.code,
                    retryAt: health.retryAt
                )
            )
        }

        return EnvelopeV1(
            schemaVersion: currentSchemaVersion,
            writtenAt: now,
            providers: providers
        )
    }

    static func restore(_ envelope: EnvelopeV1, at now: Date) throws -> UsageCore.State {
        let knownProviderIDs = Set(UsageCore.ProviderID.allCases.map(\.rawValue))
        guard Set(envelope.providers.keys).isSubset(of: knownProviderIDs) else {
            throw RepositoryError.malformedPayload
        }

        var state = UsageCore.State()
        for providerID in UsageCore.ProviderID.allCases {
            guard let persisted = envelope.providers[providerID.rawValue] else { continue }
            var readings: [UsageCore.WindowID: UsageCore.Reading] = [:]

            for (rawWindowID, persistedReading) in persisted.readings {
                guard isSafeWindowID(rawWindowID) else { continue }
                let reading = UsageCore.Reading(
                    usedFraction: persistedReading.usedFraction,
                    resetAt: boundedReset(persistedReading.resetAt, at: now),
                    observedAt: boundedPastDate(persistedReading.observedAt, at: now) ?? now,
                    source: .restoredSnapshot,
                    confidence: persistedReading.usedFraction == nil ? .unknown : .cached
                ).resolved(at: now)
                readings[UsageCore.WindowID(rawWindowID)] = reading
            }

            let decodedHealth = UsageCore.ProviderHealth(
                lastAttemptAt: persisted.health.lastAttemptAt,
                lastSuccessAt: persisted.health.lastSuccessAt,
                failure: persisted.health.failureCode.map {
                    UsageCore.Failure(code: $0, message: safeFailureMessage(for: $0))
                },
                retryAt: persisted.health.retryAt
            )
            state[providerID] = UsageCore.ProviderState(
                readings: readings,
                health: normalizedHealth(decodedHealth, at: now)
            )
        }

        return state.resolved(at: now)
    }

    static func normalizedReading(
        _ reading: UsageCore.Reading,
        at now: Date
    ) -> UsageCore.Reading {
        let knownValue = reading.usedFraction.flatMap { $0.isFinite ? $0 : nil }
        return UsageCore.Reading(
            usedFraction: knownValue,
            resetAt: boundedReset(reading.resetAt, at: now),
            observedAt: boundedPastDate(reading.observedAt, at: now) ?? now,
            source: reading.source,
            confidence: reading.confidence
        ).resolved(at: now)
    }

    static func normalizedHealth(
        _ health: UsageCore.ProviderHealth,
        at now: Date
    ) -> UsageCore.ProviderHealth {
        UsageCore.ProviderHealth(
            lastAttemptAt: health.lastAttemptAt.flatMap { boundedPastDate($0, at: now) },
            lastSuccessAt: health.lastSuccessAt.flatMap { boundedPastDate($0, at: now) },
            failure: health.failure.map {
                UsageCore.Failure(code: $0.code, message: safeFailureMessage(for: $0.code))
            },
            retryAt: boundedRetry(health.retryAt, at: now)
        )
    }

    static func safeFailureMessage(for code: UsageCore.Failure.Code) -> String {
        switch code {
        case .authenticationExpired:
            return "Access expired"
        case .reauthenticationRequired:
            return "Sign-in required"
        case .rateLimited:
            return "Temporarily rate limited"
        case .transport:
            return "Service temporarily unreachable"
        case .malformedResponse:
            return "Usage response was invalid"
        case .unavailable:
            return "Usage temporarily unavailable"
        }
    }

    static func isSafeWindowID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 95
                || byte == 45
                || byte == 46
        }
    }

    static func safeNow(_ date: Date) -> Date {
        isFinite(date) ? date : Date()
    }

    static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    static func boundedPastDate(_ date: Date, at now: Date) -> Date? {
        guard isFinite(date) else { return nil }
        let tenYears: TimeInterval = 10 * 366 * 24 * 60 * 60
        return min(max(date, now.addingTimeInterval(-tenYears)), now)
    }

    static func boundedReset(_ date: Date?, at now: Date) -> Date? {
        guard let date, isFinite(date) else { return nil }
        let maximumFutureReset: TimeInterval = 366 * 24 * 60 * 60
        guard date <= now.addingTimeInterval(maximumFutureReset) else { return nil }
        return date
    }

    static func boundedRetry(_ date: Date?, at now: Date) -> Date? {
        guard let date, isFinite(date), date > now else { return nil }
        let maximumRetry: TimeInterval = 7 * 24 * 60 * 60
        return min(date, now.addingTimeInterval(maximumRetry))
    }
}

// MARK: - Secure filesystem boundary

private extension UsageCore.StateRepository {
    typealias POSIXStat = Darwin.stat

    func withSecureDirectoryDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try ensureDirectoryExists()

        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw RepositoryError.insecureDirectory
            }
            throw RepositoryError.io(operation: "open storage directory", code: errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = POSIXStat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw RepositoryError.io(operation: "inspect storage directory", code: errno)
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        let permissions = metadata.st_mode & mode_t(0o777)
        guard fileType == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              permissions == mode_t(0o700) else {
            throw RepositoryError.insecureDirectory
        }

        return try body(descriptor)
    }

    func ensureDirectoryExists() throws {
        let result = directoryURL.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        if result == 0 { return }
        guard errno == EEXIST else {
            throw RepositoryError.io(operation: "create storage directory", code: errno)
        }
    }

    func readStateFile(from directoryFD: Int32) throws -> Data? {
        let descriptor = fileName.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw RepositoryError.fileIsSymbolicLink }
            throw RepositoryError.io(operation: "open state file", code: errno)
        }
        defer { Darwin.close(descriptor) }

        try validateOpenStateFile(descriptor)

        var data = Data()
        data.reserveCapacity(min(maximumPayloadBytes, 16 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw RepositoryError.io(operation: "read state file", code: errno)
            }
            guard data.count <= maximumPayloadBytes - bytesRead else {
                throw RepositoryError.payloadTooLarge(limit: maximumPayloadBytes)
            }
            data.append(buffer, count: bytesRead)
        }

        guard !data.isEmpty else { throw RepositoryError.payloadEmpty }
        return data
    }

    func validateExistingStateFile(in directoryFD: Int32) throws {
        var metadata = POSIXStat()
        let result = fileName.withCString {
            Darwin.fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw RepositoryError.io(operation: "inspect existing state file", code: errno)
        }
        try validateStateMetadata(metadata)
    }

    func validateOpenStateFile(_ descriptor: Int32) throws {
        var metadata = POSIXStat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw RepositoryError.io(operation: "inspect state file", code: errno)
        }
        try validateStateMetadata(metadata)
        if metadata.st_size <= 0 { throw RepositoryError.payloadEmpty }
        if metadata.st_size > off_t(maximumPayloadBytes) {
            throw RepositoryError.payloadTooLarge(limit: maximumPayloadBytes)
        }
    }

    func validateStateMetadata(_ metadata: POSIXStat) throws {
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) { throw RepositoryError.fileIsSymbolicLink }
        guard fileType == mode_t(S_IFREG) else { throw RepositoryError.fileIsNotRegular }
        guard metadata.st_uid == geteuid() else { throw RepositoryError.fileHasUnexpectedOwner }
        let permissions = UInt16(metadata.st_mode & mode_t(0o777))
        guard permissions == 0o600 else {
            throw RepositoryError.fileHasInsecurePermissions(actual: permissions)
        }
        guard metadata.st_nlink == 1 else { throw RepositoryError.fileHasMultipleLinks }
    }

    func atomicallyWrite(_ data: Data, in directoryFD: Int32) throws {
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw RepositoryError.io(operation: "create temporary state file", code: errno)
        }

        var descriptorIsOpen = true
        var renamed = false
        defer {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if !renamed {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw RepositoryError.io(operation: "secure temporary state file", code: errno)
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw RepositoryError.io(operation: "write temporary state file", code: errno)
                }
                guard written > 0 else {
                    throw RepositoryError.io(operation: "write temporary state file", code: Int32(EIO))
                }
                offset += written
            }
        }

        guard Darwin.fsync(descriptor) == 0 else {
            throw RepositoryError.io(operation: "sync temporary state file", code: errno)
        }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw RepositoryError.io(operation: "close temporary state file", code: errno)
        }

        let renameResult = temporaryName.withCString { temporaryPath in
            fileName.withCString { finalPath in
                Darwin.renameat(directoryFD, temporaryPath, directoryFD, finalPath)
            }
        }
        guard renameResult == 0 else {
            throw RepositoryError.io(operation: "replace state file", code: errno)
        }
        renamed = true

        // Directory fsync is supported on the target macOS/APFS path. Some
        // test filesystems report EINVAL/ENOTSUP; the file itself is synced.
        if Darwin.fsync(directoryFD) != 0, errno != EINVAL, errno != ENOTSUP {
            throw RepositoryError.io(operation: "sync storage directory", code: errno)
        }

        try validateExistingStateFile(in: directoryFD)
    }
}
