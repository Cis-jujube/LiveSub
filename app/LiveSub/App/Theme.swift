import AppKit
import SwiftUI

/// Paper, ink and one vermilion accent, taken from the app icon: the source line is ink,
/// the translation line is vermilion. Vermilion marks live state and the primary action only.
enum Theme {
    static let accent = Color(nsColor: .dynamic(light: 0xC4472F, dark: 0xE2664A))
    static let paper = Color(nsColor: .dynamic(light: 0xFBFAF7, dark: 0x1E1D20))
    static let raised = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x29282C))
    static let sourceInk = Color(nsColor: .dynamic(light: 0x5E5A57, dark: 0xA9A5A2))
    static let hairline = Color.primary.opacity(0.08)
    static let caution = Color(nsColor: .dynamic(light: 0xB86A12, dark: 0xF0A94B))

    /// Muted, distinguishable hues for up to five detected speakers (vermilion stays reserved).
    static func speakerColor(_ id: String) -> Color {
        let palette: [UInt32] = [0x3F8C86, 0x5A6BC0, 0xB5852C, 0x9358A0, 0x6C8A3A]
        let index = Int(id.unicodeScalars.first.map { $0.value } ?? 65) - 65
        let hex = palette[((index % palette.count) + palette.count) % palette.count]
        return Color(nsColor: .dynamic(light: hex, dark: hex))
    }
}

extension NSColor {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// The app icon's eclipse: a vermilion sun slipping out from behind a dark disc.
/// The disc stays dark in both appearances; its corona separates it from dark paper.
struct EclipseMark: View {
    /// Brightens the corona while the app is listening.
    var live = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(Theme.accent.opacity(live ? 0.5 : 0.35))
                    .frame(width: side * 0.8, height: side * 0.8)
                    .blur(radius: side * 0.22)
                    .offset(x: -side * 0.06, y: side * 0.04)
                Circle().fill(LinearGradient(colors: [Color(nsColor: .dynamic(light: 0xFF7448, dark: 0xFF7A4E)), Theme.accent],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.8, height: side * 0.8)
                    .offset(x: -side * 0.06, y: side * 0.04)
                Circle().fill(Color(nsColor: .dynamic(light: 0xFFE6D2, dark: 0xFFE0C8)).opacity(live ? 1 : 0.85))
                    .frame(width: side * 0.77, height: side * 0.77)
                    .blur(radius: side * 0.03)
                    .offset(x: side * 0.06, y: -side * 0.03)
                Circle().fill(LinearGradient(colors: [Color(nsColor: .dynamic(light: 0x26262B, dark: 0x1A1A1E)), Color(nsColor: .dynamic(light: 0x0F0F11, dark: 0x0B0B0D))],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.75, height: side * 0.75)
                    .offset(x: side * 0.06, y: -side * 0.03)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// Real input loudness from the capture frames, drawn as a few rounded bars.
struct InputLevelBars: View {
    @ObservedObject var meter: InputLevelMeter
    var barWidth: CGFloat = 2.5
    var maxHeight: CGFloat = 12
    var color: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: barWidth * 0.8) {
            ForEach(Array(meter.bars.enumerated()), id: \.offset) { _, level in
                Capsule(style: .circular)
                    .fill(color)
                    .frame(width: barWidth, height: max(barWidth, maxHeight * CGFloat(level)))
            }
        }
        .frame(height: maxHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: meter.bars)
        .accessibilityHidden(true)
    }
}
