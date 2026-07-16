import Foundation

/// Rejects short acoustic transients before they reach speech recognition and
/// validates the speech regions reported by the local diarization model.
public enum SpeechActivityGate {
    public static let frameDuration: TimeInterval = 0.02
    public static let minimumFrameRMS = 0.002
    public static let minimumFramePeak = 0.01
    public static let minimumActiveDuration: TimeInterval = 0.10
    public static let minimumConsecutiveActiveDuration: TimeInterval = 0.06
    public static let minimumDetectedSpeechDuration: Float = 0.10

    /// Uses short, zero-mean frames so one loud sample or a DC offset cannot
    /// make a complete inference window look like speech.
    public static func containsSustainedActivity(
        in samples: [Float],
        sampleRate: Double,
        range requestedRange: Range<Int>? = nil
    ) -> Bool {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty else { return false }
        let range = clamped(requestedRange ?? samples.indices, to: samples.indices)
        guard !range.isEmpty else { return false }

        let frameSize = max(1, Int((sampleRate * frameDuration).rounded()))
        let minimumActiveSamples = Int((sampleRate * minimumActiveDuration).rounded(.up))
        let minimumConsecutiveSamples = Int(
            (sampleRate * minimumConsecutiveActiveDuration).rounded(.up)
        )
        var activeSamples = 0
        var consecutiveActiveSamples = 0
        var maximumConsecutiveActiveSamples = 0
        var frameStart = range.lowerBound

        while frameStart < range.upperBound {
            let frameEnd = min(range.upperBound, frameStart + frameSize)
            let count = frameEnd - frameStart
            var sum = 0.0
            var finiteCount = 0
            for index in frameStart..<frameEnd {
                let value = Double(samples[index])
                guard value.isFinite else { continue }
                sum += value
                finiteCount += 1
            }

            var squareSum = 0.0
            var peak = 0.0
            if finiteCount > 0 {
                let mean = sum / Double(finiteCount)
                for index in frameStart..<frameEnd {
                    let value = Double(samples[index])
                    guard value.isFinite else { continue }
                    let centered = value - mean
                    squareSum += centered * centered
                    peak = max(peak, abs(centered))
                }
            }
            let rms = finiteCount > 0 ? sqrt(squareSum / Double(finiteCount)) : 0
            let isActive = rms >= minimumFrameRMS || peak >= minimumFramePeak

            if isActive {
                activeSamples += count
                consecutiveActiveSamples += count
                maximumConsecutiveActiveSamples = max(
                    maximumConsecutiveActiveSamples,
                    consecutiveActiveSamples
                )
            } else {
                consecutiveActiveSamples = 0
            }

            if activeSamples >= minimumActiveSamples,
               maximumConsecutiveActiveSamples >= minimumConsecutiveSamples {
                return true
            }
            frameStart = frameEnd
        }
        return false
    }

    /// Includes just enough retained context to recognize a short utterance
    /// split by a flush boundary, without reopening the complete overlap.
    public static func analysisRange(
        forFreshRange requestedFreshRange: Range<Int>,
        sampleRate: Double,
        sampleCount: Int
    ) -> Range<Int> {
        guard sampleRate.isFinite, sampleRate > 0, sampleCount > 0 else { return 0..<0 }
        let bounds = 0..<sampleCount
        let freshRange = clamped(requestedFreshRange, to: bounds)
        guard !freshRange.isEmpty else { return freshRange }
        let requestedContext = (sampleRate * minimumActiveDuration).rounded(.up)
        let availableContext = freshRange.lowerBound - bounds.lowerBound
        let leadingContextSamples = requestedContext >= Double(availableContext)
            ? availableContext
            : Int(requestedContext)
        let lowerBound = freshRange.lowerBound - leadingContextSamples
        return lowerBound..<freshRange.upperBound
    }

    /// Counts complete diarized intervals that overlap newly captured audio.
    /// Keeping the complete crossing interval protects short utterances split
    /// by a flush boundary; overlapping speakers still do not double-count.
    public static func detectedSpeechDuration(
        in segments: [LocalSpeakerDiarizationResult.Segment],
        overlapping timeRange: Range<Float>
    ) -> Float {
        guard timeRange.lowerBound.isFinite,
              timeRange.upperBound.isFinite,
              timeRange.lowerBound < timeRange.upperBound else {
            return 0
        }
        let intervals = segments.compactMap { segment -> Range<Float>? in
            guard segment.startTime.isFinite, segment.endTime.isFinite else { return nil }
            guard segment.startTime < segment.endTime,
                  segment.startTime < timeRange.upperBound,
                  timeRange.lowerBound < segment.endTime else { return nil }
            return segment.startTime..<segment.endTime
        }.sorted { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound { return lhs.upperBound < rhs.upperBound }
            return lhs.lowerBound < rhs.lowerBound
        }
        guard var current = intervals.first else { return 0 }

        var duration: Float = 0
        for interval in intervals.dropFirst() {
            if interval.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, interval.upperBound)
            } else {
                duration += current.upperBound - current.lowerBound
                current = interval
            }
        }
        duration += current.upperBound - current.lowerBound
        return duration
    }

    public static func containsSustainedSpeech(
        in segments: [LocalSpeakerDiarizationResult.Segment],
        overlapping timeRange: Range<Float>
    ) -> Bool {
        detectedSpeechDuration(in: segments, overlapping: timeRange)
            >= minimumDetectedSpeechDuration
    }

    /// Whisper occasionally emits punctuation alone for non-speech sounds.
    /// Keep short real utterances and numbers, but discard symbol-only output.
    public static func isMeaningfulTranscript(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func clamped(
        _ range: Range<Int>,
        to bounds: Range<Int>
    ) -> Range<Int> {
        let lower = min(bounds.upperBound, max(bounds.lowerBound, range.lowerBound))
        let upper = min(bounds.upperBound, max(lower, range.upperBound))
        return lower..<upper
    }
}
