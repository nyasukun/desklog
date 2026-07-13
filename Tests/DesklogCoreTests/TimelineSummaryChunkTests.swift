import DesklogCore
import Foundation
import Testing

@Suite struct TimelineSummaryChunkTests {
    @Test func tenMinuteChunksInterleaveSpeechAndOCRAndRemoveRepeatedScreens() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let screenMetadata = [
            "display_title": "Editor — main.swift",
            "window_id": "42",
            "bundle_identifier": "com.example.Editor"
        ]
        let events = [
            WorklogEvent(
                timestamp: start.addingTimeInterval(11 * 60 + 30),
                kind: .screenOCR,
                text: "Editor テスト結果を確認",
                metadata: screenMetadata
            ),
            WorklogEvent(
                timestamp: start.addingTimeInterval(60),
                kind: .speechTranscript,
                text: "設計方針を相談した",
                metadata: ["segment_id": "speech-1"]
            ),
            WorklogEvent(
                timestamp: start,
                kind: .screenOCR,
                text: "Editor main.swift を編集中",
                metadata: screenMetadata
            ),
            WorklogEvent(
                timestamp: start.addingTimeInterval(2 * 60),
                kind: .screenOCR,
                text: "Editor   main.swift を編集中",
                metadata: screenMetadata
            ),
            WorklogEvent(
                timestamp: start.addingTimeInterval(11 * 60),
                kind: .speechTranscript,
                text: "テスト完了を共有した",
                metadata: ["segment_id": "speech-2"]
            )
        ]

        let chunks = try TimelineBuilder.buildSummaryChunks(
            events: events,
            start: start,
            end: start.addingTimeInterval(20 * 60)
        )

        #expect(chunks.count == 2)
        #expect(chunks[0].end.timeIntervalSince(chunks[0].start) == 10 * 60)
        #expect(chunks[0].timeline.contains("[画面OCR]"))
        #expect(chunks[0].timeline.contains("[音声/Speaker-Unknown]"))
        #expect(chunks[0].timeline.range(of: "[画面OCR]") == chunks[0].timeline.range(of: "[画面OCR]", options: .backwards))
        #expect(
            chunks[0].timeline.range(of: "[画面OCR]")!.lowerBound <
                chunks[0].timeline.range(of: "[音声/Speaker-Unknown]")!.lowerBound
        )
        #expect(chunks[1].timeline.contains("[画面OCR]"))
        #expect(chunks[1].timeline.contains("[音声/Speaker-Unknown]"))
        #expect(
            chunks[1].timeline.range(of: "[音声/Speaker-Unknown]")!.lowerBound <
                chunks[1].timeline.range(of: "[画面OCR]")!.lowerBound
        )
    }

    @Test func oversizedTenMinuteWindowSplitsWithoutSeparatingSources() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let events = [
            WorklogEvent(timestamp: start, kind: .screenOCR, text: String(repeating: "画", count: 80)),
            WorklogEvent(timestamp: start.addingTimeInterval(1), kind: .speechTranscript, text: "会話"),
            WorklogEvent(timestamp: start.addingTimeInterval(2), kind: .screenOCR, text: String(repeating: "別", count: 80))
        ]

        let chunks = try TimelineBuilder.buildSummaryChunks(
            events: events,
            start: start,
            end: start.addingTimeInterval(10 * 60),
            maximumCharacters: 130
        )

        #expect(chunks.count == 3)
        #expect(chunks.flatMap { $0.timeline.components(separatedBy: "\n") }.joined().contains("会話"))
    }
}
