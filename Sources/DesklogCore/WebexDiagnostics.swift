import Foundation
import Darwin

/// A locally generated correlation identifier for one Webex synchronization pass.
///
/// This identifier is random and is never derived from a Webex person, room,
/// message, attachment, or access token.
public struct WebexDiagnosticSyncID: Codable, Sendable, Equatable, Hashable {
    private let value: UUID

    public init() {
        value = UUID()
    }

    public var displayValue: String {
        String(value.uuidString.prefix(8))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum WebexDiagnosticTrigger: String, Codable, Sendable, Equatable {
    case automatic
    case manual
    case authentication
}

public enum WebexDiagnosticOperation: String, Codable, Sendable, Equatable {
    case authentication
    case identity
    case rooms
    case messages
    case pagination
    case attachment
    case persistence
    case historicalRefresh = "historical_refresh"
}

public enum WebexDiagnosticErrorCode: String, Codable, Sendable, Equatable {
    case invalidAccessToken = "invalid_access_token"
    case invalidBaseURL = "invalid_base_url"
    case invalidDateRange = "invalid_date_range"
    case invalidResponse = "invalid_response"
    case malformedResponse = "malformed_response"
    case unauthorized
    case forbidden
    case rateLimited = "rate_limited"
    case attachmentLocked = "attachment_locked"
    case attachmentUnavailable = "attachment_unavailable"
    case attachmentRequiresUserConsent = "attachment_requires_user_consent"
    case httpStatus = "http_status"
    case transport
    case unsafePaginationURL = "unsafe_pagination_url"
    case unsafeAttachmentURL = "unsafe_attachment_url"
    case paginationLoop = "pagination_loop"
    case tooManyRedirects = "too_many_redirects"
    case invalidFileDestination = "invalid_file_destination"
    case fileWriteFailed = "file_write_failed"
    case cancelled
    case unknown
}

public enum WebexDiagnosticRejectionReason: String, Codable, Sendable, Equatable {
    case missingScheme = "missing_scheme"
    case insecureScheme = "insecure_scheme"
    case embeddedCredentials = "embedded_credentials"
    case disallowedPort = "disallowed_port"
    case missingHost = "missing_host"
    case untrustedHost = "untrusted_host"
    case originMismatch = "origin_mismatch"
    case pathOutsideAPI = "path_outside_api"
    case fragmentPresent = "fragment_present"
    case paginationLoop = "pagination_loop"
    case tooManyRedirects = "too_many_redirects"
    case malformedLocation = "malformed_location"
}

public enum WebexDiagnosticHostClassification: String, Codable, Sendable, Equatable {
    case primaryWebex = "primary_webex"
    case trustedWebexSubdomain = "trusted_webex_subdomain"
    case legacyCiscoSpark = "legacy_ciscospark"
    case untrusted
    case missing
}

/// Typed diagnostic events deliberately exclude arbitrary strings and remote identifiers.
///
/// In particular, no case can carry an access token, message body, URL, query,
/// path, Webex identifier, user name, email address, response body, or filename.
public enum WebexDiagnosticEvent: Sendable, Equatable {
    case syncStarted(
        syncID: WebexDiagnosticSyncID,
        trigger: WebexDiagnosticTrigger
    )
    case syncCompleted(
        syncID: WebexDiagnosticSyncID,
        conversationCount: Int,
        messageCount: Int,
        downloadedAttachmentCount: Int,
        pendingAttachmentCount: Int,
        durationMilliseconds: Int
    )
    case syncFailed(
        syncID: WebexDiagnosticSyncID,
        operation: WebexDiagnosticOperation,
        errorCode: WebexDiagnosticErrorCode,
        statusCode: Int?,
        retryAfterSeconds: Int?
    )
    case operationStarted(
        syncID: WebexDiagnosticSyncID,
        operation: WebexDiagnosticOperation,
        attempt: Int,
        page: Int?,
        roomOrdinal: Int?
    )
    case operationCompleted(
        syncID: WebexDiagnosticSyncID,
        operation: WebexDiagnosticOperation,
        statusCode: Int?,
        itemCount: Int?,
        durationMilliseconds: Int
    )
    case retryScheduled(
        syncID: WebexDiagnosticSyncID,
        operation: WebexDiagnosticOperation,
        attempt: Int,
        statusCode: Int?,
        delayMilliseconds: Int
    )
    case urlRejected(
        syncID: WebexDiagnosticSyncID,
        operation: WebexDiagnosticOperation,
        reason: WebexDiagnosticRejectionReason,
        hostClassification: WebexDiagnosticHostClassification
    )
    case roomFetchFailed(
        syncID: WebexDiagnosticSyncID,
        roomOrdinal: Int,
        errorCode: WebexDiagnosticErrorCode,
        statusCode: Int?,
        retryAfterSeconds: Int?
    )
    case attachmentFailed(
        syncID: WebexDiagnosticSyncID,
        roomOrdinal: Int,
        attachmentOrdinal: Int,
        errorCode: WebexDiagnosticErrorCode,
        statusCode: Int?,
        retryAfterSeconds: Int?
    )
    case historicalRefreshFailed(
        syncID: WebexDiagnosticSyncID,
        errorCode: WebexDiagnosticErrorCode,
        statusCode: Int?,
        retryAfterSeconds: Int?
    )
    case syncCancelled(
        syncID: WebexDiagnosticSyncID,
        operation: WebexDiagnosticOperation
    )
}

public enum WebexDiagnosticLoggerError: LocalizedError, Sendable, Equatable {
    case directoryPreparationFailed
    case unsafeLogDestination
    case encodingFailed
    case rotationFailed
    case fileOpenFailed
    case fileWriteFailed

    public var errorDescription: String? {
        switch self {
        case .directoryPreparationFailed:
            return "Webex診断ログの保存ディレクトリを準備できません。"
        case .unsafeLogDestination:
            return "Webex診断ログの保存先が安全ではありません。"
        case .encodingFailed:
            return "Webex診断イベントをエンコードできません。"
        case .rotationFailed:
            return "Webex診断ログをローテーションできません。"
        case .fileOpenFailed:
            return "Webex診断ログを開けません。"
        case .fileWriteFailed:
            return "Webex診断ログへ書き込めません。"
        }
    }
}

/// Private, bounded JSONL logging for troubleshooting Webex collection.
///
/// The actor serializes rotation and appends. Its public event API is typed so
/// callers cannot accidentally pass message contents, bearer tokens, remote
/// identifiers, URLs, or server-provided error text into the log.
public actor WebexDiagnosticLogger {
    public static let defaultMaximumFileSizeBytes = 1_048_576
    public static let defaultMaximumBackupCount = 4

    public static var defaultDirectoryURL: URL {
        WorklogStore.defaultRootDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    public static var defaultLogURL: URL {
        defaultDirectoryURL.appendingPathComponent("webex.log", isDirectory: false)
    }

    public nonisolated let logURL: URL

    private let directoryURL: URL
    private let maximumFileSizeBytes: Int
    private let maximumBackupCount: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(
        directoryURL: URL = WebexDiagnosticLogger.defaultDirectoryURL,
        maximumFileSizeBytes: Int = WebexDiagnosticLogger.defaultMaximumFileSizeBytes,
        maximumBackupCount: Int = WebexDiagnosticLogger.defaultMaximumBackupCount
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        logURL = directoryURL.standardizedFileURL
            .appendingPathComponent("webex.log", isDirectory: false)
        self.maximumFileSizeBytes = max(1, maximumFileSizeBytes)
        self.maximumBackupCount = max(0, maximumBackupCount)
        fileManager = .default
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public nonisolated static func makeSyncID() -> WebexDiagnosticSyncID {
        WebexDiagnosticSyncID()
    }

    public func record(
        _ event: WebexDiagnosticEvent,
        at timestamp: Date = Date()
    ) throws {
        let record = StoredRecord(event: event, timestamp: timestamp)
        let line: Data
        do {
            var encoded = try encoder.encode(record)
            encoded.append(0x0A)
            line = encoded
        } catch {
            throw WebexDiagnosticLoggerError.encodingFailed
        }

        try prepareDirectory()
        try rotateIfNeeded(forAdditionalBytes: line.count)
        try appendPrivately(line)
    }

    public func deleteAllLogs() throws {
        try prepareDirectory()
        for index in 0...maximumBackupCount {
            let candidate = index == 0 ? logURL : backupURL(index)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                throw WebexDiagnosticLoggerError.fileWriteFailed
            }
        }
    }

    public nonisolated static func safeErrorCode(
        for error: Error
    ) -> WebexDiagnosticErrorCode {
        if error is CancellationError { return .cancelled }
        guard let error = error as? WebexAPIError else { return .unknown }
        switch error {
        case .invalidAccessToken: return .invalidAccessToken
        case .invalidBaseURL: return .invalidBaseURL
        case .invalidDateRange: return .invalidDateRange
        case .invalidResponse: return .invalidResponse
        case .malformedResponse: return .malformedResponse
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .rateLimited: return .rateLimited
        case .attachmentLocked: return .attachmentLocked
        case .attachmentUnavailable: return .attachmentUnavailable
        case .attachmentRequiresUserConsent: return .attachmentRequiresUserConsent
        case .httpStatus: return .httpStatus
        case .transport: return .transport
        case .unsafePaginationURL: return .unsafePaginationURL
        case .unsafeAttachmentURL: return .unsafeAttachmentURL
        case .paginationLoop: return .paginationLoop
        case .tooManyRedirects: return .tooManyRedirects
        case .invalidFileDestination: return .invalidFileDestination
        case .fileWriteFailed: return .fileWriteFailed
        }
    }

    public nonisolated static func safeStatusCode(for error: Error) -> Int? {
        guard let error = error as? WebexAPIError else { return nil }
        switch error {
        case .attachmentUnavailable(let statusCode, _),
             .httpStatus(let statusCode, _):
            return statusCode
        case .unauthorized:
            return 401
        case .forbidden:
            return 403
        case .attachmentLocked:
            return 423
        case .attachmentRequiresUserConsent:
            return 428
        case .rateLimited:
            return 429
        default:
            return nil
        }
    }

    public nonisolated static func safeRetryAfterSeconds(for error: Error) -> Int? {
        guard let error = error as? WebexAPIError else { return nil }
        let delay: TimeInterval?
        switch error {
        case .rateLimited(let retryAfter), .attachmentLocked(let retryAfter):
            delay = retryAfter
        default:
            delay = nil
        }
        guard let delay, delay.isFinite else { return nil }
        return max(0, Int(ceil(delay)))
    }

    public nonisolated static func classifyHost(
        of url: URL?
    ) -> WebexDiagnosticHostClassification {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return .missing }
        if host == "webexapis.com" { return .primaryWebex }
        if host.hasSuffix(".webexapis.com") { return .trustedWebexSubdomain }
        if host == "api.ciscospark.com" { return .legacyCiscoSpark }
        return .untrusted
    }

    private func prepareDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try directoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw WebexDiagnosticLoggerError.unsafeLogDestination
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch let error as WebexDiagnosticLoggerError {
            throw error
        } catch {
            throw WebexDiagnosticLoggerError.directoryPreparationFailed
        }
    }

    private func rotateIfNeeded(forAdditionalBytes additionalBytes: Int) throws {
        guard fileManager.fileExists(atPath: logURL.path) else { return }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: logURL.path)
        } catch {
            throw WebexDiagnosticLoggerError.rotationFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw WebexDiagnosticLoggerError.unsafeLogDestination
        }
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize > 0,
              currentSize + additionalBytes > maximumFileSizeBytes else {
            return
        }

        do {
            if maximumBackupCount == 0 {
                try fileManager.removeItem(at: logURL)
                return
            }
            let oldest = backupURL(maximumBackupCount)
            if fileManager.fileExists(atPath: oldest.path) {
                try fileManager.removeItem(at: oldest)
            }
            if maximumBackupCount > 1 {
                for index in stride(from: maximumBackupCount - 1, through: 1, by: -1) {
                    let source = backupURL(index)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = backupURL(index + 1)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
            try fileManager.moveItem(at: logURL, to: backupURL(1))
            try enforcePrivatePermissionsOnBackups()
        } catch let error as WebexDiagnosticLoggerError {
            throw error
        } catch {
            throw WebexDiagnosticLoggerError.rotationFailed
        }
    }

    private func appendPrivately(_ data: Data) throws {
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let descriptor = Darwin.open(
            logURL.path,
            flags,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw WebexDiagnosticLoggerError.fileOpenFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw WebexDiagnosticLoggerError.fileWriteFailed
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch let error as WebexDiagnosticLoggerError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw WebexDiagnosticLoggerError.fileWriteFailed
        }
    }

    private func enforcePrivatePermissionsOnBackups() throws {
        for index in 1...maximumBackupCount {
            let candidate = backupURL(index)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: candidate.path
            )
        }
    }

    private func backupURL(_ index: Int) -> URL {
        URL(fileURLWithPath: logURL.path + ".\(index)", isDirectory: false)
    }
}

private struct StoredRecord: Codable {
    let schemaVersion: Int
    let timestamp: Date
    let level: StoredLevel
    let event: StoredEventKind
    let syncID: WebexDiagnosticSyncID
    let trigger: WebexDiagnosticTrigger?
    let operation: WebexDiagnosticOperation?
    let errorCode: WebexDiagnosticErrorCode?
    let rejectionReason: WebexDiagnosticRejectionReason?
    let hostClassification: WebexDiagnosticHostClassification?
    let attempt: Int?
    let page: Int?
    let roomOrdinal: Int?
    let attachmentOrdinal: Int?
    let statusCode: Int?
    let retryAfterSeconds: Int?
    let delayMilliseconds: Int?
    let itemCount: Int?
    let conversationCount: Int?
    let messageCount: Int?
    let downloadedAttachmentCount: Int?
    let pendingAttachmentCount: Int?
    let durationMilliseconds: Int?

    init(event source: WebexDiagnosticEvent, timestamp: Date) {
        schemaVersion = 1
        self.timestamp = timestamp

        var level: StoredLevel = .info
        var event: StoredEventKind
        var syncID: WebexDiagnosticSyncID
        var trigger: WebexDiagnosticTrigger?
        var operation: WebexDiagnosticOperation?
        var errorCode: WebexDiagnosticErrorCode?
        var rejectionReason: WebexDiagnosticRejectionReason?
        var hostClassification: WebexDiagnosticHostClassification?
        var attempt: Int?
        var page: Int?
        var roomOrdinal: Int?
        var attachmentOrdinal: Int?
        var statusCode: Int?
        var retryAfterSeconds: Int?
        var delayMilliseconds: Int?
        var itemCount: Int?
        var conversationCount: Int?
        var messageCount: Int?
        var downloadedAttachmentCount: Int?
        var pendingAttachmentCount: Int?
        var durationMilliseconds: Int?

        switch source {
        case .syncStarted(let id, let value):
            event = .syncStarted
            syncID = id
            trigger = value
        case .syncCompleted(
            let id,
            let conversations,
            let messages,
            let downloaded,
            let pending,
            let duration
        ):
            event = .syncCompleted
            syncID = id
            conversationCount = Self.nonnegative(conversations)
            messageCount = Self.nonnegative(messages)
            downloadedAttachmentCount = Self.nonnegative(downloaded)
            pendingAttachmentCount = Self.nonnegative(pending)
            durationMilliseconds = Self.nonnegative(duration)
        case .syncFailed(let id, let stage, let code, let status, let retryAfter):
            level = .error
            event = .syncFailed
            syncID = id
            operation = stage
            errorCode = code
            statusCode = Self.httpStatus(status)
            retryAfterSeconds = Self.nonnegative(retryAfter)
        case .operationStarted(let id, let stage, let attemptValue, let pageValue, let room):
            event = .operationStarted
            syncID = id
            operation = stage
            attempt = Self.nonnegative(attemptValue)
            page = Self.nonnegative(pageValue)
            roomOrdinal = Self.nonnegative(room)
        case .operationCompleted(let id, let stage, let status, let count, let duration):
            event = .operationCompleted
            syncID = id
            operation = stage
            statusCode = Self.httpStatus(status)
            itemCount = Self.nonnegative(count)
            durationMilliseconds = Self.nonnegative(duration)
        case .retryScheduled(let id, let stage, let attemptValue, let status, let delay):
            level = .warning
            event = .retryScheduled
            syncID = id
            operation = stage
            attempt = Self.nonnegative(attemptValue)
            statusCode = Self.httpStatus(status)
            delayMilliseconds = Self.nonnegative(delay)
        case .urlRejected(let id, let stage, let reason, let host):
            level = .error
            event = .urlRejected
            syncID = id
            operation = stage
            rejectionReason = reason
            hostClassification = host
        case .roomFetchFailed(let id, let room, let code, let status, let retryAfter):
            level = .warning
            event = .roomFetchFailed
            syncID = id
            operation = .messages
            roomOrdinal = Self.nonnegative(room)
            errorCode = code
            statusCode = Self.httpStatus(status)
            retryAfterSeconds = Self.nonnegative(retryAfter)
        case .attachmentFailed(
            let id,
            let room,
            let attachment,
            let code,
            let status,
            let retryAfter
        ):
            level = .warning
            event = .attachmentFailed
            syncID = id
            operation = .attachment
            roomOrdinal = Self.nonnegative(room)
            attachmentOrdinal = Self.nonnegative(attachment)
            errorCode = code
            statusCode = Self.httpStatus(status)
            retryAfterSeconds = Self.nonnegative(retryAfter)
        case .historicalRefreshFailed(let id, let code, let status, let retryAfter):
            level = .warning
            event = .historicalRefreshFailed
            syncID = id
            operation = .historicalRefresh
            errorCode = code
            statusCode = Self.httpStatus(status)
            retryAfterSeconds = Self.nonnegative(retryAfter)
        case .syncCancelled(let id, let stage):
            level = .warning
            event = .syncCancelled
            syncID = id
            operation = stage
        }

        self.level = level
        self.event = event
        self.syncID = syncID
        self.trigger = trigger
        self.operation = operation
        self.errorCode = errorCode
        self.rejectionReason = rejectionReason
        self.hostClassification = hostClassification
        self.attempt = attempt
        self.page = page
        self.roomOrdinal = roomOrdinal
        self.attachmentOrdinal = attachmentOrdinal
        self.statusCode = statusCode
        self.retryAfterSeconds = retryAfterSeconds
        self.delayMilliseconds = delayMilliseconds
        self.itemCount = itemCount
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.downloadedAttachmentCount = downloadedAttachmentCount
        self.pendingAttachmentCount = pendingAttachmentCount
        self.durationMilliseconds = durationMilliseconds
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        value.map { max(0, $0) }
    }

    private static func nonnegative(_ value: Int) -> Int {
        max(0, value)
    }

    private static func httpStatus(_ value: Int?) -> Int? {
        guard let value, (100...599).contains(value) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp
        case level
        case event
        case syncID = "sync_id"
        case trigger
        case operation
        case errorCode = "error_code"
        case rejectionReason = "rejection_reason"
        case hostClassification = "host_classification"
        case attempt
        case page
        case roomOrdinal = "room_ordinal"
        case attachmentOrdinal = "attachment_ordinal"
        case statusCode = "status_code"
        case retryAfterSeconds = "retry_after_seconds"
        case delayMilliseconds = "delay_milliseconds"
        case itemCount = "item_count"
        case conversationCount = "conversation_count"
        case messageCount = "message_count"
        case downloadedAttachmentCount = "downloaded_attachment_count"
        case pendingAttachmentCount = "pending_attachment_count"
        case durationMilliseconds = "duration_milliseconds"
    }
}

private enum StoredLevel: String, Codable {
    case info
    case warning
    case error
}

private enum StoredEventKind: String, Codable {
    case syncStarted = "sync_started"
    case syncCompleted = "sync_completed"
    case syncFailed = "sync_failed"
    case operationStarted = "operation_started"
    case operationCompleted = "operation_completed"
    case retryScheduled = "retry_scheduled"
    case urlRejected = "url_rejected"
    case roomFetchFailed = "room_fetch_failed"
    case attachmentFailed = "attachment_failed"
    case historicalRefreshFailed = "historical_refresh_failed"
    case syncCancelled = "sync_cancelled"
}
