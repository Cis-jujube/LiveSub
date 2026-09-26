import Foundation

/// A presentation preference only; original records and bilingual exports are retained.
public enum SubtitleDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case bilingual
    case translationOnly

    public static let preferenceKey = "livesub.subtitleDisplayMode"
    public var id: String { rawValue }
    public var label: String { self == .bilingual ? "双语" : "仅译文" }
    public var showsSource: Bool { self == .bilingual }
    public var overlayHeight: CGFloat { self == .bilingual ? 164 : 108 }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .bilingual
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    public func sourceForDisplay(_ source: String) -> String? {
        showsSource ? source : nil
    }
}
