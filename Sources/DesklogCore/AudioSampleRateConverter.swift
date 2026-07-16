import AVFoundation
import Foundation

/// High-quality mono sample-rate conversion for Whisper input. AVAudioConverter
/// applies the anti-aliasing filter that simple sample picking does not.
public enum AudioSampleRateConverter {
    public static func resample(
        _ input: [Float],
        from inputRate: Double,
        to outputRate: Double
    ) throws -> [Float] {
        guard inputRate.isFinite, outputRate.isFinite,
              inputRate > 0, outputRate > 0 else {
            throw AudioSampleRateConversionError.invalidSampleRate
        }
        guard input.allSatisfy(\.isFinite) else {
            throw AudioSampleRateConversionError.invalidSamples
        }
        guard !input.isEmpty else { return [] }
        if inputRate == outputRate { return input }
        guard input.count <= Int(UInt32.max) else {
            throw AudioSampleRateConversionError.audioTooLong
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
           let inputBuffer = AVAudioPCMBuffer(
               pcmFormat: inputFormat,
               frameCapacity: AVAudioFrameCount(input.count)
           ) else {
            throw AudioSampleRateConversionError.converterUnavailable
        }

        inputBuffer.frameLength = AVAudioFrameCount(input.count)
        guard let inputChannel = inputBuffer.floatChannelData?[0] else {
            throw AudioSampleRateConversionError.converterUnavailable
        }
        input.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            inputChannel.update(from: baseAddress, count: source.count)
        }

        let estimatedFrames = ceil(Double(input.count) * outputRate / inputRate)
        guard estimatedFrames.isFinite,
              estimatedFrames <= Double(UInt32.max - 1_024) else {
            throw AudioSampleRateConversionError.audioTooLong
        }
        let capacity = AVAudioFrameCount(estimatedFrames) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw AudioSampleRateConversionError.converterUnavailable
        }

        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil,
              let outputChannel = outputBuffer.floatChannelData?[0] else {
            throw AudioSampleRateConversionError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown error"
            )
        }
        return Array(UnsafeBufferPointer(
            start: outputChannel,
            count: Int(outputBuffer.frameLength)
        ))
    }
}

public enum AudioSampleRateConversionError: LocalizedError, Equatable {
    case invalidSampleRate
    case invalidSamples
    case audioTooLong
    case converterUnavailable
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "音声のサンプルレートが不正です。"
        case .invalidSamples:
            return "音声に不正なサンプルが含まれています。"
        case .audioTooLong:
            return "変換する音声が長すぎます。"
        case .converterUnavailable:
            return "音声のサンプルレート変換を初期化できません。"
        case .conversionFailed(let detail):
            return "音声のサンプルレート変換に失敗しました: \(detail)"
        }
    }
}
