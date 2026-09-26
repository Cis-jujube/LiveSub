import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, NativeAudioCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let pipeline: AudioPipeline
    private let callbackQueue = DispatchQueue(label: "local.livesub.audio.system", qos: .userInitiated)
    @MainActor private var stream: SCStream?

    init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    @MainActor
    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.captureError(error, stage: "discover displays")
        }
        let displayID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw AudioCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
        do {
            try await stream.startCapture()
        } catch {
            throw Self.captureError(error, stage: "start stream")
        }
        self.stream = stream
    }

    @MainActor
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else {
            pipeline.fail(AudioCaptureError.invalidSampleBuffer("sample buffer invalid"))
            return
        }
        guard let formatDescription = sampleBuffer.formatDescription else {
            pipeline.fail(AudioCaptureError.invalidSampleBuffer("format description missing"))
            return
        }
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            pipeline.fail(AudioCaptureError.invalidSampleBuffer("not linear PCM"))
            return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let count = sampleBuffer.numSamples
        guard count > 0, count <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            pipeline.fail(AudioCaptureError.invalidSampleBuffer(
                "buffer allocation failed; frames=\(count), format=\(format)"
            ))
            return
        }
        // The CoreMedia copy API checks mDataByteSize. AVAudioPCMBuffer advertises
        // zero bytes until frameLength is set, even though frameCapacity is allocated.
        buffer.frameLength = AVAudioFrameCount(count)
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destination.allSatisfy({ $0.mData != nil && $0.mDataByteSize > 0 }) else {
            pipeline.fail(AudioCaptureError.invalidSampleBuffer(
                "destination buffer empty; frames=\(count), format=\(format)"
            ))
            return
        }
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(count),
            into: buffer.mutableAudioBufferList
        )
        guard result == noErr else {
            pipeline.fail(AudioCaptureError.invalidSampleBuffer(
                "OSStatus \(result); frames=\(count), format=\(format)"
            ))
            return
        }
        pipeline.submit(buffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        pipeline.fail(error)
    }

    private nonisolated static func captureError(_ error: Error, stage: String) -> AudioCaptureError {
        let value = error as NSError
        let detail = "\(stage): \(value.domain) \(value.code)"
        if !CGPreflightScreenCaptureAccess() {
            return .screenRecordingDenied(detail)
        }
        return .screenCaptureFailed(detail)
    }
}
