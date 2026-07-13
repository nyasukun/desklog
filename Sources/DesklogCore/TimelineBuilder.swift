import Foundation

public enum TimelineBuilder {
    public static func build(
        events: [WorklogEvent],
        start: Date,
        end: Date,
        speakerProfiles: [SpeakerProfile] = []
    ) throws -> SummaryInput {
        let relevant = events.filter { $0.kind == .screenOCR || $0.kind == .speechTranscript }
        guard !relevant.isEmpty else { throw DesklogError.noLogData }

        let speechEvents = latestSpeechSnapshots(from: relevant)
        let screens = deduplicatedScreens(from: relevant)
        let combined = (screens + speechEvents).sorted { $0.timestamp < $1.timestamp }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm:ss"

        var speakerLabels: [String: (name: String, isSelf: Bool)] = [:]
        for event in events.filter({ $0.kind == .speakerLabel }).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let profileID = event.metadata["speaker_profile_id"],
                  let name = event.metadata["speaker_name"] else { continue }
            speakerLabels[profileID] = (name, event.metadata["is_self"] == "true")
        }
        // The persisted profiles are the current source of truth. In particular,
        // they let a label taught today apply when an older time range is
        // summarized and its speaker-label event is outside that range.
        for profile in speakerProfiles {
            guard let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            speakerLabels[profile.id] = (name, profile.isSelf)
            for alternateID in profile.alternateProfileIDs {
                speakerLabels[alternateID] = (name, profile.isSelf)
            }
        }

        let lines = combined.map { event -> String in
            let source: String
            if event.kind == .screenOCR {
                source = "画面OCR"
            } else {
                let profileID = event.metadata["speaker_profile_id"] ?? event.metadata["speaker_id"] ?? "Speaker-Unknown"
                let manual = speakerLabels[profileID]
                let storedName = event.metadata["speaker_name"]
                let name = manual?.name ?? storedName ?? profileID
                let isSelf = manual?.isSelf ?? (event.metadata["is_self"] == "true")
                source = isSelf ? "音声/\(name)（自分）" : "音声/\(name)"
            }
            let limit = event.kind == .screenOCR ? 6_000 : 8_000
            let content = String(normalize(event.text).prefix(limit))
            var line = "[\(formatter.string(from: event.timestamp))][\(source)] \(content)"
            if event.kind == .screenOCR, let path = event.metadata["image_path"] {
                let title = event.metadata["display_title"]
                    ?? event.metadata["selection_title"]
                    ?? "画面"
                line += "\n[スクリーンショット候補: \(title)] <\(path)>"
            }
            return line
        }
        guard !lines.isEmpty else { throw DesklogError.noLogData }
        return SummaryInput(start: start, end: end, timeline: lines.joined(separator: "\n"))
    }

    public static func deduplicatedScreens(from events: [WorklogEvent]) -> [WorklogEvent] {
        var previousBySource: [String: String] = [:]
        return events.filter { event in
            guard event.kind == .screenOCR else { return false }
            let normalized = normalize(event.text)
            guard !normalized.isEmpty else { return false }
            let source = event.metadata["display_title"]
                ?? event.metadata["selection_title"]
                ?? "画面"
            let previous = previousBySource[source] ?? ""
            let isDuplicate = normalized == previous || similarity(normalized, previous) >= 0.92
            previousBySource[source] = normalized
            return !isDuplicate
        }
    }

    public static func latestSpeechSnapshots(from events: [WorklogEvent]) -> [WorklogEvent] {
        var bySegment: [String: WorklogEvent] = [:]
        var withoutSegment: [WorklogEvent] = []
        for event in events where event.kind == .speechTranscript {
            if let segmentID = event.metadata["segment_id"] {
                if let previous = bySegment[segmentID], previous.timestamp > event.timestamp {
                    continue
                }
                bySegment[segmentID] = event
            } else {
                withoutSegment.append(event)
            }
        }
        return Array(bySegment.values) + withoutSegment
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !rhs.isEmpty else { return 0 }
        let left = Set(lhs.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        let right = Set(rhs.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard min(left.count, right.count) >= 6 else { return 0 }
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(union)
    }
}
