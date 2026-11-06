import CoreGraphics
import Foundation

extension Config.Layer {
    /// Why this layer cannot be drawn, or nil. A layer that cannot be drawn is refused
    /// rather than skipped: a store set composed without its pattern looks finished.
    func problem() -> String? {
        guard Self.kinds.contains(kind) else {
            return "kind \"\(kind)\" is not one appshot draws (\(Self.kinds.joined(separator: ", ")))"
        }
        for (role, colour) in [("color", color), ("sun", sun)] {
            if let colour, Image.color(hex: colour) == nil { return "\(role) \"\(colour)\" is not #RRGGBB" }
        }
        for (name, value) in [("opacity", opacity), ("falloff", falloff), ("alternate", alternate)] {
            if let value, !(0...1).contains(value) { return "\(name) \(value) is outside 0–1" }
        }
        for (name, value) in [("ringWidth", ringWidth), ("sunRadius", sunRadius)] {
            if let value, value <= 0 { return "\(name) must be more than 0" }
        }
        for (name, value) in [("drop", drop), ("gap", gap)] {
            if let value, value < 0 { return "\(name) must not be negative" }
        }
        if let rings, rings < 1 { return "rings must be at least 1" }
        if let maxSegments, maxSegments < 1 { return "maxSegments must be at least 1" }
        if let fade {
            if !(0...1).contains(fade.floor) { return "fade.floor \(fade.floor) is outside 0–1" }
            if !(fade.from < fade.to) { return "fade.from must be above fade.to" }
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
        if let fade = layer.fade,
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [CGColor(gray: 0, alpha: fade.floor), CGColor(gray: 0, alpha: 1)] as CFArray,
                locations: [0, 1])
        {
            // destinationIn keeps what is drawn, scaled by the gradient's alpha.
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: fade.from * H), end: CGPoint(x: 0, y: fade.to * H),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
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
}
