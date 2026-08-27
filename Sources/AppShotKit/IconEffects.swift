import CoreGraphics
import Foundation

/// Drop shadows and inner shadows applied to an icon's mark.
///
/// ## Why this is a flag and not something you author in the SVG
///
/// You can write a `<filter>` in a mark and it will look right in a browser. It will not
/// look right in the app icon, and nothing will say so: marks are rasterised through
/// `NSImage`, whose SVG support has no filter support at all, so the filter is **silently
/// dropped**. The website and the Dock then show different artwork from one file, which is
/// the exact failure `IconSVG` exists to prevent — reintroduced one layer down.
///
/// Rather than grow a browser-grade SVG engine, appshot takes the effects as parameters and
/// applies them itself to every rendering: composited into the `.appiconset` slots and the
/// `.icon` mark layer, and emitted as real `<filter>` elements into the SVG, where browsers
/// do the same arithmetic. One spec, three renderings, no silent divergence.
///
/// `Icon.filterWarning(for:)` catches the other half — a mark that still carries its own
/// filter — because that is the case where you'd otherwise be looking at the right icon on
/// the web and wondering why the Dock disagreed.
///
/// ## Units
///
/// `distance` and `blur` are in **canvas pixels on a 1024 canvas**, and scale with the
/// output. That is what makes one spec serve a 16pt slot and a 1024pt layer: an effect
/// authored against the canvas keeps its proportions everywhere, where an effect in output
/// pixels would swamp the small slots.
///
/// `blur` is the Gaussian **standard deviation** — the same quantity SVG spells
/// `stdDeviation`. Deliberately not a "radius" or a "size": those mean different multiples
/// of sigma in every design tool, and the number here has to survive being written into an
/// SVG filter and still match the raster. Design tools that show a "blur" slider are
/// usually quoting about 2σ, so halve theirs.
///
/// `angle` is in degrees, counter-clockwise from east with y up, and it points at **where
/// the shading lands** — 270° shades the bottom, 315° the bottom right, for both kinds.
/// That is the rule a design tool's inspector follows, so a number copied out of one
/// carries over unchanged. See `offset` for why the two kinds displace in opposite
/// directions to honour it.
public struct IconEffect: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Cast outside the mark, drawn behind it.
        case drop
        /// Cast inside the mark's own shape, drawn over it. This is what gives a flat
        /// letterform depth, and it is the one that cannot be faked with a second copy
        /// of the artwork.
        case inner
    }

    public var kind: Kind
    public var angleDegrees: Double
    public var distance: Double
    public var blur: Double
    public var opacity: Double
    public var color: String

    public init(
        kind: Kind,
        angleDegrees: Double = 270,
        distance: Double = 0,
        blur: Double = 0,
        opacity: Double = 1,
        color: String = "#000000"
    ) {
        self.kind = kind
        self.angleDegrees = angleDegrees
        self.distance = distance
        self.blur = blur
        self.opacity = opacity
        self.color = color
    }

    /// How far to displace the silhouette, in canvas units, y **down** — the direction a
    /// pixel buffer and an SVG both count in, and the opposite of the angle's convention.
    ///
    /// **An inner shadow displaces the opposite way, and that is not a sign error.** The
    /// rule the angle obeys is "this is where the shading lands", which is what every
    /// design tool's inspector means and therefore what a number copied out of one will
    /// mean here. A drop shadow lands where it is displaced to, so the two agree. An inner
    /// shadow is the *gap* left by displacing the silhouette, which appears on the far
    /// side — so producing shading at 270° means displacing toward 90°.
    ///
    /// Getting this backwards is invisible in code review and obvious on screen: the icon
    /// simply looks lit from the wrong side.
    var offset: (dx: Double, dy: Double) {
        let radians = angleDegrees * .pi / 180
        let sign: Double = kind == .inner ? -1 : 1
        return (sign * distance * cos(radians), sign * -distance * sin(radians))
    }

    // MARK: - Parsing

    /// Parse `angle=270,distance=6,blur=12,opacity=0.22,color=#000000`.
    ///
    /// Named rather than positional. Five numbers in a row is exactly the shape where a
    /// transposition produces a plausible icon rather than an error, and these are read
    /// off a design tool's inspector one field at a time anyway.
    ///
    /// Every key is optional; what is left out takes the documented default. An unknown
    /// key is an error rather than a shrug, because the whole point is that a mistyped
    /// effect must not silently render as no effect.
    public static func parse(_ spec: String, kind: Kind) throws -> IconEffect {
        var effect = IconEffect(kind: kind)
        var seen: Set<String> = []

        for field in spec.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw AppShotError.invalidIconEffect(
                    spec, reason: "expected key=value, got \"\(field.trimmed)\"")
            }
            let key = parts[0].trimmed.lowercased()
            let value = parts[1].trimmed

            guard seen.insert(key).inserted else {
                throw AppShotError.invalidIconEffect(spec, reason: "\(key) given twice")
            }

            func number() throws -> Double {
                guard let v = Double(value) else {
                    throw AppShotError.invalidIconEffect(
                        spec, reason: "\(key) needs a number, got \"\(value)\"")
                }
                return v
            }

            switch key {
            case "angle": effect.angleDegrees = try number()
            case "distance": effect.distance = try number()
            case "blur":
                let v = try number()
                guard v >= 0 else {
                    throw AppShotError.invalidIconEffect(spec, reason: "blur cannot be negative")
                }
                effect.blur = v
            case "opacity":
                let v = try number()
                guard v >= 0, v <= 1 else {
                    throw AppShotError.invalidIconEffect(
                        spec, reason: "opacity is 0–1, got \(v)")
                }
                effect.opacity = v
            case "color", "colour":
                guard Image.color(hex: value) != nil else {
                    throw AppShotError.invalidIconEffect(
                        spec, reason: "\(key) needs #RRGGBB, got \"\(value)\"")
                }
                effect.color = value
            default:
                throw AppShotError.invalidIconEffect(
                    spec,
                    reason: "unknown key \"\(key)\"; known: angle, distance, blur, opacity, color")
            }
        }
        return effect
    }
}

extension StringProtocol {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

// MARK: - Applying to a raster

extension IconEffect {
    /// Composite `effects` onto an already-rendered mark layer.
    ///
    /// The mark arrives on its own transparent layer — not drawn onto the plate — because
    /// an inner shadow is defined by the mark's alpha and a drop shadow has to go *behind*
    /// it. Neither is expressible once the mark has been painted onto a background.
    ///
    /// Order is the order given: drop shadows stack back to front beneath the mark, inner
    /// shadows stack over it. That matches how the same list reads in a layer-style panel.
    static func apply(
        _ effects: [IconEffect], to mark: CGImage, canvas: Double
    ) throws -> CGImage {
        guard !effects.isEmpty else { return mark }
        let width = mark.width
        let height = mark.height
        guard let source = Image.pixels(mark) else {
            throw AppShotError.iconEffectFailed("could not read the mark's pixels")
        }
        // Canvas units to output pixels. One number, applied to both distance and blur, so
        // a slot renders a scaled copy of the same effect rather than a different one.
        let k = Double(width) / canvas

        // Straight alpha, 0–1. The shadow maths is all about coverage, and premultiplied
        // colour would drag the mark's own hue into every mask.
        var alpha = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            alpha[i] = Double(source[i].a) / 255
        }

        // Premultiplied float accumulator, composited in sRGB. sRGB rather than linear
        // because that is what CoreGraphics does everywhere else here, and because the
        // emitted SVG filter pins `color-interpolation-filters="sRGB"` to agree with it.
        var out = [Double](repeating: 0, count: width * height * 4)

        func over(color: (r: Double, g: Double, b: Double), coverage: [Double], opacity: Double) {
            for i in 0..<(width * height) {
                let a = coverage[i] * opacity
                guard a > 0 else { continue }
                let inv = 1 - a
                out[i * 4 + 0] = color.r * a + out[i * 4 + 0] * inv
                out[i * 4 + 1] = color.g * a + out[i * 4 + 1] * inv
                out[i * 4 + 2] = color.b * a + out[i * 4 + 2] * inv
                out[i * 4 + 3] = a + out[i * 4 + 3] * inv
            }
        }

        func components(_ hex: String) throws -> (r: Double, g: Double, b: Double) {
            guard let c = Image.color(hex: hex), let comps = c.components, comps.count >= 3 else {
                throw AppShotError.invalidIconEffect(hex, reason: "not a #RRGGBB colour")
            }
            return (comps[0], comps[1], comps[2])
        }

        for effect in effects where effect.kind == .drop {
            let (dx, dy) = effect.offset
            var mask = shift(alpha, width: width, height: height, dx: dx * k, dy: dy * k)
            mask = blurred(mask, width: width, height: height, sigma: effect.blur * k)
            over(color: try components(effect.color), coverage: mask, opacity: effect.opacity)
        }

        // The mark itself, straight from its own pixels — premultiplied already.
        for i in 0..<(width * height) {
            let p = source[i]
            let a = Double(p.a) / 255
            let inv = 1 - a
            out[i * 4 + 0] = Double(p.r) / 255 + out[i * 4 + 0] * inv
            out[i * 4 + 1] = Double(p.g) / 255 + out[i * 4 + 1] * inv
            out[i * 4 + 2] = Double(p.b) / 255 + out[i * 4 + 2] * inv
            out[i * 4 + 3] = a + out[i * 4 + 3] * inv
        }

        for effect in effects where effect.kind == .inner {
            let (dx, dy) = effect.offset
            var shifted = shift(alpha, width: width, height: height, dx: dx * k, dy: dy * k)
            shifted = blurred(shifted, width: width, height: height, sigma: effect.blur * k)
            // Inside the mark AND outside the offset copy: the ring the light does not
            // reach. Clamped because a blur can push a sample marginally past 1.
            var ring = [Double](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                ring[i] = max(0, min(1, alpha[i] * (1 - shifted[i])))
            }
            over(color: try components(effect.color), coverage: ring, opacity: effect.opacity)
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height * 4) {
            bytes[i] = UInt8(max(0, min(255, (out[i] * 255).rounded())))
        }
        guard let image = Image.image(rgbaPremultiplied: bytes, width: width, height: height) else {
            throw AppShotError.iconEffectFailed("could not encode the composited mark")
        }
        return image
    }

    // MARK: - Signal processing

    /// Sample `buffer` offset by (`dx`, `dy`) pixels, bilinearly, zero outside.
    ///
    /// Bilinear rather than a whole-pixel move because the same effect is rendered at ten
    /// sizes: a distance of 6 canvas units is 0.09px in the 16pt slot, and rounding that
    /// to zero is how an icon set ends up with the effect at large sizes and not at small.
    /// Zero outside rather than clamped: past the mark's edge there is genuinely nothing,
    /// and edge-clamping would smear the outermost row outward into the shadow.
    static func shift(_ buffer: [Double], width: Int, height: Int, dx: Double, dy: Double)
        -> [Double]
    {
        guard dx != 0 || dy != 0 else { return buffer }
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = Double(y) - dy
            let y0 = Int(sy.rounded(.down))
            let fy = sy - Double(y0)
            for x in 0..<width {
                let sx = Double(x) - dx
                let x0 = Int(sx.rounded(.down))
                let fx = sx - Double(x0)

                func at(_ px: Int, _ py: Int) -> Double {
                    guard px >= 0, px < width, py >= 0, py < height else { return 0 }
                    return buffer[py * width + px]
                }
                let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
                let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
                out[y * width + x] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    /// Separable Gaussian blur, `sigma` in pixels.
    ///
    /// Written out rather than handed to Core Image because this has to be reproducible:
    /// the same spec must give the same bytes on every machine and every OS version, or
    /// the golden-image gate that guards everything else here would flag the icon set as
    /// drifting whenever the GPU path changed underneath it.
    static func blurred(_ buffer: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        guard sigma > 0.01 else { return buffer }
        // 3σ each side holds 99.7% of the kernel; past that the weights round to nothing.
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Double](repeating: 0, count: radius * 2 + 1)
        var sum = 0.0
        for i in -radius...radius {
            let w = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = w
            sum += w
        }
        for i in kernel.indices { kernel[i] /= sum }

        var horizontal = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc = 0.0
                for t in -radius...radius {
                    let sx = x + t
                    guard sx >= 0, sx < width else { continue }
                    acc += buffer[row + sx] * kernel[t + radius]
                }
                horizontal[row + x] = acc
            }
        }

        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var acc = 0.0
                for t in -radius...radius {
                    let sy = y + t
                    guard sy >= 0, sy < height else { continue }
                    acc += horizontal[sy * width + x] * kernel[t + radius]
                }
                out[y * width + x] = acc
            }
        }
        return out
    }
}

// MARK: - SVG

extension IconEffect {
    /// The filter id the composed SVG hangs these off.
    static let filterID = "appshot-mark-effects"

    /// Emit `effects` as an SVG `<filter>` producing the same result as `apply`.
    ///
    /// `color-interpolation-filters="sRGB"` is not optional. SVG's default for filters is
    /// linearRGB, which is a different — and, next to the raster path, wrong — answer for
    /// every blur and every composite here. Left out, the web copy and the app icon
    /// disagree by more than the effect is usually worth.
    ///
    /// The region is padded well past the element because a drop shadow is drawn outside
    /// the mark by construction, and the default -10%/120% filter region clips it.
    static func svgFilter(_ effects: [IconEffect], scale: Double) -> [String] {
        var lines: [String] = []
        lines.append(
            "    <filter id=\"\(filterID)\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\""
                + " color-interpolation-filters=\"sRGB\">")

        var behind: [String] = []
        var above: [String] = []

        for (index, effect) in effects.enumerated() {
            let (dx, dy) = effect.offset
            let result = "appshot-fx\(index)"
            let offsetName = "\(result)-o"
            let blurName = "\(result)-b"
            let floodName = "\(result)-c"

            lines.append(
                "      <feOffset in=\"SourceAlpha\" dx=\"\(IconSVG.n(dx * scale))\""
                    + " dy=\"\(IconSVG.n(dy * scale))\" result=\"\(offsetName)\"/>")
            if effect.blur > 0 {
                lines.append(
                    "      <feGaussianBlur in=\"\(offsetName)\""
                        + " stdDeviation=\"\(IconSVG.n(effect.blur * scale))\""
                        + " result=\"\(blurName)\"/>")
            }
            let shaped = effect.blur > 0 ? blurName : offsetName

            switch effect.kind {
            case .drop:
                lines.append(
                    "      <feFlood flood-color=\"\(effect.color)\""
                        + " flood-opacity=\"\(IconSVG.n(effect.opacity))\" result=\"\(floodName)\"/>")
                lines.append(
                    "      <feComposite in=\"\(floodName)\" in2=\"\(shaped)\" operator=\"in\""
                        + " result=\"\(result)\"/>")
                behind.append(result)
            case .inner:
                // SourceAlpha minus the offset copy: the ring inside the shape that the
                // shifted silhouette leaves uncovered.
                let ringName = "\(result)-r"
                lines.append(
                    "      <feComposite in=\"SourceAlpha\" in2=\"\(shaped)\" operator=\"out\""
                        + " result=\"\(ringName)\"/>")
                lines.append(
                    "      <feFlood flood-color=\"\(effect.color)\""
                        + " flood-opacity=\"\(IconSVG.n(effect.opacity))\" result=\"\(floodName)\"/>")
                lines.append(
                    "      <feComposite in=\"\(floodName)\" in2=\"\(ringName)\" operator=\"in\""
                        + " result=\"\(result)\"/>")
                above.append(result)
            }
        }

        lines.append("      <feMerge>")
        for name in behind { lines.append("        <feMergeNode in=\"\(name)\"/>") }
        lines.append("        <feMergeNode in=\"SourceGraphic\"/>")
        for name in above { lines.append("        <feMergeNode in=\"\(name)\"/>") }
        lines.append("      </feMerge>")
        lines.append("    </filter>")
        return lines
    }
}
