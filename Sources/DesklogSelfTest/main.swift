import AVFoundation
import DesklogCore
import Foundation

@main
enum DesklogSelfTest {
    static func main() async throws {
        try testTimelineBuilder()
        try testConfigurationMigrationAndDefaults()
        try await testWorklogStore()
        try await testLocalWhisperSubprocess()
        try await testSpeakerIdentityStore()
        try await testOllamaRejectsRemoteURL()
        let environment = ProcessInfo.processInfo.environment
        let speakerSmokeRequired = environment["DESKLOG_REQUIRE_SPEAKER_SMOKE"] == "1"
        let whisperSmokeRequired = environment["DESKLOG_REQUIRE_WHISPER_SMOKE"] == "1"
        let bundledDependencyFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/checkouts/argmax-oss-swift/Tests/SpeakerKitTests/Resources/jfk.wav"
            ).path
        if whisperSmokeRequired {
            let audioPath = environment["DESKLOG_WHISPER_TEST_AUDIO"] ?? bundledDependencyFixture
            guard FileManager.default.fileExists(atPath: audioPath) else {
                throw SelfTestError.failed("Whisperテスト音声がありません: \(audioPath)")
            }
            try await RealWhisperSmokeTest.run(audioPath: audioPath)
        }
        if let audioPath = environment["DESKLOG_SPEAKER_TEST_AUDIO"] ??
            (speakerSmokeRequired ? bundledDependencyFixture : nil) {
            guard FileManager.default.fileExists(atPath: audioPath) else {
                throw SelfTestError.failed("SpeakerKitテスト音声がありません: \(audioPath)")
            }
            try await SpeakerKitSmokeTest.run(audioPath: audioPath)
        }
        if environment["DESKLOG_LIVE_TEST_OLLAMA"] == "1" {
            let info = try await OllamaClient(
                baseURL: "http://127.0.0.1:11434",
                model: "qwen3.5:4b"
            ).testConnection()
            try require(info.configuredModelAvailable, "installed Ollama model was not detected")
            print("Ollama \(info.version): \(info.models.joined(separator: ", "))")
        }
        print("Desklog self-tests passed")
    }

    private static func testLocalWhisperSubprocess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSelfTest-Whisper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-whisper")
        let model = root.appendingPathComponent("ggml-base.bin")
        let temporaryDirectory = root.appendingPathComponent("private-audio", isDirectory: true)
        let script = #"""
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
        print -r -- '{"transcription":[{"offsets":{"from":0,"to":1000},"text":"offline probe","tokens":[]}]}' > "${output}.json"
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try Data("local model".utf8).write(to: model, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let result = try await LocalWhisperProcess.run(
            samples16kHz: Array(repeating: 0.05, count: 16_000),
            executablePath: executable.path,
            modelPath: model.path,
            language: "en",
            temporaryDirectory: temporaryDirectory
        )
        try require(
            result.transcription.map(\.text).joined() == "offline probe",
            "sandboxed Whisper subprocess returned an unexpected result"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        try require(leftovers.isEmpty, "temporary Whisper audio or JSON was not removed")
    }

    private static func testTimelineBuilder() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let events = [
            WorklogEvent(
                timestamp: start,
                kind: .screenOCR,
                text: "## ディスプレイ: 内蔵Retinaディスプレイ\n\nEditor  main.swift",
                metadata: [
                    "display_title": "内蔵Retinaディスプレイ",
                    "image_path": "/tmp/editor.jpg"
                ]
            ),
            WorklogEvent(
                timestamp: start.addingTimeInterval(60),
                kind: .screenOCR,
                text: "## ディスプレイ: 内蔵Retinaディスプレイ\n\nEditor main.swift",
                metadata: ["display_title": "内蔵Retinaディスプレイ"]
            ),
            WorklogEvent(
                timestamp: start.addingTimeInterval(10),
                kind: .speechTranscript,
                text: "最初の途中結果",
                metadata: ["segment_id": "a"]
            ),
            WorklogEvent(
                timestamp: start.addingTimeInterval(20),
                kind: .speechTranscript,
                text: "確定した発言",
                metadata: ["segment_id": "a"]
            )
        ]

        let result = try TimelineBuilder.build(
            events: events,
            start: start,
            end: start.addingTimeInterval(100),
            speakerProfiles: [
                SpeakerProfile(
                    id: "Speaker-007",
                    name: "佐藤",
                    isSelf: true,
                    centroid: [1, 0]
                )
            ]
        )
        try require(
            result.timeline.components(separatedBy: "[画面OCR]").count - 1 == 1,
            "consecutive OCR entries were not deduplicated"
        )
        try require(result.timeline.contains("確定した発言"), "latest speech snapshot is missing")
        try require(!result.timeline.contains("最初の途中結果"), "stale speech snapshot remains")
        try require(result.timeline.contains("/tmp/editor.jpg"), "screenshot candidate is missing")

        let labeledSpeech = WorklogEvent(
            timestamp: start.addingTimeInterval(30),
            kind: .speechTranscript,
            text: "私が対応します",
            metadata: ["segment_id": "b", "speaker_profile_id": "Speaker-007"]
        )
        let labeledTimeline = try TimelineBuilder.build(
            events: [labeledSpeech],
            start: start,
            end: start.addingTimeInterval(100),
            speakerProfiles: [
                SpeakerProfile(id: "Speaker-007", name: "佐藤", isSelf: true, centroid: [1, 0])
            ]
        )
        try require(
            labeledTimeline.timeline.contains("[音声/佐藤（自分）]"),
            "persisted speaker/self context was not included"
        )

        do {
            _ = try TimelineBuilder.build(events: [], start: .distantPast, end: Date())
            throw SelfTestError.failed("empty timeline did not throw")
        } catch is DesklogError {
            // Expected.
        }
    }

    private static func testConfigurationMigrationAndDefaults() throws {
        let defaults = DesklogConfiguration()
        try require(defaults.ollamaModel == "gpt-oss:latest", "default Ollama model is incorrect")
        try require(
            defaults.summaryPrompt == DesklogConfiguration.defaultSummaryPrompt,
            "default summary prompt is incorrect"
        )
        try require(defaults.whisperExecutablePath.hasSuffix("whisper-cli"), "default Whisper executable is incorrect")
        try require(defaults.whisperModelPath.hasSuffix("ggml-large-v3-turbo-q5_0.bin"), "default Whisper model is incorrect")

        let oldJSON = """
        {"captureIntervalSeconds":60,"saveScreenshots":true,"ocrLanguages":["ja-JP"],"speechLocale":"ja-JP","ollamaBaseURL":"http://127.0.0.1:11434","ollamaModel":"custom:latest","summaryHours":8}
        """
        let migrated = try JSONDecoder().decode(DesklogConfiguration.self, from: Data(oldJSON.utf8))
        try require(!migrated.summaryScheduleEnabled, "old configuration unexpectedly enabled scheduling")
        try require(migrated.summaryScheduleHour == 18, "old configuration schedule was not defaulted")
        try require(migrated.ollamaModel == "custom:latest", "existing model setting was not preserved")
        try require(
            migrated.summaryPrompt == DesklogConfiguration.defaultSummaryPrompt,
            "legacy summary prompt was not defaulted"
        )
        try require(
            migrated.excludedCaptureWindows.isEmpty,
            "legacy capture exclusions were not defaulted"
        )
        try require(
            SpeechChunkingPolicy.cadenceSeconds == 12 &&
                SpeechChunkingPolicy.boundaryContextSeconds == 2,
            "Speech chunking policy is not the expected 12-second cadence with context"
        )
        let roundTrip = try JSONDecoder().decode(
            DesklogConfiguration.self,
            from: JSONEncoder().encode(defaults)
        )
        try require(roundTrip == defaults, "configuration does not round-trip")

        let legacyProfileJSON = """
        {
          "id":"Speaker-009",
          "name":"旧プロファイル",
          "isSelf":false,
          "centroid":[1,0],
          "sampleCount":2,
          "createdAt":"2026-01-01T00:00:00Z",
          "updatedAt":"2026-01-01T00:00:00Z"
        }
        """
        let profileDecoder = JSONDecoder()
        profileDecoder.dateDecodingStrategy = .iso8601
        let legacyProfile = try profileDecoder.decode(
            SpeakerProfile.self,
            from: Data(legacyProfileJSON.utf8)
        )
        try require(
            legacyProfile.alternateProfileIDs.isEmpty,
            "legacy speaker profile did not migrate"
        )
    }

    private static func testWorklogStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorklogStore(rootDirectory: root)
        let date = Date(timeIntervalSince1970: 2_000)
        let event = WorklogEvent(timestamp: date, kind: .system, text: "started")

        try await store.append(event)
        let loaded = try await store.events(from: date.addingTimeInterval(-1), to: date.addingTimeInterval(1))
        try require(loaded == [event], "stored event does not round-trip")
    }

    private static func testOllamaRejectsRemoteURL() async throws {
        do {
            _ = try await OllamaClient(baseURL: "https://example.com", model: "test").testConnection()
            throw SelfTestError.failed("remote Ollama URL was accepted")
        } catch DesklogError.invalidOllamaURL {
            // Expected: rejection must happen before any transport is used.
        } catch {
            throw SelfTestError.failed("remote URL failed for the wrong reason: \(error)")
        }
    }

    private static func testSpeakerIdentityStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let first = try await store.identify(embedding: [1, 0, 0])
        let same = try await store.identify(embedding: [0.99, 0.01, 0])
        let other = try await store.identify(embedding: [0, 1, 0])
        try require(first.profile.id == "Speaker-001", "first unknown speaker ID is incorrect")
        try require(same.profile.id == first.profile.id, "same speaker was not matched")
        try require(other.profile.id == "Speaker-002", "different speaker was not separated")
        let rootPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let profilePermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("profiles.json").path
        )[.posixPermissions] as? NSNumber
        try require(rootPermissions?.intValue == 0o700, "speaker directory is not private")
        try require(profilePermissions?.intValue == 0o600, "speaker embeddings are not private")

        let eventID = UUID()
        let observation = try await store.recordObservation(
            eventID: eventID,
            timestamp: Date(),
            match: same,
            text: "テスト発話",
            embedding: [0.99, 0.01, 0]
        )
        let labeled = try await store.labelObservation(id: observation.id, name: "山田", isSelf: true)
        try require(labeled.profile.name == "山田", "speaker name was not learned")
        try require(labeled.profile.isSelf, "self speaker tag was not learned")
        let identified = try await store.identify(embedding: [0.98, 0.02, 0])
        try require(identified.profile.name == "山田", "learned speaker was not identified")

        let otherObservation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: other,
            text: "別クラスタの発話",
            embedding: [0, 1, 0]
        )
        let merged = try await store.labelObservation(id: otherObservation.id, name: "山田", isSelf: true)
        try require(merged.sourceProfileID == "Speaker-002", "source profile ID was not retained")
        try require(merged.profile.id == "Speaker-001", "same-name voice clusters were not consolidated")
        try require(
            merged.profile.alternateProfileIDs.contains("Speaker-002"),
            "consolidated speaker alias was not retained"
        )
        let migrated = try await store.recentObservations(limit: 10)
        try require(
            migrated.allSatisfy { $0.profileID == "Speaker-001" },
            "observations for a consolidated profile were left orphaned"
        )
        let negativeLimit = try await store.recentObservations(limit: -1)
        try require(negativeLimit.isEmpty, "negative observation limit was not handled safely")

        // IDs must never be reused after a profile is consolidated; immutable
        // historical worklog events continue to refer to the old ID.
        let third = try await store.identify(embedding: [0, 0, 1])
        try require(third.profile.id == "Speaker-003", "a historical speaker ID was reused")

        let reloadedStore = SpeakerIdentityStore(rootDirectory: root)
        let persisted = try await reloadedStore.identify(embedding: [0.97, 0.03, 0])
        try require(persisted.profile.name == "山田", "speaker learning was not persisted")
        try require(persisted.profile.isSelf, "self tag was not persisted")

        let historicalTimeline = try TimelineBuilder.build(
            events: [
                WorklogEvent(
                    kind: .speechTranscript,
                    text: "古いクラスタの発言",
                    metadata: [
                        "segment_id": "historical",
                        "speaker_profile_id": "Speaker-002"
                    ]
                )
            ],
            start: .distantPast,
            end: .distantFuture,
            speakerProfiles: try await reloadedStore.profiles()
        )
        try require(
            historicalTimeline.timeline.contains("[音声/山田（自分）]"),
            "historical speaker alias did not receive current label context"
        )

        do {
            _ = try await store.identify(embedding: [0, 0, 0])
            throw SelfTestError.failed("zero speaker embedding was accepted")
        } catch is SpeakerIdentityError {
            // Expected: zero/invalid embeddings must not create unusable profiles.
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SelfTestError.failed(message) }
    }
}

private enum SelfTestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return "Self-test failed: \(message)"
        }
    }
}

private enum RealWhisperSmokeTest {
    static func run(audioPath: String) async throws {
        let configuration = DesklogConfiguration()
        guard FileManager.default.isExecutableFile(atPath: configuration.whisperExecutablePath) else {
            throw SelfTestError.failed("whisper-cliがありません: \(configuration.whisperExecutablePath)")
        }
        guard FileManager.default.fileExists(atPath: configuration.whisperModelPath) else {
            throw SelfTestError.failed("Whisperモデルがありません: \(configuration.whisperModelPath)")
        }
        let samples = try SpeakerKitSmokeTest.load16kMonoAudio(at: audioPath)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogRealWhisperSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let result = try await LocalWhisperProcess.run(
            samples16kHz: samples,
            executablePath: configuration.whisperExecutablePath,
            modelPath: configuration.whisperModelPath,
            language: "en",
            temporaryDirectory: temporaryDirectory
        )
        let text = result.transcription.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SelfTestError.failed("実Whisperが文字起こしを返しませんでした。")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        guard leftovers.isEmpty else {
            throw SelfTestError.failed("実Whisperの一時ファイルが残りました。")
        }
        print("Whisper: \(text.prefix(80))")
    }
}

private enum SpeakerKitSmokeTest {
    static func run(audioPath: String) async throws {
        let samples = try load16kMonoAudio(at: audioPath)
        let modelRoot = WorklogStore.defaultRootDirectory
            .appendingPathComponent("speaker-models", isDirectory: true)
        let modelRepository = modelRoot
            .appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerSmoke-\(UUID().uuidString)", isDirectory: true)
        let helperPath = LocalSpeakerHelperClient.defaultHelperExecutablePath
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw SpeakerSmokeError.failed("話者分離helperがありません: \(helperPath)")
        }
        let client = LocalSpeakerHelperClient(
            helperExecutablePath: helperPath,
            modelPath: modelRepository.path,
            temporaryDirectory: temporaryDirectory
        )
        let result: LocalSpeakerDiarizationResult
        do {
            try await client.prepare()
            guard try await client.verifyNetworkDenied() else {
                throw SpeakerSmokeError.failed("話者分離helperのネットワーク拒否を確認できませんでした。")
            }
            result = try await client.diarize(samples16kHz: samples)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
        guard !result.segments.isEmpty else {
            throw SpeakerSmokeError.failed("話者区間が検出されませんでした。")
        }
        guard !result.speakerCentroidEmbeddings.isEmpty,
              result.speakerCentroidEmbeddings.values.allSatisfy({ !$0.isEmpty }) else {
            throw SpeakerSmokeError.failed("話者特徴量が生成されませんでした。")
        }
        print(
            "SpeakerKit: \(result.speakerCount) speaker(s), " +
                "\(result.segments.count) segment(s), " +
                "\(result.speakerCentroidEmbeddings.count) centroid(s), " +
                "helper network denied"
        )
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        guard leftovers.isEmpty else {
            throw SpeakerSmokeError.failed("話者分離helperの一時ファイルが残りました。")
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    static func load16kMonoAudio(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate == 16_000 else {
            throw SpeakerSmokeError.failed("テスト音声は16kHzである必要があります。")
        }
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: capacity) else {
            throw SpeakerSmokeError.failed("テスト音声バッファを作成できません。")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeakerSmokeError.failed("テスト音声をFloat32で読み込めません。")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private enum SpeakerSmokeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return "SpeakerKit smoke test failed: \(message)"
        }
    }
}
