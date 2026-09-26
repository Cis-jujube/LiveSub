import AVFoundation
import Foundation
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
        print("AudioPipelineChecks: 5 passed")
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
