import AppKit
import SwiftUI

/// The LCX Mixer visual: the app's icon and name above a tilted field of square tiles that rise and
/// fall like level meters, coloured green → yellow → red, fading into the bottom edge.
/// Shown in the welcome window, About and (small, without the title) at the bottom of Settings.
struct TowerVisual: View {
    /// Icons of apps and websites on this Mac, shown in one grey tone on the liveliest tiles.
    var icons: [NSImage] = []
    var showsTitle = true
    /// Frames per second while visible; the small Settings thumbnail needs fewer.
    var fps: Double = 60

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var field = TowerField()
    @State private var visible = false

    var body: some View {
        let palette = TowerPalette(dark: scheme == .dark)
        // Drawn only while its window can be seen; closed or hidden windows cost nothing.
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: reduceMotion || !visible)) { timeline in
            Canvas { context, size in
                let levels = reduceMotion ? field.stillLevels : field.levels(at: timeline.date)
                TowerRenderer(field: field, levels: levels, palette: palette, icons: icons, showsTitle: showsTitle)
                    .draw(in: &context, size: size)
            }
        }
        .overlay(alignment: .top) {
            if showsTitle {
                GeometryReader { geo in
                    let h = geo.size.height
                    VStack(spacing: h * 0.035) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: h * 0.19, height: h * 0.19)
                            .shadow(color: .black.opacity(palette.dark ? 0.5 : 0.15), radius: h * 0.02, y: h * 0.008)
                        Text("LCX MIXER")
                            .font(.system(size: h * 0.052, weight: .medium))
                            .tracking(h * 0.018)
                            .foregroundStyle(palette.title)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, h * 0.075)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("LCX Mixer")
            }
        }
        .background(palette.background)
        .background(WindowVisibilityProbe(visible: $visible))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("LCX Mixer: tiles rising and falling like level meters")
    }
}

/// Collects the icons for the visual: what's playing first, then other open apps. Local only.
/// Each icon is turned into a small grey bitmap once and kept, keyed by its app or source, so
/// nothing is converted or filtered while the visual animates.
@MainActor
enum TowerIcons {
    private static var cache: [String: NSImage] = [:]

    static func collect(from core: MixerCore, limit: Int = 10) -> [NSImage] {
        var picked: [(key: String, image: NSImage)] = core.sources.values
            .sorted { $0.displayName < $1.displayName }
            .compactMap { s in s.icon.map { ("source:" + s.rememberKey, $0) } }
        let own = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard picked.count < limit, let id = app.bundleIdentifier, id != own else { continue }
            let key = "app:" + id
            // Only ask for the icon when it isn't grey-cached yet: each request makes a new image.
            if let cached = cache[key] { picked.append((key, cached)) } else if let icon = app.icon { picked.append((key, icon)) }
        }
        return picked.prefix(limit).map { grey($0.image, key: $0.key) }
    }

    private static func grey(_ image: NSImage, key: String) -> NSImage {
        if let cached = cache[key] { return cached }
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: rect)   // drawing into a grey context makes it grey
        guard let output = context.makeImage() else { return image }
        let result = NSImage(cgImage: output, size: NSSize(width: side, height: side))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

// MARK: - Colours

struct TowerPalette {
    let dark: Bool
    var background: Color { dark ? Color(white: 0.075) : Color(red: 0.93, green: 0.94, blue: 0.95) }
    var title: Color { dark ? Color(white: 0.9) : Color(white: 0.2) }
    var tileTop: Color { dark ? Color(red: 0.13, green: 0.14, blue: 0.16) : Color(white: 0.985) }
    var unlitSide: Color { dark ? Color(red: 0.07, green: 0.075, blue: 0.085) : Color(red: 0.78, green: 0.8, blue: 0.83) }
    var glyph: Color { dark ? Color(white: 0.86) : Color(white: 0.3) }
    var shade: Double { dark ? 0.3 : 0.14 }

    /// The level-meter gradient: green, yellow from about half, red near the top.
    static func meter(_ level: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (0.16, 0.80, 0.30)),
            (0.30, (0.30, 0.86, 0.22)),
            (0.58, (0.96, 0.82, 0.10)),
            (0.86, (1.00, 0.24, 0.17)),
            (1.0, (1.00, 0.20, 0.16)),
        ]
        let l = min(max(level, 0), 1)
        for i in 1..<stops.count where l <= stops[i].0 {
            let (t0, a) = stops[i - 1], (t1, b) = stops[i]
            let f = (l - t0) / (t1 - t0)
            return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
        }
        return Color(red: 1, green: 0.2, blue: 0.16)
    }
}

// MARK: - Motion

/// Each tower's own rhythm: it kicks up quickly to a new peak, then falls slowly, like a level meter.
final class TowerField {
    static let cols = 9
    static let rows = 9

    struct Tower {
        var level: Double = 0
        var target: Double = 0
        var nextKick: Double = 0
        /// How high it tends to go; quiet tiles stay near the floor.
        let peak: Double
        /// Seconds between kicks, on average.
        let tempo: Double
        let lively: Bool
        /// Which glyph it shows, if lively.
        let glyph: Int
    }

    private(set) var towers: [Tower] = []
    let stillLevels: [Double]
    private var last: Double?

    init() {
        var rng = SplitMix(seed: 0x4C4358)
        var towers: [Tower] = []
        var still: [Double] = []
        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                // Tiles near the middle of the view are livelier; the edges stay quiet.
                let dx = Double(c - r), depth = Double(c + r) / Double(Self.cols + Self.rows - 2)
                let central = abs(dx) <= 3 && depth > 0.3 && depth < 0.85
                let lively = central ? rng.next() < 0.78 : rng.next() < 0.25
                let peak = lively ? 0.35 + rng.next() * 0.65 : 0.04 + rng.next() * 0.12
                towers.append(Tower(peak: peak, tempo: 0.7 + rng.next() * 1.6, lively: lively,
                                    glyph: Int(rng.next() * 1000)))
                still.append(lively ? peak * (0.35 + rng.next() * 0.65) : peak * 0.5)
            }
        }
        self.towers = towers
        self.stillLevels = still
    }

    func levels(at date: Date) -> [Double] {
        let t = date.timeIntervalSinceReferenceDate
        if last == nil {
            for i in towers.indices {
                towers[i].level = stillLevels[i]
                towers[i].nextKick = t + Double.random(in: 0...1.5)
            }
        }
        let dt = min(max(t - (last ?? t), 0), 0.05)
        last = t
        for i in towers.indices {
            var w = towers[i]
            if t >= w.nextKick {
                w.target = w.peak * Double.random(in: 0.4...1)
                w.nextKick = t + w.tempo * Double.random(in: 0.55...1.6)
            }
            if w.target > w.level {
                w.level += (w.target - w.level) * min(1, dt * 16)    // quick rise
                if w.target - w.level < 0.01 { w.target = 0 }
            } else {
                w.target = 0
                w.level = max(0, w.level - dt * 0.3)                  // slow fall
            }
            towers[i] = w
        }
        return towers.map(\.level)
    }
}

/// Small deterministic random numbers, so the still frame is the same every time.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

// MARK: - Drawing

private struct TowerRenderer {
    let field: TowerField
    let levels: [Double]
    let palette: TowerPalette
    let icons: [NSImage]
    let showsTitle: Bool

    static let genericGlyphs = ["music.note", "play.fill", "headphones", "mic.fill", "gamecontroller.fill",
                                "waveform", "video.fill", "radio.fill", "tv.fill", "music.mic", "speaker.wave.2.fill", "beats.headphones"]

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let cols = TowerField.cols, rows = TowerField.rows
        let theta = 24.0 * Double.pi / 180
        let s = w * 0.086                         // tile side on the ground
        let ux = s * cos(theta), uy = s * sin(theta)
        let cx = w / 2, cy = h * (showsTitle ? 0.86 : 0.7)
        let maxHeight = h * (showsTitle ? 0.4 : 0.5)
        let gap = 0.07                            // space between tiles, as a share of a tile
        let k = w / 520                           // line widths and glows scale with the size

        func ground(_ c: Double, _ r: Double) -> CGPoint {
            let dc = c - Double(cols) / 2, dr = r - Double(rows) / 2
            return CGPoint(x: cx + (dc - dr) * ux, y: cy + (dc + dr) * uy)
        }

        // Real icons go to the most prominent lively tiles: near the front and the middle.
        var iconFor: [Int: Int] = [:]
        if !icons.isEmpty {
            let ranked = field.towers.indices
                .filter { field.towers[$0].lively }
                .sorted { prominence($0) > prominence($1) }
            for (n, i) in ranked.prefix(icons.count).enumerated() { iconFor[i] = n }
        }

        let order = (0..<(cols * rows)).sorted {
            let a = ($0 % cols) + ($0 / cols), b = ($1 % cols) + ($1 / cols)
            return a == b ? $0 < $1 : a < b
        }
        for i in order {
            let c = Double(i % cols), r = Double(i / cols)
            let tower = field.towers[i]
            let level = levels[i]
            let height = 5 * k + level * maxHeight

            // Ground corners of the tile, inset by the gap: back, right, front, left.
            let back = ground(c + gap, r + gap), right = ground(c + 1 - gap, r + gap)
            let front = ground(c + 1 - gap, r + 1 - gap), left = ground(c + gap, r + 1 - gap)
            let lift = CGVector(dx: 0, dy: -height)
            func up(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + lift.dx, y: p.y + lift.dy) }

            // Skip tiles entirely outside the view.
            if right.x < -s || left.x > w + s || back.y - height > h + s { continue }
            if front.y < -s { continue }

            let top = Path { p in p.addLines([up(back), up(right), up(front), up(left)]); p.closeSubpath() }
            let leftFace = Path { p in p.addLines([left, front, up(front), up(left)]); p.closeSubpath() }
            let rightFace = Path { p in p.addLines([front, right, up(right), up(front)]); p.closeSubpath() }

            let lit = level > 0.06
            let colour = TowerPalette.meter(level)
            let sideFill: GraphicsContext.Shading
            if lit {
                // Over the unlit side colour, so the foot of each tower stays dark.
                var stops = [Gradient.Stop(color: TowerPalette.meter(0).opacity(0.35), location: 0)]
                for t in [0.3, 0.58, 0.86] where t < level {
                    stops.append(.init(color: TowerPalette.meter(t), location: t / level))
                }
                stops.append(.init(color: colour, location: 1))
                let bottom = CGPoint(x: front.x, y: front.y), topPoint = up(front)
                sideFill = .linearGradient(Gradient(stops: stops), startPoint: bottom, endPoint: topPoint)
            } else {
                sideFill = .color(palette.unlitSide)
            }

            if level > 0.45 {
                // Tall towers glow softly around their sides: wide, faint strokes of the outline behind
                // the faces. Looks like a blur, without the cost of blurring every tower every frame.
                let outline = Path { p in
                    p.addLines([left, front, right, up(right), up(back), up(left)])
                    p.closeSubpath()
                }
                let strength = (level - 0.45) / 0.55
                for (width, opacity) in [(26.0, 0.07), (16.0, 0.1), (8.0, 0.14)] {
                    context.stroke(outline, with: .color(colour.opacity(opacity * (0.5 + strength))),
                                   style: StrokeStyle(lineWidth: width * k, lineJoin: .round))
                }
            }
            if lit {
                context.fill(leftFace, with: .color(palette.unlitSide))
                context.fill(rightFace, with: .color(palette.unlitSide))
            }
            context.fill(leftFace, with: sideFill)
            context.fill(rightFace, with: sideFill)
            context.fill(rightFace, with: .color(.black.opacity(palette.shade)))

            context.fill(top, with: .color(palette.tileTop))
            if lit {
                if level > 0.25 {
                    // The top edge's halo, the same way: a wider faint stroke under the crisp one.
                    context.stroke(top, with: .color(colour.opacity(0.22)), style: StrokeStyle(lineWidth: 6 * k, lineJoin: .round))
                }
                context.stroke(top, with: .color(colour.opacity(min(1, 0.35 + level))), lineWidth: 1.3 * k)
            }

            // The glyph lies flat on the top: upright, squashed by the tilt.
            guard tower.lively else { continue }
            let centre = CGPoint(x: (up(back).x + up(front).x) / 2, y: (up(back).y + up(front).y) / 2)
            let glyphSize = ux * 0.95
            do {
                // A copy of the context carries the transform without an offscreen layer.
                var layer = context
                layer.translateBy(x: centre.x, y: centre.y)
                layer.scaleBy(x: 1, y: tan(theta) * 1.15)
                let rect = CGRect(x: -glyphSize / 2, y: -glyphSize / 2, width: glyphSize, height: glyphSize)
                if let n = iconFor[i] {
                    // Icons arrive already grey (TowerIcons), so no filter runs per frame.
                    layer.opacity = 0.9
                    layer.clip(to: Path(roundedRect: rect.insetBy(dx: glyphSize * 0.06, dy: glyphSize * 0.06),
                                        cornerRadius: glyphSize * 0.22))
                    layer.draw(Image(nsImage: icons[n]), in: rect)
                } else {
                    var symbol = layer.resolve(Image(systemName: Self.genericGlyphs[tower.glyph % Self.genericGlyphs.count]))
                    symbol.shading = .color(palette.glyph)
                    let inner = rect.insetBy(dx: glyphSize * 0.2, dy: glyphSize * 0.2)
                    let aspect = symbol.size.width / max(symbol.size.height, 1)
                    let fit = aspect >= 1
                        ? CGSize(width: inner.width, height: inner.width / aspect)
                        : CGSize(width: inner.height * aspect, height: inner.height)
                    layer.draw(symbol, in: CGRect(x: -fit.width / 2, y: -fit.height / 2, width: fit.width, height: fit.height))
                }
            }
        }

        // Fades: behind the title, so towers never run through it, and into the bottom edge.
        let bg = palette.background
        if showsTitle {
            context.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.5)), with: .linearGradient(
                Gradient(stops: [.init(color: bg, location: 0), .init(color: bg, location: 0.64), .init(color: bg.opacity(0), location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.5)))
        }
        context.fill(Path(CGRect(x: 0, y: h * 0.68, width: w, height: h * 0.32)), with: .linearGradient(
            Gradient(stops: [.init(color: bg.opacity(0), location: 0), .init(color: bg.opacity(0.8), location: 0.6),
                             .init(color: bg, location: 1)]),
            startPoint: CGPoint(x: 0, y: h * 0.68), endPoint: CGPoint(x: 0, y: h)))
        for (x0, x1) in [(0.0, w * 0.12), (w, w * 0.88)] {
            context.fill(Path(CGRect(x: min(x0, x1), y: 0, width: abs(x1 - x0), height: h)), with: .linearGradient(
                Gradient(colors: [bg.opacity(0.85), bg.opacity(0)]),
                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
        }
    }

    private func prominence(_ i: Int) -> Double {
        let c = Double(i % TowerField.cols), r = Double(i / TowerField.cols)
        let depth = c + r                 // larger = nearer the front
        let offCentre = abs(c - r)
        return depth - offCentre * 1.6 - max(0, depth - 12) * 3
    }
}
