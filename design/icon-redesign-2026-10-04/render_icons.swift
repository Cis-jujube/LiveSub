import AppKit
import SwiftUI

let ink = Color(red: 0.11, green: 0.12, blue: 0.16)
let ink2 = Color(red: 0.20, green: 0.21, blue: 0.27)
let vermilion = Color(red: 0.86, green: 0.33, blue: 0.22)
let coral = Color(red: 0.97, green: 0.52, blue: 0.36)
let paper = Color(red: 0.985, green: 0.975, blue: 0.955)
let paper2 = Color(red: 0.93, green: 0.91, blue: 0.87)

/// macOS icon grid: 824 pt body centred on a 1024 canvas, with a soft drop shadow.
struct Tile<Content: View>: View {
    let fill: AnyShapeStyle
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.0)], startPoint: .top, endPoint: .center), lineWidth: 3))
                .shadow(color: .black.opacity(0.28), radius: 22, y: 14)
            content()
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

// A · 字幕 — two caption lines on ink: source (soft white), translation (vermilion).
struct A: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [ink2, ink], startPoint: .top, endPoint: .bottom))) {
        VStack(spacing: 58) {
            Capsule().fill(.white.opacity(0.88)).frame(width: 380, height: 64)
            Capsule().fill(LinearGradient(colors: [coral, vermilion], startPoint: .leading, endPoint: .trailing)).frame(width: 540, height: 64)
        }
        .offset(y: 150)
        Ellipse().fill(RadialGradient(colors: [.white.opacity(0.10), .clear], center: .center, startRadius: 0, endRadius: 300))
            .frame(width: 700, height: 420).offset(y: -170)
    }
}}

// B · A文 — bilingual glyph pair on paper, Latin serif in ink, Chinese in vermilion.
struct B: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [paper, paper2], startPoint: .top, endPoint: .bottom))) {
        Text("A").font(.custom("New York", size: 400)).foregroundStyle(ink)
            .offset(x: -150, y: -110)
        Rectangle().fill(ink.opacity(0.18)).frame(width: 6, height: 520).rotationEffect(.degrees(35))
        Text("文").font(.custom("Songti SC", size: 360).weight(.bold)).foregroundStyle(vermilion)
            .offset(x: 150, y: 120)
    }
}}

// C · 声→字 — waveform bars that settle into a caption line.
struct C: View { var body: some View {
    let heights: [CGFloat] = [120, 250, 360, 250, 150, 84]
    return Tile(fill: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.22), Color(red: 0.07, green: 0.08, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))) {
        HStack(alignment: .center, spacing: 26) {
            ForEach(0..<6, id: \.self) { i in
                Capsule().fill(.white.opacity(0.55 + 0.07 * Double(i))).frame(width: 46, height: heights[i])
            }
            Capsule().fill(LinearGradient(colors: [coral, vermilion], startPoint: .leading, endPoint: .trailing)).frame(width: 230, height: 46)
                .shadow(color: vermilion.opacity(0.7), radius: 24)
        }
    }
}}

// D · 对页 — open book of two caption pages, refined from the old mark.
struct D: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [vermilion, Color(red: 0.70, green: 0.22, blue: 0.16)], startPoint: .top, endPoint: .bottom))) {
        HStack(spacing: 28) {
            page(lines: [260, 200, 230], color: .white.opacity(0.95))
            page(lines: [220, 260, 170], color: .white.opacity(0.95))
        }
    }
}
    func page(lines: [CGFloat], color: Color) -> some View {
        RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.white.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 14))
            .frame(width: 300, height: 400)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(lines, id: \.self) { w in Capsule().fill(color).frame(width: w * 0.85, height: 30) }
                }.padding(.leading, 42)
            }
    }
}

// E · 引号 — a single speech mark carrying a vermilion translation line, on paper.
struct E: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [paper, paper2], startPoint: .top, endPoint: .bottom))) {
        ZStack {
            RoundedRectangle(cornerRadius: 120, style: .continuous).fill(ink)
                .frame(width: 560, height: 420)
            Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 120, y: 0)); p.addLine(to: CGPoint(x: 10, y: 110)); p.closeSubpath() }
                .fill(ink).frame(width: 120, height: 110).offset(x: -150, y: 255)
            VStack(alignment: .leading, spacing: 46) {
                Capsule().fill(.white.opacity(0.55)).frame(width: 300, height: 50)
                Capsule().fill(LinearGradient(colors: [coral, vermilion], startPoint: .leading, endPoint: .trailing)).frame(width: 400, height: 50)
            }
        }.offset(y: -20)
    }
}}

@main struct Main { @MainActor static func main() throws {
    _ = NSApplication.shared
    let out = CommandLine.arguments[1]
    let views: [(String, AnyView)] = [("A-captions", AnyView(A())), ("B-bilingual-glyphs", AnyView(B())), ("C-voice-to-text", AnyView(C())), ("D-twin-pages", AnyView(D())), ("E-speech-mark", AnyView(E()))]
    var sheet: [NSImage] = []
    for (name, view) in views {
        let r = ImageRenderer(content: view.frame(width: 1024, height: 1024)); r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fatalError() }
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        sheet.append(img)
    }
    // Contact sheet: each icon at 360 px plus a 64 px and 32 px to judge small sizes.
    let r = ImageRenderer(content: HStack(spacing: 30) { ForEach(0..<sheet.count, id: \.self) { i in
        VStack(spacing: 18) {
            Image(nsImage: sheet[i]).resizable().frame(width: 360, height: 360)
            HStack(spacing: 20) { Image(nsImage: sheet[i]).resizable().frame(width: 64, height: 64); Image(nsImage: sheet[i]).resizable().frame(width: 32, height: 32) }
            Text(["A 字幕", "B A文", "C 声→字", "D 对页", "E 引号"][i]).font(.system(size: 28, weight: .semibold))
        }}}.padding(40).background(Color(white: 0.94)))
    r.scale = 1
    let rep = NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/sheet.png"))
}}
