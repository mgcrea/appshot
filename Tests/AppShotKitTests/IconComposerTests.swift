import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// A `.icon` fails in the opposite direction from an `.appiconset`, and the failure is
/// quiet in a way that a missing slot is not: artwork carrying its own corner radius
/// compiles, installs and renders, just with a sliver of nothing at each corner where
/// the baked radius and the system's squircle disagree. So the pins here are the two
/// properties the format actually requires — square, and opaque to all four edges —
/// plus the denominator that decides whether the mark inside it reads timid.
struct IconComposerTests {
    // MARK: - Helpers

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-iconcomposer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeMark(in dir: URL) throws -> URL {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <rect x="0" y="0" width="4" height="10" fill="#ff0000"/>
              <rect x="6" y="2" width="4" height="6" fill="#00ff00"/>
            </svg>
            """
        let url = dir.appending(path: "mark.svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let px = Image.pixels(image)!
        return px[y * px.width + x].a
    }

    // MARK: - The layer is square and opaque

    /// The single requirement that separates this format from `.appiconset`. A plate
    /// drawn with `Icon.render` would have transparent corners here, and that is what
    /// the corner assertions are pinning against — not merely "some pixels are opaque".
    @Test func layerIsOpaqueIntoEveryCorner() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let image = try IconComposer.renderLayer(
            mark: mark, pixels: 256,
            options: Icon.Options(plate: .solid("#0b0b0c"), markFraction: 0.7))

        #expect(image.width == 256 && image.height == 256)
        for (x, y) in [(0, 0), (255, 0), (0, 255), (255, 255)] {
            #expect(Self.alpha(image, x, y) == 255)
        }
        #expect(Image.isOpaque(image))
    }

    /// The same options through `Icon.render` must *not* be opaque, or the test above
    /// proves nothing about the two formats differing.
    @Test func appiconsetPlateStaysRoundedAndInset() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let image = try Icon.render(
            mark: mark, pixels: 256,
            options: Icon.Options(plate: .solid("#0b0b0c"), markFraction: 0.7))

        #expect(Self.alpha(image, 0, 0) == 0)
        #expect(!Image.isOpaque(image))
    }

    @Test func gradientPlateFillsTheWholeCanvas() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let plate = try Icon.gradientPlate(hexes: ["#7c7a72", "#403e39"], angle: 71)
        let image = try IconComposer.renderLayer(
            mark: mark, pixels: 128, options: Icon.Options(plate: plate, markFraction: 0.7))

        // Opaque corners, and the two of them genuinely different — a gradient that got
        // clipped to a plate rect would leave the corners transparent instead.
        let px = Image.pixels(image)!
        let topLeft = px[0]
        let bottomRight = px[127 * 128 + 127]
        #expect(topLeft.a == 255 && bottomRight.a == 255)
        #expect(topLeft.r != bottomRight.r)
    }

    // MARK: - The mark fraction

    /// The migration trap, pinned as arithmetic. The same flag value means the plate in
    /// one format and 1024/824 of it in the other, so an icon moved across at the same
    /// number silently shrinks by a quarter.
    @Test func composedPlateFractionDiffersBetweenFormats() {
        #expect(IconComposer.composedPlateFraction(0.708) == 0.708)

        let onPlate = Icon.composedPlateFraction(0.57)
        #expect(abs(onPlate - 0.708) < 0.001)

        // Stated the other way round: this is the factor a migration multiplies by.
        #expect(abs(Icon.composedPlateFraction(1.0) - 1024.0 / 824.0) < 1e-9)
    }

    @Test func markIsCentredAtTheRequestedFraction() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let image = try IconComposer.renderLayer(
            mark: mark, pixels: 200,
            options: Icon.Options(plate: .solid("#000000"), tint: "#ffffff", markFraction: 0.5))
        let px = Image.pixels(image)!

        // The mark box is 100px centred in 200, so x=99 is inside it and x=40 is not.
        // Measured on the row through the middle of the left bar rather than the centre
        // row, because the mark's own two bars leave a gap down the middle.
        let row = 100
        #expect(px[row * 200 + 55].r > 200)
        #expect(px[row * 200 + 40].r < 50)
    }

    // MARK: - Bundle layout

    @Test func generateWritesManifestAndLayer() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let bundle = dir.appending(path: "MyApp.icon")

        let written = try IconComposer.generate(
            mark: mark, into: bundle,
            options: Icon.Options(plate: .solid("#0b0b0c"), markFraction: 0.7),
            pixels: 128)

        #expect(FileManager.default.fileExists(atPath: written.manifest.path))
        #expect(written.layer.lastPathComponent == IconComposer.layerImageName)
        #expect(written.layer.path.contains("/Assets/"))

        let root =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: written.manifest)) as! [String: Any]
        let groups = root["groups"] as! [[String: Any]]
        let layers = groups[0]["layers"] as! [[String: Any]]
        #expect(layers[0]["image-name"] as? String == IconComposer.layerImageName)
        // Flat artwork must not opt into the material treatment, or it picks up
        // specular highlights it was never drawn for.
        #expect(layers[0]["glass"] as? Bool == false)
        #expect(root["supported-platforms"] != nil)
    }

    @Test func generatedBundlePassesItsOwnAudit() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let bundle = dir.appending(path: "MyApp.icon")

        _ = try IconComposer.generate(
            mark: mark, into: bundle,
            options: Icon.Options(plate: .solid("#0b0b0c"), markFraction: 0.7))
        #expect(try IconComposer.audit(bundle).isEmpty)
    }

    // MARK: - Audit

    @Test func auditReportsAMissingManifest() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appending(path: "Empty.icon")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        #expect(try IconComposer.audit(bundle) == [.init(kind: .missingManifest)])
    }

    @Test func auditReportsAManifestWithNoLayers() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appending(path: "Hollow.icon")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try #"{"groups":[{"layers":[]}]}"#.write(
            to: bundle.appending(path: "icon.json"), atomically: true, encoding: .utf8)

        #expect(try IconComposer.audit(bundle) == [.init(kind: .noLayers)])
    }

    @Test func auditReportsALayerFileThatIsNotThere() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appending(path: "Broken.icon")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try IconComposer.iconJSON().write(
            to: bundle.appending(path: "icon.json"), atomically: true, encoding: .utf8)

        #expect(
            try IconComposer.audit(bundle)
                == [.init(kind: .missingLayerImage(IconComposer.layerImageName))])
    }

    /// The migration mistake, end to end: `.appiconset` artwork dropped into a `.icon`.
    /// It is a valid PNG at the right size, so everything except the opacity check
    /// passes it — which is exactly why the opacity check exists.
    @Test func auditCatchesArtworkThatKeptItsRoundedPlate() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let bundle = dir.appending(path: "Legacy.icon")
        let assets = bundle.appending(path: "Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try IconComposer.iconJSON().write(
            to: bundle.appending(path: "icon.json"), atomically: true, encoding: .utf8)

        // Rendered through the *other* format's grid on purpose.
        let legacy = try Icon.render(
            mark: mark, pixels: 64, options: Icon.Options(plate: .solid("#0b0b0c")))
        try Image.write(legacy, to: assets.appending(path: IconComposer.layerImageName))

        let findings = try IconComposer.audit(bundle, pixels: 64)
        #expect(findings.count == 1)
        guard case .baseLayerNotOpaque(_, let transparent, let rounded) = findings[0].kind else {
            Issue.record("expected a base-layer opacity finding, got \(findings)")
            return
        }
        #expect(rounded)
        #expect(transparent > 0)
        #expect(findings[0].message.contains("rounds it again"))
    }

    @Test func auditReportsAWrongSizedLayer() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let bundle = dir.appending(path: "Small.icon")

        _ = try IconComposer.generate(
            mark: mark, into: bundle,
            options: Icon.Options(plate: .solid("#0b0b0c")), pixels: 512)

        let findings = try IconComposer.audit(bundle)
        #expect(
            findings.contains {
                if case .wrongSize(_, let got, let want) = $0.kind {
                    return got == "512x512" && want == "1024x1024"
                }
                return false
            })
    }

    /// Upper layers are meant to carry alpha — only the base is required to be opaque.
    /// Auditing every layer the same way would make a legitimate two-layer icon fail.
    @Test func auditOnlyRequiresTheBaseLayerToBeOpaque() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let bundle = dir.appending(path: "Layered.icon")
        let assets = bundle.appending(path: "Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let manifest = """
            {"groups":[{"layers":[
              {"image-name":"plate.png","name":"plate"},
              {"image-name":"glyph.png","name":"glyph"}
            ]}]}
            """
        try manifest.write(
            to: bundle.appending(path: "icon.json"), atomically: true, encoding: .utf8)

        let plate = try IconComposer.renderLayer(
            mark: mark, pixels: 64, options: Icon.Options(plate: .solid("#0b0b0c")))
        try Image.write(plate, to: assets.appending(path: "plate.png"))
        // Transparent everywhere except the mark — what a real glyph layer looks like.
        let glyph = try IconComposer.renderLayer(
            mark: mark, pixels: 64, options: Icon.Options(plate: .none, markFraction: 0.5))
        try Image.write(glyph, to: assets.appending(path: "glyph.png"))

        #expect(!Image.isOpaque(glyph))
        #expect(try IconComposer.audit(bundle, pixels: 64).isEmpty)
    }
}
