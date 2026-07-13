import DesklogCore
import Testing

@Suite struct LiveTranscriptBufferTests {
    @Test func usesProvisionalLabelUntilStableProfileIsResolved() {
        var buffer = LiveTranscriptBuffer()
        buffer.append(
            segmentID: "segment-1",
            text: "おはようございます",
            provisionalSpeakerLabel: "Speaker 1"
        )

        #expect(buffer.renderedText == "[Speaker 1] おはようございます")
        let resolved = buffer.resolveSpeaker(segmentID: "segment-1", profileID: "Speaker-001")
        #expect(resolved)
        #expect(buffer.renderedText == "[Speaker-001] おはようございます")
        #expect(buffer.lines.first?.speakerProfileID == "Speaker-001")
    }

    @Test func replacingProfilesImmediatelyRerendersExistingLines() {
        var buffer = LiveTranscriptBuffer()
        buffer.append(
            segmentID: "segment-1",
            text: "確認します",
            provisionalSpeakerLabel: "Speaker 1"
        )
        buffer.resolveSpeaker(segmentID: "segment-1", profileID: "Speaker-001")

        var profile = SpeakerProfile(
            id: "Speaker-001",
            name: "山田",
            centroid: [1, 0]
        )
        buffer.replaceSpeakerProfiles([profile])
        #expect(buffer.renderedText == "[山田] 確認します")

        profile.name = "田中"
        profile.isSelf = true
        buffer.replaceSpeakerProfiles([profile])
        #expect(buffer.renderedText == "[田中（自分）] 確認します")
        #expect(buffer.lines.map(\.segmentID) == ["segment-1"])
    }

    @Test func canonicalProfileRendersLinesResolvedToAnAlternateID() {
        var buffer = LiveTranscriptBuffer()
        buffer.append(
            segmentID: "segment-2",
            text: "旧クラスタの発話",
            provisionalSpeakerLabel: "Speaker 2"
        )
        buffer.resolveSpeaker(segmentID: "segment-2", profileID: "Speaker-002")

        buffer.replaceSpeakerProfiles([
            SpeakerProfile(
                id: "Speaker-001",
                name: "山田",
                isSelf: true,
                centroid: [1, 0],
                alternateProfileIDs: ["Speaker-002"]
            )
        ])

        #expect(buffer.renderedText == "[山田（自分）] 旧クラスタの発話")
    }

    @Test func keepsOnlyTheEightMostRecentLines() {
        var buffer = LiveTranscriptBuffer()
        for index in 1...9 {
            buffer.append(
                segmentID: "segment-\(index)",
                text: "発話\(index)",
                provisionalSpeakerLabel: "Speaker \(index)"
            )
        }

        #expect(buffer.lines.count == LiveTranscriptBuffer.maximumLineCount)
        #expect(buffer.renderedLines.count == LiveTranscriptBuffer.maximumLineCount)
        #expect(buffer.lines.map(\.segmentID) == (2...9).map { "segment-\($0)" })
        #expect(buffer.renderedLines.first == "[Speaker 2] 発話2")
        #expect(buffer.renderedLines.last == "[Speaker 9] 発話9")
    }
}
