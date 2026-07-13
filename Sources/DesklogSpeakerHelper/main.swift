import Darwin
import DesklogCore
import Foundation
import SpeakerKit

@main
enum DesklogSpeakerHelper {
    static func main() async {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            let runtime = HelperRuntime(
                modelPath: arguments.modelPath,
                ipcDirectory: arguments.ipcDirectory
            )
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8) else { continue }
                do {
                    let request = try JSONDecoder().decode(SpeakerHelperRequest.self, from: data)
                    try await runtime.handle(request)
                } catch {
                    FileHandle.standardError.write(
                        Data("Invalid helper request: \(error.localizedDescription)\n".utf8)
                    )
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(2)
        }
    }
}

private final class HelperRuntime {
    private let modelPath: String
    private let ipcDirectory: URL
    private var speakerKit: SpeakerKit?

    init(modelPath: String, ipcDirectory: URL) {
        self.modelPath = modelPath
        self.ipcDirectory = ipcDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    func handle(_ request: SpeakerHelperRequest) async throws {
        let responseURL = try validatedChild(path: request.responsePath)
        let response: SpeakerHelperResponse
        do {
            switch request.command {
            case .prepare:
                try await prepareModels()
                response = SpeakerHelperResponse(id: request.id, ready: true)
            case .diarize:
                guard let audioPath = request.audioPath else {
                    throw LocalSpeakerHelperError.emptyAudio
                }
                let audioURL = try validatedChild(path: audioPath)
                let samples = try SpeakerHelperAudioFile.read(from: audioURL)
                guard !samples.isEmpty else { throw LocalSpeakerHelperError.emptyAudio }
                guard samples.allSatisfy(\.isFinite) else {
                    throw LocalSpeakerHelperError.invalidAudio
                }
                try await prepareModels()
                guard let speakerKit else {
                    throw LocalSpeakerHelperError.modelsMissing(modelPath)
                }
                let result = try await speakerKit.diarize(
                    audioArray: samples,
                    options: PyannoteDiarizationOptions(
                        clusterDistanceThreshold: 0.6,
                        useExclusiveReconciliation: true,
                        centroidSource: .finalAssignment
                    )
                )
                response = SpeakerHelperResponse(
                    id: request.id,
                    diarization: LocalSpeakerDiarizationResult(
                        speakerCount: result.speakerCount,
                        totalFrames: result.totalFrames,
                        frameRate: result.frameRate,
                        segments: result.segments.map {
                            .init(
                                speakerID: $0.speaker.speakerId,
                                startTime: $0.startTime,
                                endTime: $0.endTime
                            )
                        },
                        speakerCentroidEmbeddings: result.speakerCentroidEmbeddings
                    )
                )
            case .networkProbe:
                response = SpeakerHelperResponse(
                    id: request.id,
                    networkDenied: Self.networkIsDeniedBySandbox()
                )
            }
        } catch {
            response = SpeakerHelperResponse(id: request.id, error: error.localizedDescription)
        }
        try write(response, to: responseURL)
    }

    private func prepareModels() async throws {
        guard speakerKit == nil else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalSpeakerHelperError.modelsMissing(modelPath)
        }
        // Runtime inference is deliberately incapable of downloading models.
        // Model installation remains in the separate DesklogModelSetup target.
        speakerKit = try await SpeakerKit(PyannoteConfig(
            modelFolder: modelPath,
            download: false,
            load: true,
            verbose: false,
            fullRedundancy: true
        ))
    }

    private func validatedChild(path: String) throws -> URL {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard parent == ipcDirectory else { throw HelperError.invalidIPCPath }
        return candidate
    }

    private func write(_ response: SpeakerHelperResponse, to url: URL) throws {
        let data = try JSONEncoder().encode(response)
        let stagingURL = ipcDirectory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        guard FileManager.default.createFile(
            atPath: stagingURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw HelperError.cannotWriteResponse
        }
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagingURL.path
        )
        // Publishing the final path is the last operation, so the client can
        // never observe a partial or not-yet-private response.
        try FileManager.default.moveItem(at: stagingURL, to: url)
    }

    private static func networkIsDeniedBySandbox() -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return errno == EPERM || errno == EACCES
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectionError = errno
        return result == -1 && (connectionError == EPERM || connectionError == EACCES)
    }
}

private struct Arguments {
    let modelPath: String
    let ipcDirectory: URL

    static func parse(_ values: [String]) throws -> Arguments {
        var modelPath: String?
        var ipcDirectory: String?
        var index = 1
        while index < values.count {
            guard index + 1 < values.count else { throw HelperError.invalidArguments }
            switch values[index] {
            case "--model-path": modelPath = values[index + 1]
            case "--ipc-directory": ipcDirectory = values[index + 1]
            default: throw HelperError.invalidArguments
            }
            index += 2
        }
        guard let modelPath, !modelPath.isEmpty,
              let ipcDirectory, !ipcDirectory.isEmpty else {
            throw HelperError.invalidArguments
        }
        return Arguments(
            modelPath: modelPath,
            ipcDirectory: URL(fileURLWithPath: ipcDirectory, isDirectory: true)
        )
    }
}

private enum HelperError: LocalizedError {
    case invalidArguments
    case invalidIPCPath
    case cannotWriteResponse

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: DesklogSpeakerHelper --model-path PATH --ipc-directory PATH"
        case .invalidIPCPath:
            return "IPC path is outside the private helper session."
        case .cannotWriteResponse:
            return "The private helper response file could not be created."
        }
    }
}
