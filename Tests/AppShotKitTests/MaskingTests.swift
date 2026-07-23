import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The macOS/iOS corner asymmetry.
///
/// A macOS ScreenCaptureKit capture already carries transparent rounded corners, so the
/// compositor rounds only the *shadow* and the window looks correct because its own
/// alpha says so. An opaque capture — an XCUIScreenshot, or a simulator shot taken
/// without `--mask=alpha` — is a hard rectangle, and the same code path yields a square
/// image sitting on a rounded shadow.
struct MaskingTests {

    // MARK: - isOpaque

    @Test func aCaptureWithTransparentCornersIsNotOpaque() {
        #expect(!Image.isOpaque(GateTests.makeImage(transparentCorner: true)))
    }

    @Test func aHardRectangleIsOpaque() {
        #expect(Image.isOpaque(GateTests.makeImage(transparentCorner: false)))
    }

    /// The four corners are where transparency lives in a capture — that is what makes
    /// sampling them decisive rather than a heuristic. All four are checked, so a
    /// capture rounded on only one side still reads as transparent.
    @Test func anyTransparentCornerCounts() {
        let ctx = Image.context(width: 20, height: 20)!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        // Top-right only, in CG's y-up coordinates.
        ctx.clear(CGRect(x: 17, y: 17, width: 3, height: 3))

        #expect(!Image.isOpaque(ctx.makeImage()!))
    }

    // MARK: - Through compose

    /// An iOS composite must end up with the capture's corners rounded by the
    /// compositor, since the capture brought none of its own.
    @Test func anOpaqueIOSCaptureIsMaskedIntoRoundedCorners() throws {
        let config = try DeviceTests.ios()
        let device = try config.resolvedDevices()[0]
        let dirs = try Self.tempDirs()

        // A hard rectangle, in the device's own aspect so the compositor scales it
        // predictably into the box.
        try Image.write(
            GateTests.makeImage(width: 330, height: 717, transparentCorner: false),
            to: dirs.source.appending(path: "home~dark.png"))
        try Image.write(
            GateTests.makeImage(width: 330, height: 717, transparentCorner: false),
            to: dirs.source.appending(path: "detail~dark.png"))

        var warnings: [String] = []
        let outputs = try Compose.appStore(
            config: config, device: device, sourceDir: dirs.source, outDir: dirs.out,
            warnings: { warnings.append($0) })

        // No "opaque capture" warning on iOS: it is a shape to fix, not a fault.
        #expect(warnings.isEmpty)

        // Locate the window by finding the capture's own flat colour rather than
        // recomputing the compositor's layout arithmetic here — a test that duplicated
        // that arithmetic would agree with a broken compositor.
        let composite = try Image.load(outputs[0].url)
        let box = try #require(Self.boundingBox(of: (120, 130, 140), in: composite))

        // The window is where the compositor said it was...
        #expect(abs(box.width - outputs[0].windowSize.width) <= 2)
        #expect(abs(box.height - outputs[0].windowSize.height) <= 2)

        // ...and its literal corner pixel is no longer the capture: the mask cut it
        // away and left the gradient. Unmasked, this pixel would be capture-coloured,
        // which is the square-image-on-a-rounded-shadow bug.
        #expect(!Self.matches((120, 130, 140), at: (box.minX, box.minY), in: composite))
        #expect(!Self.matches((120, 130, 140), at: (box.maxX, box.minY), in: composite))
        // The middle of the window is still the capture, so the mask cut corners and
        // not the whole image.
        #expect(
            Self.matches(
                (120, 130, 140), at: ((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2),
                in: composite))
    }

    /// On Mac an opaque capture is not a shape problem but a permission one: it is what
    /// a capture looks like when Screen Recording was not granted. Compose is the last
    /// place to say so before it ships.
    @Test func anOpaqueMacCaptureWarnsInsteadOfMasking() throws {
        var config = try ConfigTests.decode()
        config.fontFamily = Self.installedFont
        let device = try config.resolvedDevices()[0]
        let dirs = try Self.tempDirs()

        for name in ["browser~light.png", "browser~dark.png", "paywall~light.png", "paywall~dark.png"] {
            try Image.write(
                GateTests.makeImage(width: 400, height: 250, transparentCorner: false),
                to: dirs.source.appending(path: name))
        }

        var warnings: [String] = []
        _ = try Compose.appStore(
            config: config, device: device, sourceDir: dirs.source, outDir: dirs.out,
            warnings: { warnings.append($0) })

        #expect(warnings.contains { $0.contains("opaque") && $0.contains("Screen Recording") })
    }

    @Test func aTransparentCaptureIsLeftAloneOnBothPlatforms() throws {
        var config = try ConfigTests.decode()
        config.fontFamily = Self.installedFont
        let device = try config.resolvedDevices()[0]
        let dirs = try Self.tempDirs()

        for name in ["browser~light.png", "browser~dark.png", "paywall~light.png", "paywall~dark.png"] {
            try Image.write(
                GateTests.makeImage(width: 400, height: 250, transparentCorner: true),
                to: dirs.source.appending(path: name))
        }

        var warnings: [String] = []
        _ = try Compose.appStore(
            config: config, device: device, sourceDir: dirs.source, outDir: dirs.out,
            warnings: { warnings.append($0) })

        #expect(!warnings.contains { $0.contains("opaque") })
    }

    // MARK: - Helpers

    /// A font that exists everywhere this suite runs.
    ///
    /// `ConfigTests`' fixture carries the real-world stack, which starts at SF Pro
    /// Display — installed on a developer's Mac and *not* on a CI runner. `Text.font`
    /// refuses to substitute rather than silently typesetting the wrong face, which is
    /// the behaviour worth having and also means any test that composes a caption fails
    /// on CI alone. These tests are about masking, so the font is incidental: pin it.
    static let installedFont = "Helvetica"

    /// Where a flat colour appears in an image, as a top-down pixel box.
    static func boundingBox(
        of rgb: (UInt8, UInt8, UInt8), in image: CGImage
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)? {
        guard let px = Image.pixels(image) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<px.height {
            for x in 0..<px.width {
                let p = px[y * px.width + x]
                guard p.r == rgb.0, p.g == rgb.1, p.b == rgb.2 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX, maxY, maxX - minX + 1, maxY - minY + 1)
    }

    static func matches(_ rgb: (UInt8, UInt8, UInt8), at point: (Int, Int), in image: CGImage)
        -> Bool
    {
        guard let px = Image.pixels(image) else { return false }
        let p = px[point.1 * px.width + point.0]
        return p.r == rgb.0 && p.g == rgb.1 && p.b == rgb.2
    }

    static func tempDirs() throws -> (source: URL, out: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-mask-\(UUID().uuidString)")
        let source = root.appending(path: "source")
        let out = root.appending(path: "out")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (source, out)
    }
}

/// `appshot selftest` on a golden set that has no transparency.
///
/// The alpha mutant sets alpha to 255. On an all-opaque set that is a no-op, so the gate
/// correctly reports no difference — and a two-state self-test reads that as "expected
/// FAIL, got PASS" and declares the gate untrustworthy. That is a false alarm on every
/// iOS project whose captures came from an XCUITest.
struct SelfTestSkipTests {

    /// 400x400, not the 40x40 the other suites use.
    ///
    /// The mutants are calibrated as *fractions* of a real golden — `visibleRect` paints
    /// √(0.5% of the pixels) a side. At 40x40 that rounds to a single pixel (0.06%, under
    /// the 0.1% tolerance) and the mutant stops being a regression at all. A fixture has
    /// to be big enough for the thing under test to exist.
    static func seed(_ dir: URL, transparentCorner: Bool) throws {
        // Two different screens: identical ones would trip the duplicate check instead.
        try Image.write(
            GateTests.makeImage(
                width: 400, height: 400, rgb: (120, 130, 140),
                transparentCorner: transparentCorner),
            to: dir.appending(path: "a~dark.png"))
        try Image.write(
            GateTests.makeImage(
                width: 400, height: 400, rgb: (200, 40, 40),
                transparentCorner: transparentCorner),
            to: dir.appending(path: "b~dark.png"))
    }

    static func goldens(transparentCorner: Bool) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-selftest-goldens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seed(dir, transparentCorner: transparentCorner)
        return dir
    }

    @Test func opaqueGoldensSkipTheAlphaCaseInsteadOfFailingIt() throws {
        let results = try GateSelfTest.run(goldenDir: Self.goldens(transparentCorner: false))
        let alpha = try #require(results.first { $0.name.contains("alpha") })

        #expect(alpha.verdict == .skipped)
        // A skip has to say why, or it is indistinguishable from a check that vanished.
        #expect(alpha.detail.contains("opaque"))
        // And it must not fail the command.
        #expect(alpha.ok)
    }

    /// The other side: where there *is* transparency, the alpha check is still proven.
    /// Without this, "skipped" could silently become the answer for everyone.
    @Test func transparentGoldensStillProveTheAlphaCase() throws {
        let results = try GateSelfTest.run(goldenDir: Self.goldens(transparentCorner: true))
        let alpha = try #require(results.first { $0.name.contains("alpha") })

        #expect(alpha.verdict == .ok)
    }

    /// Every other mutant must reach its verdict on an opaque set — a skip is specific
    /// to the one check that cannot be posed, not a blanket excuse.
    @Test func everyOtherMutantStillGetsARealVerdictOnOpaqueGoldens() throws {
        let results = try GateSelfTest.run(goldenDir: Self.goldens(transparentCorner: false))

        let skipped = results.filter { $0.verdict == .skipped }
        #expect(skipped.count == 1)
        #expect(results.filter { $0.verdict == .failed }.isEmpty)
        #expect(results.count > 5)
    }
}
