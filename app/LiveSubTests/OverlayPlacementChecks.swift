import CoreGraphics
import Foundation
@testable import LiveSubOverlay

@main
enum OverlayPlacementChecks {
    @MainActor static func main() throws {
        try defaultPlacementUsesVisibleAreaAndWidthCap()
        try disconnectedDisplayRestoresIntoAvailableScreen()
        try malformedSavedPositionIsClamped()
        try placementRoundTripsAfterDragAndResize()
        try newSessionClearsPreviousCaption()
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
