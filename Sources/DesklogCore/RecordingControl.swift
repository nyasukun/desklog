import Foundation

public enum RecordingControlAction: Sendable, Equatable, CaseIterable {
    case startRecording
    case stopRecording
    case startAudio
    case stopAudio
}

public enum RecordingMode: String, Sendable, Equatable, CaseIterable {
    case stopped
    case screenOnly
    case screenAndAudio

    public var menuBarStatusText: String? {
        switch self {
        case .stopped:
            return nil
        case .screenOnly:
            return "記録中（画面のみ）"
        case .screenAndAudio:
            return "記録中（音声込み）"
        }
    }

    public func applying(_ action: RecordingControlAction) -> RecordingMode {
        switch (self, action) {
        case (.stopped, .startRecording):
            return .screenOnly
        case (.screenOnly, .startAudio):
            return .screenAndAudio
        case (.screenAndAudio, .stopAudio):
            return .screenOnly
        case (.screenOnly, .stopRecording), (.screenAndAudio, .stopRecording):
            return .stopped
        default:
            return self
        }
    }

    public func allows(_ action: RecordingControlAction) -> Bool {
        applying(action) != self
    }
}

public enum DesklogExternalAction: Sendable, Equatable {
    case startRecording
    case stopRecording
    case startAudio
    case stopAudio
    case startSummary

    public init?(url: URL) {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        components.scheme == "desklog",
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.query == nil,
        components.fragment == nil,
        let host = components.host,
        components.percentEncodedHost == host,
        components.percentEncodedPath == components.path else {
            return nil
        }

        switch (host, components.path) {
        case ("record", "/start"):
            self = .startRecording
        case ("record", "/stop"):
            self = .stopRecording
        case ("audio", "/start"):
            self = .startAudio
        case ("audio", "/stop"):
            self = .stopAudio
        case ("summary", "/start"):
            self = .startSummary
        default:
            return nil
        }
    }

    public var recordingControlAction: RecordingControlAction? {
        switch self {
        case .startRecording:
            return .startRecording
        case .stopRecording:
            return .stopRecording
        case .startAudio:
            return .startAudio
        case .stopAudio:
            return .stopAudio
        case .startSummary:
            return nil
        }
    }
}

public enum AudioAlertKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case musicDetected
    case prolongedSilence

    public var message: String {
        switch self {
        case .musicDetected:
            return "音楽を検出しました。記録を停止してください"
        case .prolongedSilence:
            return "10分無音を検出しました。記録を停止してください"
        }
    }
}

public enum MenuBarPresentation {
    public static func statusText(
        recordingMode: RecordingMode,
        isSummarizing: Bool,
        audioAlert: AudioAlertKind?
    ) -> String? {
        if let audioAlert { return audioAlert.message }
        if isSummarizing { return "要約中" }
        return recordingMode.menuBarStatusText
    }
}

public struct AudioActivityMonitor: Sendable, Equatable {
    public static let inputLevelThreshold = 0.04
    public static let prolongedSilenceDuration: TimeInterval = 600
    public static let musicConfidenceThreshold = 0.75
    public static let requiredConsecutiveMusicDetections = 2

    private var silenceStartedAt: Date?
    private var didReportProlongedSilence = false
    private var consecutiveMusicDetections = 0
    private var didReportCurrentMusic = false

    public init() {}

    public mutating func observeInputLevel(
        _ inputLevel: Double,
        at date: Date
    ) -> AudioAlertKind? {
        guard inputLevel < Self.inputLevelThreshold else {
            silenceStartedAt = nil
            didReportProlongedSilence = false
            return nil
        }

        guard let silenceStartedAt else {
            self.silenceStartedAt = date
            return nil
        }
        guard !didReportProlongedSilence,
              date.timeIntervalSince(silenceStartedAt) >= Self.prolongedSilenceDuration else {
            return nil
        }

        didReportProlongedSilence = true
        return .prolongedSilence
    }

    public mutating func observeMusicConfidence(_ confidence: Double) -> AudioAlertKind? {
        guard confidence >= Self.musicConfidenceThreshold else {
            consecutiveMusicDetections = 0
            didReportCurrentMusic = false
            return nil
        }

        consecutiveMusicDetections = min(
            Self.requiredConsecutiveMusicDetections,
            consecutiveMusicDetections + 1
        )
        guard consecutiveMusicDetections == Self.requiredConsecutiveMusicDetections,
              !didReportCurrentMusic else {
            return nil
        }

        didReportCurrentMusic = true
        return .musicDetected
    }

    public mutating func reset() {
        silenceStartedAt = nil
        didReportProlongedSilence = false
        consecutiveMusicDetections = 0
        didReportCurrentMusic = false
    }
}

public struct AudioAlertSnoozeState: Sendable, Equatable {
    public static let duration: TimeInterval = 600

    private var snoozedUntilByKind: [AudioAlertKind: Date] = [:]

    public init() {}

    public mutating func snooze(_ kind: AudioAlertKind, at date: Date) {
        snoozedUntilByKind[kind] = date.addingTimeInterval(Self.duration)
    }

    public func isSnoozed(_ kind: AudioAlertKind, at date: Date) -> Bool {
        guard let snoozedUntil = snoozedUntilByKind[kind] else { return false }
        return date < snoozedUntil
    }

    public func shouldPresent(_ kind: AudioAlertKind, at date: Date) -> Bool {
        !isSnoozed(kind, at: date)
    }

    public mutating func clear(_ kind: AudioAlertKind) {
        snoozedUntilByKind.removeValue(forKey: kind)
    }

    public mutating func reset() {
        snoozedUntilByKind.removeAll()
    }
}
