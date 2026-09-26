import SwiftUI
import LiveSubSubtitles

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
}

struct OverlayView: View {
    @ObservedObject var presentation: OverlayPresentation
    let onMove: (CGSize) -> Void
    let onMoveEnd: () -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if presentation.isAdjusting {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    }
                    .contentShape(Rectangle())
                    .gesture(moveGesture)
            }

            VStack(spacing: 7) {
                if let source = presentation.caption?.sourceForDisplay(in: presentation.displayMode) {
                    Text(source)
                        .font(.system(size: 24, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityLabel("Original subtitle")
                }

                let target = presentation.caption?.targetForDisplay(in: presentation.displayMode)
                Text(target ?? (presentation.isAdjusting ? "字幕位置预览" : " "))
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .opacity(target == nil && !presentation.isAdjusting ? 0 : 1)
                    .accessibilityLabel("Translated subtitle")
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.98), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
            .padding(.horizontal, 25)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(presentation.textOpacity)
            .allowsHitTesting(false)

            if presentation.isAdjusting {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
                    .padding(6)
                    .help("Drag to change subtitle width")
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { onResize($0.translation.width) }
                            .onEnded { _ in onResizeEnd() }
                    )
            }
        }
        .background(Color.clear)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { onMove($0.translation) }
            .onEnded { _ in onMoveEnd() }
    }
}
