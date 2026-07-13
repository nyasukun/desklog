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

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? NSNumber).intValue
    }
}
