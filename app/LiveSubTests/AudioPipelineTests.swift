import AVFoundation
import Foundation
import ScreenCaptureKit
import SpeakerKit
@testable import LiveSubAudio

/// Standalone checks because this machine's Command Line Tools omit XCTest and TestingMacros.
@main
enum AudioPipelineTests {
    static func main() async throws {
        try stereo48kConvertsToMono16kWithExactDurationAndFraming()
        try finalFlushEmitsTailOnceAndResetDoesNotReplayOldSamples()
        try stereoDownmixAndPCM16LittleEndian()
        try sustainedChunksKeepExactSampleTimeline()
        try await boundedQueueReportsOverflow()
        try screenCaptureErrorsUseTheSystemCode()
        try await speakerBatchesKeepAudioAndBoundLatency()
        print("AudioPipelineChecks: 7 passed")
    }

    @MainActor static func speakerBatchesKeepAudioAndBoundLatency() async throws {
        var windows: [[Float]] = []
        let detector = SpeakerDetectionService { samples in
            windows.append(samples)
            return DiarizationResult(speakerCount: 1, totalFrames: samples.count, frameRate: 16_000,
                segments: [SpeakerSegment(speaker: .speakerId(0), startFrame: 0,
                                          endFrame: samples.count, frameRate: 16_000)],
                speakerCentroidEmbeddings: [0: [1, 0]])
        }
        var delivered: [AudioFrame] = []
        var batchSizes: [Int] = []
        var originals: [AudioFrame] = []
        for index in 0..<30 {
            let frame = AudioFrame(sessionID: "speaker-check", generation: 1, sequence: UInt64(index),
                                   startSample: UInt64(index * 2560), pcm16: Data(repeating: 2, count: 5120))
            originals.append(frame)
            let batch = try await detector.consume(frame)
            if !batch.frames.isEmpty { batchSizes.append(batch.frames.count) }
            delivered += batch.frames
        }
        try expect(batchSizes == [13, 5, 5, 5], "first output at 2.08 s, then every 0.8 s")
        delivered += try await detector.finish().frames
        try expect(delivered.map(\.sequence) == originals.map(\.sequence), "no dropped or duplicate frames")
        try expect(delivered.map(\.pcm16) == originals.map(\.pcm16), "speaker detection preserves PCM")
        try expect(delivered.map(\.startSample) == originals.map(\.startSample), "speaker detection preserves timeline")
        try expect(delivered.allSatisfy { $0.speakerID == "A" }, "speaker identity survives windows and final tail")
        try expect(windows.allSatisfy { $0.count <= 3 * 16000 + 5 * 2560 }, "history stays bounded while batches shrink")
        try expect(try await detector.finish().frames.isEmpty, "finish emits each frame once")
        detector.beginGeneration(2)
        let next = AudioFrame(sessionID: "speaker-check", generation: 2, sequence: 0,
                              startSample: 0, pcm16: Data(repeating: 3, count: 5120))
        try expect(try await detector.consume(next).frames.isEmpty, "a new generation warms its own window")
        let tail = try await detector.finish().frames
        try expect(tail == [next], "short new generation cannot reuse old context or labels")
    }

    static func screenCaptureErrorsUseTheSystemCode() throws {
        func classify(
            _ code: Int, preflight: Bool, requestGranted: Bool? = nil, domain: String = SCStreamErrorDomain
        ) -> AudioCaptureError {
            SystemAudioCapture.captureError(
                NSError(domain: domain, code: code), stage: "discover displays", preflightAuthorized: preflight,
                permissionRequestGranted: requestGranted
            )
        }

        guard case .screenRecordingDenied(let deniedDetail) = classify(
            SCStreamError.userDeclined.rawValue, preflight: false, requestGranted: false
        ) else {
            throw TestError.failed("explicit permission refusal must be classified as permission error")
        }
        try expect(deniedDetail.contains("preflight=false") && deniedDetail.contains("request=not-granted")
                   && deniedDetail.contains("stage=discover displays"),
                   "permission diagnostics retain stage, preflight, and request result")

        guard case .screenCaptureMissingEntitlements = classify(SCStreamError.missingEntitlements.rawValue, preflight: false) else {
            throw TestError.failed("missing entitlement must have its own classification")
        }
        guard case .screenCaptureStartFailed(let startDetail) = classify(SCStreamError.failedToStart.rawValue, preflight: false) else {
            throw TestError.failed("failed stream start is not a permission refusal when preflight is false")
        }
        try expect(startDetail.contains("code=-3802") && startDetail.contains("bundle="),
                   "startup diagnostics retain error code and app identity")

        guard case .screenCaptureStartFailed = classify(SCStreamError.failedToStartAudioCapture.rawValue, preflight: true) else {
            throw TestError.failed("audio service start failure is distinct from permission refusal")
        }
        guard case .screenCaptureFailed = classify(-42, preflight: false, domain: "other.service") else {
            throw TestError.failed("unrelated errors must not become permission errors")
        }
    }

    static func stereo48kConvertsToMono16kWithExactDurationAndFraming() throws {
        let converter = PCMFrameConverter(sessionID: "s1", generation: 2)
        let first = try makeStereoBuffer(frames: 4_800, left: 0.5, right: 0.5)
        let second = try makeStereoBuffer(frames: 4_800, left: 0.5, right: 0.5)
        let third = try makeStereoBuffer(frames: 4_800, left: 0.5, right: 0.5)

        let frames = try converter.append(first)
            + converter.append(second)
            + converter.append(third)
            + converter.finish()

        try expect(frames.map(\.sequence) == [0, 1], "frame sequence")
        try expect(frames.map(\.startSample) == [0, 2_560], "frame start samples")
        try expect(frames.map(\.sampleCount) == [2_560, 2_240], "full and tail framing")
        try expect(frames.reduce(0) { $0 + $1.sampleCount } == 4_800, "resampled duration")
        try expect(frames.allSatisfy { $0.sessionID == "s1" && $0.generation == 2 }, "session identity")
        try expect(frames.allSatisfy { $0.sampleRate == 16_000 && $0.channels == 1 }, "wire audio format")
        try expect(frames.allSatisfy { $0.pcm16.count == $0.sampleCount * 2 }, "PCM16 byte count")
        let samples = frames.flatMap(decodePCM16)
        let mean = Double(samples.reduce(0) { $0 + Int($1) }) / Double(samples.count)
        try expect(abs(mean - 16_384) <= 200, "preserved amplitude after resampling: \(mean)")
    }

    static func finalFlushEmitsTailOnceAndResetDoesNotReplayOldSamples() throws {
        let converter = PCMFrameConverter(sessionID: "old", generation: 1)
        let input = try makeMonoBuffer(frames: 800, value: 0.25)
        try expect(try converter.append(input).isEmpty, "incomplete frame not emitted")
        let tail = try converter.finish()
        try expect(tail.map(\.sampleCount) == [800], "tail flush")
        try expect(try converter.finish().isEmpty, "finish idempotence")

        converter.reset(sessionID: "new", generation: 2)
        try expect(try converter.append(input).isEmpty, "new incomplete frame")
        let newTail = try converter.finish()
        try expect(newTail.map(\.sampleCount) == [800], "new tail has only new samples")
        try expect(newTail.map(\.sequence) == [0], "sequence resets")
        try expect(newTail.map(\.startSample) == [0], "sample timeline resets")
        try expect(newTail.allSatisfy { $0.sessionID == "new" && $0.generation == 2 }, "generation resets")
    }

    static func stereoDownmixAndPCM16LittleEndian() throws {
        let converter = PCMFrameConverter(sessionID: "s", generation: 0)
        let input = try makeStereoBuffer(frames: 480, left: 0.5, right: -0.5)
        _ = try converter.append(input)
        let tail = try converter.finish()
        try expect(tail.reduce(0) { $0 + $1.sampleCount } == 160, "1000/3 resample count")
        let samples = tail.flatMap(decodePCM16)
        try expect(samples.allSatisfy { abs(Int($0)) <= 200 }, "stereo downmix")

        let encoded = PCMFrameConverter.encodePCM16([-1.0, -0.5, 0, 0.5, 1.0])
        try expect(Array(encoded) == [0x00, 0x80, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x40, 0xFF, 0x7F], "PCM16 little endian")
    }

    static func sustainedChunksKeepExactSampleTimeline() throws {
        let converter = PCMFrameConverter(sessionID: "long", generation: 3)
        var frames: [AudioFrame] = []
        for _ in 0..<100 {
            let input = try makeStereoBuffer(frames: 4_800, left: 0.25, right: 0.25)
            frames += try converter.append(input)
        }
        frames += try converter.finish()
        try expect(frames.reduce(0) { $0 + $1.sampleCount } == 160_000, "ten-second sample timeline")
        try expect(frames.dropLast().allSatisfy { $0.sampleCount == 2_560 }, "all non-tail frames are 160 ms")
        try expect(frames.last?.sampleCount == 1_280, "ten-second tail is 80 ms")
        try expect(frames.enumerated().allSatisfy { offset, frame in
            frame.sequence == UInt64(offset) && frame.startSample == UInt64(offset * 2_560)
        }, "monotonic frame sequence and position")
    }

    static func boundedQueueReportsOverflow() async throws {
        var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation!
        let stream = AsyncThrowingStream<AudioFrame, Error>(bufferingPolicy: .bufferingNewest(32)) {
            continuation = $0
        }
        let pipeline = AudioPipeline(
            converter: PCMFrameConverter(sessionID: "overload", generation: 0),
            continuation: continuation,
            onFailure: {}
        )
        pipeline.submit(try makeStereoBuffer(frames: 48_000 * 6, left: 0, right: 0))
        do {
            for try await _ in stream {}
            throw TestError.failed("overflow should fail the stream")
        } catch AudioCaptureError.bufferOverflow {
            // An interrupted transcript is surfaced as an error, not silent frame loss.
        }
    }

    private static func makeStereoBuffer(frames: Int, left: Float, right: Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw TestError.invalidBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            channels[0][index] = left
            channels[1][index] = right
        }
        return buffer
    }

    private static func makeMonoBuffer(frames: Int, value: Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw TestError.invalidBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { channels[0][index] = value }
        return buffer
    }

    private static func decodePCM16(_ frame: AudioFrame) -> [Int16] {
        let bytes = Array(frame.pcm16)
        return stride(from: 0, to: bytes.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestError.failed(message) }
    }

    private enum TestError: Error {
        case invalidBuffer
        case failed(String)
    }
}
