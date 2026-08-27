import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Icon effects exist because an SVG `<filter>` is silently dropped when a mark is
/// rasterised, so the website and the Dock render different artwork from one file with
/// nothing to say why. These pin the two halves of that: the effects actually reach the
/// pixels, and the SVG output carries the same effect rather than the mark's own.
struct IconEffectTests {
    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-effect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A white square filling its viewBox, so the mark's alpha is a known rectangle and
    /// every shadow's geometry can be read off the pixels rather than eyeballed.
    static func writeSquare(in dir: URL) throws -> URL {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <rect x="0" y="0" width="10" height="10" fill="#ffffff"/>
            </svg>
            """
        let url = dir.appending(path: "square.svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        let px = Image.pixels(image)!
        return px[y * px.width + x]
    }

    // MARK: - Parsing

    @Test("named fields parse, in any order, with defaults for what is left out")
    func parses() throws {
        let e = try IconEffect.parse(
            "opacity=0.22,angle=315,color=#FF8800,distance=64,blur=3", kind: .drop)
        #expect(e.kind == .drop)
        #expect(e.angleDegrees == 315)
        #expect(e.distance == 64)
        #expect(e.blur == 3)
        #expect(abs(e.opacity - 0.22) < 1e-9)
        #expect(e.color == "#FF8800")

        let sparse = try IconEffect.parse("distance=12", kind: .inner)
        #expect(sparse.distance == 12)
        #expect(sparse.angleDegrees == 270)
        #expect(sparse.opacity == 1)
        #expect(sparse.color == "#000000")
    }

    /// A mistyped effect has to fail loudly. Rendering as *no* effect would reproduce
    /// exactly the silent-drop bug the feature exists to remove.
    @Test("a bad spec is an error rather than a no-op")
    func rejectsBadSpecs() {
        for spec in [
            "distance", "distance=lots", "opacity=4", "blur=-1", "color=red",
            "shadow=270", "distance=1,distance=2",
        ] {
            #expect(throws: AppShotError.self) {
                try IconEffect.parse(spec, kind: .drop)
            }
        }
    }

    @Test("angle is counter-clockwise from east with y up, so 270 casts downward")
    func angleConvention() throws {
        let down = try IconEffect.parse("angle=270,distance=10", kind: .drop)
        #expect(abs(down.offset.dx) < 1e-9)
        #expect(abs(down.offset.dy - 10) < 1e-9)  // y down

        let downRight = try IconEffect.parse("angle=315,distance=10", kind: .drop)
        #expect(abs(downRight.offset.dx - 7.0710678) < 1e-5)
        #expect(abs(downRight.offset.dy - 7.0710678) < 1e-5)
    }

    /// The angle means "where the shading lands" for both kinds, which an inner shadow can
    /// only honour by displacing the other way — it is the gap the displacement leaves.
    /// Left as a plain sign copy, every effect ported from a design tool would light the
    /// icon from the wrong side, and nothing but eyes would catch it.
    @Test("an inner shadow displaces opposite the angle, so the shading still lands there")
    func innerDisplacesOppositely() throws {
        let inner = try IconEffect.parse("angle=270,distance=10", kind: .inner)
        #expect(abs(inner.offset.dy + 10) < 1e-9, "displaced up, so the gap is at the bottom")

        let drop = try IconEffect.parse("angle=270,distance=10", kind: .drop)
        #expect(drop.offset.dy == -inner.offset.dy)
    }

    // MARK: - Raster

    @Test("a drop shadow paints outside the mark and leaves the mark itself alone")
    func dropShadowLandsOutside() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeSquare(in: dir)

        // Mark fills half the canvas: 256..768 of 1024. A 64-unit shadow straight down
        // therefore lands in 768..832, which is canvas, not mark.
        let options = Icon.Options(
            plate: .none, markFraction: 0.5,
            effects: [try IconEffect.parse("angle=270,distance=64,opacity=1,color=#FF0000", kind: .drop)])
        let image = try IconComposer.renderLayer(mark: mark, options: options)

        let inside = Self.pixel(image, 512, 512)
        #expect(inside.r == 255 && inside.g == 255 && inside.b == 255, "the mark stays white")

        let below = Self.pixel(image, 512, 800)
        #expect(below.a > 200, "the shadow is opaque below the mark")
        #expect(below.r > 200 && below.g < 60, "and it is the shadow's colour")

        let above = Self.pixel(image, 512, 224)
        #expect(above.a < 8, "nothing is cast upward")
    }

    /// The one an SVG filter would express and a rasterised mark would not, and the reason
    /// the feature is not just "draw the artwork twice": an inner shadow is bounded by the
    /// mark's own alpha, so no second copy of the artwork can stand in for it.
    @Test("an inner shadow paints inside the mark and never outside it")
    func innerShadowStaysInside() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeSquare(in: dir)

        let options = Icon.Options(
            plate: .none, markFraction: 0.5,
            effects: [
                try IconEffect.parse("angle=270,distance=40,opacity=1,color=#FF0000", kind: .inner)
            ])
        let image = try IconComposer.renderLayer(mark: mark, options: options)

        let justOutside = Self.pixel(image, 512, 790)
        #expect(justOutside.a < 8, "an inner shadow never leaves the shape")

        // Cast downward: the band sits along the shape's own bottom edge, inside it.
        let bottomEdge = Self.pixel(image, 512, 760)
        #expect(bottomEdge.r > 200 && bottomEdge.g < 60, "the bottom inner edge is shaded")

        let topEdge = Self.pixel(image, 512, 264)
        #expect(topEdge.g > 200, "the top inner edge is untouched, so it stays white")

        let middle = Self.pixel(image, 512, 512)
        #expect(middle.g > 200, "and so is the middle")
    }

    /// Effects are authored against the 1024 canvas so one spec serves every slot. If they
    /// were in output pixels a 6px offset would swamp the 16pt icon.
    @Test("effects scale with the slot rather than staying put in output pixels")
    func scalesWithTheSlot() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeSquare(in: dir)
        let options = Icon.Options(
            plate: .none, markFraction: 0.5,
            effects: [
                try IconEffect.parse("angle=270,distance=128,opacity=1,color=#FF0000", kind: .drop)
            ])

        // The shadow's reach as a fraction of the canvas must match at both sizes.
        func shadowBottom(pixels: Int) throws -> Double {
            let image = try IconComposer.renderLayer(mark: mark, pixels: pixels, options: options)
            let px = Image.pixels(image)!
            let x = pixels / 2
            var lowest = 0
            for y in 0..<pixels where px[y * pixels + x].a > 128 { lowest = y }
            return Double(lowest) / Double(pixels)
        }
        let large = try shadowBottom(pixels: 1024)
        let small = try shadowBottom(pixels: 128)
        #expect(abs(large - small) < 0.02, "large \(large) small \(small)")
    }

    @Test("no effects means the mark is returned untouched")
    func emptyIsIdentity() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeSquare(in: dir)
        let plain = try IconComposer.renderLayer(
            mark: mark, options: Icon.Options(plate: .none, markFraction: 0.5))
        let empty = try IconComposer.renderLayer(
            mark: mark, options: Icon.Options(plate: .none, markFraction: 0.5, effects: []))
        #expect(Image.pngData(plain) == Image.pngData(empty))
    }

    // MARK: - SVG

    /// The whole point: the same spec has to reach the vector output too, or the site and
    /// the app icon diverge again one layer down from where they used to.
    @Test("the SVG output carries the effects as a real filter")
    func svgCarriesTheFilter() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeSquare(in: dir)

        let svg = try IconSVG.compose(
            mark: mark,
            options: Icon.Options(
                plate: .solid("#123456"), markFraction: 0.5,
                effects: [
                    try IconEffect.parse("angle=315,distance=64,blur=0,opacity=0.22", kind: .drop),
                    try IconEffect.parse(
                        "angle=270,distance=6,blur=12,opacity=0.7,color=#F6821E", kind: .inner),
                ]))

        #expect(svg.contains("<filter id=\"\(IconEffect.filterID)\""))
        #expect(svg.contains("filter=\"url(#\(IconEffect.filterID))\""))
        // sRGB rather than SVG's linearRGB default, or the browser and the raster path
        // compute visibly different blurs from the same number.
        #expect(svg.contains("color-interpolation-filters=\"sRGB\""))
        #expect(svg.contains("flood-opacity=\"0.22\""))
        #expect(svg.contains("stdDeviation=\"12\""))
        #expect(svg.contains("flood-color=\"#F6821E\""))
        // The inner shadow's defining move: SourceAlpha minus the offset copy.
        #expect(svg.contains("operator=\"out\""))
        // The drop shadow goes behind the artwork and the inner shadow over it.
        let merge = svg.range(of: "<feMerge>")!
        let tail = String(svg[merge.lowerBound...])
        let source = tail.range(of: "SourceGraphic")!
        #expect(tail.range(of: "appshot-fx0")!.lowerBound < source.lowerBound)
        #expect(tail.range(of: "appshot-fx1")!.lowerBound > source.lowerBound)
    }

    @Test("no effects leaves the SVG without a filter at all")
    func svgWithoutEffects() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeSquare(in: dir)
        let svg = try IconSVG.compose(
            mark: mark, options: Icon.Options(plate: .solid("#123456"), markFraction: 0.5))
        #expect(!svg.contains("<filter"))
        #expect(!svg.contains("filter=\"url"))
    }

    // MARK: - The silent drop this feature exists for

    @Test("a mark carrying its own SVG filter is called out rather than quietly flattened")
    func warnsAboutAuthoredFilters() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let filtered = dir.appending(path: "filtered.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
          <defs><filter id="f"><feGaussianBlur stdDeviation="1"/></filter></defs>
          <rect width="10" height="10" fill="#fff" filter="url(#f)"/>
        </svg>
        """.write(to: filtered, atomically: true, encoding: .utf8)
        #expect(Icon.filterWarning(for: filtered) != nil)

        let plain = try Self.writeSquare(in: dir)
        #expect(Icon.filterWarning(for: plain) == nil)
    }
}
