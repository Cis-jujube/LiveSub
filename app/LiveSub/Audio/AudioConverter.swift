import AVFoundation
import Foundation

/// Keeps resampler state across capture callbacks and emits only complete 160 ms frames.
public final class PCMFrameConverter {
    public static let sampleRate = 16_000
    public static let frameSamples = 2_560

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!
    private var sourceFormat: AVAudioFormat?
    private var resampler: AVAudioConverter?
    private var pendingSamples: [Float] = []
    private var consumedSamples = 0
    private var nextSequence: UInt64 = 0
    private var nextStartSample: UInt64 = 0
    private var isFinished = false

    public private(set) var sessionID: String
    public private(set) var generation: UInt64

    public init(sessionID: String, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }

    public func append(_ input: AVAudioPCMBuffer) throws -> [AudioFrame] {
        guard !isFinished else { throw AudioCaptureError.converterFinished }
        guard input.frameLength > 0 else { return [] }
        try configure(for: input.format)

        if resampler == nil {
            guard let channel = input.floatChannelData?[0] else {
                throw AudioCaptureError.unsupportedAudioFormat
            }
            pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        } else {
            try convert(input)
        }
        return emitCompleteFrames()
    }

    public func finish() throws -> [AudioFrame] {
        guard !isFinished else { return [] }
        if let resampler {
            try drain(resampler)
        }
        isFinished = true
        var frames = emitCompleteFrames()
        let remaining = pendingSamples.count - consumedSamples
        if remaining > 0 {
            frames.append(makeFrame(samples: pendingSamples[consumedSamples...]))
        }
        pendingSamples.removeAll(keepingCapacity: false)
        consumedSamples = 0
        return frames
    }

    /// A new capture generation cannot reuse the previous resampler or partial frame.
    public func reset(sessionID: String, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
        sourceFormat = nil
        resampler = nil
        pendingSamples.removeAll(keepingCapacity: false)
        consumedSamples = 0
        nextSequence = 0
        nextStartSample = 0
        isFinished = false
    }

    private func configure(for format: AVAudioFormat) throws {
        if let sourceFormat {
            guard sourceFormat.isEqual(format) else { throw AudioCaptureError.audioFormatChanged }
            return
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.unsupportedAudioFormat
        }
        sourceFormat = format
        if format.commonFormat == .pcmFormatFloat32,
           format.sampleRate == Double(Self.sampleRate),
           format.channelCount == 1,
           !format.isInterleaved {
            return
        }
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw AudioCaptureError.unsupportedAudioFormat
        }
        converter.downmix = true
        resampler = converter
    }

    private func convert(_ input: AVAudioPCMBuffer) throws {
        guard let resampler else { return }
        var suppliedInput = false
        let ratio = Double(Self.sampleRate) / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(512, Int(ceil(Double(input.frameLength) * ratio)) + 128))
        for _ in 0..<32 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioCaptureError.unsupportedAudioFormat
            }
            var conversionError: NSError?
            let status = resampler.convert(to: output, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            try appendConverted(output)
            if let conversionError { throw conversionError }
            switch status {
            case .haveData:
                if output.frameLength == 0 { throw AudioCaptureError.converterStalled }
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw AudioCaptureError.conversionFailed
            @unknown default:
                throw AudioCaptureError.conversionFailed
            }
        }
        throw AudioCaptureError.converterStalled
    }

    private func drain(_ resampler: AVAudioConverter) throws {
        for _ in 0..<32 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512) else {
                throw AudioCaptureError.unsupportedAudioFormat
            }
            var conversionError: NSError?
            let status = resampler.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            try appendConverted(output)
            if let conversionError { throw conversionError }
            switch status {
            case .haveData:
                if output.frameLength == 0 { throw AudioCaptureError.converterStalled }
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw AudioCaptureError.conversionFailed
            @unknown default:
                throw AudioCaptureError.conversionFailed
            }
        }
        throw AudioCaptureError.converterStalled
    }

    private func appendConverted(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength == 0 || buffer.floatChannelData != nil else {
            throw AudioCaptureError.unsupportedAudioFormat
        }
        guard let channel = buffer.floatChannelData?[0] else { return }
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func emitCompleteFrames() -> [AudioFrame] {
        var emitted: [AudioFrame] = []
        while pendingSamples.count - consumedSamples >= Self.frameSamples {
            let end = consumedSamples + Self.frameSamples
            emitted.append(makeFrame(samples: pendingSamples[consumedSamples..<end]))
            consumedSamples = end
        }
        if consumedSamples > 0 {
            pendingSamples.removeFirst(consumedSamples)
            consumedSamples = 0
        }
        return emitted
    }

    private func makeFrame(samples: ArraySlice<Float>) -> AudioFrame {
        let frame = AudioFrame(
            sessionID: sessionID,
            generation: generation,
            sequence: nextSequence,
            startSample: nextStartSample,
            pcm16: Self.encodePCM16(samples)
        )
        nextSequence += 1
        nextStartSample += UInt64(samples.count)
        return frame
    }

    public static func encodePCM16<S: Sequence>(_ samples: S) -> Data where S.Element == Float {
        var output = Data()
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let clamped = min(1, max(-1, finite))
            let value = clamped < 0
                ? Int16((clamped * 32_768).rounded())
                : Int16((clamped * 32_767).rounded())
            let bits = UInt16(bitPattern: value)
            output.append(UInt8(truncatingIfNeeded: bits))
            output.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return output
    }
}
