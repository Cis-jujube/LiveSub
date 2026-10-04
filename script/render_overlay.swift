// One-shot render of the floating caption over a synthetic bright/dark frame. Nothing is shown on screen.
// Compiled with the overlay sources directly because OverlayView is internal to LiveSubOverlay.
import AppKit
import SwiftUI
import LiveSubSubtitles

struct Scene: View {
    let presentation: OverlayPresentation
    var body: some View {
        ZStack(alignment: .bottom) {
            // Stand-in video frame: bright sky over a dark foreground, to test legibility on both.
            LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.62, green: 0.72, blue: 0.8), Color(red: 0.16, green: 0.18, blue: 0.2)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color(red: 0.97, green: 0.96, blue: 0.92)).frame(width: 260, height: 200).offset(x: -180, y: -40)
            OverlayView(presentation: presentation, onMove: { _ in }, onMoveEnd: {}, onResize: { _ in }, onResizeEnd: {}, onDone: {})
                .frame(width: 900, height: OverlayTypography.panelHeight(for: presentation.displayMode, fontSize: presentation.fontSize))
                .padding(.bottom, 40)
        }
        .frame(width: 1100, height: 420)
    }
}

@main struct Main { @MainActor static func main() throws {
    _ = NSApplication.shared
    for (name, adjusting, backdrop) in [("overlay-bilingual", false, false), ("overlay-backdrop", false, true), ("overlay-adjusting", true, false)] {
        let p = OverlayPresentation()
        p.caption = OverlayCaption(sourceText: "The context window holds the instructions and the recent conversation.", translatedSourceText: "The context window holds the instructions and the recent conversation.", targetText: "上下文窗口容纳指令和最近的对话。", translationState: .final)
        p.isAdjusting = adjusting; p.showsBackdrop = backdrop
        let view = NSHostingView(rootView: Scene(presentation: p))
        let w = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 1100, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let path = FileManager.default.currentDirectoryPath + "/design/previews/" + name + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("Overlay render (synthetic caption): " + path)
    }
}}
