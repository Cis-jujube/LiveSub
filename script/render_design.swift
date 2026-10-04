import AppKit
import SwiftUI
import LiveSubSubtitles

@main
struct DesignRender {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        let preferenceKeys = [SubtitleDisplayMode.preferenceKey, "livesub.audioSource", "livesub.direction"]
        let originalPreferences = preferenceKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, original) in originalPreferences {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("microphone", forKey: "livesub.audioSource")
        defaults.set("en-zh", forKey: "livesub.direction")
        let controller = AppController()
        if CommandLine.arguments.contains("--settings-only") {
            // Each pane is drawn as it appears under its native Settings tab.
            let editor = TerminologyEditor()
            editor.loaded = true
            editor.maySave = true
            editor.configuration.domains = ["ai"]
            try capture(TerminologySettingsView(editor: editor), width: 680, height: 600, dark: false, name: "settings-empty.png", title: "翻译与术语")
            editor.configuration.domains = ["ai", "software", "data"]
            editor.configuration.entries = [
                TerminologyEntry(source: "AI agent", target: "AI Agent"),
                TerminologyEntry(source: "context window", target: "上下文窗口")
            ]
            try capture(TerminologySettingsView(editor: editor), width: 680, height: 600, dark: false, name: "settings-rows.png", title: "翻译与术语")
            try capture(TerminologySettingsView(editor: editor), width: 680, height: 600, dark: true, name: "settings-dark.png", title: "翻译与术语")
            try capture(LocalRuntimeSettingsView(controller: controller), width: 680, height: 430, dark: false, name: "settings-runtime.png", title: "权限与本地运行")
            return
        }
        let pairs = [
            ("An AI Agent can plan a sequence of actions and use tools to carry out a task.", "AI Agent 可以规划一系列行动，并使用工具完成任务。"),
            ("Each token is a small unit of text that the model processes.", "每个 token 都是模型处理的一小段文本。"),
            ("The context window holds the instructions and the recent conversation.", "上下文窗口容纳指令和最近的对话。"),
            ("Keeping the original text visible makes the translation easier to review.", "保留可见的原文可以让译文更容易核对。"),
            ("In the next example, the Agent compares two possible approaches before choosing a tool.", "在下一个示例中，Agent 会先比较两种可能的方法，再选择工具。"),
            ("Its response grows as new information arrives, while the translation follows alongside it.", "它的回答会随着新信息到达而逐渐增长，译文则在旁边同步更新。"),
            ("We can now look more closely at how the model uses a token budget", "现在可以进一步观察模型如何使用 token 预算")
        ]
        for (index, pair) in pairs.enumerated() {
            let object: [String: Any] = ["session_id": "render-fixture", "generation": 1,
                "segment_id": "part-\(index)", "sequence": index, "start_ms": index * 6000,
                "end_ms": (index + 1) * 6000, "source_language": "en", "target_language": "zh",
                "source_text": pair.0, "source_revision": 1, "source_final": index < 6,
                "target_text": pair.1, "translated_source_text": pair.1.isEmpty ? "" : pair.0,
                "translated_source_revision": pair.1.isEmpty ? 0 : 1,
                "translation_state": index == 6 ? "preview" : "final"]
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let segment = try decoder.decode(SubtitleSegment.self, from: JSONSerialization.data(withJSONObject: object))
            precondition(controller.store.apply(segment))
        }
        var revised = controller.store.segments[6]
        revised.sequence = 8
        revised.sourceRevision = 2
        revised.sourceText += " while planning the next action."
        precondition(controller.store.apply(revised))
        var pending = revised
        pending.segmentId = "pending-part"
        pending.sequence = 9
        pending.startMs = 42_000
        pending.endMs = 48_000
        pending.sourceText = "Next we will examine a new example."
        pending.sourceRevision = 1
        pending.targetText = ""
        pending.translatedSourceText = ""
        pending.translatedSourceRevision = 0
        pending.translationState = .pending
        precondition(controller.store.apply(pending))
        let records = controller.store.segments
        let paragraphs = controller.store.paragraphs
        let session = controller.store.activeSessionID
        let generation = controller.store.activeGeneration
        let revision = controller.store.contentRevision
        let text = controller.store.exportText
        let markdown = controller.store.exportMarkdown
        let phase = controller.phase
        let status = controller.status
        let direction = controller.direction
        let audioSource = controller.audioSource
        for mode in [SubtitleDisplayMode.translationOnly, .bilingual, .translationOnly] {
            controller.selectSubtitleDisplayMode(mode)
            precondition(controller.subtitleDisplayMode == mode)
            precondition(SubtitleDisplayMode.load() == mode)
            precondition(controller.store.segments == records && controller.store.paragraphs == paragraphs)
            precondition(controller.store.activeSessionID == session && controller.store.activeGeneration == generation)
            precondition(controller.store.contentRevision == revision)
            precondition(controller.store.exportText == text && controller.store.exportMarkdown == markdown)
            precondition(controller.phase == phase && controller.status == status)
            precondition(controller.direction == direction && controller.audioSource == audioSource)
            precondition(!controller.overlayVisible && !controller.adjustingOverlay && !controller.transitioning)
        }
        print("Actual AppController selector: session, generation, records, revision, exports, phase, status, audio source, direction, and hidden overlay preserved")
        try render(controller, mode: .bilingual, width: 1080, height: 720, dark: false, name: "bilingual-1080.png")
        try render(controller, mode: .bilingual, width: 820, height: 560, dark: false, name: "bilingual-820.png")
        try render(controller, mode: .translationOnly, width: 1440, height: 800, dark: false, name: "translation-wide.png")
        try render(controller, mode: .bilingual, width: 1080, height: 720, dark: true, name: "bilingual-dark.png")
        try render(AppController(), mode: .bilingual, width: 1080, height: 720, dark: false, name: "empty-1080.png")
        try render(AppController(), mode: .bilingual, width: 1080, height: 720, dark: true, name: "empty-dark.png")
    }

    @MainActor static func render(_ controller: AppController, mode: SubtitleDisplayMode, width: CGFloat, height: CGFloat, dark: Bool, name: String) throws {
        controller.selectSubtitleDisplayMode(mode)
        try capture(TranscriptView(controller: controller), width: width, height: height, dark: dark, name: name)
    }

    /// Renders a real titled window, including the SwiftUI toolbar, without putting it on screen.
    @MainActor static func capture<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, dark: Bool, name: String, title: String = "LiveSub") throws {
        let view = NSHostingView(rootView: content.frame(width: width, height: height).environment(\.controlActiveState, .key))
        view.sceneBridgingOptions = [.toolbars]
        let window = ActiveAppearanceWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = title
        window.toolbarStyle = .unified
        window.titleVisibility = title == "LiveSub" ? .hidden : .visible
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.setContentSize(NSSize(width: width, height: height))
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { fatalError("No bitmap") }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        window.orderOut(nil)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        let path = FileManager.default.currentDirectoryPath + "/design/previews/" + name
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: path))
        print("Production SwiftUI render (synthetic transcript or in-memory settings fixture): " + path)
    }
}

/// Draws controls with their key-window appearance so previews match the window a user is working in.
private final class ActiveAppearanceWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
