import AVFoundation
import Foundation

public enum AudioSource: String, CaseIterable, Sendable {
    case microphone
    case systemAudio
}

public struct AudioFrame: Sendable, Equatable {
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let startSample: UInt64
    public let pcm16: Data
    public let speakerID: String?

    public var sampleRate: Int { PCMFrameConverter.sampleRate }
    public var channels: Int { 1 }
    public var sampleCount: Int { pcm16.count / MemoryLayout<Int16>.size }

    public init(sessionID: String, generation: UInt64, sequence: UInt64, startSample: UInt64, pcm16: Data, speakerID: String? = nil) {
        self.sessionID = sessionID
        self.generation = generation
        self.sequence = sequence
        self.startSample = startSample
        self.pcm16 = pcm16
        self.speakerID = speakerID
    }
}

public enum AudioCaptureError: LocalizedError {
    case alreadyRunning
    case microphoneDenied
    case screenRecordingDenied(String)
    case screenCaptureMissingEntitlements(String)
    case screenCaptureStartFailed(String)
    case screenCaptureFailed(String)
    case noInputDevice
    case noDisplay
    case unsupportedAudioFormat
    case audioFormatChanged
    case conversionFailed
    case converterStalled
    case converterFinished
    case bufferOverflow
    case consumerTooSlow
    case invalidSampleBuffer(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Audio capture is already running."
        case .microphoneDenied: "Microphone access is not available. Allow LiveSub in System Settings."
        case .screenRecordingDenied(let detail):
            "macOS did not allow this version of LiveSub to record screen and system audio. If the setting is already on, check this app version and its permission state, then reopen it. (\(detail))"
        case .screenCaptureMissingEntitlements(let detail):
            "System audio capture is missing a required entitlement. Check the app's signing configuration. (\(detail))"
        case .screenCaptureStartFailed(let detail):
            "The macOS capture service could not start system audio capture. Try this source again. (\(detail))"
        case .screenCaptureFailed(let detail): "System audio capture failed: \(detail)"
        case .noInputDevice: "No microphone input device is available."
        case .noDisplay: "No display is available for system audio capture."
        case .unsupportedAudioFormat: "The audio device supplied an unsupported format."
        case .audioFormatChanged: "The audio device format changed during capture. Restart this source."
        case .conversionFailed: "Audio format conversion failed."
        case .converterStalled: "Audio converter stopped making progress."
        case .converterFinished: "Audio conversion was already finished."
        case .bufferOverflow: "Audio processing fell over five seconds behind; capture paused to avoid losing speech."
        case .consumerTooSlow: "The backend fell behind; capture stopped to avoid silently losing speech."
        case .invalidSampleBuffer(let detail): "System audio sample could not be copied (\(detail))."
        }
    }
}

@MainActor
protocol NativeAudioCapture: AnyObject {
    func start() async throws
    func stop() async
}

/// One capture source and one converter are owned by one session generation.
@MainActor
public final class AudioCaptureService {
    private var activeCapture: (any NativeAudioCapture)?
    private var pipeline: AudioPipeline?
    private var captureID: UUID?

    public var isRunning: Bool { activeCapture != nil }

    public init() {}

    public func start(
        source: AudioSource,
        sessionID: String,
        generation: UInt64
    ) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        guard activeCapture == nil else { throw AudioCaptureError.alreadyRunning }
        let id = UUID()
        var streamContinuation: AsyncThrowingStream<AudioFrame, Error>.Continuation!
        let stream = AsyncThrowingStream<AudioFrame, Error>(bufferingPolicy: .bufferingNewest(32)) {
            streamContinuation = $0
        }
        let pipeline = AudioPipeline(
            converter: PCMFrameConverter(sessionID: sessionID, generation: generation),
            continuation: streamContinuation
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.captureID == id else { return }
                await self?.stop()
            }
        }
        let capture: any NativeAudioCapture
        switch source {
        case .microphone:
            capture = MicrophoneCapture(pipeline: pipeline)
        case .systemAudio:
            capture = SystemAudioCapture(pipeline: pipeline)
        }
        self.pipeline = pipeline
        activeCapture = capture
        captureID = id
        streamContinuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.captureID == id else { return }
                await self?.stop()
            }
        }
        do {
            try await capture.start()
            guard captureID == id else {
                await capture.stop()
                throw CancellationError()
            }
            return stream
        } catch {
            await capture.stop()
            if captureID == id {
                activeCapture = nil
                self.pipeline = nil
                captureID = nil
            }
            pipeline.fail(error)
            throw error
        }
    }

    public func stop() async {
        guard let activeCapture, let pipeline else { return }
        self.activeCapture = nil
        self.pipeline = nil
        captureID = nil
        await activeCapture.stop()
        await pipeline.finish()
    }
}

/// Audio callbacks only copy buffers into this bounded queue; conversion and stream delivery
/// happen on its serial worker. Every overflow completes the stream with an explicit error.
final class AudioPipeline: @unchecked Sendable {
    private struct CopiedBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
    }

    private let worker = DispatchQueue(label: "local.livesub.audio.pipeline", qos: .userInitiated)
    private let lock = NSLock()
    private let converter: PCMFrameConverter
    private let continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation
    private let onFailure: @Sendable () -> Void
    private var pendingDuration = 0.0
    private var accepting = true
    private var terminal = false

    init(
        converter: PCMFrameConverter,
        continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.converter = converter
        self.continuation = continuation
        self.onFailure = onFailure
    }

    func submit(_ input: AVAudioPCMBuffer) {
        let duration = Double(input.frameLength) / input.format.sampleRate
        guard duration.isFinite, duration >= 0 else {
            fail(AudioCaptureError.unsupportedAudioFormat)
            return
        }
        lock.lock()
        let accepted = accepting && pendingDuration + duration <= 5
        if accepted { pendingDuration += duration }
        lock.unlock()
        guard accepted else {
            fail(AudioCaptureError.bufferOverflow)
            return
        }
        guard let copy = Self.copy(input) else {
            lock.lock()
            pendingDuration -= duration
            lock.unlock()
            fail(AudioCaptureError.unsupportedAudioFormat)
            return
        }
        worker.async { [self] in
            defer {
                lock.lock()
                pendingDuration -= duration
                lock.unlock()
            }
            do {
                try emit(converter.append(copy.value))
            } catch {
                finishWithError(error)
            }
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        let shouldFail = accepting
        accepting = false
        lock.unlock()
        guard shouldFail else { return }
        worker.async { [self] in finishWithError(error) }
    }

    func finish() async {
        lock.withLock { accepting = false }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            worker.async { [self] in
                if !terminal {
                    do {
                        try emit(converter.finish())
                        if !terminal {
                            terminal = true
                            continuation.finish()
                        }
                    } catch {
                        finishWithError(error)
                    }
                }
                done.resume()
            }
        }
    }

    private func emit(_ frames: [AudioFrame]) throws {
        for frame in frames where !terminal {
            switch continuation.yield(frame) {
            case .enqueued:
                break
            case .dropped:
                throw AudioCaptureError.consumerTooSlow
            case .terminated:
                terminal = true
                return
            @unknown default:
                throw AudioCaptureError.consumerTooSlow
            }
        }
    }

    private func finishWithError(_ error: Error) {
        guard !terminal else { return }
        // Previously accepted audio is converted before the error event is sent.
        if let tail = try? converter.finish() {
            try? emit(tail)
        }
        terminal = true
        continuation.finish(throwing: error)
        onFailure()
    }

    private static func copy(_ input: AVAudioPCMBuffer) -> CopiedBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            return nil
        }
        output.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else {
                return nil
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return CopiedBuffer(value: output)
    }
}
