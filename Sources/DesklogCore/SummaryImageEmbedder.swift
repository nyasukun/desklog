import Foundation

/// Adds locally saved captures to the summary without depending on the local
/// language model to preserve paths or emit perfectly formed image Markdown.
///
/// A summary topic is matched against both the OCR captured in each image and
/// speech/OCR events near that capture. Explicit times in the summary are also
/// used, so a capture can still be selected when the model paraphrases a topic.
public enum SummaryImageEmbedder {
    public static let defaultMaximumImages = 4
    public static let defaultContextRadius: TimeInterval = 5 * 60

    public static func embedRelevantCaptures(
        in summary: String,
        events: [WorklogEvent],
        maximumImages: Int = defaultMaximumImages,
        contextRadius: TimeInterval = defaultContextRadius
    ) -> String {
        guard maximumImages > 0, contextRadius > 0 else { return summary }

        let candidates = events.compactMap(CaptureCandidate.init(event:))
            .sorted {
                if $0.event.timestamp == $1.event.timestamp { return $0.path < $1.path }
                return $0.event.timestamp < $1.event.timestamp
            }
        guard !candidates.isEmpty else { return summary }

        let alreadyEmbedded = embeddedCandidatePaths(in: summary, candidates: candidates)
        let remainingCapacity = maximumImages - alreadyEmbedded.count
        guard remainingCapacity > 0 else { return summary }

        let lines = summary.components(separatedBy: .newlines)
        let topics = summaryTopics(in: lines)
        guard !topics.isEmpty else { return summary }

        let contextEvents = events.filter {
            $0.kind == .screenOCR || $0.kind == .speechTranscript
        }.map {
            ContextEvent(event: $0, features: features(in: $0.text))
        }
        let nearbyEvidence = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            let evidence = contextEvents.compactMap { context -> NearbyEvidence? in
                guard context.event.id != candidate.event.id else { return nil }
                let distance = abs(
                    context.event.timestamp.timeIntervalSince(candidate.event.timestamp)
                )
                guard distance <= contextRadius else { return nil }
                return NearbyEvidence(
                    features: context.features,
                    proximity: max(0, 1 - distance / contextRadius)
                )
            }
            return (candidate.event.id, evidence)
        })
        var matches: [Match] = []
        for topic in topics {
            for candidate in candidates where !alreadyEmbedded.contains(candidate.path) {
                let match = score(
                    topic: topic,
                    candidate: candidate,
                    nearbyEvidence: nearbyEvidence[candidate.event.id] ?? []
                )
                if match.hasReliableEvidence { matches.append(match) }
            }
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.topic.lineIndex != $1.topic.lineIndex {
                return $0.topic.lineIndex < $1.topic.lineIndex
            }
            return $0.candidate.event.timestamp < $1.candidate.event.timestamp
        }

        var selectedByLine: [Int: CaptureCandidate] = [:]
        var selectedPaths = alreadyEmbedded
        var selectedScreenFingerprints = Set(candidates.filter {
            alreadyEmbedded.contains($0.path)
        }.map(\.screenFingerprint))
        var selectedTopicFeatures: [Set<String>] = []

        for match in matches {
            guard selectedByLine.count < remainingCapacity else { break }
            guard selectedByLine[match.topic.lineIndex] == nil,
                  !selectedPaths.contains(match.candidate.path),
                  !selectedScreenFingerprints.contains(match.candidate.screenFingerprint),
                  !selectedTopicFeatures.contains(where: {
                      featureSimilarity($0, match.topic.features) >= 0.75
                  }) else {
                continue
            }
            selectedByLine[match.topic.lineIndex] = match.candidate
            selectedPaths.insert(match.candidate.path)
            selectedScreenFingerprints.insert(match.candidate.screenFingerprint)
            selectedTopicFeatures.append(match.topic.features)
        }
        guard !selectedByLine.isEmpty else { return summary }

        var output: [String] = []
        for (index, line) in lines.enumerated() {
            output.append(line)
            guard let candidate = selectedByLine[index] else { continue }
            output.append("")
            output.append("![\(markdownAltText(candidate.title))](<\(candidate.path)>)")
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    private static func score(
        topic: SummaryTopic,
        candidate: CaptureCandidate,
        nearbyEvidence: [NearbyEvidence]
    ) -> Match {
        let directOverlap = containment(of: topic.features, in: candidate.ocrFeatures)
        let titleOverlap = containment(of: topic.features, in: candidate.titleFeatures)
        var nearbyOverlap = 0.0

        for evidence in nearbyEvidence {
            let eventOverlap = containment(of: topic.features, in: evidence.features)
            nearbyOverlap = max(nearbyOverlap, eventOverlap * evidence.proximity)
        }

        let temporalScore = timeScore(
            topic.times,
            candidateDate: candidate.event.timestamp
        )
        let lexicalEvidence = max(directOverlap, titleOverlap, nearbyOverlap)
        let total = temporalScore.value
            + directOverlap * 8
            + nearbyOverlap * 6
            + titleOverlap * 3
            + topic.importance
        return Match(
            topic: topic,
            candidate: candidate,
            score: total,
            hasReliableEvidence: temporalScore.isReliable || lexicalEvidence >= 0.16
        )
    }

    private static func summaryTopics(in lines: [String]) -> [SummaryTopic] {
        var result: [SummaryTopic] = []
        var currentSection = ""
        var insideCodeFence = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideCodeFence.toggle()
                continue
            }
            guard !insideCodeFence else { continue }
            if trimmed.hasPrefix("#") {
                currentSection = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                continue
            }
            guard isEligibleTopicLine(trimmed), !hasFollowingImage(after: index, in: lines) else {
                continue
            }
            let topicFeatures = features(in: trimmed)
            guard topicFeatures.count >= 2 else { continue }
            result.append(SummaryTopic(
                lineIndex: index,
                features: topicFeatures,
                times: times(in: trimmed),
                importance: importance(of: trimmed, section: currentSection)
            ))
        }
        return result
    }

    private static func isEligibleTopicLine(_ line: String) -> Bool {
        guard line.count >= 5,
              !line.hasPrefix("!["),
              !line.hasPrefix("|"),
              !line.hasPrefix("---"),
              !line.hasPrefix(">"),
              line != "なし",
              line != "- なし",
              line != "* なし" else {
            return false
        }
        return true
    }

    private static func embeddedCandidatePaths(
        in summary: String,
        candidates: [CaptureCandidate]
    ) -> Set<String> {
        let imageLines = summary.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("![")
        }
        return Set(candidates.compactMap { candidate in
            let angleDestination = "](<\(candidate.path)>)"
            let plainDestination = "](\(candidate.path))"
            return imageLines.contains(where: {
                $0.contains(angleDestination) || $0.contains(plainDestination)
            }) ? candidate.path : nil
        })
    }

    private static func hasFollowingImage(after index: Int, in lines: [String]) -> Bool {
        guard index + 1 < lines.count else { return false }
        for nextIndex in (index + 1)..<lines.count {
            let next = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if next.isEmpty { continue }
            return next.hasPrefix("![")
        }
        return false
    }

    private static func importance(of line: String, section: String) -> Double {
        let normalizedSection = section.lowercased()
        var value = 0.0
        if normalizedSection.contains("主な作業") || normalizedSection.contains("成果") {
            value += 1.5
        } else if normalizedSection.contains("決定") || normalizedSection.contains("重要") {
            value += 1.0
        } else if normalizedSection.contains("todo") || normalizedSection.contains("フォロー") {
            value += 0.25
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            value += 0.25
        }
        if ["決定", "設計", "実装", "修正", "検証", "完了"].contains(where: line.contains) {
            value += 0.25
        }
        return value
    }

    private static func times(in text: String) -> [Int] {
        var result: [Int] = []
        let patterns = [
            #"(?<![0-9])([01]?[0-9]|2[0-3])[:：]([0-5][0-9])(?::[0-5][0-9])?(?![0-9])"#,
            #"(?<![0-9])([01]?[0-9]|2[0-3])時(?:([0-5]?[0-9])分)?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let hourRange = Range(match.range(at: 1), in: text),
                      let hour = Int(text[hourRange]) else { continue }
                var minute = 0
                if match.numberOfRanges > 2,
                   match.range(at: 2).location != NSNotFound,
                   let minuteRange = Range(match.range(at: 2), in: text) {
                    minute = Int(text[minuteRange]) ?? 0
                }
                let value = hour * 60 + minute
                if !result.contains(value) { result.append(value) }
            }
        }
        return result
    }

    private static func timeScore(_ times: [Int], candidateDate: Date) -> TemporalScore {
        guard !times.isEmpty else { return TemporalScore(value: 0, isReliable: false) }
        let components = Calendar.current.dateComponents([.hour, .minute], from: candidateDate)
        let candidateMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if times.count >= 2 {
            let start = times[0]
            let end = times[1]
            let duration = positiveMinuteDistance(from: start, to: end)
            let elapsed = positiveMinuteDistance(from: start, to: candidateMinute)
            if elapsed <= duration {
                let centerDistance = abs(Double(elapsed) - Double(duration) / 2)
                let centerBonus = duration > 0 ? max(0, 1 - centerDistance / (Double(duration) / 2 + 1)) : 1
                return TemporalScore(value: 5 + centerBonus, isReliable: true)
            }
        }

        let distance = times.map { circularMinuteDistance($0, candidateMinute) }.min() ?? 1_440
        switch distance {
        case 0...2: return TemporalScore(value: 6, isReliable: true)
        case 3...10: return TemporalScore(value: 5, isReliable: true)
        case 11...30: return TemporalScore(value: 3, isReliable: true)
        case 31...60: return TemporalScore(value: 1, isReliable: false)
        default: return TemporalScore(value: 0, isReliable: false)
        }
    }

    private static func positiveMinuteDistance(from start: Int, to end: Int) -> Int {
        (end - start + 1_440) % 1_440
    }

    private static func circularMinuteDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 1_440 - direct)
    }

    /// Produces language-agnostic features without adding a tokenizer model to
    /// the app. Latin words and Japanese two-character sequences are enough to
    /// retain product names and concrete terms shared by a summary and OCR.
    fileprivate static func features(in text: String) -> Set<String> {
        let lowered = text.lowercased()
        var result = Set<String>()
        var latinRun = ""
        var japaneseRun = ""

        func flushLatin() {
            let containsLetter = latinRun.unicodeScalars.contains {
                $0.value >= 97 && $0.value <= 122
            }
            if latinRun.count >= 2,
               containsLetter,
               !ignoredFeatures.contains(latinRun) {
                result.insert(latinRun)
            }
            latinRun.removeAll(keepingCapacity: true)
        }
        func flushJapanese() {
            let characters = Array(japaneseRun)
            if characters.count >= 2 {
                for index in 0..<(characters.count - 1) {
                    let value = String(characters[index...index + 1])
                    if !ignoredFeatures.contains(value) { result.insert(value) }
                }
            }
            japaneseRun.removeAll(keepingCapacity: true)
        }

        for scalar in lowered.unicodeScalars {
            if isLatinWordScalar(scalar) {
                flushJapanese()
                latinRun.unicodeScalars.append(scalar)
            } else if isJapaneseScalar(scalar) {
                flushLatin()
                japaneseRun.unicodeScalars.append(scalar)
            } else {
                flushLatin()
                flushJapanese()
            }
        }
        flushLatin()
        flushJapanese()
        return result
    }

    private static func isLatinWordScalar(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar == "_"
            || scalar == "-"
    }

    private static func isJapaneseScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x30ff).contains(scalar.value)
            || (0x3400...0x4dbf).contains(scalar.value)
            || (0x4e00...0x9fff).contains(scalar.value)
            || (0xff66...0xff9f).contains(scalar.value)
    }

    private static func containment(of topic: Set<String>, in context: Set<String>) -> Double {
        guard !topic.isEmpty else { return 0 }
        return Double(topic.intersection(context).count) / Double(topic.count)
    }

    private static func featureSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    private static func markdownAltText(_ value: String) -> String {
        let oneLine = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "]", with: "］")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((oneLine.isEmpty ? "スクリーンショット" : oneLine).prefix(100))
    }

    private static let ignoredFeatures: Set<String> = [
        "the", "and", "for", "with", "from", "http", "https", "com",
        "した", "して", "する", "です", "ます", "こと", "ため", "画面",
        "作業", "確認", "対応", "実施", "開始", "完了", "内容", "なし",
        "主な", "流れ", "時刻", "次に", "必要"
    ]
}

private struct CaptureCandidate {
    let event: WorklogEvent
    let path: String
    let title: String
    let ocrFeatures: Set<String>
    let titleFeatures: Set<String>
    let screenFingerprint: String

    init?(event: WorklogEvent) {
        guard event.kind == .screenOCR,
              let path = event.metadata["image_path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else {
            return nil
        }
        self.event = event
        self.path = path
        title = event.metadata["display_title"]
            ?? event.metadata["selection_title"]
            ?? "スクリーンショット"
        ocrFeatures = SummaryImageEmbedder.features(in: event.text)
        titleFeatures = SummaryImageEmbedder.features(in: title)
        let source = event.metadata["window_id"].map {
            "\(event.metadata["bundle_identifier"] ?? "unknown"):\($0)"
        } ?? title
        let normalizedText = event.text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        screenFingerprint = "\(source.lowercased())|\(normalizedText)"
    }
}

private struct SummaryTopic {
    let lineIndex: Int
    let features: Set<String>
    let times: [Int]
    let importance: Double
}

private struct ContextEvent {
    let event: WorklogEvent
    let features: Set<String>
}

private struct NearbyEvidence {
    let features: Set<String>
    let proximity: Double
}

private struct Match {
    let topic: SummaryTopic
    let candidate: CaptureCandidate
    let score: Double
    let hasReliableEvidence: Bool
}

private struct TemporalScore {
    let value: Double
    let isReliable: Bool
}
