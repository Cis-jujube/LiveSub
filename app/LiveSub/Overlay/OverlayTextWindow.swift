import AppKit

/// The floating caption follows the newest words; the transcript keeps the full text.
/// Measure wrapped lines at the actual panel width, including CJK and emoji glyphs.
@MainActor
enum OverlayTextWindow {
    static func latestLines(_ text: String, width: CGFloat, font: NSFont) -> String {
        guard !text.isEmpty, width.isFinite, width > 0 else { return text }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        var starts: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
            starts.append(layout.characterRange(forGlyphRange: range, actualGlyphRange: nil).location)
        }
        guard starts.count > 2 else { return text }
        let start = starts[starts.count - 2]
        // TextKit ranges are UTF-16 offsets, not Swift Character offsets.
        return (text as NSString).substring(from: start)
    }
}
