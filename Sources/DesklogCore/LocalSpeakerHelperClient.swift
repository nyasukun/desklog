import Darwin
import Foundation

/// A network-denied, out-of-process boundary for SpeakerKit inference.
///
/// The helper is intentionally kept alive between requests so the Core ML
/// models are loaded once instead of once per audio segment. Audio and IPC
/// payloads exist only inside a mode-0700 session directory and are deleted
/// after every request.
public actor LocalSpeakerHelperClient {
    public static let networkSandboxProfile = "(version 1) (allow default) (deny network*)"
    public static let defaultTemporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Desklog-SpeakerHelper", isDirectory: true)

    private let helperExecutablePath: String
    private let modelPath: String
    private let temporaryDirectory: URL
    private let requestTimeout: TimeInterval

    private var process: Process?
    private var inputHandle: FileHandle?
    private var standardErrorHandle: FileHandle?
    private var sessionDirectory: URL?
    private var sessionLockHandle: FileHandle?
    private var standardErrorURL: URL?
    private var requestInFlight = false

    public init(
        helperExecutablePath: String = LocalSpeakerHelperClient.defaultHelperExecutablePath,
        modelPath: String,
        temporaryDirectory: URL = LocalSpeakerHelperClient.defaultTemporaryDirectory,
        requestTimeout: TimeInterval = 300
    ) {
        self.helperExecutablePath = helperExecutablePath
        self.modelPath = modelPath
        self.temporaryDirectory = temporaryDirectory
        self.requestTimeout = max(1, requestTimeout)

        // Cleanup is intentionally attempted when the client is created, not
        // only when inference starts. A crash or power loss must not leave raw
        // Float audio on disk until the next diarization request. Failure is
        // retried (and surfaced) before a new helper session can be created.
        try? PrivateTemporaryDirectory.prepare(at: temporaryDirectory)
        try? Self.removeStaleSessions(in: temporaryDirectory)
    }

    /// The sibling executable embedded in Desklog.app/Contents/MacOS, or the
    /// sibling SwiftPM build product when running developer self-tests.
    public nonisolated static var defaultHelperExecutablePath: String {
        if let override = ProcessInfo.processInfo.environment["DESKLOG_SPEAKER_HELPER_PATH"],
           !override.isEmpty {
            return override
        }
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return executable.deletingLastPathComponent()
            .appendingPathComponent("DesklogSpeakerHelper", isDirectory: false).path
    }

    /// Starts the helper and eagerly loads the local models. Calling this more
    /// than once reuses the same helper process and loaded model instances.
    public func prepare() async throws {
        let response = try await perform(command: .prepare, samples: nil)
        guard response.ready == true else {
            throw LocalSpeakerHelperError.invalidResponse
        }
    }

    public func diarize(samples16kHz: [Float]) async throws -> LocalSpeakerDiarizationResult {
        guard !samples16kHz.isEmpty else { throw LocalSpeakerHelperError.emptyAudio }
        guard samples16kHz.allSatisfy(\.isFinite) else {
            throw LocalSpeakerHelperError.invalidAudio
        }
        let response = try await perform(command: .diarize, samples: samples16kHz)
        guard let result = response.diarization else {
            throw LocalSpeakerHelperError.invalidResponse
        }
        return result
    }

    /// A diagnostic used by the local-only self-test. The helper attempts a
    /// loopback connect and reports success only when the OS returns EPERM or
    /// EACCES, proving that its own process cannot open a network connection.
    public func verifyNetworkDenied() async throws -> Bool {
        let response = try await perform(command: .networkProbe, samples: nil)
        guard let denied = response.networkDenied else {
            throw LocalSpeakerHelperError.invalidResponse
        }
        return denied
    }

    /// Stops the persistent child and synchronously removes its private IPC
    /// session. A later call to `prepare` or `diarize` starts a fresh helper.
    public func shutdown() {
        stopHelper()
    }

    private func perform(
        command: SpeakerHelperCommand,
        samples: [Float]?
    ) async throws -> SpeakerHelperResponse {
        try await waitForProcessingTurn()
        defer { requestInFlight = false }
        try Task.checkCancellation()
        try startHelperIfNeeded()
        guard let sessionDirectory, let inputHandle else {
            throw LocalSpeakerHelperError.helperUnavailable(helperExecutablePath)
        }

        let id = UUID()
        let audioURL = samples.map { _ in
            sessionDirectory.appendingPathComponent("\(id.uuidString).audio", isDirectory: false)
        }
        let responseURL = sessionDirectory
            .appendingPathComponent("\(id.uuidString).response.json", isDirectory: false)
        defer {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            try? FileManager.default.removeItem(at: responseURL)
        }

        if let samples, let audioURL {
            try SpeakerHelperAudioFile.write(samples, to: audioURL)
        }
        let request = SpeakerHelperRequest(
            id: id,
            command: command,
            audioPath: audioURL?.path,
            responsePath: responseURL.path
        )
        let requestEncoder = JSONEncoder()
        requestEncoder.outputFormatting = [.withoutEscapingSlashes]
        var requestData = try requestEncoder.encode(request)
        requestData.append(0x0A)

        do {
            try inputHandle.write(contentsOf: requestData)
            let response = try await waitForResponse(at: responseURL, id: id)
            if let message = response.error {
                throw LocalSpeakerHelperError.helperFailed(message)
            }
            return response
        } catch {
            if error is CancellationError || isTimeout(error) || shouldResetHelper(after: error) {
                // The helper may still be reading the audio file. Kill it before
                // the defer above removes any request files.
                stopHelper()
            }
            throw error
        }
    }

    private func waitForProcessingTurn() async throws {
        while requestInFlight {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        requestInFlight = true
    }

    private func waitForResponse(at url: URL, id: UUID) async throws -> SpeakerHelperResponse {
        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) {
                let response = try JSONDecoder().decode(
                    SpeakerHelperResponse.self,
                    from: Data(contentsOf: url)
                )
                guard response.id == id else {
                    throw LocalSpeakerHelperError.invalidResponse
                }
                return response
            }
            if let process, !process.isRunning {
                let detail = readStandardError()
                stopHelper()
                throw LocalSpeakerHelperError.processExited(
                    process.terminationStatus,
                    detail.isEmpty ? nil : detail
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LocalSpeakerHelperError.timedOut(requestTimeout)
    }

    private func startHelperIfNeeded() throws {
        if let process, process.isRunning { return }
        stopHelper()

        // Fail closed: no new audio-bearing session is created unless stale
        // sessions can first be inspected and removed.
        try PrivateTemporaryDirectory.prepare(at: temporaryDirectory)
        try Self.removeStaleSessions(in: temporaryDirectory)

        guard FileManager.default.isExecutableFile(atPath: helperExecutablePath) else {
            throw LocalSpeakerHelperError.helperUnavailable(helperExecutablePath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LocalSpeakerHelperError.modelsMissing(modelPath)
        }
        let sandboxExecutable = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandboxExecutable) else {
            throw LocalSpeakerHelperError.networkSandboxUnavailable
        }

        let (session, sessionLock) = try createLockedSession()
        let stderrURL = session.appendingPathComponent("helper.stderr", isDirectory: false)
        try Data().write(to: stderrURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stderrURL.path
        )
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let input = Pipe()
        // A helper crash must surface as EPIPE, never terminate Desklog itself
        // with SIGPIPE while writing the next request.
        _ = Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: sandboxExecutable)
        child.arguments = [
            "-p", Self.networkSandboxProfile,
            helperExecutablePath,
            "--model-path", modelPath,
            "--ipc-directory", session.path
        ]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = stderrHandle

        do {
            try child.run()
        } catch {
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: session)
            try? sessionLock.close()
            throw error
        }
        process = child
        inputHandle = input.fileHandleForWriting
        standardErrorHandle = stderrHandle
        sessionDirectory = session
        sessionLockHandle = sessionLock
        standardErrorURL = stderrURL
    }

    private func stopHelper() {
        if let process, process.isRunning {
            // SIGKILL makes timeout/cancellation cleanup deterministic even if
            // Core ML is currently inside a non-cancellable inference call.
            // `Process.waitUntilExit()` can miss the termination notification
            // and block forever on some macOS versions, so use a bounded wait.
            let didTerminate = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in didTerminate.signal() }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = didTerminate.wait(timeout: .now() + 2)
            process.terminationHandler = nil
        }
        try? inputHandle?.close()
        try? standardErrorHandle?.close()
        process = nil
        inputHandle = nil
        standardErrorHandle = nil
        standardErrorURL = nil
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
        if let sessionLockHandle {
            try? sessionLockHandle.close()
        }
        sessionLockHandle = nil
    }

    private func readStandardError() -> String {
        guard let standardErrorURL,
              let data = try? Data(contentsOf: standardErrorURL) else { return "" }
        return String(decoding: data.suffix(8_000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a session under a non-matching staging name, acquires its
    /// lifetime lock, then atomically publishes it as `session-*`. Cleanup can
    /// therefore never observe a live session before its lock is held.
    private func createLockedSession() throws -> (URL, FileHandle) {
        let id = UUID().uuidString
        let staging = temporaryDirectory
            .appendingPathComponent("starting-\(id)", isDirectory: true)
        let session = temporaryDirectory
            .appendingPathComponent("session-\(id)", isDirectory: true)
        try PrivateTemporaryDirectory.prepare(at: staging)

        let lockURL = staging.appendingPathComponent(".session.lock", isDirectory: false)
        do {
            let lockHandle = try Self.openExclusiveLock(at: lockURL, create: true)
            do {
                let descriptor = lockHandle.fileDescriptor
                let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
                guard descriptorFlags >= 0,
                      Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 else {
                    throw Self.posixError()
                }
                try FileManager.default.moveItem(at: staging, to: session)
                return (session, lockHandle)
            } catch {
                try? lockHandle.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Deletes every abandoned session immediately. A live Desklog process
    /// holds an exclusive lock for the complete session lifetime, so cleanup
    /// is independent of timestamps, PIDs, PID reuse, and wall-clock changes.
    private nonisolated static func removeStaleSessions(in temporaryDirectory: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where child.lastPathComponent.hasPrefix("session-") {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }

            let lockURL = child.appendingPathComponent(".session.lock", isDirectory: false)
            guard FileManager.default.fileExists(atPath: lockURL.path) else {
                // Legacy sessions predate lifetime locks. They cannot belong to
                // this implementation and are crash residue at next launch.
                try FileManager.default.removeItem(at: child)
                continue
            }

            let lockHandle: FileHandle
            do {
                lockHandle = try openExclusiveLock(at: lockURL, create: false)
            } catch let error as POSIXError
                where error.code == .EWOULDBLOCK || error.code == .EAGAIN {
                // The owning Desklog process is still alive; preserve it.
                continue
            } catch let error as POSIXError where error.code == .ENOENT {
                // Another process may have completed cleanup after enumeration.
                continue
            }
            // Hold the lock through unlink so another process cannot adopt the
            // stale session between the liveness check and deletion.
            do {
                try FileManager.default.removeItem(at: child)
                try lockHandle.close()
            } catch {
                try? lockHandle.close()
                throw error
            }
        }
    }

    /// `O_EXLOCK` is the Darwin `flock(2)` lock requested atomically with
    /// `open(2)`. Unlike POSIX record locks, independently opened descriptors
    /// in the same Desklog process still contend, which protects concurrent
    /// client instances as well as separate app processes.
    private nonisolated static func openExclusiveLock(
        at url: URL,
        create: Bool
    ) throws -> FileHandle {
        var flags = O_RDWR | O_EXLOCK | O_NONBLOCK
        if create { flags |= O_CREAT | O_EXCL }
        let descriptor = url.path.withCString { path in
            Darwin.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private nonisolated static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func isTimeout(_ error: Error) -> Bool {
        if case LocalSpeakerHelperError.timedOut = error { return true }
        return false
    }

    private func shouldResetHelper(after error: Error) -> Bool {
        guard let helperError = error as? LocalSpeakerHelperError else { return true }
        switch helperError {
        case .helperFailed:
            // A valid error response means the IPC channel is still healthy.
            return false
        default:
            return true
        }
    }
}

public struct LocalSpeakerDiarizationResult: Codable, Sendable, Equatable {
    public let speakerCount: Int
    public let totalFrames: Int
    public let frameRate: Float
    public let segments: [Segment]
    public let speakerCentroidEmbeddings: [Int: [Float]]

    public init(
        speakerCount: Int,
        totalFrames: Int,
        frameRate: Float,
        segments: [Segment],
        speakerCentroidEmbeddings: [Int: [Float]]
    ) {
        self.speakerCount = speakerCount
        self.totalFrames = totalFrames
        self.frameRate = frameRate
        self.segments = segments
        self.speakerCentroidEmbeddings = speakerCentroidEmbeddings
    }

    public struct Segment: Codable, Sendable, Equatable {
        public let speakerID: Int?
        public let startTime: Float
        public let endTime: Float

        public init(speakerID: Int?, startTime: Float, endTime: Float) {
            self.speakerID = speakerID
            self.startTime = startTime
            self.endTime = endTime
        }
    }
}

public enum LocalSpeakerHelperError: LocalizedError {
    case emptyAudio
    case invalidAudio
    case helperUnavailable(String)
    case modelsMissing(String)
    case networkSandboxUnavailable
    case invalidResponse
    case helperFailed(String)
    case processExited(Int32, String?)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "話者分離へ渡す音声がありません。"
        case .invalidAudio:
            return "話者分離へ渡す音声に不正な値が含まれています。"
        case .helperUnavailable(let path):
            return "話者分離helperを実行できません: \(path)"
        case .modelsMissing(let path):
            return "話者モデルがありません: \(path)"
        case .networkSandboxUnavailable:
            return "話者分離helperのネットワークを遮断するmacOS sandboxを利用できません。"
        case .invalidResponse:
            return "話者分離helperから不正な応答を受け取りました。"
        case .helperFailed(let message):
            return "話者分離helperでエラーが発生しました: \(message)"
        case .processExited(let status, let detail):
            let suffix = detail.map { "\n\($0)" } ?? ""
            return "話者分離helperが終了しました（終了コード \(status)）。\(suffix)"
        case .timedOut(let seconds):
            return "話者分離helperが \(Int(seconds)) 秒以内に応答しませんでした。"
        }
    }
}

// MARK: - Helper protocol

public enum SpeakerHelperCommand: String, Codable, Sendable {
    case prepare
    case diarize
    case networkProbe
}

public struct SpeakerHelperRequest: Codable, Sendable {
    public let id: UUID
    public let command: SpeakerHelperCommand
    public let audioPath: String?
    public let responsePath: String

    public init(id: UUID, command: SpeakerHelperCommand, audioPath: String?, responsePath: String) {
        self.id = id
        self.command = command
        self.audioPath = audioPath
        self.responsePath = responsePath
    }
}

public struct SpeakerHelperResponse: Codable, Sendable {
    public let id: UUID
    public let ready: Bool?
    public let diarization: LocalSpeakerDiarizationResult?
    public let networkDenied: Bool?
    public let error: String?

    public init(
        id: UUID,
        ready: Bool? = nil,
        diarization: LocalSpeakerDiarizationResult? = nil,
        networkDenied: Bool? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.ready = ready
        self.diarization = diarization
        self.networkDenied = networkDenied
        self.error = error
    }
}

public enum SpeakerHelperAudioFile {
    public static func write(_ samples: [Float], to url: URL) throws {
        var data = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public static func read(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw LocalSpeakerHelperError.invalidAudio
        }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).map { index in
                let bits = UInt32(bytes[index])
                    | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16
                    | UInt32(bytes[index + 3]) << 24
                return Float(bitPattern: bits)
            }
        }
    }
}
