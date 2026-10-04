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
    /// Brightens the corona and quickens its pulse while the app is listening.
    var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                EclipseFigure(live: live, time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    EclipseFigure(live: live, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One frame of the eclipse. `time` drives slow, small motion: a breath, a tilt,
/// and the dark disc drifting so the crescent waxes and wanes. `time: 0` is the resting pose.
struct EclipseFigure: View {
    let live: Bool
    let time: TimeInterval

    private func wave(_ period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin((time / period + phase) * 2 * .pi))
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let breath = 1 + 0.025 * wave(6)
            let tilt = 3 * wave(11, phase: 0.25)
            let drift = side * 0.014 * wave(9, phase: 0.5)
            let corona = live ? 0.8 + 0.2 * wave(2.4) : 0.78 + 0.1 * wave(4)
            ZStack {
                Circle().fill(Theme.accent.opacity((live ? 0.5 : 0.35) * Double(0.85 + 0.15 * wave(6))))
                    .frame(width: side * 0.8, height: side * 0.8)
                    .blur(radius: side * 0.22)
                    .offset(x: -side * 0.06, y: side * 0.04)
                Circle().fill(LinearGradient(colors: [Color(nsColor: .dynamic(light: 0xFF7448, dark: 0xFF7A4E)), Theme.accent],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.8, height: side * 0.8)
                    .offset(x: -side * 0.06, y: side * 0.04)
                Circle().fill(Color(nsColor: .dynamic(light: 0xFFE6D2, dark: 0xFFE0C8)).opacity(Double(corona)))
                    .frame(width: side * 0.77, height: side * 0.77)
                    .blur(radius: side * 0.03)
                    .offset(x: side * 0.06 + drift, y: -side * 0.03 - drift * 0.5)
                Circle().fill(LinearGradient(colors: [Color(nsColor: .dynamic(light: 0x26262B, dark: 0x1A1A1E)), Color(nsColor: .dynamic(light: 0x0F0F11, dark: 0x0B0B0D))],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.75, height: side * 0.75)
                    .offset(x: side * 0.06 + drift, y: -side * 0.03 - drift * 0.5)
            }
            .scaleEffect(breath)
            .rotationEffect(.degrees(Double(tilt)))
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Capsule call-to-action that lifts slightly on hover and presses in on click.
struct LiftButtonStyle: ButtonStyle {
    var prominent = true
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        LiftButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}

private struct LiftButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let compact: Bool
    @StateObject private var hover = LiftHoverState()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        let lifted = hover.hovering && isEnabled && !pressed
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.accent)
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.vertical, compact ? 8 : 11)
            .background(Capsule(style: .circular).fill(prominent ? Theme.accent : Theme.accent.opacity(lifted ? 0.16 : 0.1)))
            .overlay(Capsule(style: .circular).fill(.white.opacity(prominent && lifted ? 0.1 : 0)))
            .overlay(Capsule(style: .circular).fill(.black.opacity(pressed ? 0.08 : 0)))
            .shadow(color: Theme.accent.opacity(prominent ? (lifted ? 0.38 : 0.18) : 0), radius: lifted ? 14 : 6, y: lifted ? 6 : 3)
            .scaleEffect(reduceMotion ? 1 : pressed ? 0.96 : lifted ? 1.03 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule(style: .circular))
            .onHover { hover.hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: lifted)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.8), value: pressed)
    }
}

@MainActor
private final class LiftHoverState: ObservableObject {
    @Published var hovering = false
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
