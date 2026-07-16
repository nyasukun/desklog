import Foundation

public struct WebexSyncReport: Sendable, Equatable {
    public let conversationCount: Int
    public let messageCount: Int
    public let downloadedAttachmentCount: Int
    public let pendingAttachmentCount: Int
    public let refreshedHistoricalConversation: Bool
    public let failedRoomCount: Int
    public let preservedConversationCount: Int

    public init(
        conversationCount: Int,
        messageCount: Int,
        downloadedAttachmentCount: Int,
        pendingAttachmentCount: Int,
        refreshedHistoricalConversation: Bool,
        failedRoomCount: Int = 0,
        preservedConversationCount: Int = 0
    ) {
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.downloadedAttachmentCount = downloadedAttachmentCount
        self.pendingAttachmentCount = pendingAttachmentCount
        self.refreshedHistoricalConversation = refreshedHistoricalConversation
        self.failedRoomCount = failedRoomCount
        self.preservedConversationCount = preservedConversationCount
    }
}

/// Coordinates one deterministic Webex polling pass.
///
/// The current local day is rebuilt from the API on every pass. One previously
/// collected room/day is also revisited in round-robin order, allowing edits
/// made after that day ended to replace the old local snapshot without turning
/// every poll into an unbounded historical scan.
public actor WebexSyncService {
    private let store: WorklogStore
    private let diagnosticLogger: WebexDiagnosticLogger?
    private var calendar: Calendar
    private var historicalRefreshIndex = 0

    public init(
        store: WorklogStore,
        calendar: Calendar = .current,
        diagnosticLogger: WebexDiagnosticLogger? = nil
    ) {
        self.store = store
        self.calendar = calendar
        self.diagnosticLogger = diagnosticLogger
    }

    public func synchronize(
        accessToken: String,
        at now: Date = Date(),
        sessionConfiguration: URLSessionConfiguration? = nil,
        diagnosticSyncID: WebexDiagnosticSyncID? = nil
    ) async throws -> WebexSyncReport {
        guard let today = calendar.dateInterval(of: .day, for: now) else {
            await recordFailure(
                syncID: diagnosticSyncID,
                operation: .persistence,
                error: WebexSyncError.cannotDetermineLocalDay
            )
            throw WebexSyncError.cannotDetermineLocalDay
        }

        let client = WebexAPIClient(
            accessToken: accessToken,
            sessionConfiguration: sessionConfiguration
        )
        let identity: WebexIdentity
        let identityStartedAt = Date()
        await recordOperationStarted(syncID: diagnosticSyncID, operation: .identity)
        do {
            identity = try await client.identity()
            await recordOperationCompleted(
                syncID: diagnosticSyncID,
                operation: .identity,
                itemCount: 1,
                startedAt: identityStartedAt
            )
        } catch is CancellationError {
            await recordCancellation(syncID: diagnosticSyncID, operation: .identity)
            throw CancellationError()
        } catch {
            await recordFailure(syncID: diagnosticSyncID, operation: .identity, error: error)
            throw error
        }

        let rooms: [WebexRoom]
        let roomsStartedAt = Date()
        await recordOperationStarted(syncID: diagnosticSyncID, operation: .rooms)
        do {
            rooms = try await client.rooms(activeSince: today.start)
            await recordOperationCompleted(
                syncID: diagnosticSyncID,
                operation: .rooms,
                itemCount: rooms.count,
                startedAt: roomsStartedAt
            )
        } catch is CancellationError {
            await recordCancellation(syncID: diagnosticSyncID, operation: .rooms)
            throw CancellationError()
        } catch {
            await recordFailure(syncID: diagnosticSyncID, operation: .rooms, error: error)
            throw error
        }

        let existingCurrentEvents: [WorklogEvent]
        do {
            existingCurrentEvents = try await webexEvents(in: today)
        } catch {
            await recordFailure(syncID: diagnosticSyncID, operation: .persistence, error: error)
            throw error
        }
        var messagesByRoom: [String: [WebexMessage]] = [:]
        var successfulRooms: [WebexRoom] = []
        var failedRoomIDs: Set<String> = []
        for (roomIndex, room) in rooms.enumerated() {
            try Task.checkCancellation()
            let roomOrdinal = roomIndex + 1
            let messagesStartedAt = Date()
            await recordOperationStarted(
                syncID: diagnosticSyncID,
                operation: .messages,
                roomOrdinal: roomOrdinal
            )
            do {
                messagesByRoom[room.id] = try await client.messages(
                    in: room.id,
                    from: today.start,
                    before: today.end
                )
                successfulRooms.append(room)
                await recordOperationCompleted(
                    syncID: diagnosticSyncID,
                    operation: .messages,
                    itemCount: messagesByRoom[room.id]?.count,
                    startedAt: messagesStartedAt
                )
            } catch is CancellationError {
                await recordCancellation(syncID: diagnosticSyncID, operation: .messages)
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if Self.isAuthenticationFailure(error) {
                    await recordFailure(
                        syncID: diagnosticSyncID,
                        operation: .messages,
                        error: error
                    )
                    throw error
                }
                failedRoomIDs.insert(room.id)
                await recordRoomFailure(
                    syncID: diagnosticSyncID,
                    roomOrdinal: roomOrdinal,
                    error: error
                )
                await recordURLRejectionIfNeeded(
                    syncID: diagnosticSyncID,
                    operation: .pagination,
                    error: error
                )
            }
        }

        let batches = WebexConversationBuilder.build(
            identity: identity,
            rooms: successfulRooms,
            messagesByRoom: messagesByRoom,
            start: today.start,
            end: today.end
        )
        let successfulRoomIDs = Set(successfulRooms.map(\.id))
        let eventsToPreserve = existingCurrentEvents.filter { event in
            guard let roomID = event.metadata["webex_room_id"] else { return false }
            return !successfulRoomIDs.contains(roomID)
        }
        let existingRoomIDs = Set(existingCurrentEvents.compactMap {
            $0.metadata["webex_room_id"]
        })
        let current: PersistenceResult
        let persistenceStartedAt = Date()
        await recordOperationStarted(syncID: diagnosticSyncID, operation: .persistence)
        do {
            current = try await persist(
                batches: batches,
                identity: identity,
                client: client,
                day: today.start,
                preserving: eventsToPreserve,
                diagnosticSyncID: diagnosticSyncID
            )
            await recordOperationCompleted(
                syncID: diagnosticSyncID,
                operation: .persistence,
                itemCount: batches.count,
                startedAt: persistenceStartedAt,
                statusCode: nil
            )
        } catch is CancellationError {
            await recordCancellation(syncID: diagnosticSyncID, operation: .persistence)
            throw CancellationError()
        } catch {
            await recordFailure(syncID: diagnosticSyncID, operation: .persistence, error: error)
            throw error
        }

        let refreshedHistorical = try await refreshOneHistoricalConversation(
            before: today.start,
            identity: identity,
            client: client,
            diagnosticSyncID: diagnosticSyncID
        )
        return WebexSyncReport(
            conversationCount: batches.count,
            messageCount: batches.reduce(0) { $0 + $1.messages.count },
            downloadedAttachmentCount: current.downloadedAttachmentCount +
                refreshedHistorical.downloadedAttachmentCount,
            pendingAttachmentCount: current.pendingAttachmentCount +
                refreshedHistorical.pendingAttachmentCount,
            refreshedHistoricalConversation: refreshedHistorical.didRefresh,
            failedRoomCount: failedRoomIDs.count,
            preservedConversationCount: failedRoomIDs.intersection(existingRoomIDs).count
        )
    }

    private func refreshOneHistoricalConversation(
        before today: Date,
        identity: WebexIdentity,
        client: WebexAPIClient,
        diagnosticSyncID: WebexDiagnosticSyncID?
    ) async throws -> PersistenceResult {
        let refreshStartedAt = Date()
        await recordOperationStarted(syncID: diagnosticSyncID, operation: .historicalRefresh)
        do {
            let existing = try await store.events(from: .distantPast, to: today)
                .filter { $0.kind == .webexConversation && $0.timestamp < today }
                .sorted {
                    if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                    return ($0.metadata["webex_room_id"] ?? "") <
                        ($1.metadata["webex_room_id"] ?? "")
                }
            guard !existing.isEmpty else {
                await recordOperationCompleted(
                    syncID: diagnosticSyncID,
                    operation: .historicalRefresh,
                    itemCount: 0,
                    startedAt: refreshStartedAt,
                    statusCode: nil
                )
                return .empty
            }
            let index = historicalRefreshIndex % existing.count
            historicalRefreshIndex = (index + 1) % existing.count
            let snapshot = existing[index]
            guard let roomID = snapshot.metadata["webex_room_id"],
                  !roomID.isEmpty,
                  let interval = calendar.dateInterval(of: .day, for: snapshot.timestamp) else {
                await recordOperationCompleted(
                    syncID: diagnosticSyncID,
                    operation: .historicalRefresh,
                    itemCount: 0,
                    startedAt: refreshStartedAt,
                    statusCode: nil
                )
                return .empty
            }

            let messages = try await client.messages(
                in: roomID,
                from: interval.start,
                before: interval.end
            )
            let room = WebexRoom(
                id: roomID,
                title: snapshot.metadata["webex_room_title"] ?? "名称なし",
                type: snapshot.metadata["webex_room_type"] ?? "group"
            )
            let batches = WebexConversationBuilder.build(
                identity: identity,
                rooms: [room],
                messagesByRoom: [roomID: messages],
                start: interval.start,
                end: interval.end
            )
            let otherRooms = try await webexEvents(in: interval).filter {
                $0.metadata["webex_room_id"] != roomID
            }
            var result = try await persist(
                batches: batches,
                identity: identity,
                client: client,
                day: interval.start,
                preserving: otherRooms,
                diagnosticSyncID: diagnosticSyncID
            )
            result.didRefresh = true
            await recordOperationCompleted(
                syncID: diagnosticSyncID,
                operation: .historicalRefresh,
                itemCount: batches.count,
                startedAt: refreshStartedAt,
                statusCode: nil
            )
            return result
        } catch is CancellationError {
            await recordCancellation(syncID: diagnosticSyncID, operation: .historicalRefresh)
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if Self.isAuthenticationFailure(error) {
                await recordFailure(
                    syncID: diagnosticSyncID,
                    operation: .historicalRefresh,
                    error: error
                )
                throw error
            }
            await recordHistoricalFailure(syncID: diagnosticSyncID, error: error)
            await recordURLRejectionIfNeeded(
                syncID: diagnosticSyncID,
                operation: .historicalRefresh,
                error: error
            )
            // Historical validation is best effort. A room may have been left
            // or deleted; failure must not discard the successfully rebuilt
            // current-day snapshot. It will be retried in a later round.
            return .empty
        }
    }

    private func persist(
        batches: [WebexRoomMessageBatch],
        identity: WebexIdentity,
        client: WebexAPIClient,
        day: Date,
        preserving preservedEvents: [WorklogEvent],
        diagnosticSyncID: WebexDiagnosticSyncID?
    ) async throws -> PersistenceResult {
        var events = preservedEvents
        var downloadedAttachmentCount = 0
        var pendingAttachmentCount = 0

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            var attachmentPaths: WebexMessageAttachmentPaths = [:]
            var attachmentOrdinal = 0
            for message in batch.messages {
                for (index, remoteURL) in message.files.enumerated() {
                    attachmentOrdinal += 1
                    if attachmentPaths[message.id]?[remoteURL.absoluteString] != nil {
                        continue
                    }
                    let destination = try await store.webexAttachmentURL(
                        on: day,
                        roomID: batch.room.id,
                        messageID: message.id,
                        filename: remoteURL.lastPathComponent,
                        index: index
                    )
                    do {
                        if !FileManager.default.fileExists(atPath: destination.path) {
                            _ = try await client.downloadAttachment(
                                from: remoteURL,
                                to: destination,
                                allowUnscannable: true
                            )
                            downloadedAttachmentCount += 1
                        }
                        try await store.finalizeWebexAttachment(at: destination)
                        attachmentPaths[message.id, default: [:]][remoteURL.absoluteString] =
                            destination.path
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Quarantined or temporarily unavailable attachments
                        // remain pending and are retried on the next pass.
                        pendingAttachmentCount += 1
                        await recordAttachmentFailure(
                            syncID: diagnosticSyncID,
                            roomOrdinal: batchIndex + 1,
                            attachmentOrdinal: attachmentOrdinal,
                            error: error
                        )
                        await recordURLRejectionIfNeeded(
                            syncID: diagnosticSyncID,
                            operation: .attachment,
                            error: error
                        )
                    }
                }
            }

            let text = WebexConversationFormatter.format(
                [batch],
                identity: identity,
                attachmentLocalPaths: attachmentPaths,
                timeZone: calendar.timeZone
            )
            let timestamp = batch.messages.map(\.created).max() ?? day
            var metadata = [
                "webex_room_id": batch.room.id,
                "webex_room_type": batch.room.type,
                "webex_room_title": batch.room.title,
                "webex_local_day": localDayString(day),
                "webex_message_count": String(batch.messages.count),
                "webex_self_id": identity.id
            ]
            if let displayName = normalizedIdentityValue(identity.displayName) {
                metadata["webex_self_display_name"] = displayName
            }
            if let email = identity.emails.lazy.compactMap(normalizedIdentityValue).first {
                metadata["webex_self_email"] = email
            }
            events.append(WorklogEvent(
                timestamp: timestamp,
                kind: .webexConversation,
                text: text,
                metadata: metadata
            ))
        }

        try await store.replaceWebexConversations(events, on: day)
        return PersistenceResult(
            downloadedAttachmentCount: downloadedAttachmentCount,
            pendingAttachmentCount: pendingAttachmentCount,
            didRefresh: false
        )
    }

    private func localDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func normalizedIdentityValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private func webexEvents(in interval: DateInterval) async throws -> [WorklogEvent] {
        try await store.events(
            from: interval.start,
            to: interval.end.addingTimeInterval(-0.001)
        ).filter { $0.kind == .webexConversation }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? WebexAPIError else { return false }
        switch error {
        case .invalidAccessToken, .unauthorized, .forbidden:
            return true
        default:
            return false
        }
    }

    private func recordOperationStarted(
        syncID: WebexDiagnosticSyncID?,
        operation: WebexDiagnosticOperation,
        roomOrdinal: Int? = nil
    ) async {
        guard let syncID else { return }
        await record(.operationStarted(
            syncID: syncID,
            operation: operation,
            attempt: 1,
            page: nil,
            roomOrdinal: roomOrdinal
        ))
    }

    private func recordOperationCompleted(
        syncID: WebexDiagnosticSyncID?,
        operation: WebexDiagnosticOperation,
        itemCount: Int?,
        startedAt: Date,
        statusCode: Int? = 200
    ) async {
        guard let syncID else { return }
        await record(.operationCompleted(
            syncID: syncID,
            operation: operation,
            statusCode: statusCode,
            itemCount: itemCount,
            durationMilliseconds: Self.durationMilliseconds(since: startedAt)
        ))
    }

    private func recordFailure(
        syncID: WebexDiagnosticSyncID?,
        operation: WebexDiagnosticOperation,
        error: Error
    ) async {
        guard let syncID else { return }
        await record(.syncFailed(
            syncID: syncID,
            operation: operation,
            errorCode: WebexDiagnosticLogger.safeErrorCode(for: error),
            statusCode: WebexDiagnosticLogger.safeStatusCode(for: error),
            retryAfterSeconds: WebexDiagnosticLogger.safeRetryAfterSeconds(for: error)
        ))
        await recordURLRejectionIfNeeded(syncID: syncID, operation: operation, error: error)
    }

    private func recordRoomFailure(
        syncID: WebexDiagnosticSyncID?,
        roomOrdinal: Int,
        error: Error
    ) async {
        guard let syncID else { return }
        await record(.roomFetchFailed(
            syncID: syncID,
            roomOrdinal: roomOrdinal,
            errorCode: WebexDiagnosticLogger.safeErrorCode(for: error),
            statusCode: WebexDiagnosticLogger.safeStatusCode(for: error),
            retryAfterSeconds: WebexDiagnosticLogger.safeRetryAfterSeconds(for: error)
        ))
    }

    private func recordAttachmentFailure(
        syncID: WebexDiagnosticSyncID?,
        roomOrdinal: Int,
        attachmentOrdinal: Int,
        error: Error
    ) async {
        guard let syncID else { return }
        await record(.attachmentFailed(
            syncID: syncID,
            roomOrdinal: roomOrdinal,
            attachmentOrdinal: attachmentOrdinal,
            errorCode: WebexDiagnosticLogger.safeErrorCode(for: error),
            statusCode: WebexDiagnosticLogger.safeStatusCode(for: error),
            retryAfterSeconds: WebexDiagnosticLogger.safeRetryAfterSeconds(for: error)
        ))
    }

    private func recordHistoricalFailure(
        syncID: WebexDiagnosticSyncID?,
        error: Error
    ) async {
        guard let syncID else { return }
        await record(.historicalRefreshFailed(
            syncID: syncID,
            errorCode: WebexDiagnosticLogger.safeErrorCode(for: error),
            statusCode: WebexDiagnosticLogger.safeStatusCode(for: error),
            retryAfterSeconds: WebexDiagnosticLogger.safeRetryAfterSeconds(for: error)
        ))
    }

    private func recordCancellation(
        syncID: WebexDiagnosticSyncID?,
        operation: WebexDiagnosticOperation
    ) async {
        guard let syncID else { return }
        await record(.syncCancelled(syncID: syncID, operation: operation))
    }

    private func recordURLRejectionIfNeeded(
        syncID: WebexDiagnosticSyncID?,
        operation: WebexDiagnosticOperation,
        error: Error
    ) async {
        guard let syncID,
              let rejection = Self.safeRejectionDetails(for: error) else { return }
        await record(.urlRejected(
            syncID: syncID,
            operation: operation,
            reason: rejection.reason,
            hostClassification: WebexDiagnosticLogger.classifyHost(of: rejection.url)
        ))
    }

    private func record(_ event: WebexDiagnosticEvent) async {
        guard let diagnosticLogger else { return }
        try? await diagnosticLogger.record(event)
    }

    private static func durationMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func safeRejectionDetails(
        for error: Error
    ) -> (url: URL?, reason: WebexDiagnosticRejectionReason)? {
        switch error {
        case WebexAPIError.unsafePaginationURL(let url):
            return (url, rejectionReason(for: url, expectsAPIPath: true))
        case WebexAPIError.unsafeAttachmentURL(let url):
            return (url, rejectionReason(for: url, expectsAPIPath: false))
        case WebexAPIError.paginationLoop(let url):
            return (url, .paginationLoop)
        case WebexAPIError.tooManyRedirects:
            return (nil, .tooManyRedirects)
        default:
            return nil
        }
    }

    private static func rejectionReason(
        for url: URL,
        expectsAPIPath: Bool
    ) -> WebexDiagnosticRejectionReason {
        guard let scheme = url.scheme else { return .missingScheme }
        guard scheme.caseInsensitiveCompare("https") == .orderedSame else {
            return .insecureScheme
        }
        guard url.user == nil, url.password == nil else { return .embeddedCredentials }
        guard url.port == nil || url.port == 443 else { return .disallowedPort }
        guard url.host != nil else { return .missingHost }
        guard WebexDiagnosticLogger.classifyHost(of: url) != .untrusted else {
            return .untrustedHost
        }
        guard url.fragment == nil else { return .fragmentPresent }
        if expectsAPIPath,
           url.path != "/v1",
           url.path != "/v1/",
           !url.path.hasPrefix("/v1/") {
            return .pathOutsideAPI
        }
        return .originMismatch
    }
}

public enum WebexSyncError: LocalizedError, Sendable, Equatable {
    case cannotDetermineLocalDay

    public var errorDescription: String? {
        switch self {
        case .cannotDetermineLocalDay:
            return "ローカル日付のWebex収集範囲を計算できません。"
        }
    }
}

private struct PersistenceResult {
    var downloadedAttachmentCount: Int
    var pendingAttachmentCount: Int
    var didRefresh: Bool

    static let empty = PersistenceResult(
        downloadedAttachmentCount: 0,
        pendingAttachmentCount: 0,
        didRefresh: false
    )
}
