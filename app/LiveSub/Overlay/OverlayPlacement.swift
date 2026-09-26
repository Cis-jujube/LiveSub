import CoreGraphics
import Foundation

public struct OverlayDisplay: Sendable, Equatable {
    public let id: UInt32
    public let visibleFrame: CGRect

    public init(id: UInt32, visibleFrame: CGRect) {
        self.id = id
        self.visibleFrame = visibleFrame
    }
}

/// Geometry is stored relative to a screen's usable area so scale and display changes recover.
public struct OverlayPlacement: Codable, Sendable, Equatable {
    public let displayID: UInt32
    public let horizontalFraction: Double
    public let bottomFraction: Double
    public let widthFraction: Double

    public init(displayID: UInt32, horizontalFraction: Double, bottomFraction: Double, widthFraction: Double) {
        self.displayID = displayID
        self.horizontalFraction = horizontalFraction
        self.bottomFraction = bottomFraction
        self.widthFraction = widthFraction
    }
}

public enum OverlayPlacementGeometry {
    public static let panelHeight: CGFloat = 164

    public static func resolve(
        saved: OverlayPlacement?,
        screens: [OverlayDisplay],
        preferredDisplayID: UInt32?
    ) -> CGRect? {
        guard let screen = screens.first(where: { $0.id == saved?.displayID })
            ?? screens.first(where: { $0.id == preferredDisplayID })
            ?? screens.first else { return nil }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return nil }

        let widthFraction = saved.map { bounded($0.widthFraction, min: 0, max: 1) } ?? 0.7
        let width = saved == nil
            ? min(1_200, visible.width * widthFraction)
            : min(1_200, max(min(240, visible.width), visible.width * widthFraction))
        let height = min(panelHeight, visible.height)
        let centerFraction = saved.map { bounded($0.horizontalFraction, min: 0, max: 1) } ?? 0.5
        let desiredX = visible.minX + visible.width * centerFraction - width / 2
        let desiredY = saved.map {
            visible.minY + visible.height * bounded($0.bottomFraction, min: 0, max: 1)
        } ?? visible.minY + 72
        let x = min(max(desiredX, visible.minX), visible.maxX - width)
        let y = min(max(desiredY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func record(frame: CGRect, on screen: OverlayDisplay) -> OverlayPlacement {
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else {
            return OverlayPlacement(displayID: screen.id, horizontalFraction: 0.5, bottomFraction: 0, widthFraction: 0.7)
        }
        return OverlayPlacement(
            displayID: screen.id,
            horizontalFraction: bounded(Double((frame.midX - visible.minX) / visible.width), min: 0, max: 1),
            bottomFraction: bounded(Double((frame.minY - visible.minY) / visible.height), min: 0, max: 1),
            widthFraction: bounded(Double(frame.width / visible.width), min: 0, max: 1)
        )
    }

    private static func bounded(_ value: Double, min lower: Double, max upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return Swift.min(upper, Swift.max(lower, value))
    }
}
