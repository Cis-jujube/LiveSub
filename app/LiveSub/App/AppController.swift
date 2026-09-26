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

@MainActor
public final class AppController: ObservableObject {
    @Published public private(set) var audioSource: AudioSource
    @Published public private(set) var direction: TranslationDirection
    @Published public private(set) var phase = "idle"
    @Published public private(set) var status = "就绪 · 尚未开始录音"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var overlayVisible = false
    @Published public private(set) var adjustingOverlay = false
    @Published public private(set) var transitioning = false

    public let store = SubtitleStore()
    private let backend = BackendClient()
    private let capture = AudioCaptureService()
    private let overlay = OverlayWindowController()
    private var sessionID: String?
    private var generation: UInt64 = 0
    private var desiredListening = false
    private var captureTask: Task<Void, Never>?
    private var inputMonitor: Task<Void, Never>?
    private var lastAudioFrameAt: Date?
    private var lastAudibleSignalAt: Date?
    private var shuttingDown = false

    public init() {
        let settings = UserDefaults.standard
        audioSource = AudioSource(rawValue: settings.string(forKey: "livesub.audioSource") ?? "") ?? .microphone
        direction = TranslationDirection(rawValue: settings.string(forKey: "livesub.direction") ?? "") ?? .englishToChinese
        backend.onRawEvent = { [weak self] data in
            guard let self else { return }
            if self.store.apply(eventJSON: data), let pair = self.store.latestCaption {
                self.overlay.update(OverlayCaption(
                    sourceText: pair.sourceText,
                    translatedSourceText: pair.translatedSourceText,
                    targetText: pair.targetText
                ))
            }
        }
        backend.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    public var canStart: Bool { !transitioning && (phase == "idle" || phase == "error") }
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
        let newID = UUID().uuidString
        sessionID = newID
        generation = 1
        store.beginSession(newID)
        overlay.clearCaption()
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

    public func toggleOverlay() {
        if overlayVisible {
            overlay.hide()
            overlayVisible = false
            adjustingOverlay = false
        } else {
            if let pair = store.latestCaption {
                overlay.update(OverlayCaption(
                    sourceText: pair.sourceText,
                    translatedSourceText: pair.translatedSourceText,
                    targetText: pair.targetText
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

    public func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.exportText, forType: .string)
        status = "已复制当前会话"
    }

    public func exportTranscript(markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "LiveSub-transcript.md" : "LiveSub-transcript.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try (markdown ? store.exportMarkdown : store.exportText).write(
                to: destination, atomically: true, encoding: .utf8
            )
            status = "已导出当前会话"
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    public func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
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
                status = audioSource == .microphone ? "正在识别 · 麦克风" : "正在识别 · 系统音频"
                if desiredListening { Task { await startCaptureIfNeeded() } }
            case "paused":
                status = "已暂停 · 历史字幕仍可查看"
                desiredListening = false
                Task { await stopCapture() }
            case "stopping": status = "正在处理尾句…"
            case "idle": status = "已停止 · 历史字幕保留在窗口中"
            case "error": fail("本地模型或识别发生错误：\(event.detail ?? "请检查模型与日志")")
            default: break
            }
        } else if event.kind == "error" {
            let code = event.code ?? "unknown"
            errorMessage = "后端错误（\(code)）：\(event.detail ?? "请重试")"
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
                        try await self.backend.sendAudio(frame)
                    }
                } catch {
                    if let self, !(error is CancellationError), self.desiredListening,
                       self.errorMessage == nil {
                        self.fail("音频采集中断：\(error.localizedDescription)")
                        try? await self.backend.pause()
                    }
                }
                self?.captureTask = nil
            }
        } catch {
            if !(error is CancellationError), desiredListening, errorMessage == nil {
                fail("无法开始采集：\(error.localizedDescription)")
                try? await backend.pause()
            }
        }
    }

    private func stopCapture() async {
        inputMonitor?.cancel()
        inputMonitor = nil
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
                } else if now.timeIntervalSince(self.lastAudibleSignalAt ?? .distantPast) > 8 {
                    self.status = "音频已连接 · 等待声音"
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
        if audible && (status.hasPrefix("音频已连接") || status.hasPrefix("未检测到")) {
            status = audioSource == .microphone ? "正在识别 · 麦克风" : "正在识别 · 系统音频"
        }
    }

    private func fail(_ message: String) {
        phase = "error"
        status = "需要处理"
        errorMessage = message
        desiredListening = false
        Task { await stopCapture() }
    }
}
