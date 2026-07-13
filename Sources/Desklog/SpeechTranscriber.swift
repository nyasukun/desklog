import AVFoundation
import DesklogCore
import Foundation

struct TranscriptUpdate: Sendable {
    let segmentID: String
    let text: String
    let isFinal: Bool
    let localSpeakerID: Int
    let speakerEmbedding: [Float]
}

@MainActor
final class SpeechTranscriber: ObservableObject {
    fileprivate nonisolated static let speakerModelRepository = WorklogStore.defaultRootDirectory
        .appendingPathComponent("speaker-models/models/argmaxinc/speakerkit-coreml", isDirectory: true)

    @Published private(set) var liveText = ""
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var inputDeviceName = "未接続"
    @Published private(set) var audioStatus = "停止中"
    @Published private(set) var lastError: String?
    @Published private(set) var hasReceivedAudioBuffers = false
    @Published private(set) var isRunning = false
    @Published private(set) var isTranscribing = false

    private let audioEngine = AVAudioEngine()
    private let accumulator = AudioSampleAccumulator()
    private let whisperRunner = WhisperRunner()
    private var isInputTapInstalled = false
    private var segmentTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var lastAudioBufferAt: Date?
    private var recordingStartedAt = Date.distantPast
    private var onUpdate: ((TranscriptUpdate) -> Void)?
    private var configuration: DesklogConfiguration?
    private var activeTranscriptions = 0
    private var liveTranscriptBuffer = LiveTranscriptBuffer()
    private var speakerProfiles: [SpeakerProfile] = []
    private var sessionID = UUID()
    private var previousTranscriptBySession: [UUID: String] = [:]
    private var activeTranscriptionsBySession: [UUID: Int] = [:]
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        inputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "デフォルトマイク"
        _ = try? PrivateTemporaryDirectory.removeFiles(
            in: WhisperRunner.temporaryDirectory,
            olderThan: 0
        )
    }

    var localSpeakerModelsReady: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: Self.speakerModelRepository.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func validateLocalResources(configuration: DesklogConfiguration) throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.whisperExecutablePath) else {
            throw DesklogError.speechUnavailable("whisper-cliがありません: \(configuration.whisperExecutablePath)")
        }
        guard FileManager.default.fileExists(atPath: configuration.whisperModelPath) else {
            throw DesklogError.speechUnavailable("Whisperモデルがありません: \(configuration.whisperModelPath)")
        }
        guard localSpeakerModelsReady else {
            throw DesklogError.speechUnavailable(
                "ローカル話者モデルがありません。先に `make speaker-setup` を実行してください: \(Self.speakerModelRepository.path)"
            )
        }
        let helperPath = LocalSpeakerHelperClient.defaultHelperExecutablePath
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw DesklogError.speechUnavailable("話者分離helperがありません: \(helperPath)")
        }
    }

    func prepareLocalModels() async throws {
        do {
            try await whisperRunner.prepareLocalSpeakerModels()
        } catch {
            throw DesklogError.speechUnavailable(
                "ローカル話者モデルを読み込めません。先に `make speaker-setup` を実行してください。\n\(error.localizedDescription)"
            )
        }
    }

    func resolveSpeaker(segmentID: String, profileID: String) {
        guard liveTranscriptBuffer.resolveSpeaker(segmentID: segmentID, profileID: profileID) else { return }
        liveText = liveTranscriptBuffer.renderedText
    }

    func replaceSpeakerProfiles(_ profiles: [SpeakerProfile]) {
        speakerProfiles = profiles
        liveTranscriptBuffer.replaceSpeakerProfiles(profiles)
        liveText = liveTranscriptBuffer.renderedText
    }

    func start(configuration: DesklogConfiguration, onUpdate: @escaping (TranscriptUpdate) -> Void) throws {
        guard !isRunning else { return }
        try validateLocalResources(configuration: configuration)

        self.configuration = configuration
        self.onUpdate = onUpdate
        inputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "デフォルトマイク"
        lastError = nil
        liveTranscriptBuffer.removeAllLines()
        liveTranscriptBuffer.replaceSpeakerProfiles(speakerProfiles)
        liveText = ""
        let previousSessionID = sessionID
        sessionID = UUID()
        previousTranscriptBySession[sessionID] = ""
        if activeTranscriptionsBySession[previousSessionID, default: 0] == 0 {
            previousTranscriptBySession.removeValue(forKey: previousSessionID)
            activeTranscriptionsBySession.removeValue(forKey: previousSessionID)
        }
        recordingStartedAt = Date()
        isRunning = true

        do {
            try startAudioEngine()
            startSegmentTimer()
            startDiagnostics()
        } catch {
            isRunning = false
            stopAudioEngine()
            audioStatus = "開始失敗"
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        guard isRunning || audioEngine.isRunning else { return }
        isRunning = false
        segmentTask?.cancel()
        segmentTask = nil
        diagnosticTask?.cancel()
        diagnosticTask = nil
        stopAudioEngine()
        flushAudioSegment(includeOverlap: false)
        inputLevel = 0
        hasReceivedAudioBuffers = false
        audioStatus = activeTranscriptions > 0 ? "最後の音声を文字起こし中…" : "停止中"
    }

    func waitForPendingTranscriptions() async {
        guard activeTranscriptions > 0 else { return }
        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    /// Gives the final segment a short opportunity to finish, then cancels
    /// subprocesses so Cmd-Q and logout can never wait on a hung executable.
    func finishPendingTranscriptionsForTermination(gracePeriod: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(max(0, gracePeriod))
        while activeTranscriptions > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if activeTranscriptions > 0 {
            audioStatus = "終了のため残りの文字起こしを中止しています…"
            transcriptionTasks.values.forEach { $0.cancel() }
        }
        await waitForPendingTranscriptions()
        await whisperRunner.shutdownLocalSpeakerHelper()
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DesklogError.speechUnavailable("マイクのオーディオ形式を取得できません。")
        }
        accumulator.reset(sampleRate: format.sampleRate)
        lastAudioBufferAt = nil
        hasReceivedAudioBuffers = false
        audioStatus = "Whisper用の音声を収集中…"

        var lastMeterUpdate = 0.0
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.accumulator.append(buffer)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastMeterUpdate >= 0.1 else { return }
            lastMeterUpdate = now
            let level = AudioSampleAccumulator.normalizedLevel(for: buffer)
            Task { @MainActor in
                guard self.isRunning else { return }
                self.lastAudioBufferAt = Date()
                self.hasReceivedAudioBuffers = true
                self.inputLevel = max(level, self.inputLevel * 0.65)
                if !self.isTranscribing {
                    self.audioStatus = level >= 0.04 ? "音声を収集中" : "マイク接続済み（音声待ち）"
                }
            }
        }
        isInputTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startSegmentTimer() {
        segmentTask?.cancel()
        segmentTask = Task { [weak self] in
            var delay = SpeechChunkingPolicy.firstFlushDelaySeconds
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self, self.isRunning else { return }
                self.flushAudioSegment(includeOverlap: true)
                delay = SpeechChunkingPolicy.cadenceSeconds
            }
        }
    }

    private func flushAudioSegment(includeOverlap: Bool) {
        guard let configuration else { return }
        guard let snapshot = accumulator.drain(
            overlapSeconds: includeOverlap ? SpeechChunkingPolicy.retainedOverlapSeconds : 0,
            minimumNewSeconds: 0.8
        ) else { return }
        let updateHandler = onUpdate
        let transcriptionSessionID = sessionID
        let segmentID = UUID().uuidString
        activeTranscriptions += 1
        activeTranscriptionsBySession[transcriptionSessionID, default: 0] += 1
        isTranscribing = true
        audioStatus = "Whisperで文字起こし中…"
        let transcriptionTaskID = UUID()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await whisperRunner.transcribe(
                    samples: snapshot.samples,
                    sampleRate: snapshot.sampleRate,
                    executablePath: configuration.whisperExecutablePath,
                    modelPath: configuration.whisperModelPath,
                    language: Self.whisperLanguage(from: configuration.speechLocale)
                )
                await MainActor.run {
                    let previousTranscript = self.previousTranscriptBySession[transcriptionSessionID] ?? ""
                    let utterances = Self.removeBoundaryOverlap(
                        from: output.utterances,
                        previousTranscript: previousTranscript
                    )
                    self.previousTranscriptBySession[transcriptionSessionID] = output.fullText
                    let isCurrentSession = self.sessionID == transcriptionSessionID
                    for (index, utterance) in utterances.enumerated() {
                        let cleaned = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else { continue }
                        let temporaryLabel = utterance.localSpeakerID >= 0
                            ? "Speaker \(utterance.localSpeakerID + 1)"
                            : "Speaker ?"
                        let utteranceSegmentID = "\(segmentID)-\(index)"
                        if isCurrentSession {
                            self.liveTranscriptBuffer.append(
                                segmentID: utteranceSegmentID,
                                text: cleaned,
                                provisionalSpeakerLabel: temporaryLabel
                            )
                        }
                        updateHandler?(.init(
                            segmentID: utteranceSegmentID,
                            text: cleaned,
                            isFinal: true,
                            localSpeakerID: utterance.localSpeakerID,
                            speakerEmbedding: utterance.embedding
                        ))
                    }
                    self.finishTranscription(
                        sessionID: transcriptionSessionID,
                        taskID: transcriptionTaskID
                    )
                    if isCurrentSession {
                        self.liveText = self.liveTranscriptBuffer.renderedText
                        self.audioStatus = self.isRunning
                            ? (self.isTranscribing ? "Whisperで文字起こし中…" : "Whisper待機中")
                            : (self.isTranscribing ? "最後の音声を文字起こし中…" : "停止中")
                    }
                }
            } catch {
                await MainActor.run {
                    self.finishTranscription(
                        sessionID: transcriptionSessionID,
                        taskID: transcriptionTaskID
                    )
                    guard self.sessionID == transcriptionSessionID else { return }
                    guard !Task.isCancelled else { return }
                    self.lastError = error.localizedDescription
                    self.audioStatus = "Whisperエラー"
                }
            }
        }
        transcriptionTasks[transcriptionTaskID] = task
    }

    private func startDiagnostics() {
        diagnosticTask?.cancel()
        diagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.isRunning, !Task.isCancelled else { return }
                if let lastAudioBufferAt = self.lastAudioBufferAt,
                   Date().timeIntervalSince(lastAudioBufferAt) > 3 {
                    self.audioStatus = "マイク入力が停止しています"
                    self.inputLevel = 0
                } else if self.lastAudioBufferAt == nil,
                          Date().timeIntervalSince(self.recordingStartedAt) > 3 {
                    self.audioStatus = "マイクから音声バッファを受信できません"
                    self.lastError = "入力デバイスとマイク権限を確認してください。"
                }
            }
        }
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        inputLevel = 0
    }

    private func finishTranscription(sessionID completedSessionID: UUID, taskID: UUID) {
        transcriptionTasks.removeValue(forKey: taskID)
        activeTranscriptions = max(0, activeTranscriptions - 1)
        let remainingForSession = max(
            0,
            activeTranscriptionsBySession[completedSessionID, default: 1] - 1
        )
        activeTranscriptionsBySession[completedSessionID] = remainingForSession
        isTranscribing = activeTranscriptions > 0
        if completedSessionID != sessionID, remainingForSession == 0 {
            activeTranscriptionsBySession.removeValue(forKey: completedSessionID)
            previousTranscriptBySession.removeValue(forKey: completedSessionID)
        }
        if activeTranscriptions == 0 {
            let waiters = transcriptionWaiters
            transcriptionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private static func removeBoundaryOverlap(
        from utterances: [DiarizedUtterance],
        previousTranscript: String
    ) -> [DiarizedUtterance] {
        let rawCurrent = utterances.map(\.text).joined()
        let withoutLeadingWhitespace = rawCurrent.drop(while: \.isWhitespace)
        let leadingWhitespaceCount = rawCurrent.distance(
            from: rawCurrent.startIndex,
            to: withoutLeadingWhitespace.startIndex
        )
        let current = String(withoutLeadingWhitespace)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = previousTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !previous.isEmpty else { return utterances }
        let maximum = min(60, previous.count, current.count)
        guard maximum >= 3 else { return utterances }
        var overlapLength = 0
        for length in stride(from: maximum, through: 3, by: -1) {
            if previous.suffix(length) == current.prefix(length) {
                overlapLength = length
                break
            }
        }
        guard overlapLength > 0 else { return utterances }

        // The overlap can cross a speaker boundary, so consume it across utterances
        // instead of trimming only the first speaker's text.
        var remaining = leadingWhitespaceCount + overlapLength
        return utterances.compactMap { utterance in
            guard remaining > 0 else { return utterance }
            var trimmed = utterance
            let amount = min(remaining, trimmed.text.count)
            trimmed.text = String(trimmed.text.dropFirst(amount))
            remaining -= amount
            return trimmed.text.isEmpty ? nil : trimmed
        }
    }

    private static func whisperLanguage(from locale: String) -> String {
        locale.split(separator: "-").first.map(String.init) ?? "auto"
    }
}

private final class AudioSampleAccumulator: @unchecked Sendable {
    struct Snapshot: Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 48_000.0
    /// Samples retained from the preceding inference window. Tracking them
    /// separately prevents stop() from transcribing a duplicate-only tail.
    private var retainedSampleCount = 0

    func reset(sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate
        samples.removeAll(keepingCapacity: true)
        retainedSampleCount = 0
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
        lock.unlock()
    }

    func drain(overlapSeconds: Double, minimumNewSeconds: Double) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        let newSampleCount = max(0, samples.count - retainedSampleCount)
        guard newSampleCount >= Int(sampleRate * minimumNewSeconds) else {
            return nil
        }
        let result = samples
        let overlapCount = min(samples.count, Int(sampleRate * overlapSeconds))
        samples = overlapCount > 0 ? Array(samples.suffix(overlapCount)) : []
        retainedSampleCount = overlapCount
        return .init(samples: result, sampleRate: sampleRate)
    }

    nonisolated static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum = 0.0
        for index in 0..<frames {
            let sample = Double(channels[0][index])
            sum += sample * sample
        }
        let rms = sqrt(sum / Double(frames))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

private actor WhisperRunner {
    nonisolated static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Desklog-Whisper", isDirectory: true)
    private let speakerHelper = LocalSpeakerHelperClient(
        modelPath: SpeechTranscriber.speakerModelRepository.path
    )
    private var speakerModelsReady = false
    private var speakerHelperPreparation: Task<Void, Error>?
    private var isProcessing = false
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []

    func prepareLocalSpeakerModels() async throws {
        guard !speakerModelsReady else { return }
        if let speakerHelperPreparation {
            try await speakerHelperPreparation.value
            speakerModelsReady = true
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: SpeechTranscriber.speakerModelRepository.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw WhisperError.speakerModelsMissing(SpeechTranscriber.speakerModelRepository.path)
        }

        let helper = speakerHelper
        let preparation = Task { try await helper.prepare() }
        speakerHelperPreparation = preparation
        do {
            try await preparation.value
            speakerModelsReady = true
            speakerHelperPreparation = nil
        } catch {
            speakerHelperPreparation = nil
            throw error
        }
    }

    func shutdownLocalSpeakerHelper() async {
        speakerHelperPreparation?.cancel()
        speakerHelperPreparation = nil
        speakerModelsReady = false
        await speakerHelper.shutdown()
        speakerModelsReady = false
    }

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        executablePath: String,
        modelPath: String,
        language: String
    ) async throws -> DiarizedWhisperOutput {
        try Task.checkCancellation()
        await waitForProcessingTurn()
        defer { finishProcessingTurn() }
        try Task.checkCancellation()

        guard Self.containsSpeech(samples) else { return .init(fullText: "", utterances: []) }
        let resampled = Self.resample(samples, from: sampleRate, to: 16_000)
        let whisperResult = try await LocalWhisperProcess.run(
            samples16kHz: resampled,
            executablePath: executablePath,
            modelPath: modelPath,
            language: language,
            temporaryDirectory: Self.temporaryDirectory
        )
        let diarization = try await diarize(resampled)
        return Self.associate(whisper: whisperResult, diarization: diarization)
    }

    private func waitForProcessingTurn() async {
        if !isProcessing {
            isProcessing = true
            return
        }
        await withCheckedContinuation { continuation in
            processingWaiters.append(continuation)
        }
    }

    private func finishProcessingTurn() {
        guard !processingWaiters.isEmpty else {
            isProcessing = false
            return
        }
        processingWaiters.removeFirst().resume()
    }

    private func diarize(_ samples: [Float]) async throws -> LocalSpeakerDiarizationResult {
        try await prepareLocalSpeakerModels()
        return try await speakerHelper.diarize(samples16kHz: samples)
    }

    private static func associate(
        whisper: WhisperProcessResult,
        diarization: LocalSpeakerDiarizationResult
    ) -> DiarizedWhisperOutput {
        let fullText = whisper.transcription.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var grouped: [DiarizedUtterance] = []

        for transcription in whisper.transcription {
            let tokens = transcription.tokens.filter { !$0.isSpecial && !$0.trimmedText.isEmpty }
            if tokens.isEmpty {
                append(
                    text: transcription.text,
                    speakerID: speakerWithMaximumOverlap(
                        fromMS: transcription.offsets.from,
                        toMS: transcription.offsets.to,
                        segments: diarization.segments
                    ),
                    diarization: diarization,
                    to: &grouped
                )
                continue
            }

            for token in tokens {
                let speaker = speaker(at: token.alignmentTime, segments: diarization.segments)
                append(
                    text: token.text,
                    speakerID: speaker,
                    diarization: diarization,
                    to: &grouped
                )
            }
        }

        if grouped.isEmpty, !fullText.isEmpty {
            append(
                text: fullText,
                speakerID: diarization.segments.first?.speakerID,
                diarization: diarization,
                to: &grouped
            )
        }
        return .init(fullText: fullText, utterances: grouped)
    }

    private static func append(
        text: String,
        speakerID: Int?,
        diarization: LocalSpeakerDiarizationResult,
        to result: inout [DiarizedUtterance]
    ) {
        guard !text.isEmpty else { return }
        let id = speakerID ?? -1
        if let last = result.indices.last, result[last].localSpeakerID == id {
            result[last].text += text
        } else {
            result.append(.init(
                text: text,
                localSpeakerID: id,
                embedding: speakerID.flatMap { diarization.speakerCentroidEmbeddings[$0] } ?? []
            ))
        }
    }

    private static func speaker(
        at time: Float,
        segments: [LocalSpeakerDiarizationResult.Segment]
    ) -> Int? {
        let active = segments.filter { $0.startTime <= time && time <= $0.endTime }
        if let closest = active.min(by: {
            abs(($0.startTime + $0.endTime) / 2 - time) < abs(($1.startTime + $1.endTime) / 2 - time)
        }) {
            return closest.speakerID
        }
        guard let nearest = segments.min(by: {
            distance(from: time, to: $0) < distance(from: time, to: $1)
        }), distance(from: time, to: nearest) <= 0.5 else {
            return nil
        }
        return nearest.speakerID
    }

    private static func speakerWithMaximumOverlap(
        fromMS: Int,
        toMS: Int,
        segments: [LocalSpeakerDiarizationResult.Segment]
    ) -> Int? {
        let start = Float(fromMS) / 1_000
        let end = Float(toMS) / 1_000
        guard let best = segments.max(by: { lhs, rhs in
            overlap(start: start, end: end, segment: lhs) < overlap(start: start, end: end, segment: rhs)
        }), overlap(start: start, end: end, segment: best) > 0 else {
            return nil
        }
        return best.speakerID
    }

    private static func overlap(
        start: Float,
        end: Float,
        segment: LocalSpeakerDiarizationResult.Segment
    ) -> Float {
        max(0, min(end, segment.endTime) - max(start, segment.startTime))
    }

    private static func distance(
        from time: Float,
        to segment: LocalSpeakerDiarizationResult.Segment
    ) -> Float {
        if time < segment.startTime { return segment.startTime - time }
        if time > segment.endTime { return time - segment.endTime }
        return 0
    }

    private static func containsSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var squareSum = 0.0
        var peak = 0.0
        for value in samples {
            let sample = Double(value)
            squareSum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(squareSum / Double(samples.count))
        return peak >= 0.01 || rms >= 0.002
    }

    private static func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard !input.isEmpty, inputRate > 0 else { return [] }
        if abs(inputRate - outputRate) < 1 { return input }
        let outputCount = max(1, Int(Double(input.count) * outputRate / inputRate))
        let ratio = inputRate / outputRate
        return (0..<outputCount).map { outputIndex in
            let position = Double(outputIndex) * ratio
            let lower = min(input.count - 1, Int(position))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }

}

private enum WhisperError: LocalizedError {
    case speakerModelsMissing(String)

    var errorDescription: String? {
        switch self {
        case .speakerModelsMissing(let path):
            return "話者モデルがありません: \(path)"
        }
    }
}

private struct DiarizedWhisperOutput: Sendable {
    let fullText: String
    let utterances: [DiarizedUtterance]
}

private struct DiarizedUtterance: Sendable {
    var text: String
    let localSpeakerID: Int
    let embedding: [Float]
}
