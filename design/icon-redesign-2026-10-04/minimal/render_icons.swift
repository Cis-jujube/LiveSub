import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

let T: CGFloat = 824
let C = CGPoint(x: 412, y: 412)

func hex(_ h: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB, red: Double((h >> 16) & 0xFF) / 255, green: Double((h >> 8) & 0xFF) / 255, blue: Double(h & 0xFF) / 255, opacity: a)
}

let grainImage: NSImage = {
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let noise = CIFilter.randomGenerator().outputImage!.cropped(to: rect)
    let mono = CIFilter.colorControls()
    mono.inputImage = noise
    mono.saturation = 0
    return NSImage(cgImage: CIContext().createCGImage(mono.outputImage!, from: rect)!, size: rect.size)
}()

let ink = hex(0x151517)
let verTop = hex(0xFF7448), verBottom = hex(0xE4412A)
let vermilion = LinearGradient(colors: [verTop, verBottom], startPoint: .topLeading, endPoint: .bottomTrailing)

/// One shared tile so the marks are judged on form alone: 824 squircle, faint grain, edge light, Big Sur drop shadow.
struct Tile<Content: View>: View {
    let fill: AnyShapeStyle
    var light = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Rectangle().fill(fill)
            content()
            Image(nsImage: grainImage).resizable().frame(width: T, height: T).blendMode(.overlay).opacity(0.025)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(light ? AnyShapeStyle(Color.black.opacity(0.07))
                                    : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom)),
                              lineWidth: 2)
        }
        .frame(width: T, height: T)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

struct Abs: Shape {
    let p: Path
    func path(in rect: CGRect) -> Path { p }
}

func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }

// MARK: 1 · 错位 Offset — one disc cut in two, the second half a beat behind (speech, then its translation).

struct OffsetMark: View {
    var body: some View {
        let r: CGFloat = 196, gap: CGFloat = 9, lift: CGFloat = 34
        let disc = circle(C, r)
        let left = disc.intersection(Path(CGRect(x: 0, y: 0, width: C.x, height: T)))
        let right = disc.intersection(Path(CGRect(x: C.x, y: 0, width: T - C.x, height: T)))
        return Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0xFCFBF8), hex(0xEFEBE4)], startPoint: .top, endPoint: .bottom)), light: true) {
            ZStack {
                Abs(p: left).fill(LinearGradient(colors: [hex(0x2C2C31), hex(0x111113)], startPoint: .top, endPoint: .bottom))
                    .offset(x: -gap, y: -lift / 2)
                Abs(p: right).fill(LinearGradient(colors: [verTop, verBottom], startPoint: .top, endPoint: .bottom))
                    .offset(x: gap, y: lift / 2)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 2 · 对话 Dialogue — two speech bubbles woven through each other.

func bubble(_ c: CGPoint, _ r: CGFloat, tailBottomLeft: Bool, round k: CGFloat = 0) -> Path {
    var tail = Path()
    if tailBottomLeft {
        tail.move(to: CGPoint(x: c.x - r, y: c.y))
        tail.addLine(to: CGPoint(x: c.x - r, y: c.y + r - k))
        tail.addQuadCurve(to: CGPoint(x: c.x - r + k, y: c.y + r), control: CGPoint(x: c.x - r, y: c.y + r))
        tail.addLine(to: CGPoint(x: c.x, y: c.y + r))
        tail.addLine(to: c)
    } else {
        tail.move(to: CGPoint(x: c.x + r, y: c.y))
        tail.addLine(to: CGPoint(x: c.x + r, y: c.y - r + k))
        tail.addQuadCurve(to: CGPoint(x: c.x + r - k, y: c.y - r), control: CGPoint(x: c.x + r, y: c.y - r))
        tail.addLine(to: CGPoint(x: c.x, y: c.y - r))
        tail.addLine(to: c)
    }
    tail.closeSubpath()
    return circle(c, r).union(tail)
}

struct DialogueMark: View {
    var body: some View {
        let r: CGFloat = 156
        let a = bubble(CGPoint(x: 352, y: 372), r, tailBottomLeft: true, round: 22)
        let b = bubble(CGPoint(x: 472, y: 452), r, tailBottomLeft: false, round: 22)
        let dy = (372 + r) - 452, p1 = CGPoint(x: 472 - (r * r - dy * dy).squareRoot(), y: 372 + r)
        let p2 = CGPoint(x: T - p1.x, y: T - p1.y)
        let bg = LinearGradient(colors: [hex(0xFFFFFF), hex(0xEFEEEB)], startPoint: .top, endPoint: .bottom)
        let line = StrokeStyle(lineWidth: 44, lineCap: .round, lineJoin: .round)
        let gap = StrokeStyle(lineWidth: 44 + 30, lineCap: .round, lineJoin: .round)
        return Tile(fill: AnyShapeStyle(bg), light: true) {
            ZStack {
                // A passes under B at p2: cut A where B's widened band crosses it there.
                ZStack {
                    Abs(p: a).stroke(ink, style: line)
                    Abs(p: b).stroke(.black, style: gap).mask(Circle().frame(width: 170, height: 170).position(p2)).blendMode(.destinationOut)
                }
                .compositingGroup()
                // B passes under A at p1.
                ZStack {
                    Abs(p: b).stroke(vermilion, style: line)
                    Abs(p: a).stroke(.black, style: gap).mask(Circle().frame(width: 170, height: 170).position(p1)).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 3 · 声线 Voiceline — a sound wave that settles into a line of text.

struct VoicelineMark: View {
    var wave: Path {
        var pts: [CGPoint] = []
        let x0: CGFloat = 150, xw: CGFloat = 470, x1: CGFloat = 674
        for i in 0...300 {
            let t = CGFloat(i) / 300
            let amp = 150 * pow(1 - t, 1.2)
            pts.append(CGPoint(x: x0 + (xw - x0) * t, y: C.y - amp * sin(t * 1.75 * 2 * .pi)))
        }
        pts.append(CGPoint(x: x1, y: C.y))
        var p = Path()
        p.addLines(pts)
        return p
    }
    var body: some View {
        let gradient = LinearGradient(stops: [
            .init(color: hex(0x7C6CFF), location: 0.2), .init(color: hex(0xD45CF2), location: 0.42),
            .init(color: hex(0xFF5C7C), location: 0.6), .init(color: hex(0xFF8A3D), location: 0.8)], startPoint: .leading, endPoint: .trailing)
        let style = StrokeStyle(lineWidth: 56, lineCap: .round, lineJoin: .round)
        return Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0x1B1B1F), hex(0x09090B)], startPoint: .top, endPoint: .bottom))) {
            ZStack {
                Circle().fill(hex(0x5B3C8C, 0.35)).frame(width: 520, height: 520).blur(radius: 110)
                Abs(p: wave).stroke(gradient, style: style).blur(radius: 26).opacity(0.75)
                Abs(p: wave).stroke(gradient, style: style)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 4 · 光环 Halo — one glowing stroke that is also a speech bubble.

struct HaloMark: View {
    let c = CGPoint(x: 418, y: 400)
    let r: CGFloat = 182
    var ring: Path {
        let start: CGFloat = 126, end: CGFloat = 94 + 360
        func at(_ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * cos(a * .pi / 180), y: c.y + r * sin(a * .pi / 180)) }
        let s = at(start)
        var p = Path()
        p.move(to: CGPoint(x: s.x - 34, y: s.y + 88))
        p.addLine(to: s)
        var a = start
        while a <= end { p.addLine(to: at(a)); a += 0.5 }
        return p
    }
    var body: some View {
        let spectrum = AngularGradient(colors: [hex(0xFF6A3D), hex(0xFFB347), hex(0xFF5C8D), hex(0xA25BFF), hex(0x5C7CFF), hex(0xFF6A3D)],
                                       center: UnitPoint(x: c.x / T, y: c.y / T), startAngle: .degrees(90), endAngle: .degrees(450))
        let style = StrokeStyle(lineWidth: 60, lineCap: .round, lineJoin: .round)
        return Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0x101014), hex(0x050507)], startPoint: .top, endPoint: .bottom))) {
            ZStack {
                Abs(p: ring).stroke(spectrum, style: style).blur(radius: 70).opacity(0.55)
                Abs(p: ring).stroke(spectrum, style: style).blur(radius: 18).opacity(0.8)
                Abs(p: ring).stroke(spectrum, style: style)
                Abs(p: ring).stroke(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center),
                                    style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                    .blur(radius: 4)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 5 · 字 Seal — one character, set like a stamp.

struct SealMark: View {
    var body: some View {
        Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0xFF6A3F), hex(0xD93C25)], startPoint: .topLeading, endPoint: .bottomTrailing))) {
            ZStack {
                RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 600)
                Text("字")
                    .font(.custom("PingFangSC-Semibold", size: 450))
                    .foregroundStyle(hex(0xFFF8F2))
                    .shadow(color: hex(0x8A1E0E, 0.35), radius: 16, y: 10)
                    .offset(y: -8)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 6 · 日食 Eclipse — a vermilion sun slipping out from behind a dark disc.

struct EclipseMark: View {
    var body: some View {
        let sun = CGPoint(x: 384, y: 430), moon = CGPoint(x: 440, y: 398)
        return Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0x141417), hex(0x060607)], startPoint: .top, endPoint: .bottom))) {
            ZStack {
                Circle().fill(verTop.opacity(0.55)).frame(width: 520, height: 520).blur(radius: 90).position(sun)
                Circle().fill(vermilion).frame(width: 372, height: 372).position(sun)
                Circle().fill(hex(0xFFE0C8, 0.9)).frame(width: 360, height: 360).blur(radius: 14).position(moon)
                Circle().fill(LinearGradient(colors: [hex(0x1E1E22), hex(0x0B0B0D)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 348, height: 348).position(moon)
                Circle().stroke(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .topLeading, endPoint: .center), lineWidth: 2)
                    .frame(width: 348, height: 348).position(moon)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 7 · 实时 Live — a recording dot leading two caption lines.

struct LiveMark: View {
    var body: some View {
        Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0x1A1A1D), hex(0x0A0A0C)], startPoint: .top, endPoint: .bottom))) {
            ZStack {
                Circle().fill(verTop.opacity(0.7)).frame(width: 150, height: 150).blur(radius: 40).position(x: 250, y: 362)
                Circle().fill(vermilion).frame(width: 96, height: 96).position(x: 250, y: 362)
                Capsule(style: .circular).fill(.white).frame(width: 296, height: 60).position(x: 330 + 148, y: 362)
                Capsule(style: .circular).fill(.white.opacity(0.38)).frame(width: 384, height: 60).position(x: 202 + 192, y: 470)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: 8 · 气泡 Drop — the purest speech bubble, in one rich gradient.

struct DropMark: View {
    var body: some View {
        let c = CGPoint(x: 424, y: 398), r: CGFloat = 198, k: CGFloat = 46
        var tail = Path()
        tail.move(to: CGPoint(x: c.x - r, y: c.y))
        tail.addLine(to: CGPoint(x: c.x - r, y: c.y + r - k))
        tail.addQuadCurve(to: CGPoint(x: c.x - r + k, y: c.y + r), control: CGPoint(x: c.x - r, y: c.y + r))
        tail.addLine(to: CGPoint(x: c.x, y: c.y + r))
        tail.addLine(to: c)
        tail.closeSubpath()
        let shape = circle(c, r).union(tail)
        let fill = LinearGradient(colors: [hex(0xFF9A3C), hex(0xFF4F6A), hex(0xB24DFF)], startPoint: .topTrailing, endPoint: .bottomLeading)
        return Tile(fill: AnyShapeStyle(LinearGradient(colors: [hex(0xFFFFFF), hex(0xF1F0F4)], startPoint: .top, endPoint: .bottom)), light: true) {
            ZStack {
                Abs(p: shape).fill(fill).blur(radius: 40).opacity(0.45).offset(y: 30)
                Abs(p: shape).fill(fill)
                Abs(p: shape).fill(RadialGradient(colors: [.white.opacity(0.42), .clear], center: UnitPoint(x: 0.42, y: 0.32), startRadius: 0, endRadius: 260))
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - Render

@main struct Main {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let out = CommandLine.arguments[1]
        let items: [(String, String, AnyView)] = [
            ("1-offset", "1 错位", AnyView(OffsetMark())), ("2-dialogue", "2 对话", AnyView(DialogueMark())),
            ("3-voiceline", "3 声线", AnyView(VoicelineMark())), ("4-halo", "4 光环", AnyView(HaloMark())),
            ("5-seal", "5 字", AnyView(SealMark())), ("6-eclipse", "6 日食", AnyView(EclipseMark())),
            ("7-live", "7 实时", AnyView(LiveMark())), ("8-drop", "8 气泡", AnyView(DropMark()))]
        var images: [NSImage] = []
        for (file, _, view) in items {
            let r = ImageRenderer(content: view.frame(width: 1024, height: 1024))
            r.scale = 1
            guard let img = r.nsImage, let rep = NSBitmapImageRep(data: img.tiffRepresentation!) else { fatalError(file) }
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(file).png"))
            images.append(img)
        }
        func dock(_ dark: Bool) -> some View {
            HStack(spacing: 10) {
                ForEach(0..<images.count, id: \.self) { i in Image(nsImage: images[i]).resizable().frame(width: 112, height: 112) }
            }
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(dark ? Color.white.opacity(0.14) : Color.white.opacity(0.6)))
            .padding(28)
            .background(dark ? LinearGradient(colors: [hex(0x2B3150), hex(0x151826)], startPoint: .top, endPoint: .bottom)
                             : LinearGradient(colors: [hex(0xC9D6EA), hex(0xE9E2D8)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        let sheet = VStack(spacing: 30) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 28) {
                    ForEach(0..<4, id: \.self) { col in
                        let i = row * 4 + col
                        VStack(spacing: 8) {
                            Image(nsImage: images[i]).resizable().frame(width: 290, height: 290)
                            Text(items[i].1).font(.system(size: 24, weight: .semibold))
                        }
                    }
                }
            }
            dock(true)
            dock(false)
        }
        .padding(40)
        .background(Color(white: 0.96))
        let r = ImageRenderer(content: sheet)
        r.scale = 1
        try NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(out)/sheet.png"))
        print("ok")
    }
}
