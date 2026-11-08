import CoreGraphics
import Foundation

extension Config.Layer {
    /// Why this layer cannot be drawn, or nil. A layer that cannot be drawn is refused
    /// rather than skipped: a store set composed without its pattern looks finished.
    func problem() -> String? {
        guard Self.kinds.contains(kind) else {
            return "kind \"\(kind)\" is not one appshot draws (\(Self.kinds.joined(separator: ", ")))"
        }
        let colours: [(String, String?)] =
            [("color", color), ("sun", sun), ("playhead", playhead), ("fill", fill)]
            + (colors ?? []).enumerated().map { ("colors[\($0.offset)]", $0.element) }
        for (role, colour) in colours {
            if let colour, Image.color(hex: colour) == nil { return "\(role) \"\(colour)\" is not #RRGGBB" }
        }
        if let colors, colors.isEmpty { return "colors must name at least one colour" }
        for (name, value) in [
            ("opacity", opacity), ("falloff", falloff), ("alternate", alternate), ("center", center),
            ("playheadAt", playheadAt), ("playheadOpacity", playheadOpacity), ("unplayed", unplayed),
            ("fillOpacity", fillOpacity), ("fillShare", fillShare),
        ] {
            if let value, !(0...1).contains(value) { return "\(name) \(value) is outside 0–1" }
        }
        for (name, value) in [
            ("ringWidth", ringWidth), ("sunRadius", sunRadius), ("barWidth", barWidth),
            ("amplitude", amplitude), ("lotWidth", lotWidth), ("depth", depth), ("lineWidth", lineWidth),
        ] {
            if let value, value <= 0 { return "\(name) must be more than 0" }
        }
        if let rotation, !rotation.isFinite { return "rotation must be a number of degrees" }
        for (name, value) in [("drop", drop), ("gap", gap), ("street", street)] {
            if let value, value < 0 { return "\(name) must not be negative" }
        }
        if let rings, rings < 1 { return "rings must be at least 1" }
        if let maxSegments, maxSegments < 1 { return "maxSegments must be at least 1" }
        if let fade {
            if !(0...1).contains(fade.floor) { return "fade.floor \(fade.floor) is outside 0–1" }
            if !(fade.from < fade.to) { return "fade.from must be above fade.to" }
        }
        if let clear {
            if !(0...1).contains(clear.floor) { return "clear.floor \(clear.floor) is outside 0–1" }
            if !(clear.from < clear.to) { return "clear.from must be left of clear.to" }
        }
        return nil
    }
}

extension Compose {
    /// The whole background: the gradient, then each layer over it. Store composites
    /// and family images both go through here, so a layer cannot appear on one and not
    /// the other.
    static func drawBackground(
        _ ctx: CGContext,
        _ background: Config.Background,
        width W: Double,
        height H: Double
    ) {
        drawGradient(ctx, background, width: W, height: H)
        for layer in background.layers ?? [] {
            drawLayer(ctx, layer, width: W, height: H)
        }
    }

    static func drawLayer(_ ctx: CGContext, _ layer: Config.Layer, width W: Double, height H: Double) {
        switch layer.kind {
        case "fan": drawFan(ctx, layer, width: W, height: H)
        case "waveform": drawWaveform(ctx, layer, width: W, height: H)
        case "cadastre": drawCadastre(ctx, layer, width: W, height: H)
        default: break  // refused by validate() before anything is drawn
        }
    }

    /// The geometry of a `fan` layer, in y-down canvas pixels. Split out so tests can
    /// reason about rings without reading pixels.
    struct FanGeometry: Equatable {
        var center: CGPoint
        var sunRadius: Double
        var ringWidth: Double
        var gap: Double
        var rings: Int
        var maxSegments: Int

        init(_ layer: Config.Layer, width W: Double, height H: Double) {
            let side = min(W, H)
            center = CGPoint(x: W / 2, y: H + (layer.drop ?? 0.06) * side)
            sunRadius = (layer.sunRadius ?? 0.2) * side
            ringWidth = (layer.ringWidth ?? 0.2) * side
            gap = (layer.gap ?? 0.009) * side
            // Enough rings for the outermost to reach the top edge above the centre.
            rings = layer.rings ?? max(1, Int(((center.y - sunRadius) / ringWidth).rounded(.up)))
            maxSegments = layer.maxSegments ?? 32
        }

        /// Segments in ring `k` (1-based): 2, 4, 8, … capped.
        func segments(inRing k: Int) -> Int {
            min(1 << min(k, 30), maxSegments)
        }
    }

    /// Drawn in y-down coordinates under a flipped CTM, so the arithmetic reads like the
    /// config. The upper half-plane is 180°→360° there.
    static func drawFan(_ ctx: CGContext, _ layer: Config.Layer, width W: Double, height H: Double) {
        guard let color = Image.color(hex: layer.color) else { return }
        let g = FanGeometry(layer, width: W, height: H)
        let falloff = layer.falloff ?? 0.8
        let alternate = layer.alternate ?? 0.72

        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)

        // The rings go into their own layer so the fade can scale their alpha alone,
        // leaving the gradient beneath untouched.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        var ringOpacity = layer.opacity
        for k in 1...g.rings {
            let inner = g.sunRadius + Double(k - 1) * g.ringWidth + g.gap / 2
            let outer = g.sunRadius + Double(k) * g.ringWidth - g.gap / 2
            let n = g.segments(inRing: k)
            // The same gap, in pixels, at the ring's middle as between rings.
            let halfGap = (g.gap / 2) / ((inner + outer) / 2)
            for j in 0..<n {
                let a = Double.pi + Double.pi * Double(j) / Double(n) + halfGap
                let b = Double.pi + Double.pi * Double(j + 1) / Double(n) - halfGap
                guard b > a else { continue }
                let path = CGMutablePath()
                path.addArc(center: g.center, radius: outer, startAngle: a, endAngle: b, clockwise: false)
                path.addArc(center: g.center, radius: inner, startAngle: b, endAngle: a, clockwise: true)
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(color.copy(alpha: ringOpacity * (j % 2 == 1 ? alternate : 1)) ?? color)
                ctx.fillPath()
            }
            ringOpacity *= falloff
        }
        applyFade(ctx, layer.fade, height: H)
        ctx.endTransparencyLayer()

        // The sun: solid to 78% of its radius, then softened to nothing at the edge.
        if let hex = layer.sun, let sun = Image.color(hex: hex), let clear = sun.copy(alpha: 0) {
            let radius = g.sunRadius - g.gap
            if radius > 0,
                let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                    colors: [sun, sun, clear] as CFArray, locations: [0, 0.78, 1])
            {
                ctx.drawRadialGradient(
                    gradient, startCenter: g.center, startRadius: 0,
                    endCenter: g.center, endRadius: radius, options: [])
            }
        }
        ctx.restoreGState()
    }

    /// Scales what the current transparency layer holds by the fade: `floor` above
    /// `from`, full below `to`. Called last inside the layer, under a y-down CTM.
    static func applyFade(_ ctx: CGContext, _ fade: Config.Fade?, height H: Double) {
        guard let fade,
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [CGColor(gray: 0, alpha: fade.floor), CGColor(gray: 0, alpha: 1)] as CFArray,
                locations: [0, 1])
        else { return }
        // destinationIn keeps what is drawn, scaled by the gradient's alpha.
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: fade.from * H), end: CGPoint(x: 0, y: fade.to * H),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// The geometry of a `waveform` layer, in y-down canvas pixels. Split out so tests
    /// can reason about bars without reading pixels.
    struct WaveformGeometry: Equatable {
        struct Bar: Equatable {
            var rect: CGRect
            var voice: Int
            var played: Bool
        }

        var bars: [Bar]
        var playhead: CGRect

        init(_ layer: Config.Layer, width W: Double, height H: Double) {
            let side = min(W, H)
            let barWidth = (layer.barWidth ?? 0.022) * side
            let pitch = barWidth + (layer.gap ?? (layer.barWidth ?? 0.022) * 0.75) * side
            let amplitude = (layer.amplitude ?? 0.2) * side
            let center = (layer.center ?? 0.8) * H
            let head = (layer.playheadAt ?? 0.38) * W
            let voices = max(1, layer.colors?.count ?? 1)
            // Centred on the canvas: a wider canvas shows more bars either side.
            let count = Int((W / pitch).rounded(.up)) + 1
            let offset = (Double(count) * pitch - W) / 2
            bars = Self.heights(count).enumerated().map { i, sample in
                let x = Double(i) * pitch - offset
                let height = max(barWidth, sample.height * amplitude * 2)
                return Bar(
                    rect: CGRect(x: x, y: center - height / 2, width: barWidth, height: height),
                    voice: sample.turn % voices, played: x + barWidth / 2 < head)
            }
            let thickness = barWidth * 0.38
            playhead = CGRect(
                x: head - thickness / 2, y: center - amplitude * 1.15, width: thickness,
                height: amplitude * 2.3)
        }

        /// A voice's bar heights, 0–1, and whose turn each bar is: turns of five to nine
        /// bars, a phrase rising and falling across them, the first bar of a turn a
        /// breath. A fixed function of the index, so every run draws the same bars.
        static func heights(_ count: Int) -> [(height: Double, turn: Int)] {
            var out: [(Double, Int)] = []
            var turn = 0, run = 0, length = 6
            for i in 0..<count {
                if run >= length {
                    turn += 1
                    run = 0
                    length = 5 + (i * 7) % 5
                }
                let x = Double(i)
                let hash = abs(sin(x * 12.9898 + 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let phrase = 0.55 + 0.45 * sin(x * 0.23 + 1.1) * sin(x * 0.071 + 0.3)
                let syllable = 0.35 + 0.65 * abs(sin(x * 0.9 + hash))
                let breath = run == 0 ? 0.45 : 1
                out.append((min(1, max(0.16, (0.25 + 0.75 * hash) * syllable * phrase * 1.6 * breath)), turn))
                run += 1
            }
            return out
        }
    }

    /// A player's waveform: rounded bars mirrored about a band, coloured by voice, the
    /// ones past the playhead drawn at `unplayed` of their strength.
    static func drawWaveform(_ ctx: CGContext, _ layer: Config.Layer, width W: Double, height H: Double) {
        let palette = (layer.colors ?? [layer.color]).compactMap { Image.color(hex: $0) }
        guard !palette.isEmpty else { return }
        let g = WaveformGeometry(layer, width: W, height: H)
        let unplayed = layer.unplayed ?? 0.4

        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for bar in g.bars {
            var alpha = layer.opacity * (bar.played ? 1 : unplayed)
            if let clear = layer.clear {
                alpha *= clear.floor + (1 - clear.floor) * Self.outside(clear, x: bar.rect.midX / W)
            }
            let colour = palette[bar.voice % palette.count]
            ctx.addPath(
                CGPath(
                    roundedRect: bar.rect, cornerWidth: bar.rect.width / 2,
                    cornerHeight: min(bar.rect.width, bar.rect.height) / 2, transform: nil))
            ctx.setFillColor(colour.copy(alpha: alpha) ?? colour)
            ctx.fillPath()
        }
        if let hex = layer.playhead, let colour = Image.color(hex: hex) {
            var alpha = layer.playheadOpacity ?? 0.6
            if let clear = layer.clear {
                alpha *= clear.floor + (1 - clear.floor) * Self.outside(clear, x: g.playhead.midX / W)
            }
            let r = g.playhead
            ctx.addPath(
                CGPath(roundedRect: r, cornerWidth: r.width / 2, cornerHeight: r.width / 2, transform: nil))
            ctx.setFillColor(colour.copy(alpha: alpha) ?? colour)
            ctx.fillPath()
        }
        applyFade(ctx, layer.fade, height: H)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 0 inside the clear span, 1 well outside it, eased over 6% of the width.
    static func outside(_ clear: Config.Clear, x: Double) -> Double {
        let soft = 0.06
        if x <= clear.from - soft || x >= clear.to + soft { return 1 }
        if x < clear.from { return (clear.from - x) / soft }
        if x > clear.to { return (x - clear.to) / soft }
        return 0
    }

    /// Scales what the current transparency layer holds by a `clear` span, the way
    /// `outside` scales a waveform's bars. Called last inside the layer.
    static func applyClear(_ ctx: CGContext, _ clear: Config.Clear?, width W: Double) {
        guard let clear else { return }
        let soft = 0.06
        let stops = [
            (0, 1), (clear.from - soft, 1), (clear.from, clear.floor), (clear.to, clear.floor),
            (clear.to + soft, 1), (1, 1),
        ].map { (location: min(max($0.0, 0), 1), alpha: $0.1) }
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: stops.map { CGColor(gray: 0, alpha: $0.alpha) } as CFArray,
                locations: stops.map { CGFloat($0.location) })
        else { return }
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: W, y: 0), options: [])
    }

    /// A small fixed-seed generator (mulberry32), so a cadastre is the same plan on
    /// every run, every machine and every release: a layer that moved would drift
    /// every golden composed over it.
    struct PlanRandom {
        var state: UInt32

        mutating func next() -> Double {
            state &+= 0x6D2B_79F5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// The geometry of a `cadastre` layer, in y-down canvas pixels: rows of blocks two
    /// lots deep, back to back, separated by streets, the whole plan tilted about the
    /// canvas centre. Lot lines run slightly askew and corners sit a little off true,
    /// so it reads as surveyed rather than ruled. Split out so tests can reason about
    /// lots without reading pixels.
    struct CadastreGeometry: Equatable {
        struct Lot: Equatable {
            var corners: [CGPoint]
            var shaded: Bool
        }

        var lots: [Lot]
        var lineWidth: Double

        init(_ layer: Config.Layer, width W: Double, height H: Double) {
            let side = min(W, H)
            let frontage = (layer.lotWidth ?? 0.06) * side
            let depth = (layer.depth ?? 0.075) * side
            let street = (layer.street ?? 0.03) * side
            let gap = (layer.gap ?? 0.0045) * side
            let skew = frontage * 0.5
            let jitter = frontage * 0.067
            let share = layer.fill == nil ? 0 : (layer.fillShare ?? 0.2)
            let theta = (layer.rotation ?? -9) * .pi / 180
            let (c, s) = (cos(theta), sin(theta))
            func place(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: W / 2 + x * c - y * s, y: H / 2 + x * s + y * c)
            }

            var random = PlanRandom(state: 11)
            // Far enough out that the tilted plan covers every corner of the canvas.
            let reach = hypot(W, H) / 2 + 0.15 * side
            var lots: [Lot] = []
            var y = -reach
            while y < reach {
                var x = -reach - random.next() * 0.3 * side
                while x < reach {
                    let end = x + (0.32 + random.next() * 0.45) * side
                    for row in 0..<2 {
                        let y0 = y + Double(row) * depth
                        let y1 = y0 + depth
                        var top = x
                        var bottom = x
                        while top < end - 0.01 * side {
                            let width = frontage * (0.6 + 0.8 * random.next())
                            var nextTop = min(top + width, end)
                            var nextBottom = min(bottom + width + (random.next() - 0.5) * skew, end)
                            // No sliver at the block's end: the last lot takes it.
                            if end - nextTop < 0.03 * side {
                                nextTop = end
                                nextBottom = end
                            }
                            let corners = [
                                (top + gap, y0 + gap), (nextTop - gap, y0 + gap),
                                (nextBottom - gap, y1 - gap), (bottom + gap, y1 - gap),
                            ].map { x, y in
                                let dx = (random.next() - 0.5) * jitter
                                let dy = (random.next() - 0.5) * jitter
                                return place(x + dx, y + dy)
                            }
                            lots.append(Lot(corners: corners, shaded: random.next() < share))
                            top = nextTop
                            bottom = nextBottom
                        }
                    }
                    x = end + street
                }
                y += 2 * depth + street * (random.next() < 0.22 ? 2.6 : 1)
            }
            // Keep the lots that can reach the canvas: none is wider than this margin.
            let margin = 1.5 * frontage + depth
            let visible = CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: -margin, dy: -margin)
            self.lots = lots.filter { $0.corners.contains(where: visible.contains) }
            lineWidth = max(1, (layer.lineWidth ?? 0.0026) * side)
        }
    }

    /// A land registry's plan: every lot outlined in `color`, a share of them shaded in
    /// `fill`, quiet under the caption with `fade` and over a span with `clear`. Built
    /// for Parcelle, whose icon is a house on its lot over the cadastre.
    static func drawCadastre(_ ctx: CGContext, _ layer: Config.Layer, width W: Double, height H: Double) {
        guard let line = Image.color(hex: layer.color) else { return }
        let shade = layer.fill.flatMap { Image.color(hex: $0) }
            .flatMap { $0.copy(alpha: layer.fillOpacity ?? 0.16) }
        let g = CadastreGeometry(layer, width: W, height: H)
        let stroke = line.copy(alpha: layer.opacity) ?? line

        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineWidth(g.lineWidth)
        ctx.setLineJoin(.round)
        for lot in g.lots {
            let path = CGMutablePath()
            path.addLines(between: lot.corners)
            path.closeSubpath()
            if lot.shaded, let shade {
                ctx.addPath(path)
                ctx.setFillColor(shade)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.strokePath()
        }
        applyFade(ctx, layer.fade, height: H)
        applyClear(ctx, layer.clear, width: W)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
