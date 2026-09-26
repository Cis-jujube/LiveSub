import CoreGraphics
import Foundation
import LiveSubSubtitles
@testable import LiveSubOverlay

@main
enum OverlayPlacementChecks {
    @MainActor static func main() throws {
        try defaultPlacementUsesVisibleAreaAndWidthCap()
        try disconnectedDisplayRestoresIntoAvailableScreen()
        try malformedSavedPositionIsClamped()
        try placementRoundTripsAfterDragAndResize()
        try newSessionClearsPreviousCaption()
        try translationOnlyProjectionAndPlacement()
        print("OverlayPlacementChecks: 4 geometry checks and caption reset passed")
    }

    @MainActor static func newSessionClearsPreviousCaption() throws {
        let overlay = OverlayWindowController()
        let previous = OverlayCaption(sourceText: "Previous session", translatedSourceText: "Previous session", targetText: "上一会话")
        overlay.update(previous)
        overlay.hide()
        try expect(overlay.caption == previous, "hiding within one session preserves its latest caption")
        overlay.clearCaption()
        try expect(overlay.caption == nil, "new session must not retain the previous session caption")
        try expect(!overlay.isVisible && !overlay.isAdjusting, "reset must not open or unlock the panel")
        let next = OverlayCaption(sourceText: "New session")
        overlay.update(next)
        try expect(overlay.caption == next, "new session accepts fresh captions")
    }

    @MainActor static func translationOnlyProjectionAndPlacement() throws {
        let pending = OverlayCaption(sourceText: "Original must stay hidden")
        try expect(pending.sourceForDisplay(in: .translationOnly) == nil, "translation-only never leaks pending source")
        try expect(pending.targetForDisplay(in: .translationOnly) == "翻译中…", "pending has explicit target placeholder")
        let pair = OverlayCaption(sourceText: "A newer source revision", translatedSourceText: "An earlier source", targetText: "较早译文", translationState: .preview)
        try expect(pair.visibleSourceText == "An earlier source", "bilingual source retains translation pairing")
        try expect(pair.targetForDisplay(in: .translationOnly) == "较早译文", "valid paired preview remains visible while ASR advances")
        let unpaired = OverlayCaption(sourceText: "Source", targetText: "Unpaired target")
        try expect(unpaired.targetForDisplay(in: .translationOnly) == "翻译中…", "unpaired targets must not render")
        let failed = OverlayCaption(sourceText: "Source", translationState: .failed)
        try expect(failed.targetForDisplay(in: .translationOnly) == "翻译失败", "failure is distinct from pending")
        let overlay = OverlayWindowController()
        overlay.update(pair)
        overlay.setDisplayMode(.translationOnly)
        overlay.setDisplayMode(.bilingual)
        try expect(overlay.caption == pair && !overlay.isVisible && !overlay.isAdjusting, "display toggles preserve caption and never open or unlock a hidden panel")
        let display = OverlayDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850))
        let adjusted = CGRect(x: 130, y: 200, width: 820, height: 164)
        let saved = OverlayPlacementGeometry.record(frame: adjusted, on: display)
        let compact = OverlayPlacementGeometry.resolve(saved: saved, screens: [display], preferredDisplayID: 1, height: SubtitleDisplayMode.translationOnly.overlayHeight)!
        try expect(compact.height == 108 && abs(compact.minY - adjusted.minY) < 1 && abs(compact.width - adjusted.width) < 1, "compact mode preserves adjusted bottom and width")
        let restored = try resolved(OverlayPlacementGeometry.record(frame: compact, on: display), screens: [display], preferredDisplayID: 1)
        try expect(abs(restored.height - 164) < 1 && abs(restored.minY - adjusted.minY) < 1, "bilingual height restores at saved bottom anchor")
        print("Translation-only pending, pairing, failure, visibility, and compact placement checks passed")
    }

    static func defaultPlacementUsesVisibleAreaAndWidthCap() throws {
        let display = OverlayDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 25, width: 3_000, height: 1_400))
        let frame = try resolved(nil, screens: [display], preferredDisplayID: 1)
        try expect(frame.width == 1_200, "maximum width")
        try expect(frame.midX == display.visibleFrame.midX, "centered horizontally")
        try expect(frame.minY == display.visibleFrame.minY + 72, "default bottom offset")
    }

    static func disconnectedDisplayRestoresIntoAvailableScreen() throws {
        let current = OverlayDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 25, width: 1_440, height: 850))
        let saved = OverlayPlacement(displayID: 2, horizontalFraction: 0.8, bottomFraction: 0.25, widthFraction: 0.7)
        let frame = try resolved(saved, screens: [current], preferredDisplayID: 1)
        try expect(current.visibleFrame.contains(frame), "lost-display placement must be recoverable")
        try expect(abs(frame.width - 1_008) < 1, "width follows surviving display")
    }

    static func malformedSavedPositionIsClamped() throws {
        let display = OverlayDisplay(id: 1, visibleFrame: CGRect(x: -1_280, y: 20, width: 1_280, height: 700))
        let saved = OverlayPlacement(displayID: 1, horizontalFraction: 8, bottomFraction: -5, widthFraction: 9)
        let frame = try resolved(saved, screens: [display], preferredDisplayID: 1)
        try expect(display.visibleFrame.contains(frame), "invalid stored coordinates are clamped")
        try expect(frame.width <= display.visibleFrame.width, "resized width stays visible")
    }

    static func placementRoundTripsAfterDragAndResize() throws {
        let display = OverlayDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 25, width: 1_440, height: 850))
        let dragged = CGRect(x: 130, y: 200, width: 820, height: OverlayPlacementGeometry.panelHeight)
        let saved = OverlayPlacementGeometry.record(frame: dragged, on: display)
        let restored = try resolved(saved, screens: [display], preferredDisplayID: 1)
        try expect(abs(restored.minX - dragged.minX) < 1, "dragged X restores")
        try expect(abs(restored.minY - dragged.minY) < 1, "dragged Y restores")
        try expect(abs(restored.width - dragged.width) < 1, "resized width restores")
        let narrow = CGRect(x: 130, y: 200, width: 240, height: OverlayPlacementGeometry.panelHeight)
        let narrowSaved = OverlayPlacementGeometry.record(frame: narrow, on: display)
        let narrowRestored = try resolved(narrowSaved, screens: [display], preferredDisplayID: 1)
        try expect(abs(narrowRestored.width - 240) < 1, "minimum adjusted width restores")
    }

    private static func resolved(
        _ saved: OverlayPlacement?,
        screens: [OverlayDisplay],
        preferredDisplayID: UInt32?
    ) throws -> CGRect {
        guard let frame = OverlayPlacementGeometry.resolve(
            saved: saved,
            screens: screens,
            preferredDisplayID: preferredDisplayID
        ) else { throw CheckError.noFrame }
        return frame
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckError.failed(message) }
    }

    private enum CheckError: Error {
        case noFrame
        case failed(String)
    }
}
