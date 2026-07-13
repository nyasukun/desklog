import DesklogCore
import Darwin
import Foundation
import Testing

@Suite struct LocalWhisperProcessTests {
    @Test func productionSubprocessWritesPrivateWAVAndRemovesAllAudioArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogWhisperProcessTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-whisper")
        let model = root.appendingPathComponent("ggml-base.bin")
        let temporaryDirectory = root.appendingPathComponent("private-audio", isDirectory: true)
        let (socket, port) = try makeListeningLoopbackSocket()
        defer { close(socket) }
        try Data(fakeWhisperScript(networkPort: port).utf8).write(to: executable, options: .atomic)
        try Data("local model".utf8).write(to: model, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let result = try await LocalWhisperProcess.run(
            samples16kHz: Array(repeating: 0.05, count: 16_000),
            executablePath: executable.path,
            modelPath: model.path,
            language: "ja",
            temporaryDirectory: temporaryDirectory
        )

        #expect(result.transcription.map(\.text).joined() == "ローカル文字起こし")
        #expect(try permissions(at: temporaryDirectory) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func failedWhisperProcessStillRemovesTemporaryAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogWhisperFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("failing-whisper")
        let model = root.appendingPathComponent("ggml-base.bin")
        let temporaryDirectory = root.appendingPathComponent("private-audio", isDirectory: true)
        let failingScript = #"""
        #!/bin/zsh
        set -euo pipefail
        output=""
        while (( $# > 0 )); do
          case "$1" in
            -of) output="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        print -r -- '{"partial":true}' > "${output}.json"
        exit 27
        """#
        try Data(failingScript.utf8).write(to: executable, options: .atomic)
        try Data("local model".utf8).write(to: model, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        do {
            _ = try await LocalWhisperProcess.run(
                samples16kHz: Array(repeating: 0.05, count: 8_000),
                executablePath: executable.path,
                modelPath: model.path,
                language: "ja",
                temporaryDirectory: temporaryDirectory
            )
            Issue.record("A failing whisper process unexpectedly succeeded")
        } catch LocalWhisperProcessError.processFailed(let status, _) {
            #expect(status == 27)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func timedOutWhisperProcessIsTerminatedAndCleansTemporaryAudio() async throws {
        let fixture = try makeHangingWhisperFixture(prefix: "DesklogWhisperTimeoutTests")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await LocalWhisperProcess.run(
                samples16kHz: Array(repeating: 0.05, count: 8_000),
                executablePath: fixture.executable.path,
                modelPath: fixture.model.path,
                language: "ja",
                temporaryDirectory: fixture.temporaryDirectory,
                timeout: 0.2
            )
            Issue.record("A hanging whisper process unexpectedly succeeded")
        } catch LocalWhisperProcessError.timedOut(let timeout) {
            #expect(timeout == 0.2)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func cancellingWhisperTerminatesTheChildAndCleansTemporaryAudio() async throws {
        let fixture = try makeHangingWhisperFixture(prefix: "DesklogWhisperCancellationTests")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task {
            try await LocalWhisperProcess.run(
                samples16kHz: Array(repeating: 0.05, count: 8_000),
                executablePath: fixture.executable.path,
                modelPath: fixture.model.path,
                language: "ja",
                temporaryDirectory: fixture.temporaryDirectory,
                timeout: 10
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled whisper process unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    private func fakeWhisperScript(networkPort: UInt16) -> String {
        #"""
        #!/bin/zsh
        set -euo pipefail
        input=""
        output=""
        while (( $# > 0 )); do
          case "$1" in
            -f) input="$2"; shift 2 ;;
            -of) output="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [[ -f "$input" ]]
        [[ "$(stat -f '%Lp' "$input")" == "600" ]]
        if /usr/bin/nc -z -w 1 127.0.0.1 \#(networkPort) >/dev/null 2>&1; then
          exit 41
        fi
        print -r -- '{"transcription":[{"offsets":{"from":0,"to":1000},"text":"ローカル文字起こし","tokens":[{"text":"ローカル文字起こし","offsets":{"from":0,"to":1000},"t_dtw":50}]}]}' > "${output}.json"
        """#
    }

    private func makeHangingWhisperFixture(
        prefix: String
    ) throws -> (root: URL, executable: URL, model: URL, temporaryDirectory: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("hanging-whisper")
        let model = root.appendingPathComponent("ggml-base.bin")
        let temporaryDirectory = root.appendingPathComponent("private-audio", isDirectory: true)
        let script = #"""
        #!/bin/zsh
        trap '' TERM
        while true; do :; done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try Data("local model".utf8).write(to: model, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable, model, temporaryDirectory)
    }

    private func makeListeningLoopbackSocket() throws -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
                throw posixError()
            }
            var boundAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard nameResult == 0 else { throw posixError() }
            return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? NSNumber).intValue
    }
}
