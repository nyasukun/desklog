import DesklogCore
import Foundation
import Testing

@Suite(.serialized) struct LocalSpeakerHelperClientTests {
    @Test func privateAudioFormatRoundTrips() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateTemporaryDirectory.prepare(at: root)
        let audio = root.appendingPathComponent("samples.audio")
        let samples: [Float] = [-1, -0.25, 0, 0.5, 1]

        try SpeakerHelperAudioFile.write(samples, to: audio)

        #expect(try SpeakerHelperAudioFile.read(from: audio) == samples)
        let permissions = try FileManager.default.attributesOfItem(atPath: audio.path)[.posixPermissions]
        #expect((permissions as? NSNumber)?.intValue == 0o600)
    }

    @Test func helperIsPersistentAndCleansEveryIPCFile() async throws {
        let fixture = try makeFixture(scriptBody: persistentHelperScript)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = LocalSpeakerHelperClient(
            helperExecutablePath: fixture.executable.path,
            modelPath: fixture.modelDirectory.path,
            temporaryDirectory: fixture.ipcRoot,
            requestTimeout: 5
        )

        try await client.prepare()
        try await client.prepare()
        let result = try await client.diarize(samples16kHz: Array(repeating: 0.1, count: 1_600))
        #expect(result.speakerCount == 3) // shell-local count proves one persistent process
        #expect(result.segments == [.init(speakerID: 0, startTime: 0, endTime: 0.1)])

        await client.shutdown()
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.ipcRoot,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty)
    }

    @Test func startupImmediatelyDeletesCrashResidueButPreservesLiveSessions() async throws {
        let fixture = try makeFixture(scriptBody: persistentHelperScript)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstClient = LocalSpeakerHelperClient(
            helperExecutablePath: fixture.executable.path,
            modelPath: fixture.modelDirectory.path,
            temporaryDirectory: fixture.ipcRoot,
            requestTimeout: 5
        )
        try await firstClient.prepare()

        let liveSession = try #require(sessionDirectories(in: fixture.ipcRoot).first)
        let staleSession = fixture.ipcRoot
            .appendingPathComponent("session-crashed", isDirectory: true)
        try PrivateTemporaryDirectory.prepare(at: staleSession)
        let staleLock = staleSession.appendingPathComponent(".session.lock")
        try Data().write(to: staleLock, options: .atomic)
        let rawAudio = staleSession.appendingPathComponent("unfinished.audio")
        try SpeakerHelperAudioFile.write([0.1, 0.2, 0.3], to: rawAudio)

        // Construction models the next app launch. The crash residue is new,
        // proving cleanup has no 24-hour grace period.
        let secondClient = LocalSpeakerHelperClient(
            helperExecutablePath: fixture.executable.path,
            modelPath: fixture.modelDirectory.path,
            temporaryDirectory: fixture.ipcRoot,
            requestTimeout: 5
        )
        #expect(!FileManager.default.fileExists(atPath: staleSession.path))
        #expect(FileManager.default.fileExists(atPath: liveSession.path))

        try await secondClient.prepare()
        #expect(sessionDirectories(in: fixture.ipcRoot).count == 2)
        // The first helper remains usable after the second client's cleanup.
        try await firstClient.prepare()

        await secondClient.shutdown()
        await firstClient.shutdown()
        #expect(sessionDirectories(in: fixture.ipcRoot).isEmpty)
    }

    @Test func startupDeletesRecentLegacySessionWithoutLifetimeLock() throws {
        let fixture = try makeFixture(scriptBody: persistentHelperScript)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try PrivateTemporaryDirectory.prepare(at: fixture.ipcRoot)
        let legacySession = fixture.ipcRoot
            .appendingPathComponent("session-from-previous-version", isDirectory: true)
        try PrivateTemporaryDirectory.prepare(at: legacySession)
        try SpeakerHelperAudioFile.write(
            [0.25, -0.25],
            to: legacySession.appendingPathComponent("recent.audio")
        )

        _ = LocalSpeakerHelperClient(
            helperExecutablePath: fixture.executable.path,
            modelPath: fixture.modelDirectory.path,
            temporaryDirectory: fixture.ipcRoot,
            requestTimeout: 5
        )

        #expect(!FileManager.default.fileExists(atPath: legacySession.path))
    }

    @Test func cancellationKillsHelperBeforeRemovingPrivateAudio() async throws {
        let fixture = try makeFixture(scriptBody: stalledHelperScript)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = LocalSpeakerHelperClient(
            helperExecutablePath: fixture.executable.path,
            modelPath: fixture.modelDirectory.path,
            temporaryDirectory: fixture.ipcRoot,
            requestTimeout: 30
        )
        let task = Task {
            try await client.diarize(samples16kHz: Array(repeating: 0.1, count: 1_600))
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled helper request completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Cancellation returned a different error: \(error)")
        }
        await client.shutdown()
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.ipcRoot,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty)
    }

    @Test func timeoutKillsHelperAndCleansSession() async throws {
        let fixture = try makeFixture(scriptBody: stalledHelperScript)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = LocalSpeakerHelperClient(
            helperExecutablePath: fixture.executable.path,
            modelPath: fixture.modelDirectory.path,
            temporaryDirectory: fixture.ipcRoot,
            requestTimeout: 1
        )

        do {
            _ = try await client.diarize(samples16kHz: Array(repeating: 0.1, count: 1_600))
            Issue.record("A stalled helper request did not time out")
        } catch LocalSpeakerHelperError.timedOut {
            // Expected.
        } catch {
            Issue.record("Timeout returned a different error: \(error)")
        }
        await client.shutdown()
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.ipcRoot,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty)
    }

    private func makeFixture(scriptBody: String) throws -> Fixture {
        let root = temporaryRoot()
        try PrivateTemporaryDirectory.prepare(at: root)
        let executable = root.appendingPathComponent("fake-speaker-helper")
        let modelDirectory = root.appendingPathComponent("models", isDirectory: true)
        let ipcRoot = root.appendingPathComponent("ipc", isDirectory: true)
        try PrivateTemporaryDirectory.prepare(at: modelDirectory)
        try Data(scriptBody.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return Fixture(
            root: root,
            executable: executable,
            modelDirectory: modelDirectory,
            ipcRoot: ipcRoot
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerHelperTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sessionDirectories(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("session-") } ?? []
    }

    private var persistentHelperScript: String {
        #"""
        #!/bin/zsh
        set -euo pipefail
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          id="${line#*\"id\":\"}"
          id="${id%%\"*}"
          response="${line#*\"responsePath\":\"}"
          response="${response%%\"*}"
          staging="${response}.tmp"
          if [[ "$line" == *'"command":"diarize"'* ]]; then
            audio="${line#*\"audioPath\":\"}"
            audio="${audio%%\"*}"
            if [[ "$(stat -f '%Lp' "$audio")" != "600" ]]; then
              print -rn -- '{"id":"'"$id"'","error":"audio was not private"}' > "$staging"
            else
              print -rn -- '{"id":"'"$id"'","diarization":{"speakerCount":'"$count"',"totalFrames":10,"frameRate":100,"segments":[{"speakerID":0,"startTime":0,"endTime":0.1}],"speakerCentroidEmbeddings":{"0":[1,0]}}}' > "$staging"
            fi
          else
            print -rn -- '{"id":"'"$id"'","ready":true}' > "$staging"
          fi
          chmod 600 "$staging"
          mv "$staging" "$response"
        done
        """#
    }

    private var stalledHelperScript: String {
        #"""
        #!/bin/zsh
        set -euo pipefail
        while IFS= read -r line; do
          # Stay in this process so cancellation cannot orphan a `sleep` child.
          while true; do :; done
        done
        """#
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let modelDirectory: URL
        let ipcRoot: URL
    }
}
