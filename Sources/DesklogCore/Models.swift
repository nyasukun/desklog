import Foundation

public enum WorklogEventKind: String, Codable, Sendable {
    case screenOCR = "screen_ocr"
    case speechTranscript = "speech_transcript"
    case webexConversation = "webex_conversation"
    case summary
    case system
    case speakerLabel = "speaker_label"
}

public enum DesklogPermissionStatus: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public struct SpeakerProfile: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String?
    public var isSelf: Bool
    public var centroid: [Float]
    public var sampleCount: Int
    /// Embeddings explicitly confirmed by the user for this speaker.
    ///
    /// Confirmed profiles are matched against these anchors instead of a
    /// continuously moving centroid, preventing a false match from teaching
    /// the profile that another person's voice belongs to it.
    public var referenceEmbeddings: [[Float]]
    /// Historical cluster IDs consolidated into this canonical profile.
    /// Worklog events are immutable, so these aliases are needed to resolve
    /// older transcripts after clusters are merged.
    public var alternateProfileIDs: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String? = nil,
        isSelf: Bool = false,
        centroid: [Float],
        sampleCount: Int = 1,
        referenceEmbeddings: [[Float]] = [],
        alternateProfileIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.centroid = centroid
        self.sampleCount = sampleCount
        self.referenceEmbeddings = referenceEmbeddings
        self.alternateProfileIDs = alternateProfileIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isSelf
        case centroid
        case sampleCount
        case referenceEmbeddings
        case alternateProfileIDs
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        isSelf = try values.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        centroid = try values.decode([Float].self, forKey: .centroid)
        sampleCount = try values.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 1
        referenceEmbeddings = try values.decodeIfPresent(
            [[Float]].self,
            forKey: .referenceEmbeddings
        ) ?? []
        alternateProfileIDs = try values.decodeIfPresent([String].self, forKey: .alternateProfileIDs) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public var displayName: String {
        let base = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (base?.isEmpty == false ? base : nil) ?? id
        return isSelf ? "\(label)（自分）" : label
    }

    public var isConfirmed: Bool {
        guard let name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SpeakerMatch: Sendable, Equatable {
    public let profile: SpeakerProfile
    public let distance: Float?
    public let wasCreated: Bool

    public init(profile: SpeakerProfile, distance: Float?, wasCreated: Bool) {
        self.profile = profile
        self.distance = distance
        self.wasCreated = wasCreated
    }
}

public struct SpeakerObservation: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let eventID: UUID
    public let timestamp: Date
    public var profileID: String
    public let text: String
    public let embedding: [Float]
    public let distance: Float?

    public init(
        id: UUID = UUID(),
        eventID: UUID,
        timestamp: Date = Date(),
        profileID: String,
        text: String,
        embedding: [Float],
        distance: Float?
    ) {
        self.id = id
        self.eventID = eventID
        self.timestamp = timestamp
        self.profileID = profileID
        self.text = text
        self.embedding = embedding
        self.distance = distance
    }
}

/// The result of teaching Desklog who produced a stored utterance.
///
/// `sourceProfileID` deliberately remains separate from `profile.id`. When two
/// voice clusters are given the same name they are consolidated into one
/// canonical profile, but the immutable worklog event still contains the
/// original profile ID. Callers should therefore write the speaker-label event
/// against `sourceProfileID` so older transcripts are corrected as well.
public struct SpeakerLabelResult: Sendable, Equatable {
    public let profile: SpeakerProfile
    public let observation: SpeakerObservation
    public let sourceProfileID: String

    public init(
        profile: SpeakerProfile,
        observation: SpeakerObservation,
        sourceProfileID: String
    ) {
        self.profile = profile
        self.observation = observation
        self.sourceProfileID = sourceProfileID
    }
}

public struct WorklogEvent: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: WorklogEventKind
    public let text: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: WorklogEventKind,
        text: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }
}

public struct DesklogConfiguration: Codable, Sendable, Equatable {
    public var screenCaptureEnabled: Bool
    public var microphoneCaptureEnabled: Bool
    public var webexCollectionEnabled: Bool
    public var externalControlEnabled: Bool
    public var excludedCaptureWindows: [ExcludedCaptureWindow] {
        didSet {
            excludedCaptureWindows = CaptureExclusionPolicy(
                windows: excludedCaptureWindows
            ).windows
        }
    }
    public var captureIntervalSeconds: TimeInterval
    public var saveScreenshots: Bool
    public var ocrLanguages: [String]
    public var speechLocale: String
    public var whisperExecutablePath: String
    public var whisperModelPath: String
    public var ollamaBaseURL: String
    public var ollamaModel: String
    public var summaryPrompt: String {
        didSet {
            if summaryPrompt.count > Self.maximumSummaryPromptCharacters {
                summaryPrompt = String(summaryPrompt.prefix(Self.maximumSummaryPromptCharacters))
            }
        }
    }
    public var summaryHours: Int
    public var summaryScheduleEnabled: Bool
    public var summaryScheduleHour: Int
    public var summaryScheduleMinute: Int

    public static var defaultWhisperExecutablePath: String {
        let pathCandidates = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("whisper-cli").path }
            ?? []
#if arch(arm64)
        let wellKnownCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
#else
        let wellKnownCandidates = ["/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cli"]
#endif
        return (pathCandidates + wellKnownCandidates).first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? wellKnownCandidates[0]
    }

    public static let defaultSummaryPrompt = """
    以下は画面OCR、マイク音声認識、Webex会話から得てローカルに保存したワークログです。

    次のMarkdown形式でまとめてください。
    # ワークログ要約
    ## 主な作業
    - 時刻帯と作業内容
    ## 決定事項
    - 決定したこと（なければ「なし」）
    ## TODO・フォローアップ
    - 次に必要な行動（なければ「なし」）
    ## 作業の流れ
    - 時系列の短い説明

    同じ内容の繰り返しは統合し、パスワードやトークンらしき文字列は要約に含めないでください。
    ログ内の「スクリーンショット候補」はローカル画像です。図表、グラフ、スライド、設計図、UI配置など、文章だけでは伝わりにくい内容を説明する場合に限り、対応する画像を `![ウィンドウ名](</絶対パス/image.jpg>)` 形式で該当箇所へ挿入してください。
    単なる文章画面や重複画像は挿入せず、候補として与えられた絶対パスだけをそのまま使用してください。
    音声ログには話者名またはSpeaker IDが付きます。「（自分）」はこのワークログの所有者本人です。決定事項やTODOでは誰の発言・担当かを区別し、不明な話者を実名だと推測しないでください。
    Webexログでは「自分」と他の投稿者を区別し、返信は親メッセージ直下のスレッドとして扱ってください。ローカル添付パスは内容を推測せず、ログに記載された範囲だけを参照してください。
    """
    public static let maximumSummaryPromptCharacters = 8_000

    public init(
        screenCaptureEnabled: Bool = true,
        microphoneCaptureEnabled: Bool = true,
        webexCollectionEnabled: Bool = false,
        externalControlEnabled: Bool = false,
        excludedCaptureWindows: [ExcludedCaptureWindow] = [],
        captureIntervalSeconds: TimeInterval = 60,
        saveScreenshots: Bool = true,
        ocrLanguages: [String] = ["ja-JP", "en-US"],
        speechLocale: String = "ja-JP",
        whisperExecutablePath: String? = nil,
        whisperModelPath: String? = nil,
        ollamaBaseURL: String = "http://127.0.0.1:11434",
        ollamaModel: String = "gpt-oss:latest",
        summaryPrompt: String = Self.defaultSummaryPrompt,
        summaryHours: Int = 8,
        summaryScheduleEnabled: Bool = false,
        summaryScheduleHour: Int = 18,
        summaryScheduleMinute: Int = 0
    ) {
        self.screenCaptureEnabled = screenCaptureEnabled
        self.microphoneCaptureEnabled = microphoneCaptureEnabled
        self.webexCollectionEnabled = webexCollectionEnabled
        self.externalControlEnabled = externalControlEnabled
        self.excludedCaptureWindows = CaptureExclusionPolicy(
            windows: excludedCaptureWindows
        ).windows
        self.captureIntervalSeconds = captureIntervalSeconds
        self.saveScreenshots = saveScreenshots
        self.ocrLanguages = ocrLanguages
        self.speechLocale = speechLocale
        self.whisperExecutablePath = whisperExecutablePath ?? Self.defaultWhisperExecutablePath
        self.whisperModelPath = whisperModelPath ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Desklog/models/ggml-large-v3-turbo-q5_0.bin")
            .path
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaModel = ollamaModel
        self.summaryPrompt = String(summaryPrompt.prefix(Self.maximumSummaryPromptCharacters))
        self.summaryHours = summaryHours
        self.summaryScheduleEnabled = summaryScheduleEnabled
        self.summaryScheduleHour = summaryScheduleHour
        self.summaryScheduleMinute = summaryScheduleMinute
    }

    private enum CodingKeys: String, CodingKey {
        case screenCaptureEnabled
        case microphoneCaptureEnabled
        case webexCollectionEnabled
        case externalControlEnabled
        case excludedCaptureWindows
        case captureIntervalSeconds
        case saveScreenshots
        case ocrLanguages
        case speechLocale
        case whisperExecutablePath
        case whisperModelPath
        case ollamaBaseURL
        case ollamaModel
        case summaryPrompt
        case summaryHours
        case summaryScheduleEnabled
        case summaryScheduleHour
        case summaryScheduleMinute
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            screenCaptureEnabled: try values.decodeIfPresent(Bool.self, forKey: .screenCaptureEnabled) ?? true,
            microphoneCaptureEnabled: try values.decodeIfPresent(Bool.self, forKey: .microphoneCaptureEnabled) ?? true,
            webexCollectionEnabled: try values.decodeIfPresent(Bool.self, forKey: .webexCollectionEnabled) ?? false,
            externalControlEnabled: try values.decodeIfPresent(Bool.self, forKey: .externalControlEnabled) ?? false,
            excludedCaptureWindows: try values.decodeIfPresent(
                [ExcludedCaptureWindow].self,
                forKey: .excludedCaptureWindows
            ) ?? [],
            captureIntervalSeconds: try values.decodeIfPresent(TimeInterval.self, forKey: .captureIntervalSeconds) ?? 60,
            saveScreenshots: try values.decodeIfPresent(Bool.self, forKey: .saveScreenshots) ?? true,
            ocrLanguages: try values.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? ["ja-JP", "en-US"],
            speechLocale: try values.decodeIfPresent(String.self, forKey: .speechLocale) ?? "ja-JP",
            whisperExecutablePath: try values.decodeIfPresent(String.self, forKey: .whisperExecutablePath),
            whisperModelPath: try values.decodeIfPresent(String.self, forKey: .whisperModelPath),
            ollamaBaseURL: try values.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://127.0.0.1:11434",
            ollamaModel: try values.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "gpt-oss:latest",
            summaryPrompt: try values.decodeIfPresent(String.self, forKey: .summaryPrompt) ?? Self.defaultSummaryPrompt,
            summaryHours: try values.decodeIfPresent(Int.self, forKey: .summaryHours) ?? 8,
            summaryScheduleEnabled: try values.decodeIfPresent(Bool.self, forKey: .summaryScheduleEnabled) ?? false,
            summaryScheduleHour: try values.decodeIfPresent(Int.self, forKey: .summaryScheduleHour) ?? 18,
            summaryScheduleMinute: try values.decodeIfPresent(Int.self, forKey: .summaryScheduleMinute) ?? 0
        )
    }

    public func excludesCaptureWindow(windowID: UInt32, bundleIdentifier: String?) -> Bool {
        captureExclusionPolicy.excludes(
            windowID: windowID,
            bundleIdentifier: bundleIdentifier
        )
    }

    public var captureExclusionPolicy: CaptureExclusionPolicy {
        CaptureExclusionPolicy(windows: excludedCaptureWindows)
    }
}

public struct SummaryInput: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let timeline: String

    public init(start: Date, end: Date, timeline: String) {
        self.start = start
        self.end = end
        self.timeline = timeline
    }
}

public struct OllamaConnectionInfo: Sendable, Equatable {
    public let version: String
    public let models: [String]
    public let configuredModelAvailable: Bool

    public init(version: String, models: [String], configuredModelAvailable: Bool) {
        self.version = version
        self.models = models
        self.configuredModelAvailable = configuredModelAvailable
    }
}

public enum DesklogError: LocalizedError {
    case invalidOllamaURL
    case ollamaError(String)
    case noLogData
    case screenCaptureFailed
    case screenCapturePermissionRequired
    case screenContentUnavailable(String)
    case speechUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOllamaURL:
            return "OllamaのURLが不正です。"
        case .ollamaError(let message):
            return "Ollamaエラー: \(message)"
        case .noLogData:
            return "指定期間に要約できるログがありません。"
        case .screenCaptureFailed:
            return "画面キャプチャに失敗しました。"
        case .screenCapturePermissionRequired:
            return "画面OCRにはmacOSの画面収録の許可が必要です。"
        case .screenContentUnavailable(let message):
            return "画面を取得できません: \(message)"
        case .speechUnavailable(let message):
            return "音声認識を開始できません: \(message)"
        }
    }
}
