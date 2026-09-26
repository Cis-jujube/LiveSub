import AppKit
import SwiftUI
import LiveSubSubtitles

@main
struct LiveSubApp: App {
    @NSApplicationDelegateAdaptor(LiveSubApplicationDelegate.self) private var delegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup("LiveSub", id: "main") {
            TranscriptView(controller: controller)
                .onAppear { delegate.controller = controller }
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            LiveSubMenu(controller: controller)
                .onAppear { delegate.controller = controller }
        } label: {
            Label("LiveSub", systemImage: "captions.bubble")
        }

        Settings {
            ScrollView {
                LiveSubSettings(controller: controller)
                    .padding(24)
            }
            .frame(width: 660, height: 680)
        }
    }
}

@MainActor
final class LiveSubApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var controller: AppController?
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        if terminationPending { return .terminateLater }
        terminationPending = true
        Task {
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct LiveSubMenu: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.status)
        Divider()
        Button("显示主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if controller.canStart {
            Button("开始识别") { Task { await controller.start() } }
        } else if controller.canPause {
            Button("暂停识别") { Task { await controller.pause() } }
        } else if controller.canResume {
            Button("继续识别") { Task { await controller.resume() } }
        }
        Button("停止识别") { Task { await controller.stop() } }
            .disabled(!controller.canStop)
        Divider()
        Button(controller.overlayVisible ? "隐藏悬浮字幕" : "显示悬浮字幕") {
            controller.toggleOverlay()
        }
        Button(controller.adjustingOverlay ? "完成调整并锁定" : "调整字幕位置") {
            controller.togglePositionAdjustment()
        }
        Picker("字幕显示", selection: Binding(
            get: { controller.subtitleDisplayMode },
            set: { controller.selectSubtitleDisplayMode($0) }
        )) {
            ForEach(SubtitleDisplayMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        Button("重置字幕位置") { controller.resetOverlayPosition() }
        Divider()
        Button("设置…") { openSettings() }
        Button("退出 LiveSub") { NSApp.terminate(nil) }
    }
}

private struct LiveSubSettings: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LiveSub 设置")
                .font(.system(size: 22, weight: .semibold))
            Text("识别与翻译均在本机运行。原始音频和当前字幕默认不写入磁盘；只有手动导出才保存字幕。")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("语音识别", value: "Confucius4-R2T2 · 本地 Metal")
            LabeledContent("翻译", value: "Qwen3-4B-Instruct · 本地 MLX")
            LabeledContent("当前状态", value: controller.status)
            Divider()
            TerminologySettingsView()
            Divider()
            Text("权限")
                .font(.headline)
            Text("麦克风输入需要麦克风权限；系统音频输入需要 macOS 的屏幕与系统音频录制权限。授权或拒绝后，可能需要重新打开 App。")
                .fixedSize(horizontal: false, vertical: true)
            Button("打开系统设置") { controller.openSystemSettings() }
        }
        .font(.system(size: 13))
    }
}
