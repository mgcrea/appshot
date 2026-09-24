import CoreGraphics
import Foundation

/// Repaint an inactive window's grey traffic lights in their active colours.
///
/// `--no-activate` exists so a run never takes the screen from whoever is using the
/// Mac, and its one visible cost is the title bar: macOS draws the close, minimise and
/// zoom buttons grey on a window whose app is not active, and nothing inside the app
/// can change that — they follow app-level activation, not the window's key state.
/// So this fixes it after the fact, on the pixels.
///
/// Two halves, deliberately kept apart:
///
///   find    pure over pixels, so the geometry is testable without a window server.
///           Locates exactly three equal discs on one row at an even pitch in the
///           window's top-left corner, and refuses anything less certain. Positions
///           are measured, never assumed: the button size and pitch change with the
///           toolbar style (a plain titled window: 12pt discs on a 20pt pitch; a
///           unified toolbar: 14pt on 23pt) and moved again in macOS 26.
///   paint   draws the active buttons over the grey ones at the measured size, from
///           colours sampled off AppKit's own artwork (macOS 27, 8x supersampled).
///
/// Drawn, not borrowed from AppKit. `NSWindow.standardWindowButton` detached from a
/// window does render active, but only when AppKit believes the binary was built
/// against a current SDK — and a `-reproducible` link stamps the SDK as the deployment
/// target, which gets the legacy button, which draws nothing outside a window. Artwork
/// that depends on link flags is not artwork to ship. Drawing also keeps goldens still
/// across macOS updates, where borrowed artwork would drift with every restyle.
///
/// What this does not touch is the rest of the inactive chrome: the sidebar material
/// still sits ~11/255 lighter and toolbar glyphs stay dimmed. Those are far subtler
/// than three grey dots, and repainting them would mean inventing pixels.
public enum TrafficLights {
    public struct Disc: Equatable, Sendable {
        /// Centre, in pixels from the image's top-left.
        public let x: Double
        public let y: Double
        public let diameter: Double
    }

    public enum Outcome: Equatable, Sendable {
        /// The discs were grey and have been repainted.
        case recolored
        /// The discs were already coloured — the app happened to be frontmost — and
        /// were left alone.
        case alreadyActive
    }

    /// Where to look, in points from the window's top-left. Generous on purpose: the
    /// tallest unified toolbar centres its buttons ~26pt down, and the corner alone is
    /// cheap to scan.
    static let searchWidth = 120.0
    static let searchHeight = 64.0
    /// The first disc's centre must sit this close to the window's left edge. Keeps a
    /// row of round toolbar buttons further right from ever qualifying.
    static let maxLeadingOffset = 40.0
    /// Disc diameter bounds, in points. Measured discs are 12-14pt.
    static let minDiameter = 9.0
    static let maxDiameter = 18.0
    /// Mean chroma (max channel minus min channel) inside a disc. Grey discs measure
    /// under 5; red, yellow and green all measure over 150. Between the two is a state
    /// nobody should guess at.
    static let greyChroma = 24.0
    static let colourChroma = 60.0

    // MARK: - Recolour

    /// Find the window's traffic lights and repaint them if they are grey.
    ///
    /// - Parameters:
    ///   - windowOrigin: the base window's top-left, in image pixels. Not assumed to be
    ///     the image's corner: a popover can extend the capture past the window edge.
    ///   - scale: backing scale factor the image was captured at.
    public static func recolor(
        _ image: CGImage, windowOrigin: CGPoint, scale: Double, screen: String
    ) throws -> (image: CGImage, outcome: Outcome) {
        guard let pixels = Image.pixels(image) else {
            throw AppShotError.captureFailed(screen: screen, reason: "could not read pixels")
        }
        guard let discs = find(in: pixels, windowOrigin: windowOrigin, scale: scale) else {
            throw AppShotError.trafficLightsNotFound(screen: screen)
        }

        let chroma = discs.map { meanChroma(pixels, $0) }
        if chroma.allSatisfy({ $0 >= colourChroma }) { return (image, .alreadyActive) }
        guard chroma.allSatisfy({ $0 < greyChroma }) else {
            throw AppShotError.trafficLightsAmbiguous(screen: screen, chroma: chroma)
        }

        let backgrounds = discs.map { ringColour(pixels, $0) }
        let palette = luminance(backgrounds[0]) < 0.5 ? Palette.dark : Palette.light

        guard let ctx = Image.context(width: image.width, height: image.height) else {
            throw AppShotError.captureFailed(screen: screen, reason: "could not allocate context")
        }
        let height = Double(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        for (index, disc) in discs.enumerated() {
            // Erase first: the light buttons are translucent and would let the grey
            // show through, and a grey halo is exactly the tell this is removing.
            // Filled with the ring just outside the disc, so a title bar that is not one
            // flat colour still gets its own local shade back.
            let bg = backgrounds[index]
            ctx.setFillColor(
                CGColor(srgbRed: bg.r / 255, green: bg.g / 255, blue: bg.b / 255, alpha: 1))
            let erase = disc.diameter / 2 + 1.5
            ctx.fillEllipse(
                in: CGRect(
                    x: disc.x - erase, y: height - disc.y - erase,
                    width: erase * 2, height: erase * 2))

            paint(palette.buttons[index], disc: disc, in: ctx, height: height)
        }

        guard let out = ctx.makeImage() else {
            throw AppShotError.captureFailed(screen: screen, reason: "could not encode recolour")
        }
        return (out, .recolored)
    }

    // MARK: - Find

    /// The three traffic-light discs, left to right, or nil when there is not exactly
    /// one convincing row of them.
    public static func find(in pixels: Image.Pixels, windowOrigin: CGPoint, scale: Double)
        -> [Disc]?
    {
        let x0 = max(0, Int(windowOrigin.x.rounded()))
        let y0 = max(0, Int(windowOrigin.y.rounded()))
        let x1 = min(pixels.width, x0 + Int(searchWidth * scale))
        let y1 = min(pixels.height, y0 + Int(searchHeight * scale))
        guard x1 > x0, y1 > y0 else { return nil }

        let box = Box(x0: x0, y0: y0, w: x1 - x0, h: y1 - y0)

        // Flat title bars first — nearly every window — against the box's dominant
        // colour. A title bar that is glass over content (Maps puts its buttons on the
        // map) is a gradient no single colour describes, so that gets a second pass
        // against a local mean instead. Ordered, not either-or: the local mean smears
        // the content edge below a short title bar into the search box, which the
        // flat pass never sees.
        if let bg = dominantColour(pixels, x0..<x1, y0..<y1),
            let discs = row(in: flatMask(pixels, box, bg), box, windowOrigin, scale)
        {
            return discs
        }
        // Twice: the first mean is pulled toward the discs it sits among, which flags
        // a halo that merges them into one blob. The second leaves out everything the
        // first flagged, so it is the mean of the title bar alone.
        let first = localMask(pixels, box, scale: scale, excluding: nil)
        return row(in: localMask(pixels, box, scale: scale, excluding: first), box, windowOrigin, scale)
    }

    struct Box {
        let x0: Int, y0: Int, w: Int, h: Int
    }

    /// A pixel belongs to something drawn on the title bar when it is opaque and
    /// visibly off the title bar's own colour. Transparent pixels — the rounded corner —
    /// are never candidates, so the corner cannot merge into a disc.
    static func flatMask(_ pixels: Image.Pixels, _ box: Box, _ bg: (r: Int, g: Int, b: Int))
        -> [Bool]
    {
        var mask = [Bool](repeating: false, count: box.w * box.h)
        for y in 0..<box.h {
            for x in 0..<box.w {
                let p = pixels[(box.y0 + y) * pixels.width + box.x0 + x]
                guard p.a >= 250 else { continue }
                let d = max(abs(Int(p.r) - bg.r), abs(Int(p.g) - bg.g), abs(Int(p.b) - bg.b))
                mask[y * box.w + x] = d > 10
            }
        }
        return mask
    }

    /// Radius of the local mean, in points. Wide enough that a 14pt disc moves the mean
    /// only a few levels, narrow enough to follow a gradient across the title bar.
    static let localRadius = 16.0

    /// The same test against the mean of the opaque pixels around each one, from an
    /// integral image so the wide window costs nothing per pixel. Pixels in `excluding`
    /// do not count toward any mean.
    static func localMask(_ pixels: Image.Pixels, _ box: Box, scale: Double, excluding: [Bool]?)
        -> [Bool]
    {
        let (w, h) = (box.w, box.h)
        // Summed-area tables of r, g, b and opaque count, one row and column of padding.
        var sums = [[Double]](repeating: [Double](repeating: 0, count: (w + 1) * (h + 1)), count: 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixels[(box.y0 + y) * pixels.width + box.x0 + x]
                let opaque = p.a >= 250 && excluding?[y * w + x] != true
                let v = opaque ? [Double(p.r), Double(p.g), Double(p.b), 1] : [0, 0, 0, 0]
                let i = (y + 1) * (w + 1) + x + 1
                for c in 0..<4 {
                    sums[c][i] = v[c] + sums[c][i - 1] + sums[c][i - w - 1] - sums[c][i - w - 2]
                }
            }
        }
        let r = Int(localRadius * scale)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixels[(box.y0 + y) * pixels.width + box.x0 + x]
                guard p.a >= 250 else { continue }
                let (ax, ay) = (max(0, x - r), max(0, y - r))
                let (bx, by) = (min(w, x + r + 1), min(h, y + r + 1))
                func area(_ c: Int) -> Double {
                    sums[c][by * (w + 1) + bx] - sums[c][ay * (w + 1) + bx]
                        - sums[c][by * (w + 1) + ax] + sums[c][ay * (w + 1) + ax]
                }
                let n = area(3)
                guard n > 0 else { continue }
                let d = max(
                    abs(Double(p.r) - area(0) / n), abs(Double(p.g) - area(1) / n),
                    abs(Double(p.b) - area(2) / n))
                mask[y * w + x] = d > 10
            }
        }
        return mask
    }

    /// The one convincing row of three discs in `mask`, or nil.
    static func row(in mask: [Bool], _ box: Box, _ windowOrigin: CGPoint, _ scale: Double)
        -> [Disc]?
    {
        let (x0, y0, w, h) = (box.x0, box.y0, box.w, box.h)
        let candidates = components(mask, width: w, height: h).compactMap {
            c -> Disc? in
            let bw = Double(c.maxX - c.minX + 1)
            let bh = Double(c.maxY - c.minY + 1)
            let d = (bw + bh) / 2
            guard
                d >= minDiameter * scale, d <= maxDiameter * scale,
                abs(bw - bh) <= max(2, 0.1 * d),
                // A filled circle covers π/4 ≈ 0.785 of its box; a ring or a glyph
                // covers far less, a square far more.
                case let fill = Double(c.count) / (bw * bh), fill > 0.65, fill < 0.9
            else { return nil }
            return Disc(
                x: Double(x0 + c.minX) + bw / 2,
                y: Double(y0 + c.minY) + bh / 2,
                diameter: d)
        }.sorted { $0.x < $1.x }

        guard candidates.count >= 3 else { return nil }
        for i in 0...(candidates.count - 3) {
            let (a, b, c) = (candidates[i], candidates[i + 1], candidates[i + 2])
            let d = a.diameter
            let tol = max(2, 0.1 * d)
            let pitch1 = b.x - a.x
            let pitch2 = c.x - b.x
            guard
                a.x - windowOrigin.x <= maxLeadingOffset * scale,
                abs(b.diameter - d) <= tol, abs(c.diameter - d) <= tol,
                abs(b.y - a.y) <= 2, abs(c.y - a.y) <= 2,
                abs(pitch1 - pitch2) <= 3,
                pitch1 >= 1.2 * d, pitch1 <= 2.2 * d
            else { continue }
            return [a, b, c]
        }
        return nil
    }

    struct Component {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min, count = 0
    }

    /// 4-connected components of `mask`, by iterative flood fill.
    static func components(_ mask: [Bool], width: Int, height: Int) -> [Component] {
        var seen = [Bool](repeating: false, count: mask.count)
        var out: [Component] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            var c = Component()
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % width
                let y = i / width
                c.minX = min(c.minX, x)
                c.maxX = max(c.maxX, x)
                c.minY = min(c.minY, y)
                c.maxY = max(c.maxY, y)
                c.count += 1
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let n = ny * width + nx
                    if mask[n] && !seen[n] {
                        seen[n] = true
                        stack.append(n)
                    }
                }
            }
            out.append(c)
        }
        return out
    }

    /// The most common opaque colour in the box, quantised so antialiasing noise does
    /// not split one flat fill into many.
    static func dominantColour(_ pixels: Image.Pixels, _ xs: Range<Int>, _ ys: Range<Int>)
        -> (r: Int, g: Int, b: Int)?
    {
        var counts: [Int: Int] = [:]
        for y in ys {
            for x in xs {
                let p = pixels[y * pixels.width + x]
                guard p.a >= 250 else { continue }
                counts[(Int(p.r) >> 2) << 16 | (Int(p.g) >> 2) << 8 | Int(p.b) >> 2, default: 0] += 1
            }
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return ((key >> 16 & 0xFF) << 2 + 2, (key >> 8 & 0xFF) << 2 + 2, (key & 0xFF) << 2 + 2)
    }

    /// Mean chroma over the disc's inner 70%, clear of its rim and antialiasing.
    static func meanChroma(_ pixels: Image.Pixels, _ disc: Disc) -> Double {
        let r = disc.diameter / 2 * 0.7
        var sum = 0.0
        var n = 0
        forEachPixel(pixels, around: disc, within: 0...r) { p in
            sum += Double(max(p.r, p.g, p.b) - min(p.r, p.g, p.b))
            n += 1
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    /// Mean colour of a thin ring just outside the disc: the title bar behind it.
    static func ringColour(_ pixels: Image.Pixels, _ disc: Disc) -> (r: Double, g: Double, b: Double) {
        let r = disc.diameter / 2
        var sum = (0.0, 0.0, 0.0)
        var n = 0.0
        forEachPixel(pixels, around: disc, within: (r + 2)...(r + 4)) { p in
            guard p.a >= 250 else { return }
            sum.0 += Double(p.r)
            sum.1 += Double(p.g)
            sum.2 += Double(p.b)
            n += 1
        }
        guard n > 0 else { return (128, 128, 128) }
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }

    private static func forEachPixel(
        _ pixels: Image.Pixels, around disc: Disc, within radii: ClosedRange<Double>,
        _ body: ((r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Void
    ) {
        let reach = Int(radii.upperBound.rounded(.up)) + 1
        let cx = Int(disc.x)
        let cy = Int(disc.y)
        for y in max(0, cy - reach)..<min(pixels.height, cy + reach + 1) {
            for x in max(0, cx - reach)..<min(pixels.width, cx + reach + 1) {
                let dist = hypot(Double(x) + 0.5 - disc.x, Double(y) + 0.5 - disc.y)
                if radii.contains(dist) { body(pixels[y * pixels.width + x]) }
            }
        }
    }

    static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255
    }

    // MARK: - Paint

    struct Stop {
        /// Fraction of the diameter, top to bottom.
        let at: Double
        let rgb: UInt32
        let alpha: Double
    }

    struct Button {
        /// The disc's body, a vertical gradient.
        let body: [Stop]
        /// The edge ring, a vertical gradient of its own: dark buttons are glossed
        /// light at top and bottom, light buttons are outlined dark down the sides.
        let rim: [Stop]
    }

    struct Palette {
        let buttons: [Button]

        /// Sampled from the real buttons. Opaque, with a light gloss on the top and
        /// bottom edges and none at the sides.
        static let dark = Palette(buttons: [
            Button(
                body: [
                    Stop(at: 0.10, rgb: 0xF8645A, alpha: 1), Stop(at: 0.35, rgb: 0xF55047, alpha: 1),
                    Stop(at: 0.60, rgb: 0xF2635B, alpha: 1), Stop(at: 0.90, rgb: 0xEF6760, alpha: 1),
                ],
                rim: gloss(top: 0xFFA59C, bottom: 0xFFBCB4)),
            Button(
                body: [
                    Stop(at: 0.10, rgb: 0xFBB401, alpha: 1), Stop(at: 0.35, rgb: 0xFCB200, alpha: 1),
                    Stop(at: 0.60, rgb: 0xFDC301, alpha: 1), Stop(at: 0.90, rgb: 0xFECF30, alpha: 1),
                ],
                rim: gloss(top: 0xFFE24D, bottom: 0xFFE84B)),
            Button(
                body: [
                    Stop(at: 0.10, rgb: 0x45C418, alpha: 1), Stop(at: 0.35, rgb: 0x00BC00, alpha: 1),
                    Stop(at: 0.60, rgb: 0x3AC009, alpha: 1), Stop(at: 0.90, rgb: 0x50C33B, alpha: 1),
                ],
                rim: gloss(top: 0x8BF16E, bottom: 0x6EE159)),
        ])

        /// Translucent — the body fades to ~80% opacity toward the bottom, and more for
        /// green — with a dark outline strongest at the sides.
        static let light = Palette(buttons: [
            Button(
                body: [
                    Stop(at: 0.10, rgb: 0xFC6C62, alpha: 0.99), Stop(at: 0.50, rgb: 0xF96E63, alpha: 0.93),
                    Stop(at: 0.90, rgb: 0xF57269, alpha: 0.80),
                ],
                rim: outline(0xC50505)),
            Button(
                body: [
                    Stop(at: 0.10, rgb: 0xFAB51B, alpha: 0.94), Stop(at: 0.50, rgb: 0xFBC128, alpha: 0.97),
                    Stop(at: 0.90, rgb: 0xFFD034, alpha: 0.92),
                ],
                rim: outline(0x9F0A02)),
            Button(
                body: [
                    Stop(at: 0.10, rgb: 0x5CCC24, alpha: 0.99), Stop(at: 0.50, rgb: 0x68CD39, alpha: 0.89),
                    Stop(at: 0.90, rgb: 0x78D34B, alpha: 0.73),
                ],
                rim: outline(0x045402)),
        ])

        static func gloss(top: UInt32, bottom: UInt32) -> [Stop] {
            [
                Stop(at: 0, rgb: top, alpha: 1), Stop(at: 0.2, rgb: top, alpha: 0),
                Stop(at: 0.8, rgb: bottom, alpha: 0), Stop(at: 1, rgb: bottom, alpha: 1),
            ]
        }

        /// Faint where the ring runs horizontal (top and bottom), full down the sides.
        static func outline(_ rgb: UInt32) -> [Stop] {
            [
                Stop(at: 0, rgb: rgb, alpha: 0.1), Stop(at: 0.3, rgb: rgb, alpha: 0.75),
                Stop(at: 0.7, rgb: rgb, alpha: 0.75), Stop(at: 1, rgb: rgb, alpha: 0.35),
            ]
        }
    }

    /// Rim thickness as a fraction of the diameter: half a point on a 14pt button.
    static let rimFraction = 0.04

    static func paint(_ button: Button, disc: Disc, in ctx: CGContext, height: Double) {
        let r = disc.diameter / 2
        // CoreGraphics is bottom-up; the disc was measured top-down.
        let cy = height - disc.y
        let outer = CGRect(x: disc.x - r, y: cy - r, width: disc.diameter, height: disc.diameter)
        let top = CGPoint(x: disc.x, y: outer.maxY)
        let bottom = CGPoint(x: disc.x, y: outer.minY)

        ctx.saveGState()
        ctx.addEllipse(in: outer)
        ctx.clip()
        if let body = gradient(button.body) {
            ctx.drawLinearGradient(body, start: top, end: bottom, options: [])
        }
        ctx.restoreGState()

        let inset = disc.diameter * rimFraction
        ctx.saveGState()
        ctx.addEllipse(in: outer)
        ctx.addEllipse(in: outer.insetBy(dx: inset, dy: inset))
        ctx.clip(using: .evenOdd)
        if let rim = gradient(button.rim) {
            ctx.drawLinearGradient(rim, start: top, end: bottom, options: [])
        }
        ctx.restoreGState()
    }

    static func gradient(_ stops: [Stop]) -> CGGradient? {
        let colours = stops.map {
            CGColor(
                srgbRed: Double($0.rgb >> 16 & 0xFF) / 255,
                green: Double($0.rgb >> 8 & 0xFF) / 255,
                blue: Double($0.rgb & 0xFF) / 255,
                alpha: $0.alpha)
        }
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colours as CFArray,
            locations: stops.map { CGFloat($0.at) })
    }
}
