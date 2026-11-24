import AppKit
import Foundation
import Testing

@testable import AppShotKit

/// The sheet draws every compiled symbol in every mode, size and appearance a family is
/// judged in, so these pin its grid (a row per symbol, a column per variant), that a cell
/// draws something, and that references reach the HTML page and never the PNG.
struct SymbolSheetTests {
    typealias Folders = SymbolBuildTests.Folders

    /// Two sources, built, and the asset folder to draw.
    static func built(_ names: [String] = ["a", "b"]) throws -> Folders {
        let f = try Folders()
        for (i, name) in names.enumerated() {
            try f.source(name, i.isMultiple(of: 2) ? SymbolBuildTests.ring : SymbolBuildTests.bar)
        }
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        return f
    }

    static func image(_ png: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func pngHasACellPerSymbolAndSize() throws {
        let two = try Self.built()
        defer { two.remove() }
        let three = try Self.built(["a", "b", "c"])
        defer { three.remove() }
        let variant = SymbolVariant(
            name: "selected", colors: ["#FFFFFF", "#FFFFFF", "#FFFFFF40"], tile: "#0A84FF")

        let base = try Self.image(SymbolSheet.png(assets: two.out, settings: SymbolSettings()))
        let taller = try Self.image(SymbolSheet.png(assets: three.out, settings: SymbolSettings()))
        let wider = try Self.image(
            SymbolSheet.png(assets: two.out, settings: SymbolSettings(variants: [variant])))

        let scale = Int(SymbolSheet.scale)
        #expect(taller.height - base.height == Int(SymbolSheet.rowHeight) * scale)
        #expect(taller.width == base.width)
        // One variant is one column in the light half and one in the dark half.
        #expect(wider.width - base.width == 2 * Int(SymbolSheet.cellWidth) * scale)
        #expect(wider.height == base.height)
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func cellsAreNotEmpty() throws {
        let f = try Self.built()
        defer { f.remove() }
        let image = try Self.image(SymbolSheet.png(assets: f.out, settings: SymbolSettings()))
        let cell = SymbolSheet.cellRect(row: 0, column: 0).applying(
            CGAffineTransform(scaleX: SymbolSheet.scale, y: SymbolSheet.scale))
        let cropped = try #require(image.cropping(to: cell))
        // The light half's background is opaque, so ink is any pixel darker than it.
        #expect(Self.darkPixels(cropped) > 20)
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func referencesOnlyInHTML() throws {
        let f = try Self.built()
        defer { f.remove() }
        let reference = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )?.representation(using: .png, properties: [:]))
        try reference.write(to: f.root.appending(path: "ref.png"))
        let settings = SymbolSettings(references: ["ref.png"])

        let plain = try SymbolSheet.png(assets: f.out, settings: SymbolSettings())
        #expect(try SymbolSheet.png(assets: f.out, settings: settings) == plain)

        let html = try SymbolSheet.html(assets: f.out, settings: settings, referencesRoot: f.root)
        #expect(html.components(separatedBy: "data:image/png;base64,").count - 1 == 2)
        #expect(html.contains("ref.png"))
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func missingReferenceSaysWhich() throws {
        let f = try Self.built()
        defer { f.remove() }
        let settings = SymbolSettings(references: ["gone.png"])
        #expect {
            try SymbolSheet.html(assets: f.out, settings: settings, referencesRoot: f.root)
        } throws: { error in
            guard case .symbolMissingReference(let url) = error as? AppShotError else { return false }
            return url.lastPathComponent == "gone.png"
        }
    }

    /// Monochrome is drawn in `labelColor` as macOS draws it, alpha and all, so its ink is
    /// the palette outline's (also `labelColor`), not heavier: the column judged first.
    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func monochromeInkIsLabelColor() throws {
        let f = try Self.built()
        defer { f.remove() }
        let image = try Self.image(SymbolSheet.png(assets: f.out, settings: SymbolSettings()))
        func cell(_ column: Int, dark: Bool) throws -> CGImage {
            let shift = dark ? SymbolSheet.halfWidth(variants: 0) : 0
            let rect = SymbolSheet.cellRect(row: 0, column: column).offsetBy(dx: shift, dy: 0)
            return try #require(
                image.cropping(
                    to: rect.applying(CGAffineTransform(scaleX: SymbolSheet.scale, y: SymbolSheet.scale))))
        }
        let palette13 = SymbolSheet.sizes.count + 1
        // Light: the darkest ink; dark: the brightest.
        let lightMono = Self.extremeInk(try cell(0, dark: false), darkest: true)
        let lightPalette = Self.extremeInk(try cell(palette13, dark: false), darkest: true)
        #expect(abs(lightMono - lightPalette) <= 2, "light: monochrome \(lightMono), palette \(lightPalette)")
        // The Label cell's glyph is the same ink as its word, so nothing in it is darker.
        let label = Self.extremeInk(
            try cell(palette13 + SymbolSheet.sizes.count + 1, dark: false), darkest: true)
        #expect(abs(label - lightPalette) <= 2, "label: \(label), palette \(lightPalette)")
        let darkMono = Self.extremeInk(try cell(0, dark: true), darkest: false)
        let darkPalette = Self.extremeInk(try cell(palette13, dark: true), darkest: false)
        #expect(abs(darkMono - darkPalette) <= 2, "dark: monochrome \(darkMono), palette \(darkPalette)")
    }

    /// The lowest (or highest) grey level in `image`, a pixel's mean of red, green and blue.
    static func extremeInk(_ image: CGImage, darkest: Bool) -> Int {
        var levels: [Int] = []
        forEachPixel(image) { r, g, b in levels.append((Int(r) + Int(g) + Int(b)) / 3) }
        return (darkest ? levels.min() : levels.max()) ?? -1
    }

    static func forEachPixel(_ image: CGImage, _ body: (UInt8, UInt8, UInt8) -> Void) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) { body(pixels[i], pixels[i + 1], pixels[i + 2]) }
    }

    /// The pixels whose red, green and blue are all well under the light background's.
    static func darkPixels(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4)
        where pixels[i] < 128 && pixels[i + 1] < 128 && pixels[i + 2] < 128 {
            count += 1
        }
        return count
    }
}
