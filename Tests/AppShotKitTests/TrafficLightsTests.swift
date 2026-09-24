import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Repainting `--no-activate`'s grey traffic lights.
///
/// The geometry is the part that can go wrong silently — a repaint in the wrong place
/// is worse than none — so these build title bars with known discs and check the
/// detector finds exactly those, refuses anything less certain, and leaves every pixel
/// outside the discs alone.
struct TrafficLightsTests {
    /// A plain titled window at 2x, as measured on macOS 27: 12pt discs on a 20pt pitch,
    /// the first centred 16pt in and 14pt down.
    static let plain = (x: 32.0, y: 28.0, pitch: 40.0, diameter: 24.0)

    /// A 300x120 title bar at 2x with discs drawn on it. `y` is top-down, as captured.
    static func titleBar(
        discs: [(x: Double, y: Double, d: Double, rgb: UInt32)],
        background: (CGContext, Int, Int) -> Void = { ctx, w, h in
            ctx.setFillColor(CGColor(srgbRed: 0x2E / 255, green: 0x31 / 255, blue: 0x35 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    ) -> CGImage {
        let (w, h) = (300, 120)
        let ctx = Image.context(width: w, height: h)!
        background(ctx, w, h)
        for disc in discs {
            ctx.setFillColor(
                CGColor(
                    srgbRed: Double(disc.rgb >> 16 & 0xFF) / 255,
                    green: Double(disc.rgb >> 8 & 0xFF) / 255,
                    blue: Double(disc.rgb & 0xFF) / 255, alpha: 1))
            ctx.fillEllipse(
                in: CGRect(
                    x: disc.x - disc.d / 2, y: Double(h) - disc.y - disc.d / 2,
                    width: disc.d, height: disc.d))
        }
        return ctx.makeImage()!
    }

    static let grey: UInt32 = 0x505356

    static func greyRow(
        x: Double = plain.x, y: Double = plain.y, pitch: Double = plain.pitch,
        d: Double = plain.diameter, count: Int = 3
    ) -> [(x: Double, y: Double, d: Double, rgb: UInt32)] {
        (0..<count).map { (x: x + Double($0) * pitch, y: y, d: d, rgb: grey) }
    }

    static func find(_ image: CGImage) -> [TrafficLights.Disc]? {
        TrafficLights.find(in: Image.pixels(image)!, windowOrigin: .zero, scale: 2)
    }

    // MARK: - find

    @Test func findsThePlainWindowRow() throws {
        let discs = try #require(Self.find(Self.titleBar(discs: Self.greyRow())))
        #expect(discs.map(\.x) == [32, 72, 112])
        #expect(discs.allSatisfy { $0.y == 28 && $0.diameter == 24 })
    }

    /// A unified toolbar puts bigger discs lower and further apart. Measured, not
    /// assumed, so the same code finds both.
    @Test func findsTheUnifiedToolbarRow() throws {
        let discs = try #require(
            Self.find(Self.titleBar(discs: Self.greyRow(x: 52, y: 52, pitch: 46, d: 28))))
        #expect(discs.map(\.x) == [52, 98, 144])
    }

    /// The window is not assumed to start at the image's corner: a popover can extend
    /// the capture past the window's left edge.
    @Test func searchesFromTheWindowOrigin() throws {
        let image = Self.titleBar(discs: Self.greyRow(x: 82))
        let discs = try #require(
            TrafficLights.find(
                in: Image.pixels(image)!, windowOrigin: CGPoint(x: 50, y: 0), scale: 2))
        #expect(discs[0].x == 82)
    }

    @Test func twoDiscsAreNotARow() {
        #expect(Self.find(Self.titleBar(discs: Self.greyRow(count: 2))) == nil)
    }

    /// Three round toolbar buttons further right are not the window's buttons.
    @Test func aRowFarFromTheLeftEdgeIsNotTheTrafficLights() {
        #expect(Self.find(Self.titleBar(discs: Self.greyRow(x: 120))) == nil)
    }

    @Test func unevenPitchIsNotARow() {
        var discs = Self.greyRow()
        discs[2].x += 12
        #expect(Self.find(Self.titleBar(discs: discs)) == nil)
    }

    /// Glass over content — Maps puts its buttons on the map — is a gradient no single
    /// colour describes. The local-mean pass has to find them anyway.
    @Test func findsDiscsOnAGradientTitleBar() throws {
        let image = Self.titleBar(discs: Self.greyRow().map { ($0.x, $0.y, $0.d, 0x7A7C7E) }) {
            ctx, w, h in
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [
                    CGColor(srgbRed: 0.36, green: 0.30, blue: 0.26, alpha: 1),
                    CGColor(srgbRed: 0.18, green: 0.24, blue: 0.22, alpha: 1),
                ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        let discs = try #require(Self.find(image))
        #expect(discs.map(\.x) == [32, 72, 112])
    }

    // MARK: - recolor

    @Test func greyDiscsAreRepaintedInColour() throws {
        let image = Self.titleBar(discs: Self.greyRow())
        let (out, outcome) = try TrafficLights.recolor(
            image, windowOrigin: .zero, scale: 2, screen: "s")
        #expect(outcome == .recolored)

        let pixels = Image.pixels(out)!
        let discs = try #require(Self.find(image))
        let chroma = discs.map { TrafficLights.meanChroma(pixels, $0) }
        #expect(chroma.allSatisfy { $0 > TrafficLights.colourChroma }, "\(chroma)")

        // Red, yellow, green, in that order.
        let centres = discs.map { pixels[Int($0.y) * pixels.width + Int($0.x)] }
        #expect(centres[0].r > centres[0].g)
        #expect(centres[1].r > 200 && centres[1].g > 150)
        #expect(centres[2].g > centres[2].r)
    }

    /// Everything outside the discs' erase radius is the capture, untouched.
    @Test func pixelsAwayFromTheDiscsAreUnchanged() throws {
        let image = Self.titleBar(discs: Self.greyRow())
        let (out, _) = try TrafficLights.recolor(image, windowOrigin: .zero, scale: 2, screen: "s")
        let before = Image.pixels(image)!
        let after = Image.pixels(out)!
        for y in 0..<before.height {
            for x in 0..<before.width {
                let near = [32.0, 72, 112].contains {
                    hypot(Double(x) + 0.5 - $0, Double(y) + 0.5 - 28) < 16
                }
                if !near { #expect(before[y * before.width + x] == after[y * after.width + x]) }
            }
        }
    }

    /// The app happened to be frontmost: nothing to fix, and nothing touched.
    @Test func colouredDiscsAreLeftAlone() throws {
        let rgb: [UInt32] = [0xF55047, 0xFCB200, 0x00BC00]
        let discs = Self.greyRow().enumerated().map { ($1.x, $1.y, $1.d, rgb[$0]) }
        let image = Self.titleBar(discs: discs)
        let (out, outcome) = try TrafficLights.recolor(
            image, windowOrigin: .zero, scale: 2, screen: "s")
        #expect(outcome == .alreadyActive)
        #expect(out === image)
    }

    @Test func aMissingRowFailsRatherThanShippingUnpainted() {
        let image = Self.titleBar(discs: Self.greyRow(count: 2))
        #expect(throws: AppShotError.self) {
            try TrafficLights.recolor(image, windowOrigin: .zero, scale: 2, screen: "s")
        }
    }

    /// One grey, two coloured — a hover, say. Not a state to guess at.
    @Test func aMixedRowIsAmbiguous() {
        let rgb: [UInt32] = [Self.grey, 0xFCB200, 0x00BC00]
        let discs = Self.greyRow().enumerated().map { ($1.x, $1.y, $1.d, rgb[$0]) }
        do {
            _ = try TrafficLights.recolor(
                Self.titleBar(discs: discs), windowOrigin: .zero, scale: 2, screen: "s")
            Issue.record("expected trafficLightsAmbiguous")
        } catch AppShotError.trafficLightsAmbiguous {
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// The palette follows the title bar, not the appearance's name: an appearance is
    /// any string a config names, and only the pixels say which one it was.
    @Test func aLightTitleBarGetsTheLightPalette() throws {
        let image = Self.titleBar(discs: Self.greyRow().map { ($0.x, $0.y, $0.d, 0xD2D3D4) }) {
            ctx, w, h in
            ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.92, blue: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let (out, outcome) = try TrafficLights.recolor(
            image, windowOrigin: .zero, scale: 2, screen: "s")
        #expect(outcome == .recolored)
        // The light palette's dark outline: the left edge of the red disc goes darker
        // than the dark palette's glossy rim ever does.
        let pixels = Image.pixels(out)!
        let edge = (18...24).map { pixels[28 * pixels.width + $0].g }.min()!
        #expect(edge < 0x40, "\(edge)")
    }
}
