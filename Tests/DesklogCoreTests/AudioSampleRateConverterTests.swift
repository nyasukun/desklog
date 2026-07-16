import DesklogCore
import Foundation
import Testing

@Suite struct AudioSampleRateConverterTests {
    @Test func equalRatesPreserveSamplesExactly() throws {
        let input: [Float] = [-0.5, 0, 0.5]
        #expect(try AudioSampleRateConverter.resample(
            input,
            from: 16_000,
            to: 16_000
        ) == input)
    }

    @Test func downsamplingPreservesSpeechBandAndSuppressesAliasing() throws {
        let inputRate = 48_000.0
        let outputRate = 16_000.0
        let speechBand = sine(frequency: 1_000, sampleRate: inputRate, duration: 1)
        let aboveNyquist = sine(frequency: 12_000, sampleRate: inputRate, duration: 1)

        let convertedSpeech = try AudioSampleRateConverter.resample(
            speechBand,
            from: inputRate,
            to: outputRate
        )
        let convertedNoise = try AudioSampleRateConverter.resample(
            aboveNyquist,
            from: inputRate,
            to: outputRate
        )

        #expect(abs(convertedSpeech.count - 16_000) <= 16)
        #expect(rms(convertedSpeech) > 0.2)
        #expect(rms(convertedNoise) < 0.05)
    }

    @Test func invalidInputIsRejected() {
        #expect(throws: AudioSampleRateConversionError.invalidSampleRate) {
            try AudioSampleRateConverter.resample([0], from: 0, to: 16_000)
        }
        #expect(throws: AudioSampleRateConversionError.invalidSamples) {
            try AudioSampleRateConverter.resample([.nan], from: 48_000, to: 16_000)
        }
    }

    @Test func nearbyButDifferentRatesAreStillConverted() throws {
        let inputRate = 16_000.5
        let input = sine(frequency: 440, sampleRate: inputRate, duration: 10)
        let output = try AudioSampleRateConverter.resample(
            input,
            from: inputRate,
            to: 16_000
        )

        #expect(output.count != input.count)
        #expect(abs(output.count - 160_000) <= 2)
    }

    private func sine(
        frequency: Double,
        sampleRate: Double,
        duration: Double
    ) -> [Float] {
        (0..<Int(sampleRate * duration)).map { index in
            Float(0.5 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let squareSum = samples.reduce(0.0) { result, sample in
            result + Double(sample * sample)
        }
        return sqrt(squareSum / Double(samples.count))
    }
}
