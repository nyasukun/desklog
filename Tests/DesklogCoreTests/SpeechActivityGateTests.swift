import DesklogCore
import Foundation
import Testing

@Suite struct SpeechActivityGateTests {
    @Test func thresholdsDescribeSustainedRatherThanSingleSampleActivity() {
        #expect(SpeechActivityGate.frameDuration == 0.02)
        #expect(SpeechActivityGate.minimumActiveDuration == 0.10)
        #expect(SpeechActivityGate.minimumConsecutiveActiveDuration == 0.06)
        #expect(SpeechActivityGate.minimumDetectedSpeechDuration == 0.10)
    }

    @Test func silenceDCAndNonFiniteSamplesAreRejected() {
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: Array(repeating: 0, count: 16_000),
            sampleRate: 16_000
        ))
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: Array(repeating: 0.2, count: 16_000),
            sampleRate: 16_000
        ))
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: [.nan, .infinity, -.infinity],
            sampleRate: 16_000
        ))
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: [0.1],
            sampleRate: 0
        ))
    }

    @Test func aLoudImpulseAndSeparatedClicksAreRejected() {
        var impulse = Array(repeating: Float.zero, count: 16_000)
        impulse[8_000] = 1
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: impulse,
            sampleRate: 16_000
        ))

        var clicks = Array(repeating: Float.zero, count: 16_000)
        for index in stride(from: 800, to: clicks.count, by: 1_600) {
            clicks[index] = 1
        }
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: clicks,
            sampleRate: 16_000
        ))
    }

    @Test func sustainedVoiceLikeSignalIsAcceptedAtDifferentSampleRates() {
        for sampleRate in [16_000.0, 48_000.0] {
            let count = Int(sampleRate)
            let signal = (0..<count).map { index -> Float in
                let time = Double(index) / sampleRate
                guard (0.2..<0.5).contains(time) else { return 0 }
                return Float(0.04 * sin(2 * .pi * 220 * time))
            }
            #expect(SpeechActivityGate.containsSustainedActivity(
                in: signal,
                sampleRate: sampleRate
            ))
        }
    }

    @Test func onlyTheRequestedFreshRangeAffectsTheAcousticGate() {
        let sampleRate = 16_000.0
        var samples = Array(repeating: Float.zero, count: 32_000)
        for index in 0..<4_800 {
            samples[index] = Float(0.04 * sin(2 * .pi * 220 * Double(index) / sampleRate))
        }

        #expect(SpeechActivityGate.containsSustainedActivity(
            in: samples,
            sampleRate: sampleRate
        ))
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: samples,
            sampleRate: sampleRate,
            range: 16_000..<32_000
        ))
    }

    @Test func leadingContextProtectsSpeechSplitByAFlushBoundary() {
        let sampleRate = 16_000.0
        let freshRange = 16_000..<32_000
        let analysisRange = SpeechActivityGate.analysisRange(
            forFreshRange: freshRange,
            sampleRate: sampleRate,
            sampleCount: 32_000
        )
        var samples = Array(repeating: Float.zero, count: 32_000)
        for index in 15_200..<16_800 {
            samples[index] = Float(0.04 * sin(2 * .pi * 220 * Double(index) / sampleRate))
        }

        #expect(analysisRange == 14_400..<32_000)
        #expect(SpeechActivityGate.containsSustainedActivity(
            in: samples,
            sampleRate: sampleRate,
            range: analysisRange
        ))

        var oldActivity = Array(repeating: Float.zero, count: 32_000)
        for index in 12_000..<13_600 {
            oldActivity[index] = 0.04
        }
        #expect(!SpeechActivityGate.containsSustainedActivity(
            in: oldActivity,
            sampleRate: sampleRate,
            range: analysisRange
        ))
    }

    @Test func diarizedIntervalsCrossingTheFreshRangeAreMergedAtFullLength() {
        let segments: [LocalSpeakerDiarizationResult.Segment] = [
            .init(speakerID: 0, startTime: 0, endTime: 0.5),
            .init(speakerID: 1, startTime: 0.4, endTime: 0.8),
            .init(speakerID: 0, startTime: 1.1, endTime: 1.2),
        ]

        let duration = SpeechActivityGate.detectedSpeechDuration(
            in: segments,
            overlapping: 0.3..<1.15
        )
        #expect(abs(duration - 0.9) < 0.000_1)
        #expect(SpeechActivityGate.containsSustainedSpeech(
            in: segments,
            overlapping: 0.3..<1.15
        ))
        #expect(!SpeechActivityGate.containsSustainedSpeech(
            in: segments,
            overlapping: 0.81..<1.05
        ))
    }

    @Test func speechFoundOnlyInRetainedOverlapDoesNotOpenTheGate() {
        let segments: [LocalSpeakerDiarizationResult.Segment] = [
            .init(speakerID: 0, startTime: 1, endTime: 2),
        ]

        #expect(!SpeechActivityGate.containsSustainedSpeech(
            in: segments,
            overlapping: 4..<16
        ))
        #expect(SpeechActivityGate.containsSustainedSpeech(
            in: segments + [.init(speakerID: 0, startTime: 5, endTime: 5.3)],
            overlapping: 4..<16
        ))
    }

    @Test func completeDiarizedIntervalProtectsSpeechSplitByAFlushBoundary() {
        let crossing = [
            LocalSpeakerDiarizationResult.Segment(
                speakerID: 0,
                startTime: 3.92,
                endTime: 4.08
            )
        ]

        #expect(SpeechActivityGate.containsSustainedSpeech(
            in: crossing,
            overlapping: 4..<16
        ))
        #expect(!SpeechActivityGate.containsSustainedSpeech(
            in: crossing,
            overlapping: 4.08..<16
        ))
    }

    @Test func punctuationOnlyTranscriptIsRejectedWithoutDroppingShortWordsOrNumbers() {
        #expect(!SpeechActivityGate.isMeaningfulTranscript("。！？… ,"))
        #expect(SpeechActivityGate.isMeaningfulTranscript("はい"))
        #expect(SpeechActivityGate.isMeaningfulTranscript("3"))
    }
}
