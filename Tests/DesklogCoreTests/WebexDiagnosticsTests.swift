import DesklogCore
import Foundation
import Testing

@Suite(.serialized) struct WebexDiagnosticsTests {
    @Test func defaultLocationAndPrivatePermissionsAreStable() async throws {
        let expectedDirectory = WorklogStore.defaultRootDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
        #expect(WebexDiagnosticLogger.defaultDirectoryURL == expectedDirectory)
        #expect(
            WebexDiagnosticLogger.defaultLogURL ==
                expectedDirectory.appendingPathComponent("webex.log", isDirectory: false)
        )
        #expect(WebexDiagnosticLogger.defaultMaximumFileSizeBytes == 1_048_576)
        #expect(WebexDiagnosticLogger.defaultMaximumBackupCount == 4)

        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let logger = WebexDiagnosticLogger(directoryURL: directory)
        let syncID = WebexDiagnosticLogger.makeSyncID()

        try await logger.record(
            .syncStarted(syncID: syncID, trigger: .manual),
            at: Date(timeIntervalSince1970: 1_000)
        )

        #expect(logger.logURL == directory.appendingPathComponent("webex.log"))
        #expect(try permissions(at: directory) == 0o700)
        #expect(try permissions(at: logger.logURL) == 0o600)
        let records = try decodedRecords(in: logger.logURL)
        #expect(records.count == 1)
        #expect(records[0]["schema_version"] as? Int == 1)
        #expect(records[0]["event"] as? String == "sync_started")
        #expect(records[0]["trigger"] as? String == "manual")
        #expect(records[0]["sync_id"] as? String != nil)
        #expect(syncID.displayValue.count == 8)
    }

    @Test func typedEventsAndErrorSanitizersNeverPersistSentinels() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = WebexDiagnosticLogger(
            directoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let syncID = WebexDiagnosticSyncID()
        let sentinelToken = "SENTINEL_BEARER_TOKEN_7D5A"
        let sentinelBody = "SENTINEL_MESSAGE_BODY_3C91"
        let sentinelRoomID = "SENTINEL_ROOM_ID_894E"
        let sentinelPath = "/private/SENTINEL_LOCAL_PATH_43F0"
        let secretURL = try #require(URL(
            string: "https://" + sentinelToken +
                "@attacker.invalid/v1/messages?roomId=" + sentinelRoomID
        ))

        let errors: [(any Error, WebexDiagnosticErrorCode)] = [
            (WebexAPIError.invalidAccessToken, .invalidAccessToken),
            (WebexAPIError.invalidBaseURL(secretURL.absoluteString), .invalidBaseURL),
            (WebexAPIError.invalidDateRange, .invalidDateRange),
            (WebexAPIError.invalidResponse, .invalidResponse),
            (WebexAPIError.malformedResponse(sentinelBody), .malformedResponse),
            (WebexAPIError.unauthorized(sentinelToken), .unauthorized),
            (WebexAPIError.forbidden(sentinelBody), .forbidden),
            (WebexAPIError.rateLimited(retryAfter: 1.2), .rateLimited),
            (WebexAPIError.attachmentLocked(retryAfter: 2.1), .attachmentLocked),
            (
                WebexAPIError.attachmentUnavailable(
                    statusCode: 410,
                    message: sentinelBody
                ),
                .attachmentUnavailable
            ),
            (
                WebexAPIError.attachmentRequiresUserConsent(sentinelBody),
                .attachmentRequiresUserConsent
            ),
            (
                WebexAPIError.httpStatus(statusCode: 502, message: sentinelBody),
                .httpStatus
            ),
            (
                WebexAPIError.transport(code: -1, message: sentinelToken),
                .transport
            ),
            (WebexAPIError.unsafePaginationURL(secretURL), .unsafePaginationURL),
            (WebexAPIError.unsafeAttachmentURL(secretURL), .unsafeAttachmentURL),
            (WebexAPIError.paginationLoop(secretURL), .paginationLoop),
            (WebexAPIError.tooManyRedirects, .tooManyRedirects),
            (
                WebexAPIError.invalidFileDestination(
                    URL(fileURLWithPath: sentinelPath)
                ),
                .invalidFileDestination
            ),
            (WebexAPIError.fileWriteFailed(sentinelPath), .fileWriteFailed),
            (CancellationError(), .cancelled),
            (NSError(domain: sentinelBody, code: 9), .unknown)
        ]

        for (ordinal, pair) in errors.enumerated() {
            let (error, expectedCode) = pair
            let code = WebexDiagnosticLogger.safeErrorCode(for: error)
            #expect(code == expectedCode)
            try await logger.record(.syncFailed(
                syncID: syncID,
                operation: .messages,
                errorCode: code,
                statusCode: WebexDiagnosticLogger.safeStatusCode(for: error),
                retryAfterSeconds: WebexDiagnosticLogger.safeRetryAfterSeconds(for: error)
            ), at: Date(timeIntervalSince1970: TimeInterval(2_000 + ordinal)))
        }

        try await logger.record(.urlRejected(
            syncID: syncID,
            operation: .pagination,
            reason: .untrustedHost,
            hostClassification: WebexDiagnosticLogger.classifyHost(of: secretURL)
        ))

        let raw = try String(contentsOf: logger.logURL, encoding: .utf8)
        for sentinel in [
            sentinelToken,
            sentinelBody,
            sentinelRoomID,
            sentinelPath,
            "attacker.invalid",
            "roomId=",
            "Authorization",
            "Bearer "
        ] {
            #expect(!raw.contains(sentinel), "Leaked diagnostic sentinel")
        }

        let allowedKeys: Set<String> = [
            "schema_version", "timestamp", "level", "event", "sync_id", "trigger",
            "operation", "error_code", "rejection_reason", "host_classification",
            "attempt", "page", "room_ordinal", "attachment_ordinal", "status_code",
            "retry_after_seconds", "delay_milliseconds", "item_count",
            "conversation_count", "message_count", "downloaded_attachment_count",
            "pending_attachment_count", "duration_milliseconds"
        ]
        let records = try decodedRecords(in: logger.logURL)
        #expect(records.count == errors.count + 1)
        for record in records {
            #expect(Set(record.keys).isSubset(of: allowedKeys))
        }

        #expect(WebexDiagnosticLogger.safeStatusCode(
            for: WebexAPIError.unauthorized(sentinelBody)
        ) == 401)
        #expect(WebexDiagnosticLogger.safeStatusCode(
            for: WebexAPIError.attachmentUnavailable(statusCode: 410, message: sentinelBody)
        ) == 410)
        #expect(WebexDiagnosticLogger.safeRetryAfterSeconds(
            for: WebexAPIError.rateLimited(retryAfter: 1.2)
        ) == 2)
    }

    @Test func hostClassificationReturnsOnlyFixedCategories() throws {
        #expect(WebexDiagnosticLogger.classifyHost(
            of: URL(string: "https://webexapis.com/v1/rooms")
        ) == .primaryWebex)
        #expect(WebexDiagnosticLogger.classifyHost(
            of: URL(string: "https://files.webexapis.com/v1/contents/file")
        ) == .trustedWebexSubdomain)
        #expect(WebexDiagnosticLogger.classifyHost(
            of: URL(string: "https://api.ciscospark.com/v1/messages")
        ) == .legacyCiscoSpark)
        #expect(WebexDiagnosticLogger.classifyHost(
            of: URL(string: "https://webexapis.com.attacker.invalid/collect?secret=value")
        ) == .untrusted)
        #expect(WebexDiagnosticLogger.classifyHost(of: nil) == .missing)
    }

    @Test func rotationKeepsAtMostFourPrivateBackups() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let maximumSize = 650
        let logger = WebexDiagnosticLogger(
            directoryURL: directory,
            maximumFileSizeBytes: maximumSize,
            maximumBackupCount: 4
        )
        let syncID = WebexDiagnosticSyncID()

        for ordinal in 0..<80 {
            try await logger.record(.operationStarted(
                syncID: syncID,
                operation: .messages,
                attempt: 0,
                page: ordinal / 10,
                roomOrdinal: ordinal
            ))
        }

        let expectedFiles = (0...4).map { index in
            index == 0
                ? logger.logURL
                : URL(fileURLWithPath: logger.logURL.path + "." + String(index))
        }
        for file in expectedFiles {
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try permissions(at: file) == 0o600)
            let size = try #require(
                FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            ).intValue
            #expect(size <= maximumSize)
            _ = try decodedRecords(in: file)
        }
        let fifthBackup = URL(fileURLWithPath: logger.logURL.path + ".5")
        #expect(!FileManager.default.fileExists(atPath: fifthBackup.path))
        #expect(try permissions(at: directory) == 0o700)

        let retainedOrdinals = try expectedFiles
            .flatMap(decodedRecords)
            .compactMap { $0["room_ordinal"] as? Int }
        #expect(retainedOrdinals.contains(79))
        #expect(!retainedOrdinals.contains(0))

        try await logger.deleteAllLogs()
        for file in expectedFiles {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func concurrentRecordingProducesCompleteJSONLines() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = WebexDiagnosticLogger(
            directoryURL: root.appendingPathComponent("diagnostics", isDirectory: true),
            maximumFileSizeBytes: 2_000_000,
            maximumBackupCount: 0
        )
        let syncID = WebexDiagnosticSyncID()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for ordinal in 0..<100 {
                group.addTask {
                    try await logger.record(.operationStarted(
                        syncID: syncID,
                        operation: .messages,
                        attempt: 0,
                        page: nil,
                        roomOrdinal: ordinal
                    ))
                }
            }
            try await group.waitForAll()
        }

        let records = try decodedRecords(in: logger.logURL)
        #expect(records.count == 100)
        let ordinals = Set(records.compactMap { $0["room_ordinal"] as? Int })
        #expect(ordinals == Set(0..<100))
        #expect(try permissions(at: logger.logURL) == 0o600)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DesklogWebexDiagnosticsTests-" + UUID().uuidString,
                isDirectory: true
            )
    }

    private func decodedRecords(in file: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: file)
        return try data.split(separator: 0x0A).map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line))
            return try #require(object as? [String: Any])
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions]
        return try #require(value as? NSNumber).intValue
    }
}
