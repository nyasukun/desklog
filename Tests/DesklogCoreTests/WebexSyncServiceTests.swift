import DesklogCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite(.serialized) struct WebexSyncServiceTests {
    @Test func currentTokyoDaySelectsSelfRoomsDownloadsThreadsAndReplacesEdits() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let service = WebexSyncService(store: store, calendar: tokyoCalendar())
        let state = SyncScenarioState(phase: .currentInitial)
        SyncServiceURLProtocol.install { request in
            try currentDayResponse(for: request, phase: state.phase)
        }

        let now = try date("2026-07-15T03:00:00Z")
        let dayStart = try date("2026-07-14T15:00:00Z")
        let dayEnd = try date("2026-07-15T15:00:00Z")
        let initialReport = try await service.synchronize(
            accessToken: "integration-token",
            at: now,
            sessionConfiguration: stubConfiguration()
        )

        #expect(initialReport.conversationCount == 2)
        #expect(initialReport.messageCount == 4)
        #expect(initialReport.downloadedAttachmentCount == 2)
        #expect(initialReport.pendingAttachmentCount == 0)
        #expect(!initialReport.refreshedHistoricalConversation)
        #expect(initialReport.failedRoomCount == 0)
        #expect(initialReport.preservedConversationCount == 0)

        let initialEvents = try await store.events(
            from: dayStart,
            to: dayEnd.addingTimeInterval(-0.001)
        ).filter { $0.kind == .webexConversation }
        #expect(initialEvents.count == 2)
        let initialByRoom = Dictionary(uniqueKeysWithValues: initialEvents.compactMap { event in
            event.metadata["webex_room_id"].map { ($0, event) }
        })
        let group = try #require(initialByRoom["group-selected"])
        let direct = try #require(initialByRoom["direct-selected"])
        #expect(group.metadata["webex_room_type"] == "group")
        #expect(direct.metadata["webex_room_type"] == "direct")
        #expect(group.metadata["webex_local_day"] == "2026-07-15")
        #expect(direct.metadata["webex_local_day"] == "2026-07-15")
        #expect(group.metadata["webex_self_id"] == "person-me")
        #expect(group.metadata["webex_self_display_name"] == "Desklog User")
        #expect(group.metadata["webex_self_email"] == "me@example.com")
        #expect(group.text.contains("## Webex スペース: Project Space"))
        #expect(direct.text.contains("## Webex DM: Teammate"))
        #expect(group.text.contains("> 記録ユーザー（自分）: Desklog User <me@example.com>"))

        let rootRange = try #require(group.text.range(of: "ORIGINAL-ROOT-BODY"))
        let replyRange = try #require(group.text.range(of: "SELF-THREAD-REPLY"))
        #expect(rootRange.lowerBound < replyRange.lowerBound)
        #expect(group.text.contains("\n  - ["))
        #expect(occurrences(of: "添付:", in: group.text) == 2)
        #expect(group.text.contains("webex-attachments/2026-07-15/"))

        let combinedInitialText = initialEvents.map(\.text).joined(separator: "\n")
        #expect(combinedInitialText.contains("AT-START-INCLUDED"))
        #expect(!combinedInitialText.contains("OUTSIDE-BEFORE"))
        #expect(!combinedInitialText.contains("OUTSIDE-AT-END"))
        #expect(!combinedInitialText.contains("OTHER-ONLY-ROOM"))

        let downloadedFiles = try regularFiles(in: await store.webexAttachmentsDirectory)
        #expect(downloadedFiles.count == 2)
        #expect(try downloadedFiles.allSatisfy { try permissions(at: $0) == 0o600 })
        #expect(try Set(downloadedFiles.map { try String(contentsOf: $0, encoding: .utf8) }) == [
            "attachment:selected-a.pdf",
            "attachment:selected-b.txt"
        ])

        let initialRequests = SyncServiceURLProtocol.requests
        #expect(initialRequests.allSatisfy { $0.url?.host == "webexapis.com" })
        #expect(initialRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer integration-token"
        })
        let initialMessageRequests = initialRequests.filter { $0.url?.path == "/v1/messages" }
        #expect(initialMessageRequests.compactMap { queryValue("roomId", in: $0.url) } == [
            "group-selected",
            "direct-selected",
            "direct-selected",
            "other-only",
            "other-only"
        ])
        #expect(!initialMessageRequests.compactMap { queryValue("roomId", in: $0.url) }
            .contains("inactive-room"))
        let firstMessageRequestByRoom = Dictionary(
            initialMessageRequests.compactMap { request in
                queryValue("roomId", in: request.url).map { ($0, request) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(try firstMessageRequestByRoom.values.allSatisfy {
            try queryValue("before", in: $0.url).map(date) == dayEnd
        })
        let initialAttachmentRequests = initialRequests.filter {
            $0.url?.path.hasPrefix("/v1/contents/") == true
        }
        #expect(initialAttachmentRequests.compactMap { $0.url?.lastPathComponent }.sorted() == [
            "selected-a.pdf",
            "selected-b.txt"
        ])

        state.phase = .currentEdited
        let editedReport = try await service.synchronize(
            accessToken: "integration-token",
            at: now,
            sessionConfiguration: stubConfiguration()
        )
        #expect(editedReport.conversationCount == 2)
        #expect(editedReport.messageCount == 4)
        #expect(editedReport.downloadedAttachmentCount == 0)
        #expect(editedReport.pendingAttachmentCount == 0)

        let webexLog = try await onlyWebexLog(in: store)
        let rawJSONL = try String(contentsOf: webexLog, encoding: .utf8)
        #expect(!rawJSONL.contains("ORIGINAL-ROOT-BODY"))
        #expect(rawJSONL.contains("EDITED-ROOT-BODY"))
        #expect(occurrences(of: "EDITED-ROOT-BODY", in: rawJSONL) == 1)
        #expect(rawJSONL.split(separator: "\n").count == 2)

        let editedEvents = try await store.events(
            from: dayStart,
            to: dayEnd.addingTimeInterval(-0.001)
        ).filter { $0.kind == .webexConversation }
        #expect(editedEvents.count == 2)
        #expect(editedEvents.contains { $0.text.contains("EDITED-ROOT-BODY") })
        #expect(!editedEvents.contains { $0.text.contains("ORIGINAL-ROOT-BODY") })
        let allAttachmentRequests = SyncServiceURLProtocol.requests.filter {
            $0.url?.path.hasPrefix("/v1/contents/") == true
        }
        #expect(allAttachmentRequests.count == 2)
    }

    @Test func historicalSnapshotsRefreshOneRoomPerPassAndApplyNextDayEdits() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let service = WebexSyncService(store: store, calendar: tokyoCalendar())
        let state = SyncScenarioState(phase: .historyInitial)
        SyncServiceURLProtocol.install { request in
            try historicalResponse(for: request, phase: state.phase)
        }

        let firstDayNow = try date("2026-07-14T03:00:00Z")
        let firstDayStart = try date("2026-07-13T15:00:00Z")
        let firstDayEnd = try date("2026-07-14T15:00:00Z")
        let initial = try await service.synchronize(
            accessToken: "integration-token",
            at: firstDayNow,
            sessionConfiguration: stubConfiguration()
        )
        #expect(initial.conversationCount == 2)
        #expect(initial.messageCount == 2)
        #expect(!initial.refreshedHistoricalConversation)

        var priorLogText = try String(
            contentsOf: await onlyWebexLog(in: store),
            encoding: .utf8
        )
        #expect(priorLogText.contains("HISTORY-A-ORIGINAL"))
        #expect(priorLogText.contains("HISTORY-B-ORIGINAL"))

        state.phase = .historyNextDay
        let nextDayNow = try date("2026-07-15T03:00:00Z")
        let firstRefresh = try await service.synchronize(
            accessToken: "integration-token",
            at: nextDayNow,
            sessionConfiguration: stubConfiguration()
        )
        #expect(firstRefresh.conversationCount == 0)
        #expect(firstRefresh.messageCount == 0)
        #expect(firstRefresh.refreshedHistoricalConversation)

        priorLogText = try String(contentsOf: await onlyWebexLog(in: store), encoding: .utf8)
        #expect(priorLogText.contains("HISTORY-A-EDITED-NEXT-DAY"))
        #expect(!priorLogText.contains("HISTORY-A-ORIGINAL"))
        #expect(priorLogText.contains("HISTORY-B-ORIGINAL"))
        #expect(!priorLogText.contains("HISTORY-B-EDITED-NEXT-DAY"))

        let secondRefresh = try await service.synchronize(
            accessToken: "integration-token",
            at: nextDayNow,
            sessionConfiguration: stubConfiguration()
        )
        #expect(secondRefresh.conversationCount == 0)
        #expect(secondRefresh.messageCount == 0)
        #expect(secondRefresh.refreshedHistoricalConversation)

        priorLogText = try String(contentsOf: await onlyWebexLog(in: store), encoding: .utf8)
        #expect(priorLogText.contains("HISTORY-A-EDITED-NEXT-DAY"))
        #expect(priorLogText.contains("HISTORY-B-EDITED-NEXT-DAY"))
        #expect(!priorLogText.contains("HISTORY-A-ORIGINAL"))
        #expect(!priorLogText.contains("HISTORY-B-ORIGINAL"))
        #expect(occurrences(of: "HISTORY-A-EDITED-NEXT-DAY", in: priorLogText) == 1)
        #expect(occurrences(of: "HISTORY-B-EDITED-NEXT-DAY", in: priorLogText) == 1)
        #expect(priorLogText.split(separator: "\n").count == 2)

        let priorEvents = try await store.events(
            from: firstDayStart,
            to: firstDayEnd.addingTimeInterval(-0.001)
        ).filter { $0.kind == .webexConversation }
        #expect(priorEvents.count == 2)

        let messageRoomIDs = SyncServiceURLProtocol.requests
            .filter { $0.url?.path == "/v1/messages" }
            .compactMap { queryValue("roomId", in: $0.url) }
        #expect(messageRoomIDs == [
            "history-a",
            "history-a",
            "history-b",
            "history-b",
            "history-a",
            "history-a",
            "history-b",
            "history-b"
        ])
        #expect(try SyncServiceURLProtocol.requests
            .filter { $0.url?.path == "/v1/messages" }
            .filter { try queryValue("before", in: $0.url).map(date) == firstDayEnd }
            .count == 4)
        #expect(SyncServiceURLProtocol.requests.allSatisfy { $0.url?.host == "webexapis.com" })
    }

    @Test func failedRoomKeepsExistingSnapshotWhileSuccessfulRoomsAreAuthoritativelyReplaced() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let service = WebexSyncService(store: store, calendar: tokyoCalendar())
        let now = try date("2026-07-15T03:00:00Z")
        let dayStart = try date("2026-07-14T15:00:00Z")
        let dayEnd = try date("2026-07-15T15:00:00Z")
        try await store.replaceWebexConversations([
            storedConversation(
                roomID: "updated-room",
                text: "UPDATED-ROOM-OLD",
                timestamp: try date("2026-07-15T00:00:00Z")
            ),
            storedConversation(
                roomID: "failed-room",
                text: "FAILED-ROOM-PRESERVED",
                timestamp: try date("2026-07-15T00:01:00Z")
            ),
            storedConversation(
                roomID: "removed-room",
                text: "REMOVED-ROOM-OLD-SELF",
                timestamp: try date("2026-07-15T00:02:00Z")
            )
        ], on: dayStart)

        SyncServiceURLProtocol.install { request in
            let url = try validatedURL(for: request)
            switch url.path {
            case "/v1/people/me":
                return try .jsonObject([
                    "id": "person-me",
                    "emails": ["me@example.com"]
                ])
            case "/v1/rooms":
                return try .jsonObject(["items": [
                    [
                        "id": "updated-room",
                        "title": "Updated",
                        "type": "group",
                        "lastActivity": "2026-07-15T02:00:00Z"
                    ],
                    [
                        "id": "failed-room",
                        "title": "Failed",
                        "type": "group",
                        "lastActivity": "2026-07-15T02:01:00Z"
                    ],
                    [
                        "id": "removed-room",
                        "title": "No longer authored by self",
                        "type": "direct",
                        "lastActivity": "2026-07-15T02:02:00Z"
                    ]
                ]])
            case "/v1/messages":
                switch queryValue("roomId", in: url) {
                case "updated-room":
                    guard try queryValue("before", in: url).map(date) == dayEnd else {
                        return try .jsonObject(["items": []])
                    }
                    return try .jsonObject(["items": [[
                        "id": "updated-message",
                        "roomId": "updated-room",
                        "text": "UPDATED-ROOM-NEW",
                        "personId": "person-me",
                        "created": "2026-07-15T02:00:00Z"
                    ]]])
                case "failed-room":
                    return .httpStatus(404, message: "room unavailable")
                case "removed-room":
                    guard try queryValue("before", in: url).map(date) == dayEnd else {
                        return try .jsonObject(["items": []])
                    }
                    return try .jsonObject(["items": [[
                        "id": "other-message",
                        "roomId": "removed-room",
                        "text": "OTHER-AUTHOR-ONLY",
                        "personId": "person-other",
                        "created": "2026-07-15T02:02:00Z"
                    ]]])
                default:
                    throw SyncStubFailure.unexpectedRequest(url.absoluteString)
                }
            default:
                throw SyncStubFailure.unexpectedRequest(url.absoluteString)
            }
        }

        let report = try await service.synchronize(
            accessToken: "integration-token",
            at: now,
            sessionConfiguration: stubConfiguration()
        )

        #expect(report.conversationCount == 1)
        #expect(report.messageCount == 1)
        #expect(report.failedRoomCount == 1)
        #expect(report.preservedConversationCount == 1)
        let events = try await store.events(
            from: dayStart,
            to: dayEnd.addingTimeInterval(-0.001)
        ).filter { $0.kind == .webexConversation }
        let eventsByRoom = Dictionary(uniqueKeysWithValues: events.compactMap { event in
            event.metadata["webex_room_id"].map { ($0, event) }
        })
        #expect(eventsByRoom.count == 2)
        #expect(eventsByRoom["updated-room"]?.text.contains("UPDATED-ROOM-NEW") == true)
        #expect(eventsByRoom["updated-room"]?.text.contains("UPDATED-ROOM-OLD") == false)
        #expect(eventsByRoom["failed-room"]?.text == "FAILED-ROOM-PRESERVED")
        #expect(eventsByRoom["removed-room"] == nil)
    }

    @Test func roomAuthenticationFailureAbortsThePassWithoutChangingExistingSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let service = WebexSyncService(store: store, calendar: tokyoCalendar())
        let now = try date("2026-07-15T03:00:00Z")
        let dayStart = try date("2026-07-14T15:00:00Z")
        try await store.replaceWebexConversations([
            storedConversation(
                roomID: "auth-room",
                text: "AUTH-ROOM-EXISTING",
                timestamp: try date("2026-07-15T00:00:00Z")
            )
        ], on: dayStart)
        let logURL = try await onlyWebexLog(in: store)
        let before = try Data(contentsOf: logURL)

        SyncServiceURLProtocol.install { request in
            let url = try validatedURL(for: request)
            switch url.path {
            case "/v1/people/me":
                return try .jsonObject([
                    "id": "person-me",
                    "emails": ["me@example.com"]
                ])
            case "/v1/rooms":
                return try .jsonObject(["items": [[
                    "id": "auth-room",
                    "title": "Auth",
                    "type": "group",
                    "lastActivity": "2026-07-15T02:00:00Z"
                ]]])
            case "/v1/messages":
                return .httpStatus(401, message: "token expired")
            default:
                throw SyncStubFailure.unexpectedRequest(url.absoluteString)
            }
        }

        do {
            _ = try await service.synchronize(
                accessToken: "integration-token",
                at: now,
                sessionConfiguration: stubConfiguration()
            )
            Issue.record("A room authentication failure did not abort the synchronization pass")
        } catch WebexAPIError.unauthorized {
            // Expected: authentication failures remain pass-wide failures.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try Data(contentsOf: logURL) == before)
    }

    @Test func unsafeRoomRedirectIsDiagnosableWithoutPersistingSensitiveValues() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let diagnosticLogger = WebexDiagnosticLogger(
            directoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let service = WebexSyncService(
            store: store,
            calendar: tokyoCalendar(),
            diagnosticLogger: diagnosticLogger
        )
        let now = try date("2026-07-15T03:00:00Z")
        let dayStart = try date("2026-07-14T15:00:00Z")
        try await store.replaceWebexConversations([
            storedConversation(
                roomID: "sensitive-room-id",
                text: "SENSITIVE-EXISTING-BODY",
                timestamp: try date("2026-07-15T00:00:00Z")
            )
        ], on: dayStart)

        SyncServiceURLProtocol.install { request in
            let url = try validatedURL(for: request)
            switch url.path {
            case "/v1/people/me":
                return try .jsonObject([
                    "id": "sensitive-person-id",
                    "emails": ["sensitive@example.com"]
                ])
            case "/v1/rooms":
                return try .jsonObject(["items": [[
                    "id": "sensitive-room-id",
                    "title": "Sensitive room title",
                    "type": "group",
                    "lastActivity": "2026-07-15T02:00:00Z"
                ]]])
            case "/v1/messages":
                return .init(
                    statusCode: 302,
                    body: Data(),
                    headers: ["Location": "https://attacker.example/private?token=sentinel"]
                )
            default:
                throw SyncStubFailure.unexpectedRequest(url.absoluteString)
            }
        }

        let report = try await service.synchronize(
            accessToken: "integration-token",
            at: now,
            sessionConfiguration: stubConfiguration(),
            diagnosticSyncID: WebexDiagnosticLogger.makeSyncID()
        )

        #expect(report.failedRoomCount == 1)
        #expect(report.preservedConversationCount == 1)
        let diagnosticText = try String(
            contentsOf: diagnosticLogger.logURL,
            encoding: .utf8
        )
        #expect(diagnosticText.contains(#""event":"room_fetch_failed""#))
        #expect(diagnosticText.contains(#""error_code":"unsafe_pagination_url""#))
        #expect(diagnosticText.contains(#""event":"url_rejected""#))
        #expect(diagnosticText.contains(#""host_classification":"untrusted""#))
        for sensitiveValue in [
            "integration-token",
            "sensitive-room-id",
            "sensitive-person-id",
            "sensitive@example.com",
            "Sensitive room title",
            "SENSITIVE-EXISTING-BODY",
            "attacker.example",
            "sentinel"
        ] {
            #expect(!diagnosticText.contains(sensitiveValue))
        }
    }

    @Test func cancellationDuringHistoricalRefreshIsPropagated() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let service = WebexSyncService(store: store, calendar: tokyoCalendar())
        let historicalDay = try date("2026-07-13T15:00:00Z")
        try await store.replaceWebexConversations([
            storedConversation(
                roomID: "historical-cancel-room",
                text: "HISTORICAL-BEFORE-CANCEL",
                timestamp: try date("2026-07-14T00:00:00Z")
            )
        ], on: historicalDay)

        SyncServiceURLProtocol.install { request in
            let url = try validatedURL(for: request)
            switch url.path {
            case "/v1/people/me":
                return try .jsonObject([
                    "id": "person-me",
                    "emails": ["me@example.com"]
                ])
            case "/v1/rooms":
                return try .jsonObject(["items": []])
            case "/v1/messages":
                guard try queryValue("before", in: url).map(date) ==
                    date("2026-07-14T15:00:00Z") else {
                    return try .jsonObject(["items": []])
                }
                Thread.sleep(forTimeInterval: 0.5)
                return try .jsonObject(["items": [[
                    "id": "historical-cancel-message",
                    "roomId": "historical-cancel-room",
                    "text": "SHOULD-NOT-BE-COMMITTED",
                    "personId": "person-me",
                    "created": "2026-07-14T00:00:00Z"
                ]]])
            default:
                throw SyncStubFailure.unexpectedRequest(url.absoluteString)
            }
        }

        let synchronization = Task {
            try await service.synchronize(
                accessToken: "integration-token",
                at: try date("2026-07-15T03:00:00Z"),
                sessionConfiguration: stubConfiguration()
            )
        }
        var reachedHistoricalRequest = false
        for _ in 0..<100 {
            if SyncServiceURLProtocol.requests.contains(where: {
                $0.url?.path == "/v1/messages"
            }) {
                reachedHistoricalRequest = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(reachedHistoricalRequest)
        synchronization.cancel()

        do {
            _ = try await synchronization.value
            Issue.record("Historical cancellation was swallowed as a successful synchronization")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let historicalEvents = try await store.events(
            from: historicalDay,
            to: try date("2026-07-14T15:00:00Z").addingTimeInterval(-0.001)
        ).filter { $0.kind == .webexConversation }
        #expect(historicalEvents.count == 1)
        #expect(historicalEvents.first?.text == "HISTORICAL-BEFORE-CANCEL")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogWebexSyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func tokyoCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncServiceURLProtocol.self]
        return configuration
    }

    private func onlyWebexLog(in store: WorklogStore) async throws -> URL {
        let directory = await store.webexDirectory
        let logs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
        return try #require(logs.count == 1 ? logs[0] : nil)
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                ? url
                : nil
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? NSNumber).intValue
    }

    private func storedConversation(
        roomID: String,
        text: String,
        timestamp: Date
    ) -> WorklogEvent {
        WorklogEvent(
            timestamp: timestamp,
            kind: .webexConversation,
            text: text,
            metadata: [
                "webex_room_id": roomID,
                "webex_room_type": "group",
                "webex_room_title": roomID,
                "webex_local_day": "2026-07-15",
                "webex_message_count": "1",
                "webex_self_id": "person-me"
            ]
        )
    }
}

private enum SyncScenarioPhase {
    case currentInitial
    case currentEdited
    case historyInitial
    case historyNextDay
}

private final class SyncScenarioState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPhase: SyncScenarioPhase

    init(phase: SyncScenarioPhase) {
        storedPhase = phase
    }

    var phase: SyncScenarioPhase {
        get { lock.withLock { storedPhase } }
        set { lock.withLock { storedPhase = newValue } }
    }
}

private func currentDayResponse(
    for request: URLRequest,
    phase: SyncScenarioPhase
) throws -> SyncServiceURLProtocol.Stub {
    let url = try validatedURL(for: request)
    switch url.path {
    case "/v1/people/me":
        return try .jsonObject([
            "id": "person-me",
            "emails": ["me@example.com"],
            "displayName": "Desklog User"
        ])
    case "/v1/rooms":
        return try .jsonObject(["items": [
            [
                "id": "group-selected",
                "title": "Project Space",
                "type": "group",
                "lastActivity": "2026-07-15T01:00:00Z"
            ],
            [
                "id": "direct-selected",
                "title": "Teammate",
                "type": "direct",
                "lastActivity": "2026-07-15T02:00:00Z"
            ],
            [
                "id": "other-only",
                "title": "Other People",
                "type": "group",
                "lastActivity": "2026-07-15T03:00:00Z"
            ],
            [
                "id": "inactive-room",
                "title": "Inactive",
                "type": "group",
                "lastActivity": "2026-07-14T14:59:59Z"
            ]
        ]])
    case "/v1/messages":
        switch queryValue("roomId", in: url) {
        case "group-selected":
            let rootBody = phase == .currentEdited
                ? "EDITED-ROOT-BODY"
                : "ORIGINAL-ROOT-BODY AT-START-INCLUDED"
            var root: [String: Any] = [
                "id": "g-root",
                "roomId": "group-selected",
                "text": rootBody,
                "personId": "person-other",
                "personEmail": "other@example.com",
                "created": "2026-07-14T15:00:00.000Z",
                "files": [
                    "https://webexapis.com/v1/contents/selected-a.pdf",
                    "https://webexapis.com/v1/contents/selected-b.txt"
                ]
            ]
            if phase == .currentEdited {
                root["updated"] = "2026-07-15T02:30:00Z"
            }
            return try .jsonObject(["items": [
                [
                    "id": "g-before",
                    "roomId": "group-selected",
                    "text": "OUTSIDE-BEFORE",
                    "personId": "person-other",
                    "created": "2026-07-14T14:59:59.999Z",
                    "files": ["https://webexapis.com/v1/contents/outside-before.bin"]
                ],
                root,
                [
                    "id": "g-reply",
                    "roomId": "group-selected",
                    "text": "SELF-THREAD-REPLY",
                    "personId": "person-me",
                    "personEmail": "me@example.com",
                    "created": "2026-07-14T15:05:00Z",
                    "parentId": "g-root"
                ],
                [
                    "id": "g-at-end",
                    "roomId": "group-selected",
                    "text": "OUTSIDE-AT-END",
                    "personId": "person-other",
                    "created": "2026-07-15T15:00:00Z",
                    "files": ["https://webexapis.com/v1/contents/outside-end.bin"]
                ]
            ]])
        case "direct-selected":
            guard try queryValue("before", in: url).map(date) ==
                date("2026-07-15T15:00:00Z") else {
                return try .jsonObject(["items": []])
            }
            return try .jsonObject(["items": [
                [
                    "id": "d-other",
                    "roomId": "direct-selected",
                    "text": "DIRECT-OTHER",
                    "personId": "person-other",
                    "created": "2026-07-15T00:00:00Z"
                ],
                [
                    "id": "d-self",
                    "roomId": "direct-selected",
                    "text": "DIRECT-SELF-BY-EMAIL",
                    "personEmail": "ME@EXAMPLE.COM",
                    "created": "2026-07-15T00:01:00Z"
                ]
            ]])
        case "other-only":
            guard try queryValue("before", in: url).map(date) ==
                date("2026-07-15T15:00:00Z") else {
                return try .jsonObject(["items": []])
            }
            return try .jsonObject(["items": [[
                "id": "o-other",
                "roomId": "other-only",
                "text": "OTHER-ONLY-ROOM",
                "personId": "person-other",
                "created": "2026-07-15T01:00:00Z",
                "files": ["https://webexapis.com/v1/contents/unselected-secret.bin"]
            ]]])
        default:
            throw SyncStubFailure.unexpectedRequest(url.absoluteString)
        }
    case "/v1/contents/selected-a.pdf", "/v1/contents/selected-b.txt":
        return .data(Data("attachment:\(url.lastPathComponent)".utf8))
    default:
        throw SyncStubFailure.unexpectedRequest(url.absoluteString)
    }
}

private func historicalResponse(
    for request: URLRequest,
    phase: SyncScenarioPhase
) throws -> SyncServiceURLProtocol.Stub {
    let url = try validatedURL(for: request)
    switch url.path {
    case "/v1/people/me":
        return try .jsonObject([
            "id": "person-me",
            "emails": ["me@example.com"]
        ])
    case "/v1/rooms":
        return try .jsonObject(["items": [
            [
                "id": "history-a",
                "title": "History A",
                "type": "group",
                "lastActivity": "2026-07-14T10:00:00Z"
            ],
            [
                "id": "history-b",
                "title": "History B",
                "type": "direct",
                "lastActivity": "2026-07-14T10:30:00Z"
            ]
        ]])
    case "/v1/messages":
        guard let roomID = queryValue("roomId", in: url),
              roomID == "history-a" || roomID == "history-b" else {
            throw SyncStubFailure.unexpectedRequest(url.absoluteString)
        }
        guard try queryValue("before", in: url).map(date) ==
            date("2026-07-14T15:00:00Z") else {
            return try .jsonObject(["items": []])
        }
        let suffix = roomID == "history-a" ? "A" : "B"
        let created = roomID == "history-a"
            ? "2026-07-13T16:00:00Z"
            : "2026-07-13T17:00:00Z"
        let isEdited = phase == .historyNextDay
        var message: [String: Any] = [
            "id": "history-message-\(suffix.lowercased())",
            "roomId": roomID,
            "text": isEdited
                ? "HISTORY-\(suffix)-EDITED-NEXT-DAY"
                : "HISTORY-\(suffix)-ORIGINAL",
            "personId": "person-me",
            "created": created
        ]
        if isEdited {
            message["updated"] = "2026-07-15T01:00:00Z"
        }
        return try .jsonObject(["items": [message]])
    default:
        throw SyncStubFailure.unexpectedRequest(url.absoluteString)
    }
}

private func validatedURL(for request: URLRequest) throws -> URL {
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer integration-token",
          let url = request.url,
          url.scheme == "https",
          url.host == "webexapis.com" else {
        throw SyncStubFailure.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
    }
    return url
}

private func queryValue(_ name: String, in url: URL?) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func date(_ value: String) throws -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let result = fractional.date(from: value) { return result }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return try #require(wholeSeconds.date(from: value))
}

private func occurrences(of needle: String, in value: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return value.components(separatedBy: needle).count - 1
}

private enum SyncStubFailure: Error {
    case unexpectedRequest(String)
}

private final class SyncServiceURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        static func jsonObject(_ object: Any) throws -> Stub {
            Stub(
                statusCode: 200,
                body: try JSONSerialization.data(withJSONObject: object),
                headers: ["Content-Type": "application/json"]
            )
        }

        static func data(_ body: Data) -> Stub {
            Stub(
                statusCode: 200,
                body: body,
                headers: ["Content-Type": "application/octet-stream"]
            )
        }

        static func httpStatus(_ statusCode: Int, message: String) -> Stub {
            Stub(
                statusCode: statusCode,
                body: Data(#"{"message":"\#(message)"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Stub)?
    private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func install(_ handler: @escaping (URLRequest) throws -> Stub) {
        lock.withLock {
            recordedRequests.removeAll()
            Self.handler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> ((URLRequest) throws -> Stub)? in
            Self.recordedRequests.append(request)
            return Self.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let stub = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                  ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
