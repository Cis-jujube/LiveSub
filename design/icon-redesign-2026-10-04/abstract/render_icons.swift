import AppKit
import SwiftUI

func rgb(_ h: UInt32) -> Color { Color(red: Double((h >> 16) & 255) / 255, green: Double((h >> 8) & 255) / 255, blue: Double(h & 255) / 255) }

struct Tile<Content: View>: View {
    let fill: AnyShapeStyle
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous).fill(fill)
            content()
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0), .black.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 14)
        .frame(width: 1024, height: 1024)
    }
}

// 1 · 日出 Rising Sun — vermilion sun over layered sea arcs, Japanese print calm.
struct Sun: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [rgb(0xF6E9D7), rgb(0xF2D2B4)], startPoint: .top, endPoint: .bottom))) {
        Circle().fill(LinearGradient(colors: [rgb(0xF0603E), rgb(0xD13B2A)], startPoint: .top, endPoint: .bottom))
            .frame(width: 380).offset(y: -40)
        VStack(spacing: 0) {
            Spacer()
            ForEach(0..<4, id: \.self) { i in
                Rectangle().fill([rgb(0x24456B), rgb(0x1D3858), rgb(0x162C47), rgb(0x0F2036)][i]).frame(height: 80)
                    .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.18)).frame(width: CGFloat(500 - i * 90), height: 8).offset(y: 18) }
            }
        }
    }
}}

// 2 · 月 Crescent — a pale moon with soft halo on midnight blue, three tiny stars.
struct Moon: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [rgb(0x1B2350), rgb(0x0A0D24)], startPoint: .top, endPoint: .bottom))) {
        Circle().fill(RadialGradient(colors: [rgb(0x7F8CFF).opacity(0.35), .clear], center: .center, startRadius: 120, endRadius: 420)).frame(width: 840)
        Circle().fill(LinearGradient(colors: [rgb(0xFFF6DA), rgb(0xF1D79A)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 400)
            .mask(ZStack { Circle().frame(width: 400); Circle().frame(width: 360).offset(x: 120, y: -70).blendMode(.destinationOut) }.compositingGroup())
            .shadow(color: rgb(0xF6D98A).opacity(0.6), radius: 40)
        ForEach([(CGPoint(x: 230, y: -230), 16.0), (CGPoint(x: 290, y: 120), 10.0), (CGPoint(x: -260, y: -260), 9.0)], id: \.1) { star in
            Circle().fill(.white).frame(width: star.1).offset(x: star.0.x, y: star.0.y).shadow(color: .white, radius: 8)
        }
    }
}}

// 3 · 圆相 Ensō — a single vermilion brush circle on warm paper.
struct Enso: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [rgb(0xFBF7EF), rgb(0xEFE7D8)], startPoint: .top, endPoint: .bottom))) {
        ZStack {
            ForEach(0..<5, id: \.self) { i in
                Circle().trim(from: 0.04 + Double(i) * 0.004, to: 0.93 - Double(i) * 0.012)
                    .stroke(rgb(0xC8361F).opacity(0.85 - Double(i) * 0.1), style: StrokeStyle(lineWidth: CGFloat(78 - i * 12), lineCap: .round))
                    .frame(width: 470 + CGFloat(i * 6), height: 470 + CGFloat(i * 4))
                    .offset(x: CGFloat(i * 3), y: CGFloat(-i * 2))
            }
        }.rotationEffect(.degrees(-62))
    }
}}

// 4 · 极光 Aurora — glowing iridescent orb, like a glass marble lit from within.
struct Aurora: View { var body: some View {
    Tile(fill: AnyShapeStyle(rgb(0x0B0B14))) {
        ZStack {
            Circle().fill(AngularGradient(colors: [rgb(0xFF5F6D), rgb(0xFFC371), rgb(0x47E5BC), rgb(0x4A6CF7), rgb(0xB84BFF), rgb(0xFF5F6D)], center: .center))
                .frame(width: 520).blur(radius: 60)
            Circle().fill(AngularGradient(colors: [rgb(0xFF5F6D), rgb(0xFFC371), rgb(0x47E5BC), rgb(0x4A6CF7), rgb(0xB84BFF), rgb(0xFF5F6D)], center: .center))
                .frame(width: 470).blur(radius: 14)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.75), .clear], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 200)).frame(width: 470)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 3).frame(width: 470)
        }
    }
}}

// 5 · 包豪斯 Bauhaus — circle, half-disc and square in a bold, balanced grid.
struct Bauhaus: View { var body: some View {
    Tile(fill: AnyShapeStyle(rgb(0xF3EEE3))) {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Rectangle().fill(rgb(0x1F3A93)).overlay(Circle().fill(rgb(0xF3EEE3)).padding(70))
                Rectangle().fill(rgb(0xF2B134)).overlay(alignment: .bottom) { Circle().fill(rgb(0xE4572E)).frame(width: 412, height: 412).offset(y: 206) }.clipped()
            }
            GridRow {
                Rectangle().fill(rgb(0xE4572E)).overlay(alignment: .topTrailing) { Circle().fill(rgb(0x1B1B1B)).frame(width: 412, height: 412).offset(x: 206, y: -206) }.clipped()
                Rectangle().fill(rgb(0x1B1B1B)).overlay(Rectangle().fill(rgb(0xF3EEE3)).frame(width: 150, height: 150).rotationEffect(.degrees(45)))
            }
        }
    }
}}

// 6 · 玻璃 Glass Prism — stacked translucent panes catching a rainbow edge.
struct Prism: View { var body: some View {
    Tile(fill: AnyShapeStyle(LinearGradient(colors: [rgb(0xEAF0FF), rgb(0xC9D6F5)], startPoint: .top, endPoint: .bottom))) {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 70, style: .continuous)
                    .fill(LinearGradient(colors: [[rgb(0x7A5CFF), rgb(0x2EC5FF), rgb(0xFF6FB1)][i].opacity(0.55), .white.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 70, style: .continuous).strokeBorder(.white.opacity(0.8), lineWidth: 4))
                    .frame(width: 360, height: 460)
                    .rotationEffect(.degrees(Double(i - 1) * 14))
                    .offset(x: CGFloat(i - 1) * 70, y: CGFloat(i - 1) * -20)
                    .shadow(color: .black.opacity(0.12), radius: 20, y: 12)
            }
        }
    }
}}

@main struct Main { @MainActor static func main() throws {
    _ = NSApplication.shared
    let out = CommandLine.arguments[1]
    let items: [(String, String, AnyView)] = [("1-rising-sun", "1 日出", AnyView(Sun())), ("2-crescent", "2 月", AnyView(Moon())), ("3-enso", "3 圆相", AnyView(Enso())), ("4-aurora", "4 极光", AnyView(Aurora())), ("5-bauhaus", "5 包豪斯", AnyView(Bauhaus())), ("6-glass-prism", "6 玻璃", AnyView(Prism()))]
    var imgs: [NSImage] = []
    for (file, _, view) in items {
        let r = ImageRenderer(content: view.frame(width: 1024, height: 1024)); r.scale = 1
        let img = r.nsImage!
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(file).png"))
        imgs.append(img)
    }
    let r = ImageRenderer(content: VStack(spacing: 30) { ForEach(0..<2, id: \.self) { row in HStack(spacing: 30) { ForEach(0..<3, id: \.self) { c in let i = row * 3 + c
        VStack(spacing: 14) {
            Image(nsImage: imgs[i]).resizable().frame(width: 340, height: 340)
            HStack(spacing: 20) { Image(nsImage: imgs[i]).resizable().frame(width: 64, height: 64); Image(nsImage: imgs[i]).resizable().frame(width: 32, height: 32) }
            Text(items[i].1).font(.system(size: 26, weight: .semibold))
        }}}}}.padding(40).background(Color(white: 0.94)))
    r.scale = 1
    try NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/sheet.png"))
}}
