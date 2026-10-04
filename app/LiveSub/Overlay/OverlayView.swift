import AppKit
import SwiftUI
import LiveSubSubtitles

public enum OverlayTypography {
    public static let preferenceKey = "livesub.overlayFontSize"
    /// Opt-in dark backdrop behind the caption text; the default overlay stays fully transparent.
    public static let backdropPreferenceKey = "livesub.overlayBackdrop"
    public static let defaultSize: CGFloat = 28
    public static let minimumSize: CGFloat = 18
    public static let maximumSize: CGFloat = 40

    public static func bounded(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return defaultSize }
        return min(max(size, minimumSize), maximumSize)
    }

    public static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: preferenceKey) != nil else { return defaultSize }
        return bounded(CGFloat(defaults.double(forKey: preferenceKey)))
    }

    public static func panelHeight(for mode: SubtitleDisplayMode, fontSize: CGFloat) -> CGFloat {
        let size = bounded(fontSize)
        let growth: CGFloat = mode == .bilingual ? 5 : 3
        return max(mode == .bilingual ? 130 : 80, mode.overlayHeight + (size - defaultSize) * growth)
    }
}

public struct OverlayCaption: Equatable, Sendable {
    public let sourceText: String
    public let translatedSourceText: String?
    public let targetText: String?

    public let translationState: TranslationState

    public init(sourceText: String, translatedSourceText: String? = nil, targetText: String? = nil, translationState: TranslationState = .pending) {
        self.sourceText = sourceText
        self.translatedSourceText = translatedSourceText
        self.targetText = targetText
        self.translationState = translationState
    }

    /// Never put a target under a newer, unpaired source revision.
    public var visibleSourceText: String {
        hasPairedTranslation ? translatedSourceText! : sourceText
    }

    public var visibleTargetText: String? {
        hasPairedTranslation ? targetText : nil
    }

    public func sourceForDisplay(in mode: SubtitleDisplayMode) -> String? {
        mode.sourceForDisplay(visibleSourceText)
    }

    public func targetForDisplay(in mode: SubtitleDisplayMode) -> String? {
        if translationState == .failed { return "翻译失败" }
        if let visibleTargetText { return visibleTargetText }
        return mode == .translationOnly ? "翻译中…" : nil
    }

    private var hasPairedTranslation: Bool {
        translatedSourceText?.isEmpty == false && targetText?.isEmpty == false
    }
}

@MainActor
final class OverlayPresentation: ObservableObject {
    @Published var displayMode: SubtitleDisplayMode = .bilingual
    @Published var caption: OverlayCaption?
    @Published var textOpacity = 1.0
    @Published var isAdjusting = false
    @Published var fontSize = OverlayTypography.defaultSize
    @Published var showsBackdrop = false
}

struct OverlayView: View {
    @ObservedObject var presentation: OverlayPresentation
    let onMove: (CGSize) -> Void
    let onMoveEnd: () -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    let onDone: () -> Void

    private var sourceSize: CGFloat { presentation.fontSize * 0.84 }
    private var backdropVisible: Bool {
        presentation.showsBackdrop && !presentation.isAdjusting && presentation.caption != nil
    }

    var body: some View {
        GeometryReader { geometry in
            content(textWidth: max(1, geometry.size.width - 50))
        }
    }

    private func content(textWidth: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if presentation.isAdjusting {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.42))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                    .contentShape(Rectangle())
                    .gesture(moveGesture)
                    .pointerStyle(.grabIdle)
            }

            VStack(spacing: 6) {
                if let source = presentation.caption?.sourceForDisplay(in: presentation.displayMode) {
                    Text(OverlayTextWindow.latestLines(
                        source, width: textWidth,
                        font: .systemFont(ofSize: sourceSize, weight: .medium)
                    ))
                        .font(.system(size: sourceSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .accessibilityLabel("Original subtitle")
                        .accessibilityValue(source)
                }

                let target = presentation.caption?.targetForDisplay(in: presentation.displayMode)
                Text(OverlayTextWindow.latestLines(
                    target ?? (presentation.isAdjusting ? "字幕位置预览" : " "),
                    width: textWidth,
                    font: .systemFont(ofSize: presentation.fontSize, weight: .semibold)
                ))
                    .font(.system(size: presentation.fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .opacity(target == nil && !presentation.isAdjusting ? 0 : 1)
                    .accessibilityLabel("Translated subtitle")
                    .accessibilityValue(target ?? "")
            }
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.98), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
            .padding(.horizontal, backdropVisible ? 16 : 0)
            .padding(.vertical, backdropVisible ? 8 : 0)
            .background {
                if backdropVisible {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.58))
                }
            }
            .padding(.horizontal, backdropVisible ? 9 : 25)
            .padding(.top, presentation.isAdjusting ? 26 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(presentation.textOpacity)
            .allowsHitTesting(false)

            if presentation.isAdjusting {
                adjustmentChrome
            }
        }
        .background(Color.clear)
    }

    private var adjustmentChrome: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(alignment: .center) {
                Text("拖动移动 · 拖动右下角改宽度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule(style: .circular))
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                Button(action: onDone) {
                    Text("完成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(.white, in: Capsule(style: .circular))
                }
                .buttonStyle(.plain)
                .help("完成调整并恢复鼠标穿透")
                .accessibilityLabel("完成调整")
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(.white, in: Circle())
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                .padding(6)
                .contentShape(Circle())
                .help("拖动以调整字幕宽度")
                .accessibilityLabel("调整字幕宽度")
                .pointerStyle(.frameResize(position: .trailing))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { onResize($0.translation.width) }
                        .onEnded { _ in onResizeEnd() }
                )
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { onMove($0.translation) }
            .onEnded { _ in onMoveEnd() }
    }
}
