import AppKit
import LiveSubAudio
import LiveSubSubtitles
import SwiftUI

struct TranscriptView: View {
    @ObservedObject private var controller: AppController
    @ObservedObject private var store: SubtitleStore
    @StateObject private var viewState = TranscriptViewState()

    init(controller: AppController) {
        _controller = ObservedObject(wrappedValue: controller)
        _store = ObservedObject(wrappedValue: controller.store)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)

            GeometryReader { geometry in
                let availableWidth = max(500, geometry.size.width - 48)
                VStack(spacing: 0) {
                    columnHeader(availableWidth)
                    Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
                    ScrollViewReader { scroll in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                if store.segments.isEmpty {
                                    emptyState
                                        .frame(maxWidth: .infinity, minHeight: max(260, geometry.size.height - 130))
                                } else {
                                    ForEach(store.segments) { segment in
                                        transcriptRow(segment, width: availableWidth)
                                            .id(segment.id)
                                        Rectangle().fill(.primary.opacity(0.07))
                                            .frame(height: 1)
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                        .onScrollPhaseChange { _, phase in
                            if phase == .interacting { viewState.followLive = false }
                        }
                        .onChange(of: store.segments.last?.sequence) { _, _ in
                            guard viewState.followLive, let id = store.segments.last?.id else { return }
                            scroll.scrollTo(id, anchor: .bottom)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !viewState.followLive && !store.segments.isEmpty {
                                Button("回到实时") {
                                    viewState.followLive = true
                                    if let id = store.segments.last?.id {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            scroll.scrollTo(id, anchor: .bottom)
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(22)
                            }
                        }
                    }
                }
            }

            if let error = controller.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error).frame(maxWidth: .infinity, alignment: .leading)
                    Button("打开系统设置") { controller.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))
            }
            footer
        }
        .frame(minWidth: 790, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LiveSub")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("本地实时双语字幕")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(controller.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(controller.phase == "error" ? .orange : .secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Picker("音源", selection: Binding(
                    get: { controller.audioSource },
                    set: { controller.selectAudioSource($0) }
                )) {
                    Text("麦克风").tag(AudioSource.microphone)
                    Text("系统音频").tag(AudioSource.systemAudio)
                }
                .frame(width: 175)
                .disabled(controller.transitioning || controller.phase == "loading" || controller.phase == "stopping")

                Picker("方向", selection: Binding(
                    get: { controller.direction },
                    set: { controller.selectDirection($0) }
                )) {
                    ForEach(TranslationDirection.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .frame(width: 235)
                .disabled(controller.transitioning || controller.phase == "loading" || controller.phase == "stopping")

                Spacer(minLength: 10)
                if controller.canStart {
                    Button("开始") { Task { await controller.start() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.space, modifiers: [.command])
                } else if controller.canPause {
                    Button("暂停") { Task { await controller.pause() } }
                        .keyboardShortcut(.space, modifiers: [.command])
                } else if controller.canResume {
                    Button("继续") { Task { await controller.resume() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.space, modifiers: [.command])
                }
                Button("停止") { Task { await controller.stop() } }
                    .disabled(!controller.canStop)

                Button(controller.overlayVisible ? "隐藏悬浮字幕" : "显示悬浮字幕") {
                    controller.toggleOverlay()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func columnHeader(_ width: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("原文")
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.direction.sourceLabel)
                    .foregroundStyle(.secondary)
            }
            .frame(width: max(180, width * viewState.sourceFraction - 10), alignment: .leading)
            .accessibilityLabel("原文栏，可拖动中间分隔线调整宽度")

            Rectangle()
                .fill(.primary.opacity(0.18))
                .frame(width: 2, height: 26)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let candidate = viewState.dragStartFraction + value.translation.width / width
                            viewState.sourceFraction = min(0.72, max(0.28, candidate))
                        }
                        .onEnded { _ in viewState.dragStartFraction = viewState.sourceFraction }
                )
                .help("拖动以调整两栏宽度")

            HStack(spacing: 8) {
                Text("译文")
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.direction.targetLabel)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private func transcriptRow(_ segment: SubtitleSegment, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(segment.sourceText)
                    .font(.system(size: 16, weight: .medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(segment.sourceLanguage.uppercased()) · \(timeLabel(segment.startMs))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: max(180, width * viewState.sourceFraction - 10), alignment: .leading)

            Color.clear.frame(width: 16)

            VStack(alignment: .leading, spacing: 7) {
                if segment.translationState == .failed {
                    Text("翻译失败 · 原文已保留")
                        .foregroundStyle(.orange)
                } else if segment.targetText.isEmpty {
                    Text("翻译中…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(segment.targetText)
                        .textSelection(.enabled)
                    if !segment.translationIsCurrent {
                        Text("原文更新中 · 译文对应前一版本")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 15)
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("开始后，双语字幕会出现在这里")
                .font(.system(size: 17, weight: .medium))
            Text("选择麦克风或系统音频；首次使用时 macOS 会请求相应权限。\n原始音频默认不保存，字幕只保留在本次会话中。")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.phase == "listening" ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text("\(store.segments.count) 个片段 · \(controller.phase == "listening" ? "本地识别中" : controller.status)")
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button("复制全部") { controller.copyTranscript() }
                .disabled(store.segments.isEmpty)
            Menu("导出") {
                Button("纯文本 · TXT") { controller.exportTranscript(markdown: false) }
                Button("Markdown · MD") { controller.exportTranscript(markdown: true) }
            }
            .disabled(store.segments.isEmpty)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func timeLabel(_ ms: UInt64) -> String {
        let seconds = ms / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
private final class TranscriptViewState: ObservableObject {
    @Published var sourceFraction = 0.5
    @Published var followLive = true
    var dragStartFraction = 0.5
}
