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
        let permissionRequestGranted: Bool?
        if CGPreflightScreenCaptureAccess() {
            permissionRequestGranted = nil
        } else {
            // A first request needs an explicit system prompt. The grant may require
            // relaunching LiveSub, so still let ScreenCaptureKit report the result.
            permissionRequestGranted = CGRequestScreenCaptureAccess()
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.captureError(error, stage: "discover displays", permissionRequestGranted: permissionRequestGranted)
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
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
        } catch {
            throw Self.captureError(error, stage: "attach audio output", permissionRequestGranted: permissionRequestGranted)
        }
        do {
            try await stream.startCapture()
        } catch {
            throw Self.captureError(error, stage: "start stream", permissionRequestGranted: permissionRequestGranted)
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
        pipeline.fail(Self.captureError(error, stage: "stream stopped"))
    }

    private nonisolated static func captureError(
        _ error: Error, stage: String, permissionRequestGranted: Bool? = nil
    ) -> AudioCaptureError {
        captureError(error, stage: stage, preflightAuthorized: CGPreflightScreenCaptureAccess(),
                     permissionRequestGranted: permissionRequestGranted)
    }

    // Accept the preflight result as data so error classification can be checked without
    // querying TCC or starting a stream. A false preflight alone does not identify the error.
    nonisolated static func captureError(
        _ error: Error, stage: String, preflightAuthorized: Bool, permissionRequestGranted: Bool? = nil
    ) -> AudioCaptureError {
        let value = error as NSError
        let bundle = Bundle.main
        let requestResult = permissionRequestGranted.map { $0 ? "granted" : "not-granted" } ?? "not-requested"
        let detail = "stage=\(stage); domain=\(value.domain); code=\(value.code); "
            + "preflight=\(preflightAuthorized); request=\(requestResult); bundle=\(bundle.bundleIdentifier ?? "unknown"); "
            + "version=\(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"); "
            + "app=\(bundle.bundleURL.path)"
        guard value.domain == SCStreamErrorDomain else {
            return .screenCaptureFailed(detail)
        }
        switch value.code {
        case SCStreamError.userDeclined.rawValue:
            return .screenRecordingDenied(detail)
        case SCStreamError.missingEntitlements.rawValue:
            return .screenCaptureMissingEntitlements(detail)
        case SCStreamError.failedToStart.rawValue, SCStreamError.failedToStartAudioCapture.rawValue:
            return .screenCaptureStartFailed(detail)
        default:
            return .screenCaptureFailed(detail)
        }
    }
}
