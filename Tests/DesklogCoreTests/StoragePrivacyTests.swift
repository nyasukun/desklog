import DesklogCore
import Foundation
import Testing

@Suite struct StoragePrivacyTests {
    @Test func cancelledCaptureRemovesOnlyScreenshotsWithoutPersistedEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogCaptureCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persisted = root.appendingPathComponent("persisted.jpg")
        let orphaned = root.appendingPathComponent("orphaned.jpg")
        try Data("persisted".utf8).write(to: persisted)
        try Data("orphaned".utf8).write(to: orphaned)

        var tracker = CaptureArtifactTracker(urls: [persisted, orphaned])
        tracker.markPersisted(persisted)
        tracker.discardUnpersisted()

        #expect(FileManager.default.fileExists(atPath: persisted.path))
        #expect(!FileManager.default.fileExists(atPath: orphaned.path))
        #expect(tracker.unpersistedURLs.isEmpty)
    }

    @Test func worklogFilesAndDirectoriesUsePrivatePermissions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let date = Date(timeIntervalSince1970: 10_000)

        try await store.append(WorklogEvent(timestamp: date, kind: .system, text: "private"))
        let capture = try await store.captureURL(at: date)
        let summary = try await store.saveSummary("private summary", at: date)

        #expect(try permissions(at: root) == 0o700)
        #expect(try permissions(at: capture.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(at: summary) == 0o600)

        let log = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "jsonl" }
        )
        #expect(try permissions(at: log) == 0o600)
    }

    @Test func webexSnapshotsReplaceEditedTextWithoutRewritingAppendOnlyLogs() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let day = Date(timeIntervalSince1970: 100_000)
        let appendOnlyEvent = WorklogEvent(
            timestamp: day,
            kind: .system,
            text: "append-only sentinel"
        )
        try await store.append(appendOnlyEvent)
        let appendOnlyLog = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "jsonl" }
        )
        let appendOnlyBefore = try Data(contentsOf: appendOnlyLog)

        let original = webexConversation(
            timestamp: day.addingTimeInterval(10),
            roomID: "room-a",
            text: "old body that must disappear"
        )
        try await store.replaceWebexConversations([original], on: day)

        let edited = webexConversation(
            timestamp: day.addingTimeInterval(10),
            roomID: "room-a",
            text: "edited body"
        )
        let otherRoom = webexConversation(
            timestamp: day.addingTimeInterval(20),
            roomID: "room-b",
            text: "another conversation"
        )
        // Supplying the same room twice must retain only the last snapshot.
        try await store.replaceWebexConversations([original, edited, otherRoom], on: day)

        let webexDirectory = await store.webexDirectory
        let webexLog = try #require(
            FileManager.default.contentsOfDirectory(
                at: webexDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "jsonl" }
        )
        let storedText = try String(contentsOf: webexLog, encoding: .utf8)
        #expect(!storedText.contains("old body that must disappear"))
        #expect(storedText.contains("edited body"))
        #expect(storedText.split(separator: "\n").count == 2)
        #expect(try permissions(at: webexDirectory) == 0o700)
        #expect(try permissions(at: webexLog) == 0o600)
        #expect(try Data(contentsOf: appendOnlyLog) == appendOnlyBefore)

        let loaded = try await store.events(
            from: day.addingTimeInterval(-1),
            to: day.addingTimeInterval(30)
        )
        #expect(loaded.contains(appendOnlyEvent))
        #expect(loaded.filter { $0.kind == .webexConversation }.map(\.text) == [
            "edited body",
            "another conversation"
        ])

        try await store.replaceWebexConversations([], on: day)
        #expect(!FileManager.default.fileExists(atPath: webexLog.path))
        #expect(FileManager.default.fileExists(atPath: appendOnlyLog.path))
    }

    @Test func webexSnapshotBoundaryRejectsOtherEventKindsAndMissingRoomIDs() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let day = Date(timeIntervalSince1970: 200_000)

        do {
            try await store.replaceWebexConversations([
                WorklogEvent(timestamp: day, kind: .system, text: "wrong kind")
            ], on: day)
            Issue.record("A non-Webex event crossed the Webex storage boundary")
        } catch let error as WorklogStoreError {
            #expect(error == .invalidWebexConversationKind)
        }

        do {
            try await store.replaceWebexConversations([
                WorklogEvent(timestamp: day, kind: .webexConversation, text: "missing room")
            ], on: day)
            Issue.record("A Webex event without a room ID was persisted")
        } catch let error as WorklogStoreError {
            #expect(error == .missingWebexRoomID)
        }
    }

    @Test func webexAttachmentDestinationsAreStablePrivateAndTraversalSafe() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let day = Date(timeIntervalSince1970: 300_000)

        let destination = try await store.webexAttachmentURL(
            on: day,
            roomID: "../../outside-room",
            messageID: "../message/../../../outside-message",
            filename: "../../secrets/token.txt",
            index: 2
        )
        let repeated = try await store.webexAttachmentURL(
            on: day,
            roomID: "../../outside-room",
            messageID: "../message/../../../outside-message",
            filename: "../../secrets/token.txt",
            index: 2
        )
        #expect(destination == repeated)

        let attachmentRoot = await store.webexAttachmentsDirectory
        let rootPath = attachmentRoot.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        #expect(destinationPath.hasPrefix(rootPath + "/"))
        #expect(destination.pathExtension == "txt")
        let relativeComponents = destinationPath
            .dropFirst(rootPath.count)
            .split(separator: "/")
        #expect(relativeComponents.count == 4)
        #expect(!relativeComponents.contains(".."))

        try Data("private attachment".utf8).write(to: destination, options: .atomic)
        try await store.finalizeWebexAttachment(at: destination)
        #expect(try permissions(at: destination) == 0o600)
        #expect(try permissions(at: attachmentRoot) == 0o700)
        #expect(try permissions(at: destination.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(at: destination.deletingLastPathComponent().deletingLastPathComponent()) == 0o700)

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("DesklogOutside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside, options: .atomic)
        do {
            try await store.finalizeWebexAttachment(at: outside)
            Issue.record("An attachment path outside the private store was accepted")
        } catch let error as WorklogStoreError {
            #expect(error == .attachmentOutsideWebexDirectory)
        }

        do {
            _ = try await store.webexAttachmentURL(
                on: day,
                roomID: "room",
                messageID: "message",
                index: -1
            )
            Issue.record("A negative attachment index was accepted")
        } catch let error as WorklogStoreError {
            #expect(error == .invalidWebexAttachmentIndex)
        }
    }

    @Test func sensitiveTemporaryDirectoryIsPrivateAndPurgesOnlyStaleFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        let old = root.appendingPathComponent("interrupted.wav")
        let recent = root.appendingPathComponent("active.json")
        try Data("audio".utf8).write(to: old)
        try Data("result".utf8).write(to: recent)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)],
            ofItemAtPath: recent.path
        )

        let removed = try PrivateTemporaryDirectory.removeFiles(
            in: root,
            olderThan: 3_600,
            now: now
        )

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(try permissions(at: root) == 0o700)
    }

    @Test func speakerEmbeddingsStayInPrivateFilesOutsideTheWorklog() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let match = try await store.identify(embedding: [1, 0, 0])
        let observation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: match,
            text: "ローカル発話",
            embedding: [1, 0, 0]
        )

        let profiles = root.appendingPathComponent("profiles.json")
        let observations = root.appendingPathComponent("observations", isDirectory: true)
        let observationFile = observations.appendingPathComponent("\(observation.id.uuidString).json")
        #expect(try permissions(at: root) == 0o700)
        #expect(try permissions(at: observations) == 0o700)
        #expect(try permissions(at: profiles) == 0o600)
        #expect(try permissions(at: observationFile) == 0o600)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func webexConversation(
        timestamp: Date,
        roomID: String,
        text: String
    ) -> WorklogEvent {
        WorklogEvent(
            timestamp: timestamp,
            kind: .webexConversation,
            text: text,
            metadata: [
                "webex_room_id": roomID,
                "webex_room_type": "group",
                "webex_room_title": roomID
            ]
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? NSNumber).intValue
    }
}
