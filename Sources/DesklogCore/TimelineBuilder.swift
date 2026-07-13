import Foundation

public enum TimelineBuilder {
    /// Ten-minute windows keep OCR and speech close enough in time to preserve
    /// their relationship while bounding each incremental Ollama request.
    public static let summaryWindowDuration: TimeInterval = 10 * 60
    public static let maximumSummaryChunkCharacters = 12_000

    public static func build(
        events: [WorklogEvent],
        start: Date,
        end: Date,
        speakerProfiles: [SpeakerProfile] = []
    ) throws -> SummaryInput {
        let entries = try preparedEntries(events: events, speakerProfiles: speakerProfiles)
        return SummaryInput(
            start: start,
            end: end,
            timeline: entries.map(\.line).joined(separator: "\n")
        )
    }

    /// Builds chronological, mixed-source windows for rolling summarization.
    /// A window is split only when its text would otherwise exceed the local
    /// model request budget; OCR and speech remain interleaved in either case.
    public static func buildSummaryChunks(
        events: [WorklogEvent],
        start: Date,
        end: Date,
        speakerProfiles: [SpeakerProfile] = [],
        windowDuration: TimeInterval = summaryWindowDuration,
        maximumCharacters: Int = maximumSummaryChunkCharacters
    ) throws -> [SummaryInput] {
        precondition(windowDuration > 0)
        precondition(maximumCharacters > 0)
        let entries = try preparedEntries(events: events, speakerProfiles: speakerProfiles)
        var result: [SummaryInput] = []
        var currentWindowIndex: Int?
        var currentLines: [String] = []
        var currentCharacters = 0

        func appendCurrent(windowIndex: Int) {
            guard !currentLines.isEmpty else { return }
            let windowStart = start.addingTimeInterval(Double(windowIndex) * windowDuration)
            result.append(SummaryInput(
                start: max(start, windowStart),
                end: min(end, windowStart.addingTimeInterval(windowDuration)),
                timeline: currentLines.joined(separator: "\n")
            ))
        }

        for entry in entries {
            let elapsed = max(0, entry.timestamp.timeIntervalSince(start))
            let windowIndex = Int(floor(elapsed / windowDuration))
            if let existingWindowIndex = currentWindowIndex,
               existingWindowIndex != windowIndex {
                appendCurrent(windowIndex: existingWindowIndex)
                currentLines.removeAll(keepingCapacity: true)
                currentCharacters = 0
            }
            currentWindowIndex = windowIndex

            let addedCharacters = entry.line.count + (currentLines.isEmpty ? 0 : 1)
            if !currentLines.isEmpty,
               currentCharacters + addedCharacters > maximumCharacters {
                appendCurrent(windowIndex: windowIndex)
                currentLines.removeAll(keepingCapacity: true)
                currentCharacters = 0
            }
            currentLines.append(entry.line)
            currentCharacters += entry.line.count + (currentLines.count == 1 ? 0 : 1)
        }
        if let currentWindowIndex {
            appendCurrent(windowIndex: currentWindowIndex)
        }
        return result
    }

    private static func preparedEntries(
        events: [WorklogEvent],
        speakerProfiles: [SpeakerProfile]
    ) throws -> [TimelineEntry] {
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

        let entries = combined.map { event -> TimelineEntry in
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
            return TimelineEntry(timestamp: event.timestamp, line: line)
        }
        guard !entries.isEmpty else { throw DesklogError.noLogData }
        return entries
    }

    public static func deduplicatedScreens(from events: [WorklogEvent]) -> [WorklogEvent] {
        var previousBySource: [String: String] = [:]
        return events.sorted { $0.timestamp < $1.timestamp }.filter { event in
            guard event.kind == .screenOCR else { return false }
            let normalized = normalize(event.text)
            guard !normalized.isEmpty else { return false }
            let source = event.metadata["window_id"].map {
                "\(event.metadata["bundle_identifier"] ?? "unknown"):\($0)"
            } ?? event.metadata["display_title"]
                ?? event.metadata["selection_title"]
                ?? "画面"
            let previous = previousBySource[source] ?? ""
            let isDuplicate = normalized == previous || similarity(normalized, previous) >= 0.92
            // Compare against the last retained frame, not merely the last
            // sampled frame. Small incremental changes then accumulate until
            // they become materially different and are retained.
            if !isDuplicate { previousBySource[source] = normalized }
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

private struct TimelineEntry {
    let timestamp: Date
    let line: String
}
