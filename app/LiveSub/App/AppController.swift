import AppKit
import Combine
import Foundation
import LiveSubAudio
import LiveSubBackend
import LiveSubOverlay
import LiveSubSubtitles

public enum TranslationDirection: String, CaseIterable, Identifiable {
    case englishToChinese = "en-zh"
    case chineseToEnglish = "zh-en"

    public var id: String { rawValue }
    public var sourceLanguage: String { self == .englishToChinese ? "en" : "zh" }
    public var targetLanguage: String { self == .englishToChinese ? "zh" : "en" }
    public var label: String { self == .englishToChinese ? "English → 简体中文" : "中文 → English" }
    public var sourceLabel: String { self == .englishToChinese ? "English" : "中文" }
    public var targetLabel: String { self == .englishToChinese ? "简体中文" : "English" }
}

/// Live input loudness, published separately so meter updates do not re-render the transcript.
@MainActor
public final class InputLevelMeter: ObservableObject {
    public static let barCount = 4
    @Published public private(set) var bars = [Float](repeating: 0, count: barCount)

    /// Splits one 16 kHz PCM16 frame into equal windows and maps each RMS to 0...1 on a -54...-6 dBFS scale.
    func record(_ pcm16: Data) {
        let sampleCount = pcm16.count / 2
        guard sampleCount >= Self.barCount else { return }
        let window = sampleCount / Self.barCount
        var next = [Float](repeating: 0, count: Self.barCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for bar in 0..<Self.barCount {
                var sum: Float = 0
                var counted: Float = 0
                for index in stride(from: bar * window, to: (bar + 1) * window, by: 4) {
                    let value = Float(Int16(littleEndian: samples[index])) / 32_768
                    sum += value * value
                    counted += 1
                }
                let rms = (sum / max(counted, 1)).squareRoot()
                let decibels = 20 * log10(max(rms, 0.000_01))
                next[bar] = min(1, max(0, (decibels + 54) / 48))
            }
        }
        bars = next
    }

    func reset() {
        if bars.contains(where: { $0 != 0 }) { bars = [Float](repeating: 0, count: Self.barCount) }
    }
}

@MainActor
public final class AppController: ObservableObject {
    @Published public private(set) var audioSource: AudioSource
    @Published public private(set) var subtitleDisplayMode: SubtitleDisplayMode
    @Published public private(set) var direction: TranslationDirection
    @Published public private(set) var phase = "idle"
    @Published public private(set) var status = "就绪 · 尚未开始录音"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var permissionError = false
    @Published public private(set) var overlayVisible = false
    @Published public private(set) var adjustingOverlay = false
    @Published public private(set) var overlayFontSize = OverlayTypography.defaultSize
    @Published public private(set) var overlayBackdrop = false
    @Published public private(set) var transitioning = false
    @Published public private(set) var selectedSpeakerIDs: Set<String>?
    @Published public private(set) var detectedSpeakerIDs: [String] = []
    @Published public private(set) var speakerDetectionEnabled = false
    @Published public private(set) var speakerModelLoading = false
    /// Actionable capture hint while listening, e.g. no frames or only silence.
    @Published public private(set) var inputNotice: String?

    public let store = SubtitleStore()
    public let inputLevel = InputLevelMeter()
    public let setup = RuntimeSetup()
    private let backend = BackendClient()
    private let capture = AudioCaptureService()
    private let speakerDetector = SpeakerDetectionService()
    private let overlay = OverlayWindowController()
    private var sessionID: String?
    private var generation: UInt64 = 0
    private var desiredListening = false
    private var captureTask: Task<Void, Never>?
    private var inputMonitor: Task<Void, Never>?
    private var lastAudioFrameAt: Date?
    private var lastAudibleSignalAt: Date?
    private var shuttingDown = false
    private var speakerSelectionVersion = 0
    private var speakerSelectionTail: Task<Void, Never>?

    public init() {
        let settings = UserDefaults.standard
        subtitleDisplayMode = SubtitleDisplayMode.load(from: settings)
        audioSource = AudioSource(rawValue: settings.string(forKey: "livesub.audioSource") ?? "") ?? .microphone
        direction = TranslationDirection(rawValue: settings.string(forKey: "livesub.direction") ?? "") ?? .englishToChinese
        overlayFontSize = overlay.fontSize
        overlayBackdrop = overlay.showsBackdrop
        overlay.setDisplayMode(subtitleDisplayMode)
        backend.onRawEvent = { [weak self] data in
            guard let self else { return }
            if self.store.apply(eventJSON: data),
               let pair = self.store.latestCaption(for: self.selectedSpeakerIDs) {
                self.overlay.update(OverlayCaption(
                    sourceText: pair.sourceText,
                    translatedSourceText: pair.translatedSourceText,
                    targetText: pair.targetText,
                    translationState: pair.translationState
                ))
            }
        }
        backend.onEvent = { [weak self] event in
            self?.handle(event)
        }
        overlay.onFinishAdjustmentRequest = { [weak self] in
            guard let self, self.adjustingOverlay else { return }
            self.togglePositionAdjustment()
        }
    }

    public var canStart: Bool { setup.isReady && !transitioning && !speakerModelLoading && (phase == "idle" || phase == "error") }
    public var canPause: Bool { !transitioning && phase == "listening" }
    public var canResume: Bool { !transitioning && phase == "paused" }
    public var canStop: Bool { !transitioning && phase != "idle" }

    public func start() async {
        guard canStart, !shuttingDown else { return }
        transitioning = true
        if phase == "error" {
            // A local capture failure can leave the backend paused or listening.
            // Finish that session before assigning the retry a new identity.
            desiredListening = false
            await stopCapture()
            await backend.shutdown()
        }
        desiredListening = true
        errorMessage = nil
        permissionError = false
        let newID = UUID().uuidString
        speakerSelectionVersion += 1
        selectedSpeakerIDs = nil
        detectedSpeakerIDs = []
        speakerDetector.beginSession()
        sessionID = newID
        generation = 1
        phase = "loading"
        status = "正在启动本地模型…首次启动可能需要一些时间"
        do {
            try await backend.start(
                sessionID: newID, generation: generation,
                sourceLanguage: direction.sourceLanguage, targetLanguage: direction.targetLanguage
            )
        } catch {
            fail("后端启动失败：\(error.localizedDescription)")
        }
        transitioning = false
    }

    public func pause() async {
        guard canPause, !shuttingDown else { return }
        transitioning = true
        desiredListening = false
        await stopCapture()
        do {
            try await backend.pause()
        } catch {
            fail("暂停失败：\(error.localizedDescription)")
        }
        transitioning = false
    }

    public func resume() async {
        guard canResume, !shuttingDown else { return }
        transitioning = true
        desiredListening = true
        errorMessage = nil
        permissionError = false
        generation += 1
        phase = "loading"
        status = "正在继续识别…"
        do {
            try await backend.resume(
                generation: generation,
                sourceLanguage: direction.sourceLanguage, targetLanguage: direction.targetLanguage
            )
        } catch {
            fail("继续失败：\(error.localizedDescription)")
        }
        transitioning = false
    }

    public func stop() async {
        guard canStop, !shuttingDown else { return }
        let recoveringFromError = phase == "error"
        transitioning = true
        desiredListening = false
        await stopCapture()
        phase = "stopping"
        status = "正在处理尾句…"
        if recoveringFromError {
            // A disconnected backend cannot acknowledge stop. Releasing its
            // resources still lets the user finish the failed local session.
            await backend.shutdown()
            phase = "idle"
            status = "已停止 · 历史字幕保留在窗口中"
            errorMessage = nil
            permissionError = false
            transitioning = false
            return
        }
        do {
            try await backend.stop()
        } catch {
            fail("停止失败：\(error.localizedDescription)")
        }
        transitioning = false
    }

    public func selectAudioSource(_ source: AudioSource) {
        guard audioSource != source, !transitioning,
              phase != "loading", phase != "stopping" else { return }
        audioSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "livesub.audioSource")
        if phase == "listening" { Task { await switchGeneration() } }
    }

    public func selectDirection(_ next: TranslationDirection) {
        guard direction != next, !transitioning,
              phase != "loading", phase != "stopping" else { return }
        direction = next
        UserDefaults.standard.set(next.rawValue, forKey: "livesub.direction")
        if phase == "listening" { Task { await switchGeneration() } }
    }

    private func switchGeneration() async {
        guard !transitioning, phase == "listening" else { return }
        await pause()
        if phase != "error" { await resume() }
    }

    public func selectSubtitleDisplayMode(_ mode: SubtitleDisplayMode) {
        guard subtitleDisplayMode != mode else { return }
        subtitleDisplayMode = mode
        mode.save()
        overlay.setDisplayMode(mode)
    }

    public func selectSpeakers(_ speakerIDs: Set<String>?) {
        let detected = Set(detectedSpeakerIDs)
        guard speakerIDs == nil || (speakerIDs!.count <= 5 && speakerIDs!.isSubset(of: detected)) else { return }
        let previous = selectedSpeakerIDs
        selectedSpeakerIDs = speakerIDs
        overlay.clearCaption()
        guard phase == "listening" || phase == "paused" else { return }
        speakerSelectionVersion += 1
        let version = speakerSelectionVersion
        let selectedSessionID = sessionID
        let selectedGeneration = generation
        let previousTail = speakerSelectionTail
        speakerSelectionTail = Task {
            await previousTail?.value
            guard sessionID == selectedSessionID, generation == selectedGeneration else { return }
            do {
                try await backend.selectSpeakers(speakerIDs.map { $0.sorted() })
            } catch {
                if speakerSelectionVersion == version {
                    selectedSpeakerIDs = previous
                    errorMessage = "无法更改说话人选择：\(error.localizedDescription)"
                }
            }
        }
    }

    public func setSpeakerDetectionEnabled(_ enabled: Bool) async {
        guard enabled != speakerDetectionEnabled, !transitioning, !speakerModelLoading,
              phase != "loading", phase != "stopping" else { return }
        if enabled {
            speakerModelLoading = true
            let priorStatus = status
            status = "正在准备本地说话人模型…"
            do {
                try await speakerDetector.prepare()
            } catch {
                status = priorStatus
                errorMessage = "说话人模型准备失败：\(error.localizedDescription)"
                speakerModelLoading = false
                return
            }
            speakerModelLoading = false
        }
        let wasListening = phase == "listening"
        if wasListening { await pause() }
        guard phase != "error" else { return }
        speakerDetectionEnabled = enabled
        detectedSpeakerIDs = []
        selectedSpeakerIDs = nil
        overlay.clearCaption()
        if wasListening {
            await resume()
        } else if phase == "idle" {
            status = enabled ? "说话人检测已就绪 · 点击开始" : "就绪 · 尚未开始录音"
        }
    }

    public func toggleSpeaker(_ speakerID: String) {
        var selection = selectedSpeakerIDs ?? []
        if selection.contains(speakerID) {
            selection.remove(speakerID)
        } else {
            selection.insert(speakerID)
        }
        selectSpeakers(selection.isEmpty ? nil : selection)
    }

    public func toggleOverlay() {
        if overlayVisible {
            overlay.hide()
            overlayVisible = false
            adjustingOverlay = false
        } else {
            if let pair = store.latestCaption(for: selectedSpeakerIDs) {
                overlay.update(OverlayCaption(
                    sourceText: pair.sourceText,
                    translatedSourceText: pair.translatedSourceText,
                    targetText: pair.targetText,
                    translationState: pair.translationState
                ))
            }
            overlay.show()
            overlayVisible = true
        }
    }

    public func togglePositionAdjustment() {
        if adjustingOverlay {
            overlay.finishPositionAdjustment()
            adjustingOverlay = false
            overlayVisible = overlay.isVisible
        } else {
            overlay.beginPositionAdjustment()
            overlayVisible = true
            adjustingOverlay = true
        }
    }

    public func resetOverlayPosition() { overlay.resetPosition() }

    public func setOverlayFontSize(_ size: CGFloat) {
        overlay.setFontSize(size)
        overlayFontSize = overlay.fontSize
    }

    public func setOverlayBackdrop(_ visible: Bool) {
        overlay.setBackdrop(visible)
        overlayBackdrop = overlay.showsBackdrop
    }

    public func resetOverlayFontSize() {
        overlay.resetFontSize()
        overlayFontSize = overlay.fontSize
    }

    public func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.exportText, forType: .string)
        status = "已复制当前会话"
    }

    /// Returns true only when the file was written.
    @discardableResult
    public func exportTranscript(markdown: Bool) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "LiveSub-transcript.md" : "LiveSub-transcript.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            try (markdown ? store.exportMarkdown : store.exportText).write(
                to: destination, atomically: true, encoding: .utf8
            )
            status = "已导出当前会话"
            return true
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
            permissionError = false
            return false
        }
    }

    public func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        setup.stopForQuit()
        desiredListening = false
        await stopCapture()
        overlay.hide()
        await backend.shutdown()
    }

    private func handle(_ event: BackendEvent) {
        if event.kind == "state", let next = event.state {
            if let incomingID = event.sessionID, incomingID != sessionID { return }
            if let incomingGeneration = event.generation, incomingGeneration < generation { return }
            phase = next
            switch next {
            case "loading": status = "正在加载本地模型…"
            case "listening":
                if store.activeSessionID != sessionID, let sessionID {
                    store.beginSession(sessionID)
                    overlay.clearCaption()
                }
                status = audioSource == .microphone ? "正在识别 · 麦克风" : "正在识别 · 系统音频"
                if desiredListening {
                    Task {
                        if let selectedSpeakerIDs {
                            do {
                                try await backend.selectSpeakers(selectedSpeakerIDs.sorted())
                            } catch {
                                fail("无法恢复说话人选择：\(error.localizedDescription)")
                                return
                            }
                        }
                        await startCaptureIfNeeded()
                    }
                }
            case "paused":
                status = "已暂停 · 历史字幕仍可查看"
                desiredListening = false
                Task { await stopCapture() }
            case "stopping": status = "正在处理尾句…"
            case "idle": status = "已停止 · 历史字幕保留在窗口中"
            case "error":
                let message: String
                switch event.detail ?? "" {
                case "translation_load_failed":
                    message = "翻译模型加载失败。请检查本地模型文件后重试。"
                case "asr_load_failed":
                    message = "语音识别模型加载失败。请检查本地模型文件后重试。"
                default:
                    message = "识别或本地模型发生错误。请停止后重试。"
                }
                fail(message)
            default: break
            }
        } else if event.kind == "error" {
            let code = event.code ?? "unknown"
            errorMessage = Self.backendErrorMessage(code: code)
            permissionError = false
            let interruptsCapture: Set<String> = [
                "audio_overflow", "translation_overflow", "frame_rejected", "invalid_frame",
                "asr_timeout", "asr_failed", "translation_timeout", "backend_failure",
            ]
            if interruptsCapture.contains(code) {
                desiredListening = false
                status = "采集已中断 · 请查看错误"
                phase = "error"
                Task {
                    await stopCapture()
                    if code != "backend_failure" { try? await backend.pause() }
                }
            }
        }
    }

    private func startCaptureIfNeeded() async {
        guard desiredListening, phase == "listening", captureTask == nil,
              let sessionID, !shuttingDown else { return }
        let currentGeneration = generation
        do {
            if speakerDetectionEnabled { speakerDetector.beginGeneration(currentGeneration) }
            let frames = try await capture.start(
                source: audioSource, sessionID: sessionID, generation: currentGeneration
            )
            guard desiredListening, phase == "listening", generation == currentGeneration else {
                await capture.stop()
                return
            }
            lastAudioFrameAt = Date()
            lastAudibleSignalAt = Date()
            startInputMonitor()
            captureTask = Task { [weak self] in
                do {
                    for try await frame in frames {
                        guard let self, self.generation == currentGeneration else { break }
                        self.noteAudioFrame(frame)
                        if self.speakerDetectionEnabled {
                            let batch = try await self.speakerDetector.consume(frame)
                            self.detectedSpeakerIDs = batch.speakerIDs
                            for labeled in batch.frames { try await self.backend.sendAudio(labeled) }
                        } else {
                            try await self.backend.sendAudio(frame)
                        }
                    }
                    if let self, self.speakerDetectionEnabled,
                       self.generation == currentGeneration {
                        let tail = try await self.speakerDetector.finish()
                        self.detectedSpeakerIDs = tail.speakerIDs
                        for labeled in tail.frames { try await self.backend.sendAudio(labeled) }
                    }
                } catch {
                    if let self, !(error is CancellationError), self.desiredListening,
                       self.errorMessage == nil {
                        self.fail("音频采集中断：\(error.localizedDescription)", permissionError: Self.isPermissionError(error))
                        try? await self.backend.pause()
                    }
                }
                self?.captureTask = nil
            }
        } catch {
            if !(error is CancellationError), desiredListening, errorMessage == nil {
                fail("无法开始采集：\(error.localizedDescription)", permissionError: Self.isPermissionError(error))
                try? await backend.pause()
            }
        }
    }

    private func stopCapture() async {
        inputMonitor?.cancel()
        inputMonitor = nil
        inputNotice = nil
        inputLevel.reset()
        await capture.stop()
        if let captureTask {
            await captureTask.value
            self.captureTask = nil
        }
    }

    private func startInputMonitor() {
        inputMonitor?.cancel()
        inputMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.phase == "listening",
                      self.desiredListening, self.errorMessage == nil else { return }
                let now = Date()
                if now.timeIntervalSince(self.lastAudioFrameAt ?? .distantPast) > 8 {
                    self.status = "未检测到音频输入 · 请检查音源和权限"
                    self.inputNotice = self.status
                    self.inputLevel.reset()
                } else if now.timeIntervalSince(self.lastAudibleSignalAt ?? .distantPast) > 8 {
                    self.status = "音频已连接 · 等待声音"
                    self.inputNotice = self.status
                }
            }
        }
    }

    private func noteAudioFrame(_ frame: AudioFrame) {
        let now = Date()
        lastAudioFrameAt = now
        let data = frame.pcm16
        var audible = false
        for offset in stride(from: 0, to: data.count - 1, by: 32) {
            let raw = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            if abs(Int(Int16(bitPattern: raw))) > 300 {
                audible = true
                break
            }
        }
        if audible { lastAudibleSignalAt = now }
        inputLevel.record(data)
        if audible && (status.hasPrefix("音频已连接") || status.hasPrefix("未检测到")) {
            status = audioSource == .microphone ? "正在识别 · 麦克风" : "正在识别 · 系统音频"
        }
        if audible || inputNotice?.hasPrefix("未检测到") == true { inputNotice = nil }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        guard let error = error as? AudioCaptureError else { return false }
        switch error {
        case .microphoneDenied, .screenRecordingDenied: return true
        default: return false
        }
    }

    private static func backendErrorMessage(code: String) -> String {
        let guidance: String
        switch code {
        case "audio_overflow", "translation_overflow":
            guidance = "处理速度跟不上音频，采集已暂停。请停止后重试。"
        case "frame_rejected", "invalid_frame":
            guidance = "音频帧与当前会话不一致，采集已中断。请停止后重试。"
        case "asr_timeout", "asr_failed", "asr_drain_failed", "asr_reset_failed":
            guidance = "语音识别未能继续。请停止后重试。"
        case "translation_timeout":
            guidance = "翻译等待超时。请停止后重试。"
        case "backend_failure":
            guidance = "本地后端连接中断。请停止后重试。"
        default:
            guidance = "本地后端未能完成操作。请停止后重试。"
        }
        return "\(guidance)（\(code)）"
    }

    private func fail(_ message: String, permissionError: Bool = false) {
        phase = "error"
        status = "需要处理"
        errorMessage = message
        self.permissionError = permissionError
        desiredListening = false
        Task { await stopCapture() }
    }
}
