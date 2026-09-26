import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture: NativeAudioCapture {
    private let pipeline: AudioPipeline
    private var engine: AVAudioEngine?
    private var captureFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?

    init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioCaptureError.microphoneDenied
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        Self.installInputTap(on: input, format: format, pipeline: pipeline)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        captureFormat = format
        configurationObserver = Self.observeConfigurationChanges(for: engine, owner: self)
    }

    func stop() async {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        captureFormat = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // CoreAudio invokes taps and configuration notifications on its own queues.
    // Construct these callbacks outside MainActor isolation before it calls them.
    private nonisolated static func installInputTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        pipeline: AudioPipeline
    ) {
        input.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, _ in
            pipeline.submit(buffer)
        }
    }

    private nonisolated static func observeConfigurationChanges(
        for engine: AVAudioEngine,
        owner: MicrophoneCapture
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak owner] _ in
            Task { @MainActor [weak owner] in
                guard let owner, let engine = owner.engine,
                      let captureFormat = owner.captureFormat else { return }
                let currentFormat = engine.inputNode.outputFormat(forBus: 0)
                guard currentFormat.isEqual(captureFormat) else {
                    owner.pipeline.fail(AudioCaptureError.audioFormatChanged)
                    return
                }
                // A configuration notification does not always change the format.
                if !engine.isRunning {
                    do { try engine.start() }
                    catch { owner.pipeline.fail(error) }
                }
            }
        }
    }
}
