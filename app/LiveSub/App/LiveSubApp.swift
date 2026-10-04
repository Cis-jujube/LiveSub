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
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra {
            LiveSubMenu(controller: controller)
                .onAppear { delegate.controller = controller }
        } label: {
            Image(systemName: controller.phase == "listening" ? "captions.bubble.fill" : "captions.bubble")
                .accessibilityLabel("LiveSub")
        }

        Settings {
            LiveSubSettings(controller: controller)
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
        Button(controller.adjustingOverlay ? "完成调整并锁定" : "调整字幕位置与宽度") {
            controller.togglePositionAdjustment()
        }
        Menu("悬浮字幕字号 · \(Int(controller.overlayFontSize)) pt") {
            Button("缩小") { controller.setOverlayFontSize(controller.overlayFontSize - 2) }
                .disabled(controller.overlayFontSize <= 18)
            Button("放大") { controller.setOverlayFontSize(controller.overlayFontSize + 2) }
                .disabled(controller.overlayFontSize >= 40)
            Divider()
            Button("恢复默认字号") { controller.resetOverlayFontSize() }
        }
        Toggle("字幕底板", isOn: Binding(
            get: { controller.overlayBackdrop },
            set: { controller.setOverlayBackdrop($0) }
        ))
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

@MainActor
struct LiveSubSettings: View {
    @ObservedObject var controller: AppController
    // Owned outside the TabView so the draft survives switching tabs.
    @StateObject private var terminologyEditor: TerminologyEditor

    init(controller: AppController, terminologyEditor: TerminologyEditor = TerminologyEditor()) {
        self.controller = controller
        _terminologyEditor = StateObject(wrappedValue: terminologyEditor)
    }

    var body: some View {
        TabView {
            TerminologySettingsView(editor: terminologyEditor)
                .frame(width: 680, height: 600)
                .tabItem { Label("翻译与术语", systemImage: "character.book.closed") }
            LocalRuntimeSettingsView(controller: controller)
                .frame(width: 680, height: 430)
                .tabItem { Label("权限与本地运行", systemImage: "lock.shield") }
        }
        .font(.system(size: 13))
    }
}

@MainActor
struct LocalRuntimeSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section {
                LabeledContent("语音识别", value: "Qwen3-ASR-1.7B · 本地 MPS")
                LabeledContent("翻译") {
                    Text(translationRuntimeDescription)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("当前状态") {
                    Text(controller.status)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("本地运行")
            } footer: {
                Text("识别与翻译均在本机运行。原始音频和当前字幕默认不写入磁盘；只有手动导出才保存字幕。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            Section {
                LabeledContent {
                    Button("打开系统设置") { controller.openSystemSettings() }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("麦克风与系统音频")
                        Text("麦克风输入需要麦克风权限；系统音频输入需要 macOS 的屏幕与系统音频录制权限。授权或拒绝后，可能需要重新打开 App。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("权限")
            }
        }
        .formStyle(.grouped)
    }

    private var translationRuntimeDescription: String {
        if #available(macOS 26.4, *), let resources = Bundle.main.resourceURL,
           FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("LiveSubNativeTranslation").path) {
            return "系统离线翻译可用时英译中优先 · Qwen 本地备用"
        }
        return "Qwen3-4B-Instruct · 本地 MLX"
    }
}
