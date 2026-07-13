import Darwin
import Foundation

/// Runs whisper.cpp against a private temporary WAV while an OS sandbox
/// denies every network operation in the child process.
public enum LocalWhisperProcess {
    public static let networkSandboxProfile = "(version 1) (allow default) (deny network*)"
    public static let defaultTimeout: TimeInterval = 300

    public static func run(
        samples16kHz: [Float],
        executablePath: String,
        modelPath: String,
        language: String,
        temporaryDirectory: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> WhisperProcessResult {
        guard !samples16kHz.isEmpty else { throw LocalWhisperProcessError.emptyAudio }
        guard timeout > 0 else { throw LocalWhisperProcessError.invalidTimeout }
        try PrivateTemporaryDirectory.prepare(at: temporaryDirectory)
        let wavURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let outputPrefix = temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let jsonURL = URL(fileURLWithPath: outputPrefix + ".json")
        let standardErrorURL = URL(fileURLWithPath: outputPrefix + ".stderr")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: jsonURL)
            try? FileManager.default.removeItem(at: standardErrorURL)
        }

        try Task.checkCancellation()
        try writeWAV(samples16kHz, to: wavURL)

        var whisperArguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "-l", language,
            "-nt", "-np", "--suppress-nst", "-ojf", "-of", outputPrefix,
            "--prompt", "以下は日本語の仕事、会議、ソフトウェア開発に関する会話です。"
        ]
        if let preset = dtwPreset(forModelAt: modelPath) {
            // whisper.cpp does not populate t_dtw while flash attention is enabled.
            whisperArguments.append(contentsOf: ["-nfa", "-dtw", preset])
        }

        let sandboxExecutable = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandboxExecutable) else {
            throw LocalWhisperProcessError.networkSandboxUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExecutable)
        process.arguments = ["-p", networkSandboxProfile, executablePath] + whisperArguments
        process.standardOutput = FileHandle.nullDevice
        try Data().write(to: standardErrorURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: standardErrorURL.path
        )
        let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        defer { try? standardErrorHandle.close() }
        process.standardError = standardErrorHandle
        let termination = WhisperProcessTermination(process: process)
        let timeoutNanoseconds = UInt64(min(timeout, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            termination.request(.timeout)
        }
        defer { timeoutTask.cancel() }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in
                        termination.didFinish()
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        try termination.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                termination.request(.cancellation)
            }
        } catch {
            switch termination.reason {
            case .timeout: throw LocalWhisperProcessError.timedOut(timeout)
            case .cancellation: throw CancellationError()
            case nil: throw error
            }
        }
        try? standardErrorHandle.close()
        switch termination.reason {
        case .timeout:
            throw LocalWhisperProcessError.timedOut(timeout)
        case .cancellation:
            throw CancellationError()
        case nil:
            break
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let detail = (try? Data(contentsOf: standardErrorURL))
                .map { String(decoding: $0.suffix(8_000), as: UTF8.self) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            throw LocalWhisperProcessError.processFailed(
                status,
                detail?.isEmpty == false ? detail : nil
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: jsonURL.path
        )
        return try JSONDecoder().decode(
            WhisperProcessResult.self,
            from: Data(contentsOf: jsonURL)
        )
    }

    private static func dtwPreset(forModelAt path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "_", with: ".")
        let presets = [
            "large.v3.turbo", "large.v3", "large.v2", "large.v1",
            "medium.en", "medium", "small.en", "small",
            "base.en", "base", "tiny.en", "tiny"
        ]
        return presets.first { name.contains($0) }
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(36) + byteCount)
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(16_000))
        data.appendLittleEndian(UInt32(32_000))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append("data".data(using: .ascii)!)
        data.appendLittleEndian(byteCount)
        for sample in samples {
            let clamped = min(1, max(-1, sample))
            data.appendLittleEndian(Int16(clamped * Float(Int16.max)))
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct WhisperProcessResult: Decodable, Sendable {
    public let transcription: [Segment]

    public struct Segment: Decodable, Sendable {
        public let offsets: Offsets
        public let text: String
        public let tokens: [Token]
    }

    public struct Token: Decodable, Sendable {
        public let text: String
        public let offsets: Offsets
        public let tDtw: Int?

        private enum CodingKeys: String, CodingKey {
            case text, offsets
            case tDtw = "t_dtw"
        }

        public var trimmedText: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var isSpecial: Bool {
            let value = trimmedText
            return value.hasPrefix("<|")
                || (value.hasPrefix("[_") && value.hasSuffix("_]"))
        }

        public var alignmentTime: Float {
            if let tDtw, tDtw >= 0 {
                // whisper.cpp timestamps use 10 ms units.
                return Float(tDtw) / 100
            }
            return Float(offsets.from + offsets.to) / 2_000
        }
    }

    public struct Offsets: Decodable, Sendable {
        public let from: Int
        public let to: Int
    }
}

public enum LocalWhisperProcessError: LocalizedError {
    case emptyAudio
    case invalidTimeout
    case networkSandboxUnavailable
    case timedOut(TimeInterval)
    case processFailed(Int32, String?)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Whisperへ渡す音声がありません。"
        case .invalidTimeout:
            return "Whisperのタイムアウト値が不正です。"
        case .networkSandboxUnavailable:
            return "Whisperのネットワークを遮断するmacOS sandboxを利用できません。"
        case .timedOut(let seconds):
            return "Whisperが\(Int(seconds))秒以内に完了しなかったため停止しました。"
        case .processFailed(let status, let detail):
            let suffix = detail.map { "\n\($0)" } ?? ""
            return "Whisperの実行に失敗しました（終了コード \(status)）。\(suffix)"
        }
    }
}

private final class WhisperProcessTermination: @unchecked Sendable {
    enum Reason {
        case timeout
        case cancellation
    }

    private let process: Process
    private let lock = NSLock()
    private var requestedReason: Reason?
    private var hasStarted = false
    private var hasFinished = false

    init(process: Process) {
        self.process = process
    }

    var reason: Reason? {
        lock.withLock { requestedReason }
    }

    func run() throws {
        try lock.withLock {
            if requestedReason != nil { throw CancellationError() }
            try process.run()
            hasStarted = true
        }
    }

    func didFinish() {
        lock.withLock { hasFinished = true }
    }

    func request(_ reason: Reason) {
        let shouldTerminate = lock.withLock { () -> Bool in
            if hasFinished || (hasStarted && !process.isRunning) {
                hasFinished = true
                return false
            }
            if requestedReason == nil { requestedReason = reason }
            return hasStarted && process.isRunning
        }
        guard shouldTerminate else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.forceTerminateIfNeeded()
        }
    }

    private func forceTerminateIfNeeded() {
        let processID = lock.withLock { process.isRunning ? process.processIdentifier : nil }
        if let processID { Darwin.kill(processID, SIGKILL) }
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
