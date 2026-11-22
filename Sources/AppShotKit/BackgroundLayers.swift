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
            [
                ("color", color), ("sun", sun), ("playhead", playhead), ("fill", fill),
                ("noteColor", noteColor), ("lit", lit),
            ]
            + (colors ?? []).enumerated().map { ("colors[\($0.offset)]", $0.element) }
        for (role, colour) in colours {
            if let colour, Image.color(hex: colour) == nil { return "\(role) \"\(colour)\" is not #RRGGBB" }
        }
        if let colors, colors.isEmpty { return "colors must name at least one colour" }
        for (name, value) in [
            ("opacity", opacity), ("falloff", falloff), ("alternate", alternate), ("center", center),
            ("playheadAt", playheadAt), ("playheadOpacity", playheadOpacity), ("unplayed", unplayed),
            ("fillOpacity", fillOpacity), ("fillShare", fillShare), ("noteOpacity", noteOpacity),
            ("litOpacity", litOpacity),
        ] {
            if let value, !(0...1).contains(value) { return "\(name) \(value) is outside 0–1" }
        }
        for (name, value) in [
            ("ringWidth", ringWidth), ("sunRadius", sunRadius), ("barWidth", barWidth),
            ("amplitude", amplitude), ("lotWidth", lotWidth), ("depth", depth), ("lineWidth", lineWidth),
            ("lineGap", lineGap), ("measure", measure),
        ] {
            if let value, value <= 0 { return "\(name) must be more than 0" }
        }
        // A staff's note count grows as one over these: below them it draws a smear of
        // millions of notes rather than a score.
        if let lineGap, lineGap > 0, lineGap < 0.005 { return "lineGap must be at least 0.005" }
        if let measure, measure > 0, measure < 0.08 { return "measure must be at least 0.08" }
        if let rotation, !rotation.isFinite { return "rotation must be a number of degrees" }
        for (name, value) in [("drop", drop), ("gap", gap), ("street", street), ("staffGap", staffGap)] {
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
        case "staff": drawStaff(ctx, layer, width: W, height: H)
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

    /// The geometry of a `staff` layer, in y-down canvas pixels: staves of five lines
    /// centred down the canvas, barred every four beats, each beat a quarter note, a
    /// rest or two eighths under a beam, the melody a fixed-seed walk so it is the same
    /// score on every run. The beats are laid so one falls on the playhead, and that
    /// beat is always a quarter: the lit column always holds a note. Split out so tests
    /// can reason about notes without reading pixels.
    struct StaffGeometry: Equatable {
        struct Note: Equatable {
            /// The head's centre.
            var head: CGPoint
            /// The staff position: 0 is the bottom line, 8 the top one, each step half
            /// a line gap.
            var step: Int
            var stem: CGRect
            var lit: Bool
            /// One of a beamed pair of eighths, whose stems both go the pair's way.
            var beamed: Bool
        }

        /// Each line of every staff, as a thin rect across the width.
        var lines: [CGRect]
        var barlines: [CGRect]
        var notes: [Note]
        /// Each pair of eighths' beam, as its four corners.
        var beams: [[CGPoint]]
        /// The playhead's column, full height. Present whether or not it is shaded.
        var column: CGRect
        /// A head's half-width and half-height, before its tilt.
        var headRadii: CGSize
        var lineWidth: Double

        init(_ layer: Config.Layer, width W: Double, height H: Double) {
            let side = min(W, H)
            let gap = (layer.lineGap ?? 0.02) * side
            let staffGap = (layer.staffGap ?? 0.1) * side
            let measure = (layer.measure ?? 0.36) * side
            let pitch = measure / 4
            let head = (layer.playheadAt ?? 0.38) * W
            lineWidth = max(1, (layer.lineWidth ?? 0.0024) * side)
            headRadii = CGSize(width: gap * 0.68, height: gap * 0.48)
            let stemWidth = max(1, lineWidth * 1.4)
            let stemLength = gap * 3.4
            column = CGRect(x: head - gap * 1.3, y: 0, width: gap * 2.6, height: H)

            // Centred: as many staves as reach past both edges.
            let period = 4 * gap + staffGap
            let count = Int((H / period).rounded(.up)) + 1
            let firstTop = (H - (Double(count) * period - staffGap)) / 2
            // Beat k stands at head + k·pitch; the playhead's beat is the second of its bar.
            let firstBeat = Int((-head / pitch).rounded(.down)) - 1
            let lastBeat = Int(((W - head) / pitch).rounded(.up)) + 1

            var lines: [CGRect] = []
            var barlines: [CGRect] = []
            var notes: [Note] = []
            var beams: [[CGPoint]] = []
            let r = headRadii
            /// A stem on the head's right going up, or its left going down, as
            /// engravers set them, reaching `to`.
            func stem(_ x: Double, _ y: Double, up: Bool, to end: Double) -> CGRect {
                up
                    ? CGRect(x: x + r.width * 0.86 - stemWidth, y: end, width: stemWidth, height: y - end)
                    : CGRect(x: x - r.width * 0.86, y: y, width: stemWidth, height: end - y)
            }
            for s in 0..<count {
                let top = firstTop + Double(s) * period
                let bottom = top + 4 * gap
                for i in 0..<5 {
                    let y = top + Double(i) * gap
                    lines.append(CGRect(x: 0, y: y - lineWidth / 2, width: W, height: lineWidth))
                }
                var random = PlanRandom(state: 29 &+ UInt32(s) &* 7919)
                var step = 2 + Int(random.next() * 5)
                /// A walk of one to three steps, turned back at the staff's edges.
                func walk() -> Int {
                    let move = 1 + Int(random.next() * 3)
                    step += random.next() < 0.5 ? -move : move
                    if step < -1 { step = -1 + (-1 - step) }
                    if step > 9 { step = 9 - (step - 9) }
                    return step
                }
                func y(_ step: Int) -> Double { bottom - Double(step) * gap / 2 }
                for k in firstBeat...lastBeat {
                    let x = head + Double(k) * pitch
                    // A barline before the first beat of each bar (k ≡ -1 mod 4).
                    if ((k + 1) % 4 + 4) % 4 == 0 {
                        let bx = x - pitch / 2
                        barlines.append(
                            CGRect(x: bx - lineWidth / 2, y: top, width: lineWidth, height: bottom - top))
                    }
                    // The playhead's beat is always a quarter; the others are a quarter,
                    // a rest, or two eighths beamed.
                    let roll = k == 0 ? 1 : random.next()
                    if roll < 0.14 { continue }
                    if roll < 0.4 {
                        let steps = [walk(), walk()]
                        let xs = [x - pitch / 4, x + pitch / 4]
                        let ys = steps.map(y)
                        let up = Double(steps[0] + steps[1]) / 2 < 4
                        // Each stem's natural end, the beam's slope held to half a gap,
                        // and the beam moved outward until neither stem is short.
                        let natural = ys.map { up ? $0 - stemLength : $0 + stemLength }
                        let slope = min(max(natural[1] - natural[0], -gap / 2), gap / 2)
                        let start = up ? min(natural[0], natural[1] - slope) : max(natural[0], natural[1] - slope)
                        let ends = [start, start + slope]
                        let stems = (0..<2).map { stem(xs[$0], ys[$0], up: up, to: ends[$0]) }
                        for i in 0..<2 {
                            notes.append(
                                Note(
                                    head: CGPoint(x: xs[i], y: ys[i]), step: steps[i], stem: stems[i],
                                    lit: false, beamed: true))
                        }
                        let thickness = gap * 0.5 * (up ? 1 : -1)
                        let (l, rr) = (stems[0].minX, stems[1].maxX)
                        beams.append([
                            CGPoint(x: l, y: ends[0]), CGPoint(x: rr, y: ends[1]),
                            CGPoint(x: rr, y: ends[1] + thickness), CGPoint(x: l, y: ends[0] + thickness),
                        ])
                        continue
                    }
                    let n = walk()
                    let up = n < 4
                    let end = up ? y(n) - stemLength : y(n) + stemLength
                    notes.append(
                        Note(
                            head: CGPoint(x: x, y: y(n)), step: n, stem: stem(x, y(n), up: up, to: end),
                            lit: k == 0, beamed: false))
                }
            }
            self.lines = lines
            self.barlines = barlines
            self.notes = notes
            self.beams = beams
        }
    }

    /// A score: five-line staves in `color`, quarter notes in `noteColor`, the column at
    /// the playhead shaded in `playhead` and its notes in `lit`, quiet under the caption
    /// with `fade` and over a span with `clear`. Built for Pupitre, whose icon is a
    /// score on its music stand above a keyboard, the note being played lit.
    static func drawStaff(_ ctx: CGContext, _ layer: Config.Layer, width W: Double, height H: Double) {
        guard let line = Image.color(hex: layer.color) else { return }
        let g = StaffGeometry(layer, width: W, height: H)
        let ink = Image.color(hex: layer.noteColor ?? layer.color) ?? line
        let noteAlpha = layer.noteOpacity ?? layer.opacity
        let litInk = layer.lit.flatMap { Image.color(hex: $0) }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let hex = layer.playhead, let band = Image.color(hex: hex) {
            let c = g.column
            ctx.addPath(
                CGPath(roundedRect: c, cornerWidth: c.width / 2, cornerHeight: c.width / 2, transform: nil))
            ctx.setFillColor(band.copy(alpha: layer.playheadOpacity ?? 0.25) ?? band)
            ctx.fillPath()
        }
        // One path for every line and barline, so a crossing is not drawn twice.
        ctx.addRects(g.lines + g.barlines)
        ctx.setFillColor(line.copy(alpha: layer.opacity) ?? line)
        ctx.fillPath(using: .winding)
        // Each note is one path, so its stem does not double the alpha where it meets
        // the head, and is painted with .copy, so what lies under it (a line, the
        // column) is replaced rather than showing through: a solid head, as on the icon.
        ctx.setBlendMode(.copy)
        let radii = g.headRadii
        for note in g.notes {
            let litNote = note.lit && litInk != nil
            let colour = (litNote ? litInk : nil) ?? ink
            let alpha = litNote ? (layer.litOpacity ?? 0.9) : noteAlpha
            let tilt = CGAffineTransform(translationX: note.head.x, y: note.head.y)
                .rotated(by: -22 * .pi / 180)
            let path = CGMutablePath()
            path.addRect(note.stem)
            path.addEllipse(
                in: CGRect(
                    x: -radii.width, y: -radii.height, width: 2 * radii.width, height: 2 * radii.height),
                transform: tilt)
            ctx.addPath(path)
            ctx.setFillColor(colour.copy(alpha: alpha) ?? colour)
            ctx.fillPath(using: .winding)
        }
        // Still under .copy: where a beam overlaps its stems' ends it replaces them with
        // the same colour, so the overlap is not drawn twice.
        ctx.setFillColor(ink.copy(alpha: noteAlpha) ?? ink)
        for beam in g.beams {
            ctx.addLines(between: beam)
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)
        applyFade(ctx, layer.fade, height: H)
        applyClear(ctx, layer.clear, width: W)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
