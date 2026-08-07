import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The vector output exists to stop a marketing site hand-transcribing the app's icon,
/// so the property that matters is not "it is valid SVG" — it is that this file and the
/// `.icon` beside it are the *same drawing*. The pins here are therefore placement,
/// gradient axis and rendered pixels against the raster path, not markup shape.
struct IconSVGTests {
    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-iconsvg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deliberately not square, with a non-zero viewBox origin, and asymmetric in **both**
    /// axes. The origin and the aspect are what naive placement arithmetic drops; the
    /// asymmetry is what makes a flipped or mirrored composition fail rather than pass by
    /// coincidence, which a mark centred in its own artboard would let through.
    static func writeMark(in dir: URL, name: String = "mark.svg") throws -> URL {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="2 4 52 40">
              <rect x="6" y="8" width="16" height="10" fill="currentColor"/>
              <rect x="32" y="30" width="18" height="12" fill="currentColor"/>
            </svg>
            """
        let url = dir.appending(path: name)
        try svg.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Bounding box of everything that is not the plate colour, as (minX, minY, maxX, maxY).
    ///
    /// Geometry rather than pixels: two rasterisers disagree by a level or two along an
    /// antialiased edge, so comparing them pixel-for-pixel pins the renderer instead of
    /// the placement. Where the mark *lands* is the thing this output has to get right.
    static func glyphBox(_ image: CGImage) -> (Int, Int, Int, Int)? {
        let px = Image.pixels(image)!
        let plate = px[0]
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<px.height {
            for x in 0..<px.width {
                let p = px[y * px.width + x]
                // Well clear of any antialiased rim, so the box is the shape's own.
                let far =
                    abs(Int(p.r) - Int(plate.r)) > 96 || abs(Int(p.g) - Int(plate.g)) > 96
                    || abs(Int(p.b) - Int(plate.b)) > 96
                if far {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// Rasterise composed SVG source the same way a browser or `sharp` would.
    static func rasterize(_ svg: String, pixels: Int, in dir: URL) throws -> CGImage {
        let url = dir.appending(path: "composed-\(UUID().uuidString).svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        guard let image = NSImage(contentsOf: url),
            let ctx = Image.context(width: pixels, height: pixels)
        else { throw AppShotError.imageDecodeFailed(url) }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(
            in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current = previous
        guard let out = ctx.makeImage() else { throw AppShotError.imageDecodeFailed(url) }
        return out
    }

    static func pixel(
        _ image: CGImage, _ x: Int, _ y: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let px = Image.pixels(image)!
        return px[y * px.width + x]
    }

    // MARK: - Same drawing as the raster path

    /// The whole point: rasterising the SVG and rendering the `.icon` layer from the same
    /// inputs must produce the same picture. Compared as pixels rather than as markup,
    /// because markup can agree while the drawing does not.
    @Test func theSVGRendersAsTheRasterLayerDoes() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let options = Icon.Options(
            plate: .solid("#0b0b0c"), tint: "#ffffff", markFraction: 0.7)

        // Square plate, so the two differ in nothing but their renderer.
        let svg = try IconSVG.compose(
            mark: mark, pixels: 128, options: options, cornerRadius: 0)
        let fromSVG = try Self.rasterize(svg, pixels: 128, in: dir)
        let fromRaster = try IconComposer.renderLayer(mark: mark, pixels: 128, options: options)

        // Where the mark lands, to within a pixel of rounding.
        let a = try #require(Self.glyphBox(fromSVG))
        let b = try #require(Self.glyphBox(fromRaster))
        #expect(abs(a.0 - b.0) <= 1, "minX \(a.0) vs \(b.0)")
        #expect(abs(a.1 - b.1) <= 1, "minY \(a.1) vs \(b.1)")
        #expect(abs(a.2 - b.2) <= 1, "maxX \(a.2) vs \(b.2)")
        #expect(abs(a.3 - b.3) <= 1, "maxY \(a.3) vs \(b.3)")

        // And that the two shapes are where they are for the same reason: probes deep
        // inside each block and deep inside the plate, well away from every edge. The
        // mark is asymmetric in both axes, so a flipped or mirrored composition puts a
        // block where one of these expects plate.
        for (x, y) in [(40, 45), (86, 84), (100, 30), (30, 100)] {
            let p = Self.pixel(fromSVG, x, y)
            let q = Self.pixel(fromRaster, x, y)
            #expect(abs(Int(p.r) - Int(q.r)) <= 8, "r at \(x),\(y)")
            #expect(abs(Int(p.g) - Int(q.g)) <= 8, "g at \(x),\(y)")
            #expect(abs(Int(p.b) - Int(q.b)) <= 8, "b at \(x),\(y)")
        }
    }

    /// Placement comes from `IconComposer.markBox`, and a viewBox with a non-zero origin
    /// has to be subtracted out or the mark sits offset by its own artboard margin.
    @Test func theMarkIsPlacedFromTheSharedBox() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let svg = try IconSVG.compose(
            mark: mark, pixels: 1024, options: Icon.Options(markFraction: 0.5))

        // 52x40 aspect-fitted into a 512 box is width-limited: scale = 512/52.
        let scale = 512.0 / 52.0
        // translate = box origin − viewBox origin × scale.
        let expectedX = (1024.0 - 512.0) / 2 - 2 * scale
        let expectedY = (1024.0 - 40 * scale) / 2 - 4 * scale
        #expect(svg.contains("scale(\(IconSVG.n(scale)))"))
        #expect(svg.contains("translate(\(IconSVG.n(expectedX)) \(IconSVG.n(expectedY)))"))
    }

    /// The gradient is emitted in user space from the same projection the CoreGraphics
    /// path uses, so the ramp cannot run at one angle in the app and another on the site.
    @Test func theGradientAxisMatchesTheRasterPath() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let plate = try Icon.gradientPlate(hexes: ["#ff7c54", "#eaa33b"], angle: 45)
        let svg = try IconSVG.compose(
            mark: mark, pixels: 1024, options: Icon.Options(plate: plate))

        // 45° on a square canvas is corner to corner.
        #expect(svg.contains("gradientUnits=\"userSpaceOnUse\""))
        #expect(svg.contains("x1=\"0\" y1=\"0\" x2=\"1024\" y2=\"1024\""))
        #expect(svg.contains("stop-color=\"#ff7c54\""))
        #expect(svg.contains("stop-color=\"#eaa33b\""))
    }

    // MARK: - The corner radius, which is the opposite rule from a .icon

    /// Nothing masks an SVG on a web page, so this one keeps its radius — unlike the
    /// `.icon` layer, which must be square because the system masks it.
    @Test func theWebPlateKeepsItsCornerRadius() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let rounded = try IconSVG.compose(mark: mark, options: Icon.Options(plate: .solid("#000")))
        #expect(rounded.contains("rx=\"\(IconSVG.n(IconSVG.defaultCornerRadius))\""))

        // ...and 0 drops the attribute entirely, which is what an apple-touch-icon needs:
        // iOS masks that one itself, and a rounded source gets rounded twice.
        let square = try IconSVG.compose(
            mark: mark, options: Icon.Options(plate: .solid("#000")), cornerRadius: 0)
        #expect(!square.contains("rx="))
    }

    @Test func theDefaultRadiusIsApplesProportionOnAFullBleedCanvas() {
        // 185 on an 824 plate, rescaled to 1024.
        #expect(abs(IconSVG.defaultCornerRadius - 229.9029) < 0.001)
    }

    // MARK: - Reading the mark

    /// The mark's own source survives the trip — groups, comments and all — rather than
    /// being re-serialised into flat shapes, so gradients and masks inside it still work.
    @Test func theMarksBodyIsCarriedThroughVerbatim() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let svg = try IconSVG.compose(mark: mark, options: Icon.Options())
        #expect(svg.contains("width=\"16\""))
        #expect(svg.contains("width=\"18\""))
    }

    /// `--tint` on a currentColor mark, which is what the flag is documented for.
    @Test func tintDrivesCurrentColor() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let svg = try IconSVG.compose(
            mark: mark, pixels: 64,
            options: Icon.Options(plate: .solid("#000000"), tint: "#ff0000", markFraction: 0.9))
        #expect(svg.contains("color=\"#ff0000\""))

        // And it actually renders red, not black — `color` without `fill` would leave a
        // mark that inherits rather than uses currentColor drawing in the wrong one.
        let image = try Self.rasterize(svg, pixels: 64, in: dir)
        let insideTheFirstBlock = Self.pixel(image, 16, 20)
        #expect(insideTheFirstBlock.r > 200 && insideTheFirstBlock.g < 60)
    }

    /// A mark with no viewBox falls back to width/height, units and all.
    @Test func aMarkWithNoViewBoxUsesItsWidthAndHeight() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "sized.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="40px" height="20px">
          <rect x="0" y="0" width="40" height="20" fill="#123456"/>
        </svg>
        """.write(to: url, atomically: true, encoding: .utf8)

        let svg = try IconSVG.compose(mark: url, pixels: 1024, options: Icon.Options(markFraction: 0.5))
        #expect(svg.contains("scale(\(IconSVG.n(512.0 / 40.0)))"))
    }

    /// Vector out needs vector in. A PNG embedded in an SVG is vector only in its
    /// extension, and silently producing one would defeat the point of the output.
    @Test func aRasterMarkIsRefused() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "mark.png")
        let image = try IconComposer.renderPlateLayer(
            pixels: 8, options: Icon.Options(plate: .solid("#123456")))
        try Image.write(image, to: png)

        #expect(throws: AppShotError.self) {
            try IconSVG.compose(mark: png, options: Icon.Options())
        }
    }
}
