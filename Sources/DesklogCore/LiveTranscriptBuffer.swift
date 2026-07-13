import Foundation

/// A recent live-transcription line whose speaker may be resolved asynchronously.
public struct LiveTranscriptLine: Identifiable, Sendable, Equatable {
    public var id: String { segmentID }

    public let segmentID: String
    public let text: String
    public let provisionalSpeakerLabel: String
    public fileprivate(set) var speakerProfileID: String?

    public init(
        segmentID: String,
        text: String,
        provisionalSpeakerLabel: String,
        speakerProfileID: String? = nil
    ) {
        self.segmentID = segmentID
        self.text = text
        self.provisionalSpeakerLabel = provisionalSpeakerLabel
        self.speakerProfileID = speakerProfileID
    }

    fileprivate func rendered(using speakerLabelsByProfileID: [String: String]) -> String {
        let speakerLabel: String
        if let speakerProfileID {
            speakerLabel = speakerLabelsByProfileID[speakerProfileID] ?? speakerProfileID
        } else {
            speakerLabel = provisionalSpeakerLabel
        }
        return "[\(speakerLabel)] \(text)"
    }
}

/// Keeps the most recent live-transcription lines separate from their rendered labels.
///
/// Speaker identification can finish after a line is appended. Keeping the stable profile
/// ID on the line lets a later profile registration, rename, self-tag change, or merge
/// immediately re-render existing lines without running speech recognition again.
public struct LiveTranscriptBuffer: Sendable, Equatable {
    public static let maximumLineCount = 8

    public private(set) var lines: [LiveTranscriptLine]
    private var speakerLabelsByProfileID: [String: String]

    public init(speakerProfiles: [SpeakerProfile] = []) {
        lines = []
        speakerLabelsByProfileID = Self.makeSpeakerLabelLookup(from: speakerProfiles)
    }

    public var renderedLines: [String] {
        lines.map { $0.rendered(using: speakerLabelsByProfileID) }
    }

    public var renderedText: String {
        renderedLines.joined(separator: "\n")
    }

    public mutating func removeAllLines() {
        lines.removeAll(keepingCapacity: true)
    }

    /// Appends a provisional line. Re-appending the same segment updates and moves that
    /// segment to the end while preserving a stable speaker resolution already received.
    public mutating func append(
        segmentID: String,
        text: String,
        provisionalSpeakerLabel: String
    ) {
        let resolvedProfileID: String?
        if let existingIndex = lines.firstIndex(where: { $0.segmentID == segmentID }) {
            resolvedProfileID = lines.remove(at: existingIndex).speakerProfileID
        } else {
            resolvedProfileID = nil
        }

        lines.append(LiveTranscriptLine(
            segmentID: segmentID,
            text: text,
            provisionalSpeakerLabel: provisionalSpeakerLabel,
            speakerProfileID: resolvedProfileID
        ))
        if lines.count > Self.maximumLineCount {
            lines.removeFirst(lines.count - Self.maximumLineCount)
        }
    }

    /// Associates an asynchronously identified stable speaker profile with a live segment.
    /// Returns `false` when the segment has already fallen out of the recent-line buffer.
    @discardableResult
    public mutating func resolveSpeaker(segmentID: String, profileID: String) -> Bool {
        guard let index = lines.firstIndex(where: { $0.segmentID == segmentID }) else {
            return false
        }
        lines[index].speakerProfileID = profileID
        return true
    }

    /// Replaces the current profile snapshot used to render every retained line.
    /// Historical IDs consolidated into a canonical profile resolve through its aliases.
    public mutating func replaceSpeakerProfiles(_ speakerProfiles: [SpeakerProfile]) {
        speakerLabelsByProfileID = Self.makeSpeakerLabelLookup(from: speakerProfiles)
    }

    private static func makeSpeakerLabelLookup(from profiles: [SpeakerProfile]) -> [String: String] {
        var result: [String: String] = [:]

        // Canonical IDs take precedence if malformed data also lists one as an alias.
        for profile in profiles {
            result[profile.id] = profile.displayName
        }
        for profile in profiles {
            for alternateID in profile.alternateProfileIDs where result[alternateID] == nil {
                result[alternateID] = profile.displayName
            }
        }
        return result
    }
}
