import AppKit
import LiveSubAudio
import LiveSubSubtitles
import SwiftUI

struct TranscriptView: View {
    @ObservedObject private var controller: AppController
    @ObservedObject private var store: SubtitleStore
    @ObservedObject private var setup: RuntimeSetup
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewState = TranscriptViewState()

    private static let bottomID = "transcript-bottom"

    init(controller: AppController) {
        _controller = ObservedObject(wrappedValue: controller)
        _store = ObservedObject(wrappedValue: controller.store)
        _setup = ObservedObject(wrappedValue: controller.setup)
    }

    var body: some View {
        Group {
            if setup.isReady {
                readingSurface
            } else {
                RuntimeSetupView(setup: setup)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.paper)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(Theme.accent)
        .modifier(MainToolbar(enabled: setup.isReady, leading: { leadingToolbar }, trailing: { trailingToolbar }, session: { sessionToolbar }))
    }

    private var readingSurface: some View {
        GeometryReader { geometry in
            let layout = ReadingLayout(
                width: geometry.size.width,
                showsSource: controller.subtitleDisplayMode.showsSource,
                sourceFraction: viewState.sourceFraction
            )
            VStack(spacing: 0) {
                notices(layout)
                columnHeader(layout)
                transcript(layout, height: geometry.size.height)
            }
        }
    }

    // MARK: Toolbar

    private var leadingToolbar: some View {
        HStack(spacing: 6) {
            SessionStatusPill(controller: controller, meter: controller.inputLevel)
            Menu {
                Picker("音源", selection: Binding(
                    get: { controller.audioSource },
                    set: { controller.selectAudioSource($0) }
                )) {
                    Label("麦克风", systemImage: "mic").tag(AudioSource.microphone)
                    Label("系统音频", systemImage: "speaker.wave.2").tag(AudioSource.systemAudio)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(
                    controller.audioSource == .microphone ? "麦克风" : "系统音频",
                    systemImage: controller.audioSource == .microphone ? "mic" : "speaker.wave.2"
                )
                .labelStyle(.titleAndIcon)
            }
            .disabled(configurationDisabled)
            .help("音源")
        }
    }

    @ViewBuilder private var trailingToolbar: some View {
        Toggle(isOn: Binding(
            get: { controller.overlayVisible },
            set: { _ in controller.toggleOverlay() }
        )) {
            Label("悬浮字幕", systemImage: "captions.bubble")
                .labelStyle(.titleAndIcon)
        }
        .toggleStyle(.button)
        .help(controller.overlayVisible ? "隐藏悬浮字幕" : "显示悬浮字幕")

        Button { viewState.showOverlayControls.toggle() } label: {
            Label("字幕外观", systemImage: "textformat.size")
        }
        .help("字幕外观")
        .popover(isPresented: $viewState.showOverlayControls, arrowEdge: .bottom) { overlayControls }

        Button { viewState.showSpeakerControls.toggle() } label: {
            Label(speakerButtonTitle, systemImage: controller.speakerDetectionEnabled ? "person.2.wave.2.fill" : "person.2.wave.2")
        }
        .help(speakerButtonTitle)
        .popover(isPresented: $viewState.showSpeakerControls, arrowEdge: .bottom) { speakerControls }

        Menu {
            Button("复制全部") { copyAll() }
            Divider()
            Button("导出纯文本 · TXT") { export(markdown: false) }
            Button("导出 Markdown · MD") { export(markdown: true) }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .disabled(store.segments.isEmpty)
        .help("复制或导出完整双语字幕")

        Button { openSettings() } label: {
            Label("设置", systemImage: "gearshape")
        }
        .help("设置")
    }

    @ViewBuilder private var sessionToolbar: some View {
        if controller.phase != "idle" {
            Button { Task { await controller.stop() } } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .disabled(!controller.canStop)
            .keyboardShortcut(".", modifiers: [.command])
            .help("停止识别（⌘.）")
        }

        sessionAction
    }

    @ViewBuilder private var sessionAction: some View {
        if controller.phase == "paused" {
            Button { Task { await controller.resume() } } label: {
                Label("继续", systemImage: "play.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canResume)
            .keyboardShortcut("r", modifiers: [.command])
            .help("继续识别（⌘R）")
        } else if controller.phase == "listening" || controller.phase == "loading" {
            Button { Task { await controller.pause() } } label: {
                Label("暂停", systemImage: "pause.fill").labelStyle(.titleAndIcon)
            }
            .disabled(!controller.canPause)
            .keyboardShortcut("r", modifiers: [.command])
            .help("暂停识别（⌘R）")
        } else {
            Button { Task { await controller.start() } } label: {
                Label("开始", systemImage: "waveform").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canStart)
            .keyboardShortcut("r", modifiers: [.command])
            .help("开始识别（⌘R）")
        }
    }

    private var speakerButtonTitle: String {
        guard controller.speakerDetectionEnabled else { return "检测说话人" }
        return "说话人 · " + (controller.selectedSpeakerIDs.map { "已选 \($0.count) 位" } ?? "全部")
    }

    // MARK: Reading surface

    @ViewBuilder private func notices(_ layout: ReadingLayout) -> some View {
        if let error = controller.errorMessage {
            NoticeBanner(systemImage: "exclamationmark.triangle.fill", tint: Theme.caution, text: error) {
                if controller.permissionError {
                    Button("打开系统设置") { controller.openSystemSettings() }
                }
            }
            .frame(width: layout.contentWidth)
            .padding(.top, 14)
        } else if let notice = controller.inputNotice {
            NoticeBanner(systemImage: "waveform.badge.exclamationmark", tint: .secondary, text: notice) {
                EmptyView()
            }
            .frame(width: layout.contentWidth)
            .padding(.top, 14)
        }
    }

    private func columnHeader(_ layout: ReadingLayout) -> some View {
        HStack(spacing: 0) {
            if layout.showsSource {
                ColumnLabel(language: controller.direction.sourceLabel, role: "原文", mark: .primary)
                    .frame(width: layout.sourceWidth, alignment: .leading)
                SpineSwapButton(direction: controller.direction, disabled: configurationDisabled) {
                    swapDirection()
                }
                .frame(width: ReadingLayout.gutter)
                .accessibilitySortPriority(-1)
                ColumnLabel(language: controller.direction.targetLabel, role: "译文", mark: Theme.accent)
            } else {
                ColumnLabel(language: controller.direction.targetLabel, role: "", mark: Theme.accent)
                Text("译自 \(controller.direction.sourceLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                SpineSwapButton(direction: controller.direction, disabled: configurationDisabled) {
                    swapDirection()
                }
                .padding(.leading, 8)
            }
            Spacer(minLength: 12)
            Picker("字幕显示", selection: Binding(
                get: { controller.subtitleDisplayMode },
                set: { controller.selectSubtitleDisplayMode($0) }
            )) {
                ForEach(SubtitleDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 128)
            .help("主窗口与悬浮字幕同步切换；导出仍保留双语")
        }
        .frame(width: layout.contentWidth, height: 30)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .topLeading) {
            if layout.showsSource && !store.segments.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.top, 18 + 15)
                    .offset(x: layout.spineX - 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(width: layout.contentWidth, height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            guard layout.showsSource else { return }
            switch direction {
            case .increment: viewState.sourceFraction = min(0.72, viewState.sourceFraction + 0.05)
            case .decrement: viewState.sourceFraction = max(0.28, viewState.sourceFraction - 0.05)
            @unknown default: break
            }
        }
    }

    private func transcript(_ layout: ReadingLayout, height: CGFloat) -> some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.segments.isEmpty {
                        emptyState
                            .frame(width: layout.contentWidth)
                            .frame(minHeight: max(320, height - 150))
                    } else {
                        let lastID = store.paragraphs.last?.id
                        ForEach(store.paragraphs) { paragraph in
                            row(paragraph, layout: layout, isLive: controller.phase == "listening" && paragraph.id == lastID)
                                .id(paragraph.id)
                        }
                    }
                    Color.clear.frame(height: 88).id(Self.bottomID)
                }
                .frame(width: layout.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(alignment: .topLeading) {
                if layout.showsSource && !store.segments.isEmpty {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .offset(x: layout.spineX - 0.5)
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { viewState.followLive = false }
            }
            .onChange(of: store.contentRevision) { _, _ in
                guard viewState.followLive else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard viewState.followLive else { return }
                    scroll.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if let toast = viewState.toast {
                        Text(toast)
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule(style: .circular))
                            .overlay(Capsule(style: .circular).strokeBorder(Theme.hairline))
                            .transition(.opacity)
                    }
                    if !viewState.followLive && !store.segments.isEmpty {
                        Button {
                            viewState.followLive = true
                            if reduceMotion {
                                scroll.scrollTo(Self.bottomID, anchor: .bottom)
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scroll.scrollTo(Self.bottomID, anchor: .bottom)
                                }
                            }
                        } label: {
                            Label("回到实时", systemImage: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    }
                }
                .padding(.bottom, 22)
            }
        }
    }

    private func row(_ paragraph: TranscriptParagraph, layout: ReadingLayout, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let speakerID = paragraph.speakerID {
                HStack(spacing: 6) {
                    Circle().fill(Theme.speakerColor(speakerID)).frame(width: 7, height: 7)
                    Text("说话人 \(speakerID)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                if let source = controller.subtitleDisplayMode.sourceForDisplay(paragraph.sourceText) {
                    Text(source)
                        .font(.system(size: 15.5))
                        .foregroundStyle(Theme.sourceInk)
                        .lineSpacing(6.5)
                        .textSelection(.enabled)
                        .frame(width: layout.sourceWidth, alignment: .leading)
                    columnResizeHandle(layout)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.styledTarget(paragraph.targetForDisplay(in: controller.subtitleDisplayMode)))
                        .font(.system(size: layout.showsSource ? 18 : 19))
                        .lineSpacing(8)
                        .textSelection(.enabled)
                    if paragraph.failedCount > 0 {
                        Label("部分翻译失败 · 原文已保留", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.caution)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 22)
        .background(alignment: .leading) {
            if isLive {
                Capsule(style: .circular)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 24)
                    .offset(x: -20)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                if layout.showsSource {
                    Rectangle().fill(Theme.hairline).frame(width: layout.sourceWidth, height: 1)
                    Color.clear.frame(width: ReadingLayout.gutter, height: 1)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The gutter of every row doubles as the column divider's drag area.
    private func columnResizeHandle(_ layout: ReadingLayout) -> some View {
        Color.clear
            .frame(width: ReadingLayout.gutter)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = viewState.dragStartFraction ?? viewState.sourceFraction
                        viewState.dragStartFraction = start
                        let candidate = start + value.translation.width / max(1, layout.columnsWidth)
                        viewState.sourceFraction = min(0.72, max(0.28, candidate))
                    }
                    .onEnded { _ in viewState.dragStartFraction = nil }
            )
            .help("拖动以调整两栏宽度")
            .accessibilityHidden(true)
    }

    /// Restyles the paragraph's inline placeholders; consecutive placeholders collapse into one quiet note.
    static func styledTarget(_ raw: String) -> AttributedString {
        enum Token { case text(Substring), marker(String) }
        var tokens: [Token] = []
        var rest = Substring(raw)
        while !rest.isEmpty {
            let next = TranscriptParagraph.Marker.all
                .compactMap { marker in rest.range(of: marker).map { ($0, marker) } }
                .min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, marker) = next else {
                tokens.append(.text(rest))
                break
            }
            if range.lowerBound > rest.startIndex { tokens.append(.text(rest[..<range.lowerBound])) }
            tokens.append(.marker(marker))
            rest = rest[range.upperBound...]
        }

        var result = AttributedString()
        var index = 0
        while index < tokens.count {
            guard case .marker = tokens[index] else {
                if case .text(let text) = tokens[index] { result += AttributedString(text) }
                index += 1
                continue
            }
            var markers: [String] = []
            while index < tokens.count {
                if case .marker(let marker) = tokens[index] {
                    markers.append(marker)
                    index += 1
                } else if case .text(let text) = tokens[index], text.allSatisfy(\.isWhitespace),
                          index + 1 < tokens.count, case .marker = tokens[index + 1] {
                    index += 1
                } else {
                    break
                }
            }
            typealias M = TranscriptParagraph.Marker
            var notes: [(String, Color)] = []
            if markers.contains(M.unselected) { notes.append(("未选中 · 未翻译", .secondary)) }
            if markers.contains(M.previousVersion) {
                notes.append(("上一版译文 · 更新中…", .secondary))
            } else if markers.contains(M.pending) || markers.contains(M.updating) {
                notes.append(("翻译中…", .secondary))
            }
            if markers.contains(M.failed) { notes.append(("翻译失败", Theme.caution)) }
            for (offset, note) in notes.enumerated() {
                var run = AttributedString((offset > 0 ? " · " : "") + note.0)
                run.font = .system(size: 14)
                run.foregroundColor = note.1
                result += run
            }
        }
        return result
    }

    // MARK: Empty state

    private var emptyCopy: (title: String, detail: String) {
        switch controller.phase {
        case "loading":
            return ("正在准备本地模型。", "准备完成后，听到的语音会显示在这里。")
        case "listening":
            return ("等待声音。", "听到语音后，字幕会在这里连续呈现。")
        case "paused":
            return ("识别已暂停。", "点击「继续」，接着听取新的语音。")
        case "stopping":
            return ("正在结束本次识别。", "请稍候，完成后可开始新的会话。")
        case "error":
            return ("识别暂时无法继续。", "请查看上方的错误提示，处理后重新开始。")
        default:
            return (controller.subtitleDisplayMode.showsSource ? "字幕会显示在这里" : "译文会显示在这里", "选择音源与翻译方向，点击「开始」。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            EclipseMark(live: controller.phase == "listening")
                .frame(width: 96, height: 96)
                .padding(.bottom, 20)
            Text(emptyCopy.title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 8)
            Text(emptyCopy.detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            emptyStateAccessory
                .frame(minHeight: 44)
                .padding(.top, 24)
            Label("首次使用需授权音频访问。原始音频默认不保存，字幕仅保留于本次会话。", systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 34)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var emptyStateAccessory: some View {
        switch controller.phase {
        case "loading", "stopping":
            ProgressView().controlSize(.small)
        case "listening":
            InputLevelBars(meter: controller.inputLevel, barWidth: 4, maxHeight: 26)
        case "paused":
            Button { Task { await controller.resume() } } label: {
                Label("继续", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!controller.canResume)
        default:
            VStack(spacing: 10) {
                Button { Task { await controller.start() } } label: {
                    Label("开始", systemImage: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!controller.canStart)
                Text("⌘R")
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Popovers

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("悬浮字幕")
                    .font(.system(size: 15, weight: .semibold))
                Text("字号与位置只影响屏幕上的悬浮字幕。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号")
                    Spacer()
                    Text("\(Int(controller.overlayFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                Slider(value: Binding(
                    get: { Double(controller.overlayFontSize) },
                    set: { controller.setOverlayFontSize(CGFloat($0)) }
                ), in: 18...40, step: 1) {
                    Text("悬浮字幕字号")
                } minimumValueLabel: {
                    Text("A").font(.system(size: 11))
                } maximumValueLabel: {
                    Text("A").font(.system(size: 17))
                }
                .labelsHidden()
                .accessibilityLabel("悬浮字幕字号")
            }
            Toggle(isOn: Binding(
                get: { controller.overlayBackdrop },
                set: { controller.setOverlayBackdrop($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("字幕底板").font(.system(size: 13))
                    Text("在明亮画面上更易读；默认透明。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            HStack {
                Button(controller.adjustingOverlay ? "完成调整" : "调整位置与宽度") {
                    controller.togglePositionAdjustment()
                }
                Spacer()
                Menu("恢复默认") {
                    Button("恢复默认位置") { controller.resetOverlayPosition() }
                    Button("恢复默认字号") { controller.resetOverlayFontSize() }
                }
                .fixedSize()
            }
            Text("调整时拖动字幕区域移动，拖动右下角改变宽度，点「完成」恢复鼠标穿透。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 316)
    }

    private var speakerControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("检测说话人")
                    .font(.system(size: 15, weight: .semibold))
                Text("最多识别 5 位，建议先选 1–2 位。可多选；仅翻译所选说话人后续说的话。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(controller.speakerModelLoading ? "正在准备本地模型…" :
                   (controller.speakerDetectionEnabled ? "停止检测" : "开始检测")) {
                Task { await controller.setSpeakerDetectionEnabled(!controller.speakerDetectionEnabled) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.speakerModelLoading || configurationDisabled)
            Text("检测说话人首次等待约 2 秒，之后每 0.8 秒更新，另需模型处理时间。追求更低延迟可停止检测；切换会结束当前识别片段。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button {
                controller.selectSpeakers(nil)
            } label: {
                Label("翻译所有人", systemImage: controller.selectedSpeakerIDs == nil ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(controller.selectedSpeakerIDs == nil ? .isSelected : [])
            if controller.detectedSpeakerIDs.isEmpty {
                Text(controller.speakerDetectionEnabled && controller.phase == "listening"
                     ? "正在等待可辨认的说话人…" : "开始检测并说话后，列表会出现在这里。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.detectedSpeakerIDs, id: \.self) { speakerID in
                    let speaker = store.speakerSummaries.first { $0.id == speakerID }
                    Toggle(isOn: Binding(
                        get: { controller.selectedSpeakerIDs?.contains(speakerID) ?? false },
                        set: { _ in controller.toggleSpeaker(speakerID) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.speakerColor(speakerID)).frame(width: 7, height: 7)
                                Text("说话人 \(speakerID)\(speaker?.isSpeaking == true ? " · 正在讲话" : "")")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            Text(speaker?.recentText ?? "等待识别到这一位的发言")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: Actions

    private var configurationDisabled: Bool {
        controller.transitioning || controller.phase == "loading" || controller.phase == "stopping"
    }

    private func swapDirection() {
        controller.selectDirection(controller.direction == .englishToChinese ? .chineseToEnglish : .englishToChinese)
    }

    private func copyAll() {
        controller.copyTranscript()
        viewState.show(toast: "已复制全部字幕", reduceMotion: reduceMotion)
    }

    private func export(markdown: Bool) {
        if controller.exportTranscript(markdown: markdown) {
            viewState.show(toast: markdown ? "已导出 Markdown" : "已导出纯文本", reduceMotion: reduceMotion)
        }
    }
}

// MARK: - Layout

private struct ReadingLayout {
    static let gutter: CGFloat = 56

    let width: CGFloat
    let showsSource: Bool
    let sourceFraction: CGFloat

    var margin: CGFloat { width < 960 ? 32 : 48 }
    /// Bilingual reading stops widening at a comfortable spread; translation-only keeps a single-column measure.
    var contentWidth: CGFloat { max(320, min(width - margin * 2, showsSource ? 1_240 : 720)) }
    var columnsWidth: CGFloat { contentWidth - Self.gutter }
    var sourceWidth: CGFloat { (columnsWidth * sourceFraction).rounded() }
    var spineX: CGFloat { (width - contentWidth) / 2 + sourceWidth + Self.gutter / 2 }
}

private struct MainToolbar<Leading: View, Trailing: View, Session: View>: ViewModifier {
    /// The first-launch setup screen has no toolbar; its only action is in the content.
    let enabled: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let session: () -> Session

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(macOS 26.0, *) {
            content.toolbar {
                ToolbarItem(placement: .navigation) { leading() }
                ToolbarSpacer(.flexible)
                ToolbarItemGroup(placement: .primaryAction) { trailing() }
                ToolbarSpacer(.fixed)
                ToolbarItemGroup(placement: .primaryAction) { session() }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) { leading() }
                ToolbarItemGroup(placement: .primaryAction) {
                    trailing()
                    Divider()
                    session()
                }
            }
        }
    }
}

// MARK: - Components

private struct SessionStatusPill: View {
    @ObservedObject var controller: AppController
    let meter: InputLevelMeter

    var body: some View {
        HStack(spacing: 7) {
            indicator.frame(width: 16, height: 14)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(controller.phase == "error" ? Theme.caution : .primary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .help(controller.status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("状态")
        .accessibilityValue(controller.status)
    }

    private var title: String {
        if controller.speakerModelLoading { return "准备说话人模型" }
        switch controller.phase {
        case "loading": return "准备中"
        case "listening": return "聆听中"
        case "paused": return "已暂停"
        case "stopping": return "正在收尾"
        case "error": return "需要处理"
        default: return "就绪"
        }
    }

    @ViewBuilder private var indicator: some View {
        if controller.speakerModelLoading || controller.phase == "loading" || controller.phase == "stopping" {
            ProgressView().controlSize(.mini)
        } else {
            switch controller.phase {
            case "listening":
                InputLevelBars(meter: meter, barWidth: 2.5, maxHeight: 13)
            case "paused":
                Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            case "error":
                Circle().fill(Theme.caution).frame(width: 7, height: 7)
            default:
                Circle().strokeBorder(.secondary, lineWidth: 1.2).frame(width: 7, height: 7)
            }
        }
    }
}

private struct ColumnLabel: View {
    let language: String
    let role: String
    let mark: Color

    var body: some View {
        HStack(spacing: 8) {
            Capsule(style: .circular).fill(mark).frame(width: 14, height: 3)
            Text(language)
                .font(.system(size: 12.5, weight: .semibold))
            if !role.isEmpty {
                Text(role)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct SpineSwapButton: View {
    let direction: TranslationDirection
    let disabled: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()
    private var hovering: Bool { hover.hovering }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering && !disabled ? Theme.accent : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.raised))
                .overlay(Circle().strokeBorder(hovering && !disabled ? Theme.accent.opacity(0.5) : Theme.hairline.opacity(2)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover.hovering = $0 }
        .help("切换翻译方向（当前：\(direction.label)）")
        .accessibilityLabel("切换翻译方向")
        .accessibilityValue(direction.label)
    }
}

private struct NoticeBanner<Action: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            action()
                .buttonStyle(.link)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }
}

@MainActor
private final class HoverState: ObservableObject {
    @Published var hovering = false
}

@MainActor
private final class TranscriptViewState: ObservableObject {
    @Published var sourceFraction: CGFloat = 0.46
    @Published var followLive = true
    @Published var showOverlayControls = false
    @Published var showSpeakerControls = false
    @Published var toast: String?
    var dragStartFraction: CGFloat?
    private var toastTask: Task<Void, Never>?

    func show(toast message: String, reduceMotion: Bool) {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) { self?.toast = nil }
        }
    }
}
