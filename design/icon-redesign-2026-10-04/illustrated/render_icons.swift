import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Basics

let T: CGFloat = 824

func hex(_ h: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB, red: Double((h >> 16) & 0xFF) / 255, green: Double((h >> 8) & 0xFF) / 255, blue: Double(h & 0xFF) / 255, opacity: a)
}

struct RNG {
    var state: UInt64
    init(_ seed: UInt64) { state = (seed &* 0x9E3779B97F4A7C15) | 1 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
    }
}

extension View {
    func at(_ x: CGFloat, _ y: CGFloat) -> some View { position(x: x * T, y: y * T) }
}

let grainImage: NSImage = {
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let noise = CIFilter.randomGenerator().outputImage!.cropped(to: rect)
    let mono = CIFilter.colorControls()
    mono.inputImage = noise
    mono.saturation = 0
    let cg = CIContext().createCGImage(mono.outputImage!, from: rect)!
    return NSImage(cgImage: cg, size: rect.size)
}()

/// macOS icon grid: an 824 pt squircle on a 1024 canvas, soft grain, a top light edge and a drop shadow.
struct Tile<Content: View>: View {
    var grain: Double = 0.06
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            content()
            Image(nsImage: grainImage).resizable().frame(width: T, height: T).blendMode(.overlay).opacity(grain)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 2.5)
        }
        .frame(width: T, height: T)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.32), radius: 18, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

func catmullRom(_ pts: [CGPoint], closed: Bool, samples: Int = 14) -> [CGPoint] {
    let n = pts.count
    var out: [CGPoint] = []
    let segments = closed ? n : n - 1
    for i in 0..<segments {
        let p0 = pts[closed ? (i - 1 + n) % n : max(i - 1, 0)]
        let p1 = pts[i]
        let p2 = pts[(i + 1) % n]
        let p3 = pts[closed ? (i + 2) % n : min(i + 2, n - 1)]
        for s in 0..<samples {
            let t = CGFloat(s) / CGFloat(samples)
            let t2 = t * t, t3 = t2 * t
            let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
            let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
            out.append(CGPoint(x: x, y: y))
        }
    }
    if !closed { out.append(pts[n - 1]) }
    return out
}

/// Absolute-coordinate polygon, drawn inside a T×T frame.
struct PolyShape: Shape {
    let points: [CGPoint]
    var closed = true
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addLines(points)
        if closed { p.closeSubpath() }
        return p
    }
}

struct StarField: View {
    var count: Int
    var seed: UInt64
    var size = CGSize(width: T, height: T)
    var xRange: ClosedRange<CGFloat> = 0...1
    var yRange: ClosedRange<CGFloat> = 0...1
    var maxRadius: CGFloat = 2.4
    var color: Color = .white
    var body: some View {
        Canvas { ctx, sz in
            var rng = RNG(seed)
            for _ in 0..<count {
                let x = (xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * rng.next()) * sz.width
                let y = (yRange.lowerBound + (yRange.upperBound - yRange.lowerBound) * rng.next()) * sz.height
                let u = rng.next()
                let r = 0.6 + u * u * maxRadius
                let a = 0.3 + 0.7 * rng.next()
                if r > maxRadius * 0.55 {
                    let g = r * 4.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2)),
                             with: .radialGradient(Gradient(colors: [color.opacity(a * 0.45), color.opacity(0)]),
                                                   center: CGPoint(x: x, y: y), startRadius: 0, endRadius: g))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(a)))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: c)
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY), control: c)
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: c)
        return p
    }
}

struct GlowSparkle: View {
    let size: CGFloat
    var color: Color = .white
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(0.6), color.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.7))
                .frame(width: size * 1.4, height: size * 1.4)
            Sparkle().fill(color).frame(width: size, height: size)
        }
    }
}

struct FivePointStar: Shape {
    var inner: CGFloat = 0.5
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        var p = Path()
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let rr = i % 2 == 0 ? R : R * inner
            let pt = CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct RidgeShape: Shape {
    let points: [CGPoint]
    var bottom: CGFloat = 1
    func path(in r: CGRect) -> Path {
        let pts = catmullRom(points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }, closed: false)
        var p = Path()
        p.addLines(pts)
        p.addLine(to: CGPoint(x: pts.last!.x, y: r.minY + bottom * r.height))
        p.addLine(to: CGPoint(x: pts.first!.x, y: r.minY + bottom * r.height))
        p.closeSubpath()
        return p
    }
}

/// Union of circles (normalised x, y, radius as fraction of width) with an optional flat base.
struct CloudShape: Shape {
    let circles: [(CGFloat, CGFloat, CGFloat)]
    var base: (CGFloat, CGFloat)? = nil
    var baseX: (CGFloat, CGFloat) = (-0.05, 1.05)
    func path(in r: CGRect) -> Path {
        var p = Path()
        for c in circles {
            let rad = c.2 * r.width
            p.addEllipse(in: CGRect(x: r.minX + c.0 * r.width - rad, y: r.minY + c.1 * r.height - rad, width: rad * 2, height: rad * 2))
        }
        if let base {
            let height = (base.1 - base.0) * r.height
            p.addRoundedRect(in: CGRect(x: r.minX + baseX.0 * r.width, y: r.minY + base.0 * r.height, width: (baseX.1 - baseX.0) * r.width, height: height),
                             cornerSize: CGSize(width: height / 2, height: height / 2))
        }
        return p
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 1 · 许愿灯 Wish Lanterns

struct LanternShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.17, 1))
        path.addQuadCurve(to: p(0.0, 0.2), control: p(-0.03, 0.6))
        path.addQuadCurve(to: p(0.2, 0.0), control: p(0.0, 0.01))
        path.addLine(to: p(0.8, 0.0))
        path.addQuadCurve(to: p(1.0, 0.2), control: p(1.0, 0.01))
        path.addQuadCurve(to: p(0.83, 1), control: p(1.03, 0.6))
        path.addQuadCurve(to: p(0.17, 1), control: p(0.5, 1.035))
        path.closeSubpath()
        return path
    }
}

struct LanternRibs: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.37, 0.02)); path.addQuadCurve(to: p(0.39, 0.99), control: p(0.33, 0.5))
        path.move(to: p(0.63, 0.02)); path.addQuadCurve(to: p(0.61, 0.99), control: p(0.67, 0.5))
        path.move(to: p(0.03, 0.17)); path.addQuadCurve(to: p(0.97, 0.17), control: p(0.5, 0.215))
        return path
    }
}

struct Lantern: View {
    let w: CGFloat
    var body: some View {
        let h = w * 1.22
        let paper = LinearGradient(stops: [
            .init(color: hex(0xC4452B), location: 0),
            .init(color: hex(0xEC7A38), location: 0.3),
            .init(color: hex(0xFFB65C), location: 0.7),
            .init(color: hex(0xFFE4A3), location: 1)], startPoint: .top, endPoint: .bottom)
        let flame = RadialGradient(colors: [hex(0xFFF8DD, 0.95), hex(0xFFE08A, 0.35), hex(0xFFE08A, 0)],
                                   center: UnitPoint(x: 0.5, y: 1.0), startRadius: 0, endRadius: h * 0.8)
        return ZStack {
            Circle().fill(RadialGradient(colors: [hex(0xFFB35E, 0.5), hex(0xFF7A3D, 0.14), hex(0xFF7A3D, 0)], center: .center, startRadius: 0, endRadius: w * 1.6))
                .frame(width: w * 3.2, height: w * 3.2).offset(y: h * 0.1)
            LanternShape().fill(hex(0xFF9443, 0.9)).frame(width: w, height: h).blur(radius: w * 0.15)
            LanternShape().fill(paper).frame(width: w, height: h)
            LanternShape().fill(flame).frame(width: w, height: h)
            LanternRibs().stroke(hex(0x9C3A1C, 0.22), lineWidth: max(1, w * 0.014)).frame(width: w, height: h)
            Capsule().fill(hex(0x6E2A14)).frame(width: w * 0.66, height: max(2, w * 0.05)).offset(y: h * 0.5)
            Ellipse().fill(hex(0xFFFBEA)).frame(width: w * 0.22, height: w * 0.1).blur(radius: w * 0.02).offset(y: h * 0.46)
        }
    }
}

struct LanternsIcon: View {
    let lanterns: [(CGFloat, CGFloat, CGFloat)] = [
        (0.50, 0.69, 16), (0.72, 0.665, 22), (0.31, 0.625, 26), (0.66, 0.085, 30), (0.07, 0.21, 28),
        (0.42, 0.115, 44), (0.13, 0.50, 54), (0.86, 0.53, 58), (0.81, 0.215, 70), (0.26, 0.28, 92), (0.56, 0.41, 168)]
    var body: some View {
        Tile {
            ZStack {
                LinearGradient(stops: [
                    .init(color: hex(0x120F33), location: 0),
                    .init(color: hex(0x2A2160), location: 0.3),
                    .init(color: hex(0x5E3775), location: 0.55),
                    .init(color: hex(0xB25F73), location: 0.7),
                    .init(color: hex(0xF0A06E), location: 0.79)], startPoint: .top, endPoint: .bottom)
                StarField(count: 90, seed: 11, yRange: 0...0.55, maxRadius: 2.2)
                RidgeShape(points: [CGPoint(x: -0.02, y: 0.735), CGPoint(x: 0.09, y: 0.69), CGPoint(x: 0.19, y: 0.715), CGPoint(x: 0.31, y: 0.65), CGPoint(x: 0.43, y: 0.705), CGPoint(x: 0.56, y: 0.685), CGPoint(x: 0.69, y: 0.635), CGPoint(x: 0.81, y: 0.695), CGPoint(x: 0.91, y: 0.67), CGPoint(x: 1.02, y: 0.715)], bottom: 0.8)
                    .fill(hex(0x3B2A5E))
                RidgeShape(points: [CGPoint(x: -0.02, y: 0.77), CGPoint(x: 0.15, y: 0.742), CGPoint(x: 0.31, y: 0.764), CGPoint(x: 0.5, y: 0.748), CGPoint(x: 0.7, y: 0.771), CGPoint(x: 0.86, y: 0.746), CGPoint(x: 1.02, y: 0.764)], bottom: 0.8)
                    .fill(hex(0x221A44))
                Rectangle().fill(LinearGradient(colors: [hex(0x7A4470), hex(0x2A1C48), hex(0x0F0B22)], startPoint: .top, endPoint: .bottom))
                    .frame(width: T, height: T * 0.21).at(0.5, 0.79 + 0.105)
                Capsule().fill(hex(0xFFB27A, 0.5)).frame(width: T, height: 3).blur(radius: 1.5).at(0.5, 0.79)
                ForEach(0..<lanterns.count, id: \.self) { i in
                    let l = lanterns[i]
                    Ellipse().fill(hex(0xFFB060, 0.08 + 0.3 * l.2 / 168))
                        .frame(width: l.2 * 0.45, height: l.2 * 1.1).blur(radius: 8)
                        .at(l.0, min(0.965, 0.81 + (0.79 - l.1) * 0.22))
                }
                ForEach(0..<9, id: \.self) { i in
                    let widths: [CGFloat] = [120, 60, 180, 90, 70, 140, 50, 100, 80]
                    let pos: [(CGFloat, CGFloat)] = [(0.3, 0.83), (0.7, 0.85), (0.52, 0.88), (0.18, 0.9), (0.85, 0.9), (0.4, 0.93), (0.62, 0.95), (0.2, 0.96), (0.8, 0.97)]
                    Capsule().fill(.white.opacity(0.1)).frame(width: widths[i], height: 2).at(pos[i].0, pos[i].1)
                }
                ForEach(0..<lanterns.count, id: \.self) { i in
                    let l = lanterns[i]
                    Lantern(w: l.2).blur(radius: max(0, (1 - l.2 / 168) * 1.4)).at(l.0, l.1)
                }
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - 2 · 星鲸 Star Whale

func whalePoint(_ r: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
    { x, y in CGPoint(x: r.minX + x * r.width / 1000, y: r.minY + y * r.height / 600) }
}

struct WhaleBody: Shape {
    func path(in r: CGRect) -> Path {
        let p = whalePoint(r)
        var path = Path()
        path.move(to: p(960, 300))
        path.addCurve(to: p(760, 150), control1: p(955, 215), control2: p(880, 158))
        path.addCurve(to: p(380, 190), control1: p(640, 140), control2: p(500, 150))
        path.addCurve(to: p(140, 300), control1: p(270, 225), control2: p(195, 268))
        path.addCurve(to: p(15, 185), control1: p(105, 272), control2: p(45, 215))
        path.addCurve(to: p(105, 322), control1: p(40, 255), control2: p(80, 305))
        path.addCurve(to: p(35, 450), control1: p(80, 360), control2: p(50, 420))
        path.addCurve(to: p(160, 345), control1: p(95, 410), control2: p(130, 365))
        path.addCurve(to: p(520, 440), control1: p(265, 405), control2: p(380, 448))
        path.addCurve(to: p(900, 360), control1: p(700, 432), control2: p(840, 402))
        path.addCurve(to: p(960, 300), control1: p(935, 338), control2: p(958, 320))
        path.closeSubpath()
        return path
    }
}

struct WhaleBelly: Shape {
    func path(in r: CGRect) -> Path {
        let p = whalePoint(r)
        var path = Path()
        path.move(to: p(990, 290))
        path.addCurve(to: p(600, 380), control1: p(930, 345), control2: p(760, 375))
        path.addCurve(to: p(200, 360), control1: p(440, 385), control2: p(300, 380))
        path.addLine(to: p(200, 600))
        path.addLine(to: p(990, 600))
        path.closeSubpath()
        return path
    }
}

struct WhaleGrooves: Shape {
    func path(in r: CGRect) -> Path {
        let p = whalePoint(r)
        var path = Path()
        for d in stride(from: CGFloat(16), through: 64, by: 16) {
            path.move(to: p(950, 312 + d))
            path.addCurve(to: p(600, 384 + d), control1: p(900, 350 + d), control2: p(760, 380 + d))
            path.addCurve(to: p(260, 372 + d), control1: p(440, 390 + d), control2: p(330, 386 + d))
        }
        return path
    }
}

struct WhaleFin: Shape {
    func path(in r: CGRect) -> Path {
        let p = whalePoint(r)
        var path = Path()
        path.move(to: p(650, 395))
        path.addCurve(to: p(500, 548), control1: p(640, 470), control2: p(575, 535))
        path.addCurve(to: p(570, 408), control1: p(520, 500), control2: p(540, 440))
        path.closeSubpath()
        return path
    }
}

struct StarWhale: View {
    let constellation: [CGPoint] = [CGPoint(x: 300, y: 262), CGPoint(x: 420, y: 228), CGPoint(x: 522, y: 282), CGPoint(x: 612, y: 222), CGPoint(x: 704, y: 262), CGPoint(x: 560, y: 345), CGPoint(x: 452, y: 330)]
    var body: some View {
        let bodyFill = LinearGradient(colors: [hex(0x141A52), hex(0x2B2C82), hex(0x5A3D9C)], startPoint: .top, endPoint: .bottom)
        return ZStack {
            WhaleBody().fill(hex(0xF3EEFF, 0.75)).blur(radius: 28)
            WhaleBody().fill(bodyFill)
            ZStack {
                Ellipse().fill(hex(0xFF8FD0, 0.45)).frame(width: 380, height: 200).blur(radius: 50).offset(x: -160, y: 20)
                Ellipse().fill(hex(0x7FD8FF, 0.35)).frame(width: 320, height: 160).blur(radius: 50).offset(x: 180, y: -50)
                StarField(count: 150, seed: 21, size: CGSize(width: 1000, height: 600), maxRadius: 2.8)
            }
            .frame(width: 1000, height: 600)
            .mask(WhaleBody())
            WhaleBelly().fill(hex(0xDCD4FF, 0.2)).mask(WhaleBody())
            WhaleGrooves().stroke(hex(0xFFFFFF, 0.2), lineWidth: 3).mask(WhaleBody())
            Path { path in
                let c = constellation
                path.addLines([c[0], c[1], c[2], c[3], c[4]])
                path.move(to: c[2]); path.addLines([c[2], c[5], c[6], c[2]])
            }
            .stroke(hex(0xFFFFFF, 0.4), lineWidth: 2)
            ForEach(0..<constellation.count, id: \.self) { i in
                GlowSparkle(size: i % 2 == 0 ? 26 : 18).position(constellation[i])
            }
            WhaleFin().fill(LinearGradient(colors: [hex(0x2E2F88), hex(0x5B42A6)], startPoint: .top, endPoint: .bottom))
            WhaleFin().stroke(hex(0xFFFFFF, 0.5), lineWidth: 2.5)
            WhaleBody().stroke(hex(0xFFFFFF, 0.65), lineWidth: 3)
            Circle().fill(.white).frame(width: 15, height: 15).shadow(color: .white, radius: 8).position(x: 800, y: 280)
        }
        .frame(width: 1000, height: 600)
    }
}

struct WhaleIcon: View {
    var body: some View {
        let cloudFill = LinearGradient(colors: [.white, hex(0xFBE2EC)], startPoint: .top, endPoint: .bottom)
        return Tile {
            ZStack {
                LinearGradient(stops: [
                    .init(color: hex(0x7FA8EA), location: 0),
                    .init(color: hex(0xBDB6F0), location: 0.45),
                    .init(color: hex(0xF4C4D3), location: 0.78),
                    .init(color: hex(0xFFE0C4), location: 1)], startPoint: .top, endPoint: .bottom)
                Circle().fill(RadialGradient(colors: [hex(0xFFF6EA, 0.9), hex(0xFFE9DA, 0)], center: .center, startRadius: 0, endRadius: 180))
                    .frame(width: 360, height: 360).at(0.8, 0.17)
                Circle().fill(hex(0xFFFCF4)).frame(width: 58, height: 58).at(0.8, 0.17)
                StarField(count: 26, seed: 3, yRange: 0...0.4, maxRadius: 1.8)
                CloudShape(circles: [(0.06, 0.82, 0.07), (0.19, 0.80, 0.09), (0.33, 0.83, 0.07), (0.6, 0.815, 0.08), (0.77, 0.79, 0.1), (0.93, 0.82, 0.08)], base: (0.83, 1))
                    .fill(hex(0xF3EAFF, 0.7)).frame(width: T, height: T)
                StarWhale().scaleEffect(0.7).rotationEffect(.degrees(-9)).at(0.5, 0.45)
                ForEach(0..<16, id: \.self) { i in
                    let t = CGFloat(i) / 15
                    Circle().fill(.white.opacity(0.85 - 0.6 * t)).frame(width: 9 - 6 * t, height: 9 - 6 * t)
                        .shadow(color: .white, radius: 4)
                        .at(0.15 - 0.17 * t + 0.03 * sin(t * 7), 0.56 + 0.22 * t)
                }
                ForEach(0..<8, id: \.self) { i in
                    let s: [(CGFloat, CGFloat, CGFloat)] = [(0.11, 0.58, 34), (0.05, 0.665, 20), (0.18, 0.69, 16), (0.09, 0.76, 11), (0.26, 0.61, 11), (0.9, 0.33, 24), (0.94, 0.43, 13), (0.3, 0.19, 18)]
                    GlowSparkle(size: s[i].2).at(s[i].0, s[i].1)
                }
                CloudShape(circles: [(0.0, 0.94, 0.11), (0.14, 0.895, 0.12), (0.3, 0.93, 0.1), (0.45, 0.885, 0.13), (0.61, 0.925, 0.11), (0.77, 0.89, 0.13), (0.93, 0.925, 0.12)], base: (0.94, 1.02))
                    .fill(cloudFill).frame(width: T, height: T)
                    .shadow(color: hex(0xC98FB8, 0.45), radius: 16, y: -2)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - 3 · 小星球 Tiny Planet

struct House: View {
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.55)).frame(width: 16, height: 16).offset(x: 31, y: -104)
            Circle().fill(.white.opacity(0.42)).frame(width: 22, height: 22).offset(x: 42, y: -126)
            Circle().fill(.white.opacity(0.28)).frame(width: 30, height: 30).offset(x: 58, y: -154)
            Rectangle().fill(hex(0xB8473A)).frame(width: 15, height: 34).offset(x: 26, y: -76)
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [hex(0xFFF6E8), hex(0xEBD3BA)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 86, height: 60).offset(y: -30)
            Triangle().fill(LinearGradient(colors: [hex(0xF4705A), hex(0xC4413A)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 114, height: 54).offset(y: -84)
            Circle().fill(hex(0xFFD36B, 0.7)).frame(width: 54, height: 54).blur(radius: 12).offset(x: -18, y: -32)
            RoundedRectangle(cornerRadius: 3).fill(hex(0xFFDA72)).frame(width: 22, height: 20).offset(x: -18, y: -34)
            RoundedRectangle(cornerRadius: 3).fill(hex(0x74463A)).frame(width: 18, height: 30).offset(x: 21, y: -15)
        }
    }
}

struct Tree: View {
    var body: some View {
        let leaf = LinearGradient(colors: [hex(0x9BEBB0), hex(0x2F9A6A)], startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack {
            RoundedRectangle(cornerRadius: 3).fill(hex(0x7A5236)).frame(width: 14, height: 46).offset(y: -23)
            Circle().fill(leaf).frame(width: 58, height: 58).offset(x: -24, y: -58)
            Circle().fill(leaf).frame(width: 58, height: 58).offset(x: 24, y: -60)
            Circle().fill(leaf).frame(width: 74, height: 74).offset(y: -88)
            Circle().fill(hex(0xFF8A7A)).frame(width: 9, height: 9).offset(x: -12, y: -96)
            Circle().fill(hex(0xFF8A7A)).frame(width: 8, height: 8).offset(x: 18, y: -70)
            Circle().fill(hex(0xFF8A7A)).frame(width: 7, height: 7).offset(x: -30, y: -60)
        }
    }
}

struct PlanetIcon: View {
    let c = CGPoint(x: 412, y: 500)
    let R: CGFloat = 205
    var ring: some View {
        ZStack {
            Ellipse().stroke(LinearGradient(colors: [hex(0xFFE2B0, 0.9), hex(0xF5A27F, 0.9), hex(0xD48BE0, 0.85)], startPoint: .leading, endPoint: .trailing), lineWidth: 22)
                .frame(width: 690, height: 150)
            Ellipse().stroke(hex(0xFFF0D8, 0.5), lineWidth: 5).frame(width: 618, height: 122)
        }
        .frame(width: 720, height: 170)
    }
    var planet: some View {
        ZStack {
            Circle().fill(hex(0x7CF2D0, 0.35)).frame(width: R * 2 + 60, height: R * 2 + 60).blur(radius: 28)
            Circle().fill(RadialGradient(stops: [
                .init(color: hex(0xB8F7D6), location: 0), .init(color: hex(0x5CCB9F), location: 0.4),
                .init(color: hex(0x2E8C80), location: 0.78), .init(color: hex(0x1D5469), location: 1)],
                center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: R * 1.7))
                .frame(width: R * 2, height: R * 2)
            ZStack {
                Ellipse().fill(hex(0x3FAE86, 0.55)).frame(width: 150, height: 70).offset(x: -70, y: 40)
                Ellipse().fill(hex(0x3FAE86, 0.5)).frame(width: 110, height: 60).offset(x: 90, y: -30)
                Ellipse().fill(hex(0x3FAE86, 0.45)).frame(width: 130, height: 50).offset(x: 40, y: 130)
                Circle().stroke(hex(0x247566, 0.35), lineWidth: 5).frame(width: 34, height: 34).offset(x: -110, y: -60)
                Circle().stroke(hex(0x247566, 0.35), lineWidth: 4).frame(width: 22, height: 22).offset(x: 120, y: 70)
            }
            .frame(width: R * 2, height: R * 2).mask(Circle())
            Circle().fill(LinearGradient(colors: [.clear, hex(0x0B1233, 0.5)], startPoint: UnitPoint(x: 0.3, y: 0.2), endPoint: UnitPoint(x: 0.9, y: 0.95)))
                .frame(width: R * 2, height: R * 2)
            Circle().stroke(LinearGradient(colors: [.clear, hex(0xC9FFF4, 0.75)], startPoint: .leading, endPoint: .trailing), lineWidth: 5)
                .frame(width: R * 2, height: R * 2).blur(radius: 1.5)
        }
    }
    var body: some View {
        Tile {
            ZStack {
                LinearGradient(colors: [hex(0x0B1233), hex(0x1A2560), hex(0x352F78)], startPoint: .top, endPoint: .bottom)
                Circle().fill(hex(0x8E5BD6, 0.4)).frame(width: 520, height: 520).blur(radius: 90).at(0.12, 0.22)
                Circle().fill(hex(0x3FB6C9, 0.25)).frame(width: 420, height: 420).blur(radius: 80).at(0.92, 0.72)
                StarField(count: 120, seed: 5, maxRadius: 2.3)
                Capsule().fill(LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 170, height: 4).rotationEffect(.degrees(28)).at(0.2, 0.15)
                GlowSparkle(size: 22).at(0.29, 0.205)
                ZStack {
                    Circle().fill(LinearGradient(colors: [hex(0xFFE4C8), hex(0xF2A98A)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 66, height: 66)
                    Circle().fill(hex(0xE59479, 0.6)).frame(width: 12, height: 12).offset(x: -10, y: 8)
                    Circle().fill(hex(0xE59479, 0.5)).frame(width: 8, height: 8).offset(x: 12, y: -10)
                }
                .shadow(color: hex(0xFFD2B0, 0.6), radius: 14).at(0.82, 0.16)
                ring.rotationEffect(.degrees(-14)).position(c)
                planet.position(c)
                ZStack { House().offset(y: -R + 4) }.frame(width: 10, height: 10).rotationEffect(.degrees(-17)).position(c)
                ZStack { Tree().offset(y: -R + 4) }.frame(width: 10, height: 10).rotationEffect(.degrees(22)).position(c)
                ring.mask(VStack(spacing: 0) { Color.clear; Color.black }).rotationEffect(.degrees(-14)).position(c)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - 4 · 锦鲤 Koi Pond

struct KoiPath {
    let center: CGPoint
    let radius: CGFloat
    let start: CGFloat
    var scale: CGFloat = 1.12
    func warp(_ p: CGPoint) -> CGPoint {
        let theta = start + p.x * scale / radius
        let r = radius + p.y * scale
        return CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
    }
    func shape(_ local: [CGPoint]) -> PolyShape { PolyShape(points: catmullRom(local, closed: true, samples: 12).map(warp)) }
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> PolyShape {
        PolyShape(points: (0..<60).map { i in
            let a = CGFloat(i) / 60 * 2 * .pi
            return warp(CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a)))
        })
    }
}

let koiBody: [CGPoint] = [
    CGPoint(x: 362, y: 0), CGPoint(x: 354, y: 17), CGPoint(x: 334, y: 31), CGPoint(x: 298, y: 41), CGPoint(x: 252, y: 43),
    CGPoint(x: 203, y: 37), CGPoint(x: 153, y: 27), CGPoint(x: 108, y: 16), CGPoint(x: 72, y: 9), CGPoint(x: 52, y: 6),
    CGPoint(x: 52, y: -6), CGPoint(x: 72, y: -9), CGPoint(x: 108, y: -16), CGPoint(x: 153, y: -27), CGPoint(x: 203, y: -37),
    CGPoint(x: 252, y: -43), CGPoint(x: 298, y: -41), CGPoint(x: 334, y: -31), CGPoint(x: 354, y: -17)]
let koiTail: [CGPoint] = [
    CGPoint(x: 70, y: 7), CGPoint(x: 44, y: 24), CGPoint(x: 14, y: 46), CGPoint(x: -18, y: 62), CGPoint(x: -32, y: 48), CGPoint(x: -8, y: 20),
    CGPoint(x: 4, y: 0), CGPoint(x: -8, y: -20), CGPoint(x: -32, y: -48), CGPoint(x: -18, y: -62), CGPoint(x: 14, y: -46), CGPoint(x: 44, y: -24), CGPoint(x: 70, y: -7)]
let koiTailCore: [CGPoint] = [
    CGPoint(x: 70, y: 5), CGPoint(x: 42, y: 18), CGPoint(x: 16, y: 32), CGPoint(x: 4, y: 22), CGPoint(x: 14, y: 0),
    CGPoint(x: 4, y: -22), CGPoint(x: 16, y: -32), CGPoint(x: 42, y: -18), CGPoint(x: 70, y: -5)]
/// A rounded fan fin attached at body half-width `edge`, sweeping back from `x`.
func koiFin(_ side: CGFloat, x: CGFloat, edge: CGFloat, size: CGFloat) -> [CGPoint] {
    [CGPoint(x: x, y: side * edge), CGPoint(x: x - 6 * size, y: side * (edge + 22 * size)), CGPoint(x: x - 24 * size, y: side * (edge + 40 * size)),
     CGPoint(x: x - 48 * size, y: side * (edge + 40 * size)), CGPoint(x: x - 60 * size, y: side * (edge + 22 * size)), CGPoint(x: x - 40 * size, y: side * (edge + 2))]
}

struct KoiView: View {
    let path: KoiPath
    let bodyStops: [Gradient.Stop]
    let patches: [(CGFloat, CGFloat, CGFloat, CGFloat)]
    let patchColor: Color
    let finTint: Color
    var body: some View {
        let unit = UnitPoint(x: path.center.x / T, y: path.center.y / T)
        let shade = RadialGradient(stops: bodyStops, center: unit, startRadius: path.radius - 42, endRadius: path.radius + 42)
        let fin = RadialGradient(colors: [finTint.opacity(0.7), .white.opacity(0.22)], center: unit, startRadius: path.radius - 70, endRadius: path.radius + 70)
        let fins = [koiFin(1, x: 296, edge: 38, size: 1), koiFin(-1, x: 296, edge: 38, size: 1), koiFin(1, x: 176, edge: 28, size: 0.62), koiFin(-1, x: 176, edge: 28, size: 0.62)]
        return ZStack {
            ZStack {
                path.shape(koiBody).fill(.black)
                path.shape(koiTail).fill(.black)
                ForEach(0..<fins.count, id: \.self) { i in path.shape(fins[i]).fill(.black) }
            }
            .opacity(0.32).blur(radius: 10).offset(x: 16, y: 22)
            ForEach(0..<fins.count, id: \.self) { i in path.shape(fins[i]).fill(fin).blur(radius: 0.8) }
            path.shape(koiTail).fill(.white.opacity(0.32)).blur(radius: 0.8)
            path.shape(koiTailCore).fill(finTint.opacity(0.55)).blur(radius: 3)
            path.shape(koiBody).fill(shade)
            ZStack {
                ForEach(0..<patches.count, id: \.self) { i in
                    let p = patches[i]
                    path.ellipse(p.0, p.1, p.2, p.3).fill(patchColor)
                }
                path.ellipse(220, 0, 120, 7).fill(.white.opacity(0.35)).blur(radius: 5)
                path.ellipse(200, 0, 70, 2.5).fill(.black.opacity(0.12)).blur(radius: 1.5)
            }
            .mask(path.shape(koiBody))
            path.shape(koiBody).stroke(.black.opacity(0.12), lineWidth: 1.5)
            path.ellipse(338, 14, 4.5, 4.5).fill(hex(0x1C1C1C))
            path.ellipse(338, -14, 4.5, 4.5).fill(hex(0x1C1C1C))
        }
        .frame(width: T, height: T)
    }
}

struct LilyPad: View {
    let size: CGFloat
    var flower = false
    var body: some View {
        ZStack {
            NotchedPad().fill(.black.opacity(0.3)).frame(width: size, height: size).blur(radius: 10).offset(x: 10, y: 16)
            NotchedPad().fill(RadialGradient(colors: [hex(0x9BDB72), hex(0x55A84A), hex(0x2F7A3A)], center: .center, startRadius: 0, endRadius: size / 2))
                .frame(width: size, height: size)
            Path { p in
                let r = size / 2
                for a in stride(from: -60.0, through: 240.0, by: 30.0) {
                    p.move(to: CGPoint(x: r, y: r))
                    p.addLine(to: CGPoint(x: r + r * 0.86 * cos(a * .pi / 180), y: r + r * 0.86 * sin(a * .pi / 180)))
                }
            }
            .stroke(hex(0x2C6B30, 0.35), lineWidth: 2)
            .frame(width: size, height: size)
            NotchedPad().stroke(hex(0xD7F7B5, 0.35), lineWidth: 2).frame(width: size - 4, height: size - 4)
            if flower { Lotus().scaleEffect(size / 230) }
        }
    }
}

struct NotchedPad: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2, c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: r, startAngle: .degrees(-70), endAngle: .degrees(-110), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct Lotus: View {
    var body: some View {
        let petal = LinearGradient(colors: [hex(0xFF6F9E), hex(0xFFC4D8), hex(0xFFF6F8)], startPoint: .top, endPoint: .bottom)
        return ZStack {
            Circle().fill(hex(0xFFB3CC, 0.5)).frame(width: 150, height: 150).blur(radius: 24)
            ForEach(0..<8, id: \.self) { i in
                Ellipse().fill(petal).frame(width: 46, height: 92).offset(y: -40).rotationEffect(.degrees(Double(i) * 45 + 22))
            }
            ForEach(0..<6, id: \.self) { i in
                Ellipse().fill(petal).frame(width: 34, height: 64).offset(y: -26).rotationEffect(.degrees(Double(i) * 60))
                    .shadow(color: hex(0xC2406E, 0.3), radius: 4)
            }
            Circle().fill(RadialGradient(colors: [hex(0xFFE58A), hex(0xF5B53D)], center: .center, startRadius: 0, endRadius: 16)).frame(width: 30, height: 30)
        }
    }
}

struct KoiIcon: View {
    var body: some View {
        let center = CGPoint(x: 412, y: 430)
        let kohaku = [Gradient.Stop(color: hex(0xD9D2C8), location: 0), Gradient.Stop(color: hex(0xFFFBF5), location: 0.5), Gradient.Stop(color: hex(0xD9D2C8), location: 1)]
        let gold = [Gradient.Stop(color: hex(0xD9822A), location: 0), Gradient.Stop(color: hex(0xFFD36A), location: 0.5), Gradient.Stop(color: hex(0xD9822A), location: 1)]
        return Tile(grain: 0.05) {
            ZStack {
                RadialGradient(colors: [hex(0x2E9A98), hex(0x166170), hex(0x0A2E3E)], center: UnitPoint(x: 0.42, y: 0.38), startRadius: 0, endRadius: 620)
                ForEach(0..<4, id: \.self) { i in
                    let p: [(CGFloat, CGFloat, CGFloat)] = [(0.3, 0.25, 260), (0.7, 0.6, 220), (0.2, 0.75, 180), (0.85, 0.2, 160)]
                    Ellipse().fill(.white.opacity(0.06)).frame(width: p[i].2, height: p[i].2 * 0.6).blur(radius: 30).at(p[i].0, p[i].1)
                }
                ForEach(0..<3, id: \.self) { i in
                    Ellipse().stroke(.white.opacity(0.16 - Double(i) * 0.04), lineWidth: 2)
                        .frame(width: 70 + CGFloat(i) * 70, height: (70 + CGFloat(i) * 70) * 0.55).at(0.66, 0.16)
                }
                KoiView(path: KoiPath(center: center, radius: 168, start: -2.9), bodyStops: kohaku,
                        patches: [(318, 2, 34, 22), (238, -6, 46, 28), (150, 10, 32, 17)], patchColor: hex(0xE4462E), finTint: hex(0xFFE9E0))
                KoiView(path: KoiPath(center: center, radius: 168, start: 0.24), bodyStops: gold,
                        patches: [(300, -8, 24, 14), (190, 12, 30, 12)], patchColor: hex(0x2A1A10, 0.75), finTint: hex(0xFFD58A))
                LilyPad(size: 240, flower: true).at(0.82, 0.83)
                LilyPad(size: 170).rotationEffect(.degrees(120)).at(0.11, 0.14)
                LilyPad(size: 96).rotationEffect(.degrees(40)).at(0.32, 0.92)
                LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .center)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - 5 · 水母 Moon Jelly

struct Bell: Shape {
    var scallops = 8
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0, 0.82))
        path.addCurve(to: p(0.5, 0), control1: p(-0.02, 0.28), control2: p(0.2, 0))
        path.addCurve(to: p(1, 0.82), control1: p(0.8, 0), control2: p(1.02, 0.28))
        for i in 0..<scallops {
            let x0 = 1 - CGFloat(i) / CGFloat(scallops), x1 = 1 - CGFloat(i + 1) / CGFloat(scallops)
            path.addQuadCurve(to: p(x1, 0.82), control: p((x0 + x1) / 2, 0.98))
        }
        path.closeSubpath()
        return path
    }
}

struct Tentacles: Shape {
    let starts: [CGPoint]
    let length: CGFloat
    let amplitude: CGFloat
    let seed: UInt64
    func path(in r: CGRect) -> Path {
        var rng = RNG(seed)
        var p = Path()
        for s in starts {
            let phase = rng.next() * 6.28, freq = 1.0 + rng.next() * 1.1
            let len = length * (0.65 + 0.35 * rng.next()), drift = (rng.next() - 0.5) * amplitude * 1.4
            for i in 0...80 {
                let t = CGFloat(i) / 80
                let pt = CGPoint(x: s.x + sin(t * freq * 2 * .pi + phase) * amplitude * t + drift * t, y: s.y + len * t)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        return p
    }
}

struct Jellyfish: View {
    let w: CGFloat
    let core: UInt32, mid: UInt32, edge: UInt32, glow: UInt32
    var seed: UInt64 = 1
    var body: some View {
        let h = w * 0.66, L = w * 1.15
        let W = w * 1.5, H = h + L
        let left = (W - w) / 2
        let rim = (0...8).map { CGPoint(x: left + w * CGFloat($0) / 8, y: h * 0.84) }
        let arms = [0.42, 0.5, 0.58].map { CGPoint(x: left + w * $0, y: h * 0.7) }
        let frills = [0.4, 0.43, 0.46, 0.49, 0.51, 0.54, 0.57, 0.6].map { CGPoint(x: left + w * $0, y: h * 0.72) }
        let fade = LinearGradient(colors: [hex(glow, 0.85), hex(glow, 0)], startPoint: UnitPoint(x: 0.5, y: h * 0.8 / H), endPoint: .bottom)
        let bellFill = RadialGradient(stops: [
            .init(color: hex(core, 0.95), location: 0), .init(color: hex(mid, 0.75), location: 0.45),
            .init(color: hex(edge, 0.45), location: 0.85), .init(color: hex(edge, 0.25), location: 1)],
            center: UnitPoint(x: 0.5, y: 0.25), startRadius: 0, endRadius: w * 0.62)
        return ZStack {
            Tentacles(starts: rim, length: L, amplitude: w * 0.07, seed: seed).stroke(fade, style: StrokeStyle(lineWidth: max(1, w * 0.008), lineCap: .round))
            Tentacles(starts: arms, length: L * 0.72, amplitude: w * 0.08, seed: seed + 7).stroke(fade, style: StrokeStyle(lineWidth: w * 0.07, lineCap: .round)).opacity(0.18).blur(radius: w * 0.01)
            Tentacles(starts: frills, length: L * 0.7, amplitude: w * 0.08, seed: seed + 11).stroke(fade, style: StrokeStyle(lineWidth: max(1, w * 0.006), lineCap: .round)).opacity(0.85)
            ZStack {
                Bell().fill(hex(glow, 0.6)).frame(width: w, height: h).blur(radius: w * 0.13)
                Bell().fill(bellFill).frame(width: w, height: h)
                Bell().fill(RadialGradient(colors: [.clear, hex(edge, 0.35)], center: UnitPoint(x: 0.5, y: 0.3), startRadius: w * 0.25, endRadius: w * 0.62))
                    .frame(width: w, height: h)
                Ellipse().fill(RadialGradient(colors: [hex(core, 0.55), hex(core, 0)], center: .center, startRadius: 0, endRadius: w * 0.26))
                    .frame(width: w * 0.56, height: h * 0.62).offset(y: h * 0.02)
                Bell().stroke(.white.opacity(0.3), lineWidth: max(1, w * 0.006)).frame(width: w, height: h).blur(radius: 1)
                Ellipse().fill(.white.opacity(0.38)).frame(width: w * 0.4, height: h * 0.16).blur(radius: w * 0.03).offset(x: -w * 0.1, y: -h * 0.3)
            }
            .frame(width: w, height: h)
            .position(x: W / 2, y: h / 2)
        }
        .frame(width: W, height: H)
    }
}

struct JellyIcon: View {
    var body: some View {
        Tile {
            ZStack {
                LinearGradient(stops: [.init(color: hex(0x0F4467), location: 0), .init(color: hex(0x08254A), location: 0.5), .init(color: hex(0x050B22), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(0..<4, id: \.self) { i in
                    let xs: [CGFloat] = [0.18, 0.38, 0.58, 0.78]
                    Path { p in
                        let x = xs[i] * T
                        p.move(to: CGPoint(x: x - 18, y: -10)); p.addLine(to: CGPoint(x: x + 18, y: -10))
                        p.addLine(to: CGPoint(x: x + 90 + CGFloat(i) * 20, y: 640)); p.addLine(to: CGPoint(x: x - 40 + CGFloat(i) * 20, y: 640))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [.white.opacity(0.13), .clear], startPoint: .top, endPoint: .bottom))
                    .blur(radius: 16)
                }
                StarField(count: 80, seed: 9, maxRadius: 2.6, color: hex(0x9FF6FF))
                Jellyfish(w: 140, core: 0xE6FFFF, mid: 0x8FEFFF, edge: 0x3D8BFF, glow: 0x6FE3FF, seed: 4).blur(radius: 2.5).at(0.2, 0.68)
                Jellyfish(w: 104, core: 0xE6FFFF, mid: 0x8FEFFF, edge: 0x3D8BFF, glow: 0x6FE3FF, seed: 9).blur(radius: 3.5).at(0.84, 0.73)
                Jellyfish(w: 380, core: 0xFFE3F8, mid: 0xF27AD9, edge: 0x7C5CFF, glow: 0xFF7BE2, seed: 2).at(0.5, 0.53)
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - 6 · 纸山 Paper Dusk

struct WaveLayer: Shape {
    let base: CGFloat
    let waves: [(CGFloat, CGFloat, CGFloat)]
    func path(in r: CGRect) -> Path {
        var p = Path()
        let steps = 120
        for i in 0...steps {
            let x = -0.02 + 1.04 * CGFloat(i) / CGFloat(steps)
            var y = base
            for w in waves { y += w.0 * sin(2 * .pi * w.1 * x + w.2) }
            let pt = CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.addLine(to: CGPoint(x: r.maxX + 20, y: r.maxY + 20))
        p.addLine(to: CGPoint(x: r.minX - 20, y: r.maxY + 20))
        p.closeSubpath()
        return p
    }
}

struct PaperIcon: View {
    let layers: [(CGFloat, [(CGFloat, CGFloat, CGFloat)], UInt32)] = [
        (0.50, [(0.035, 1.3, 0.4), (0.015, 3.1, 1.2)], 0xF6ABA0),
        (0.57, [(0.04, 1.1, 2.0), (0.012, 3.7, 0.3)], 0xEC8E97),
        (0.645, [(0.035, 1.5, 4.1), (0.014, 2.9, 2.2)], 0xD5728F),
        (0.72, [(0.03, 1.2, 1.1), (0.016, 3.3, 0.9)], 0xAE5D8B),
        (0.795, [(0.032, 1.4, 3.0), (0.012, 4.1, 1.7)], 0x7C4C82),
        (0.87, [(0.026, 1.1, 5.0), (0.014, 3.6, 0.2)], 0x4D3E73),
        (0.94, [(0.02, 1.6, 2.4), (0.01, 4.4, 1.1)], 0x2A2C56)]
    func y(_ i: Int, _ x: CGFloat) -> CGFloat {
        var v = layers[i].0
        for w in layers[i].1 { v += w.0 * sin(2 * .pi * w.1 * x + w.2) }
        return v
    }
    var body: some View {
        Tile(grain: 0.12) {
            ZStack {
                LinearGradient(colors: [hex(0xF9A9A2), hex(0xFFCFA8), hex(0xFFE9C6)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
                Circle().fill(RadialGradient(colors: [hex(0xFFF6DF, 0.9), hex(0xFFE6C0, 0)], center: .center, startRadius: 100, endRadius: 260))
                    .frame(width: 520, height: 520).at(0.5, 0.47)
                Circle().fill(hex(0xFFF5DC)).frame(width: 230, height: 230).at(0.5, 0.47)
                    .shadow(color: hex(0xD98A7A, 0.35), radius: 10, y: 4)
                CloudShape(circles: [(0.25, 0.6, 0.18), (0.45, 0.45, 0.24), (0.68, 0.6, 0.17)], base: (0.6, 0.96), baseX: (0.06, 0.86))
                    .fill(hex(0xFFF3E6)).frame(width: 190, height: 80).shadow(color: hex(0xB0606A, 0.35), radius: 8, y: 6).at(0.2, 0.2)
                CloudShape(circles: [(0.3, 0.6, 0.2), (0.55, 0.42, 0.25), (0.75, 0.62, 0.16)], base: (0.62, 0.98), baseX: (0.1, 0.92))
                    .fill(hex(0xFFF3E6)).frame(width: 150, height: 64).shadow(color: hex(0xB0606A, 0.35), radius: 8, y: 6).at(0.8, 0.3)
                ForEach(0..<3, id: \.self) { i in
                    let b: [(CGFloat, CGFloat, CGFloat)] = [(0.64, 0.25, 1), (0.7, 0.21, 0.7), (0.6, 0.19, 0.55)]
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 6)); p.addQuadCurve(to: CGPoint(x: 18, y: 6), control: CGPoint(x: 9, y: -4))
                        p.addQuadCurve(to: CGPoint(x: 36, y: 6), control: CGPoint(x: 27, y: -4))
                    }
                    .stroke(hex(0x6B3A5E), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 36, height: 12).scaleEffect(b[i].2).at(b[i].0, b[i].1)
                }
                ForEach(0..<layers.count, id: \.self) { i in
                    WaveLayer(base: layers[i].0, waves: layers[i].1).fill(hex(layers[i].2))
                        .shadow(color: hex(0x3A1F3D, 0.35), radius: 12, y: -5)
                }
                ForEach(0..<7, id: \.self) { i in
                    let xs: [CGFloat] = [0.08, 0.13, 0.19, 0.72, 0.78, 0.83, 0.9]
                    let hs: [CGFloat] = [70, 96, 60, 64, 104, 78, 58]
                    let ly = y(6, xs[i])
                    ZStack {
                        Triangle().fill(hex(0x2A2C56)).frame(width: hs[i] * 0.62, height: hs[i] * 0.6).offset(y: -hs[i] * 0.62)
                        Triangle().fill(hex(0x2A2C56)).frame(width: hs[i] * 0.8, height: hs[i] * 0.66).offset(y: -hs[i] * 0.34)
                    }
                    .shadow(color: hex(0x3A1F3D, 0.3), radius: 8, y: -3)
                    .at(xs[i], ly + 0.012)
                }
            }
            .frame(width: T, height: T)
        }
    }
}

// MARK: - 7 · 钓星猫 Star-fishing Cat

struct CatShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width / 200, y: r.minY + y * r.height / 260) }
        var path = Path()
        path.move(to: p(22, 260))
        path.addCurve(to: p(62, 122), control1: p(2, 222), control2: p(20, 152))
        path.addQuadCurve(to: p(96, 78), control: p(80, 102))
        path.addQuadCurve(to: p(102, 42), control: p(92, 58))
        path.addLine(to: p(110, 2))
        path.addLine(to: p(138, 30))
        path.addQuadCurve(to: p(152, 29), control: p(145, 27))
        path.addLine(to: p(176, 4))
        path.addLine(to: p(184, 46))
        path.addQuadCurve(to: p(190, 82), control: p(196, 62))
        path.addQuadCurve(to: p(164, 106), control: p(188, 102))
        path.addCurve(to: p(160, 238), control1: p(150, 142), control2: p(172, 200))
        path.addQuadCurve(to: p(180, 260), control: p(170, 258))
        path.closeSubpath()
        return path
    }
}

struct CatIcon: View {
    var body: some View {
        let moon = Path(ellipseIn: CGRect(x: 360 - 250, y: 430 - 250, width: 500, height: 500))
            .subtracting(Path(ellipseIn: CGRect(x: 500 - 215, y: 345 - 215, width: 430, height: 430)))
        let catBox = CGRect(x: 400, y: 560 - 208, width: 160, height: 208)
        return Tile {
            ZStack {
                LinearGradient(colors: [hex(0x0D1940), hex(0x203268), hex(0x3B4A8A)], startPoint: .top, endPoint: .bottom)
                StarField(count: 110, seed: 13, maxRadius: 2.4)
                Ellipse().fill(hex(0xA7B7FF, 0.12)).frame(width: 420, height: 60).blur(radius: 14).at(0.75, 0.82)
                Ellipse().fill(hex(0xA7B7FF, 0.1)).frame(width: 300, height: 46).blur(radius: 12).at(0.22, 0.9)
                Circle().fill(RadialGradient(colors: [hex(0xFFE9B8, 0.32), hex(0x9DB2FF, 0.12), hex(0x9DB2FF, 0)], center: .center, startRadius: 180, endRadius: 420))
                    .frame(width: 800, height: 800).at(360 / T, 430 / T)
                moon.fill(LinearGradient(colors: [hex(0xFFF1C4), hex(0xFFD36E), hex(0xF2A93B)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: T, height: T)
                    .shadow(color: hex(0xFFD36E, 0.7), radius: 30)
                ZStack {
                    Circle().fill(hex(0xE9A23C, 0.45)).frame(width: 40, height: 40).position(x: 190, y: 560)
                    Circle().fill(hex(0xE9A23C, 0.35)).frame(width: 26, height: 26).position(x: 250, y: 620)
                    Circle().fill(hex(0xE9A23C, 0.35)).frame(width: 18, height: 18).position(x: 160, y: 470)
                }
                .frame(width: T, height: T).mask(moon.frame(width: T, height: T))
                Path { p in
                    p.move(to: CGPoint(x: 418, y: 556))
                    p.addCurve(to: CGPoint(x: 380, y: 640), control1: CGPoint(x: 370, y: 566), control2: CGPoint(x: 352, y: 610))
                    p.addQuadCurve(to: CGPoint(x: 420, y: 660), control: CGPoint(x: 398, y: 666))
                }
                .stroke(hex(0x10162F), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: 534, y: 470)); p.addLine(to: CGPoint(x: 712, y: 262))
                }
                .stroke(hex(0xC99A5B), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: 712, y: 262)); p.addQuadCurve(to: CGPoint(x: 706, y: 560), control: CGPoint(x: 726, y: 420))
                }
                .stroke(.white.opacity(0.7), lineWidth: 1.6)
                Circle().fill(RadialGradient(colors: [hex(0xFFE7A0, 0.8), hex(0xFFE7A0, 0)], center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140).position(x: 706, y: 590)
                FivePointStar().fill(LinearGradient(colors: [hex(0xFFF6CF), hex(0xFFC94A)], startPoint: .top, endPoint: .bottom))
                    .overlay(FivePointStar().stroke(hex(0xFFF6CF), style: StrokeStyle(lineWidth: 6, lineJoin: .round)))
                    .frame(width: 66, height: 66).rotationEffect(.degrees(12)).position(x: 706, y: 590)
                CatShape().fill(hex(0x10162F)).frame(width: catBox.width, height: catBox.height).position(x: catBox.midX, y: catBox.midY)
                CatShape().stroke(hex(0xFFE3A0, 0.55), lineWidth: 2.5).frame(width: catBox.width, height: catBox.height).position(x: catBox.midX, y: catBox.midY)
                    .blur(radius: 1)
                Circle().fill(hex(0xFFE7A0)).frame(width: 7, height: 7).position(x: catBox.minX + 172 * 0.8, y: catBox.minY + 62 * 0.8)
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
            ("1-wish-lanterns", "1 许愿灯", AnyView(LanternsIcon())),
            ("2-star-whale", "2 星鲸", AnyView(WhaleIcon())),
            ("3-tiny-planet", "3 小星球", AnyView(PlanetIcon())),
            ("4-koi-pond", "4 锦鲤", AnyView(KoiIcon())),
            ("5-moon-jelly", "5 水母", AnyView(JellyIcon())),
            ("6-paper-dusk", "6 纸山", AnyView(PaperIcon())),
            ("7-star-fishing-cat", "7 钓星猫", AnyView(CatIcon()))]
        let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
        var images: [NSImage] = []
        for (file, _, view) in items {
            if let only, !file.hasPrefix(only) { continue }
            let r = ImageRenderer(content: view.frame(width: 1024, height: 1024))
            r.scale = 1
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fatalError(file) }
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(file).png"))
            images.append(img)
            print("rendered", file)
        }
        guard only == nil else { return }
        let sheet = VStack(spacing: 34) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 30) {
                    ForEach(0..<(row == 0 ? 4 : 3), id: \.self) { col in
                        let i = row * 4 + col
                        VStack(spacing: 12) {
                            Image(nsImage: images[i]).resizable().frame(width: 300, height: 300)
                            HStack(spacing: 18) {
                                Image(nsImage: images[i]).resizable().frame(width: 64, height: 64)
                                Image(nsImage: images[i]).resizable().frame(width: 32, height: 32)
                            }
                            Text(items[i].1).font(.system(size: 24, weight: .semibold))
                        }
                    }
                }
            }
        }
        .padding(40)
        .background(Color(white: 0.95))
        let r = ImageRenderer(content: sheet)
        r.scale = 1
        try NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(out)/sheet.png"))
    }
}
