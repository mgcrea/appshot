import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The drawn device edge.
///
/// Two things are being pinned here, and only one of them is "does it look right".
///
/// The first is that the bezel comes out of the *layout box*, never out of the margin —
/// a frame that grows outward from a window already placed at its final size walks
/// straight past the edge the config says the device stops at, and nothing downstream
/// would notice, because a composite is never measured against anything.
///
/// The second is the shape. The ring is the capture's own alpha silhouette dilated by a
/// disc, so there is no radius to configure — which is the whole reason this is a drawn
/// bezel and not a device-frame PNG whose aperture has to agree with the capture to the
/// pixel. These tests assert the ring is present on all four sides and follows the
/// corner, since a silhouette-derived ring is exactly the kind of thing that renders
/// beautifully on the straight edges and falls apart on the arc.
struct BezelTests {

    // MARK: - Fixtures

    /// A capture the size of the device canvas, so the compositor actually has to scale
    /// it down. At 40x40 the "never upscale" clamp pins the scale to 1, the bezel takes
    /// nothing out of the box, and the geometry assertions below all pass vacuously.
    static func capture(
        width: Int = 1320, height: Int = 2868, radius: Double = 200,
        rgb: (UInt8, UInt8, UInt8) = (120, 130, 140), rounded: Bool = true
    ) -> CGImage {
        let ctx = Image.context(width: width, height: height)!
        ctx.setFillColor(
            CGColor(
                srgbRed: Double(rgb.0) / 255, green: Double(rgb.1) / 255,
                blue: Double(rgb.2) / 255, alpha: 1))
        let bounds = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
        if rounded {
            ctx.addPath(
                CGPath(
                    roundedRect: bounds, cornerWidth: radius, cornerHeight: radius,
                    transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(bounds)
        }
        return ctx.makeImage()!
    }

    static let body: (UInt8, UInt8, UInt8) = (0x1C, 0x1C, 0x1E)
    static let rim: (UInt8, UInt8, UInt8) = (0xE0, 0xE0, 0xE8)

    static func bezel(width: Double = 20, highlight: Bool = true) -> Config.Bezel {
        Config.Bezel(
            width: width, color: "#1C1C1E",
            highlight: highlight ? "#E0E0E8" : nil,
            highlightWidth: highlight ? 6 : nil)
    }

    /// Composes the iPhone device of the iOS fixture and hands back the first visual
    /// already decoded, so a test does one pixel pass rather than one per assertion.
    static func compose(
        bezel: Config.Bezel?, rounded: Bool = true
    ) throws -> (pixels: Image.Pixels, output: Compose.Output) {
        var config = try DeviceTests.ios()
        config.layout.bezel = bezel

        let device = try config.resolvedDevices()[0]
        let dirs = try MaskingTests.tempDirs()
        for screen in device.screens {
            try Image.write(
                capture(rounded: rounded),
                to: dirs.source.appending(path: "\(screen.id)~dark.png"))
        }

        let outputs = try Compose.appStore(
            config: config, device: device, sourceDir: dirs.source, outDir: dirs.out)
        let image = try Image.load(outputs[0].url)
        guard let pixels = Image.pixels(image) else {
            throw AppShotError.imageEncodeFailed(outputs[0].url)
        }
        return (pixels, outputs[0])
    }

    /// CoreImage round-trips the ring through its own working space, so an exact
    /// equality here would be pinning a rendering detail rather than the colour.
    static func near(
        _ pixels: Image.Pixels, _ point: (x: Int, y: Int), _ rgb: (UInt8, UInt8, UInt8),
        tolerance: Int = 3
    ) -> Bool {
        let p = pixels[point.y * pixels.width + point.x]
        return abs(Int(p.r) - Int(rgb.0)) <= tolerance
            && abs(Int(p.g) - Int(rgb.1)) <= tolerance
            && abs(Int(p.b) - Int(rgb.2)) <= tolerance
    }

    /// Where the screen sits in the composite, found by locating the capture's flat
    /// colour rather than by re-deriving the compositor's layout arithmetic — a test
    /// that recomputed it would agree with a broken compositor.
    static func window(
        in pixels: Image.Pixels, rgb: (UInt8, UInt8, UInt8) = (120, 130, 140)
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels[y * pixels.width + x]
                guard p.r == rgb.0, p.g == rgb.1, p.b == rgb.2 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX, maxY)
    }

    // MARK: - Backwards compatibility

    /// Every config that predates the bezel must compose exactly as it did. The key is
    /// optional and unset, so this is really asserting that no code path reads a default
    /// width of anything but zero.
    @Test func aConfigWithNoBezelIsUnchanged() throws {
        let plain = try Self.compose(bezel: nil)

        // Nothing but gradient outside the window on any side.
        let box = try #require(Self.window(in: plain.pixels))
        let mid = (box.minY + box.maxY) / 2
        #expect(!Self.near(plain.pixels, (box.minX - 4, mid), Self.body, tolerance: 12))
        #expect(!Self.near(plain.pixels, (box.maxX + 4, mid), Self.body, tolerance: 12))
    }

    // MARK: - Layout

    /// The bezel is drawn outward from the window, so unless the window shrinks first
    /// the device ends up wider than the box — silently, since a composite is only ever
    /// looked at, never measured. `2 * width` out of the binding dimension is the whole
    /// contract.
    @Test func theBezelComesOutOfTheBoxNotTheMargin() throws {
        let width = 20.0
        let plain = try Self.compose(bezel: nil)
        let framed = try Self.compose(bezel: Self.bezel(width: width))

        // Width binds in this layout, so the screen gives up exactly the ring.
        #expect(framed.output.windowSize.width == plain.output.windowSize.width - Int(width) * 2)

        // And the outer edge lands where the bare window's edge used to: the device
        // occupies the same footprint, the app UI inside it is what got smaller.
        let plainBox = try #require(Self.window(in: plain.pixels))
        let framedBox = try #require(Self.window(in: framed.pixels))
        #expect(abs((framedBox.minX - Int(width)) - plainBox.minX) <= 1)
        #expect(abs((framedBox.maxX + Int(width)) - plainBox.maxX) <= 1)
    }

    /// A margin that cannot hold the bezel is a blank canvas at render time, because the
    /// fit scale goes to zero or negative. Fail while it is still a config question.
    @Test func aBezelTooWideForTheMarginIsRejected() throws {
        var config = try DeviceTests.ios()
        config.layout.bezel = Self.bezel(width: 900)

        #expect(throws: AppShotError.self) { try config.validate() }
    }

    // MARK: - The ring

    @Test func theRingSurroundsTheScreenOnAllFourSides() throws {
        let framed = try Self.compose(bezel: Self.bezel())
        let box = try #require(Self.window(in: framed.pixels))
        let midX = (box.minX + box.maxX) / 2
        let midY = (box.minY + box.maxY) / 2

        // Just outside the screen on each edge, inside the 20px ring.
        #expect(Self.near(framed.pixels, (box.minX - 4, midY), Self.body))
        #expect(Self.near(framed.pixels, (box.maxX + 4, midY), Self.body))
        #expect(Self.near(framed.pixels, (midX, box.minY - 4), Self.body))
        #expect(Self.near(framed.pixels, (midX, box.maxY + 4), Self.body))
    }

    /// The reason the ring is derived from the capture's alpha rather than from a
    /// configured radius. A fixed-aperture frame drawn over a squircle shows gradient
    /// through the arc on one side and covers app pixels on the other; here the ring is
    /// the silhouette offset outward, so the corner is bezel at every distance the flat
    /// edges are.
    @Test func theRingFollowsTheCornerNotARectangle() throws {
        let framed = try Self.compose(bezel: Self.bezel())
        let box = try #require(Self.window(in: framed.pixels))

        // Walk the 45-degree diagonal inward from the top-left corner of the screen's
        // *bounding box*, which on a rounded capture is a point outside the screen, and
        // find where the screen actually starts. Located rather than computed: the
        // capture's corner radius, the fit scale and the ring width would otherwise all
        // have to be re-derived here, and a test carrying that arithmetic agrees with a
        // broken compositor.
        var arc: Int?
        for step in 0..<200 {
            let p = framed.pixels[
                (box.minY + step) * framed.pixels.width + (box.minX + step)]
            if (p.r, p.g, p.b) == (120, 130, 140) {
                arc = step
                break
            }
        }
        let screen = try #require(arc)
        // The box corner is genuinely outside the screen, or this proves nothing.
        #expect(screen > 20)

        // Immediately outside the arc, on the diagonal, is ring — which is the claim
        // that separates a dilated silhouette from a rectangle with rounded corners
        // drawn at a guessed radius. A step along the diagonal is √2 px, so 4 and 8
        // steps back are ~6px and ~11px into a 20px ring, past the 6px rim.
        #expect(Self.near(framed.pixels, (box.minX + screen - 4, box.minY + screen - 4), Self.body))
        #expect(Self.near(framed.pixels, (box.minX + screen - 8, box.minY + screen - 8), Self.body))

        // Far enough out on the same diagonal it is gradient again: the ring wraps the
        // arc with a finite thickness rather than filling the corner block.
        #expect(
            !Self.near(
                framed.pixels, (box.minX + screen - 25, box.minY + screen - 25), Self.body,
                tolerance: 8))
    }

    /// The rim is the outermost sliver, not an inner line: it stands for the light a
    /// real device edge catches. Drawn the other way round it reads as a seam between
    /// the frame and the screen.
    @Test func theHighlightSitsOnTheOutermostEdge() throws {
        let framed = try Self.compose(bezel: Self.bezel(width: 20))
        let box = try #require(Self.window(in: framed.pixels))
        let midY = (box.minY + box.maxY) / 2

        // 20px ring with a 6px rim: the body is the 14px adjacent to the screen and the
        // rim is the 6px beyond it, so the rim is *further* from the screen, not nearer.
        #expect(Self.near(framed.pixels, (box.minX - 5, midY), Self.body))
        #expect(Self.near(framed.pixels, (box.minX - 17, midY), Self.rim))

        // Same on the right, since the two are stamped as one dilation rather than as
        // per-edge strokes.
        #expect(Self.near(framed.pixels, (box.maxX + 5, midY), Self.body))
        #expect(Self.near(framed.pixels, (box.maxX + 17, midY), Self.rim))
    }

    @Test func aBezelWithNoHighlightIsAFlatRing() throws {
        let framed = try Self.compose(bezel: Self.bezel(highlight: false))
        let box = try #require(Self.window(in: framed.pixels))
        let midY = (box.minY + box.maxY) / 2

        #expect(Self.near(framed.pixels, (box.minX - 2, midY), Self.body))
        #expect(Self.near(framed.pixels, (box.minX - 12, midY), Self.body))
    }

    /// An opaque capture — an XCUIScreenshot, or a simulator shot taken without
    /// `--mask=alpha` — has no silhouette to dilate. It falls back to the rounded rect
    /// the compositor is about to clip it into, which is the only shape that cannot
    /// leave the bezel offset from the thing it frames.
    @Test func anOpaqueCaptureStillGetsARing() throws {
        let framed = try Self.compose(bezel: Self.bezel(), rounded: false)
        let box = try #require(Self.window(in: framed.pixels))
        let midY = (box.minY + box.maxY) / 2

        #expect(Self.near(framed.pixels, (box.minX - 4, midY), Self.body))
        #expect(Self.near(framed.pixels, (box.maxX + 4, midY), Self.body))
    }

    // MARK: - Validation

    /// A bezel is drawn, never asserted against anything, so every way of getting it
    /// wrong renders *something* and ships. These are the ways.
    @Test func aZeroWidthBezelIsRejected() throws {
        var config = try DeviceTests.ios()
        config.layout.bezel = Config.Bezel(width: 0, color: "#1C1C1E")

        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func anUnparseableColourIsRejected() throws {
        var config = try DeviceTests.ios()
        config.layout.bezel = Config.Bezel(width: 20, color: "charcoal")

        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func anUnparseableHighlightIsRejected() throws {
        var config = try DeviceTests.ios()
        config.layout.bezel = Config.Bezel(width: 20, color: "#1C1C1E", highlight: "silver")

        #expect(throws: AppShotError.self) { try config.validate() }
    }

    /// A per-device layout override carries its own bezel, and validation has to reach
    /// it — the shared layout is not where an iPad's frame would be configured.
    @Test func aPerDeviceLayoutOverrideIsValidatedToo() throws {
        var config = try DeviceTests.ios()
        config.devices?[1].layout = config.layout
        config.devices?[1].layout?.bezel = Config.Bezel(width: 20, color: "nope")

        #expect(throws: AppShotError.self) { try config.validate() }
    }

    // MARK: - Defaults

    /// A rim wider than the ring is just a differently coloured ring; one of zero is a
    /// config that reads as enabled and renders as nothing.
    @Test func theHighlightWidthIsClampedIntoTheRing() {
        #expect(Config.Bezel(width: 20, color: "#000000").resolvedHighlightWidth == 5)
        #expect(
            Config.Bezel(width: 20, color: "#000000", highlightWidth: 40)
                .resolvedHighlightWidth == 20)
        #expect(
            Config.Bezel(width: 20, color: "#000000", highlightWidth: 0)
                .resolvedHighlightWidth == 1)
    }
}
