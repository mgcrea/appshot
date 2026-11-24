import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The template is the only thing `actool` reads, so these pin where the box lands on the
/// Regular-M guides, where the margins go, how the layers are classed for the palette, and
/// that the file is one `actool` compiles into a symbol the size of a stock one.
struct SymbolTemplateTests {
    static let k = SymbolTemplate.capHeight / 100

    static func rect(_ r: CGRect) -> CGPath { CGPath(rect: r, transform: nil) }

    static func symbol(_ layers: [(SymbolLayer, CGRect)]) -> OutlinedSymbol {
        let paths = layers.map { ($0.0, rect($0.1)) }
        let bounds = layers.reduce(CGRect.null) { $0.union($1.1) }
        return OutlinedSymbol(name: "test", layers: paths, bounds: bounds)
    }

    static func attribute(_ svg: String, id: String, _ name: String) -> String? {
        let element = svg.split(separator: "\n").first { $0.contains("id=\"\(id)\"") }
        guard let element, let range = element.range(of: "\(name)=\"") else { return nil }
        return String(element[range.upperBound...].prefix { $0 != "\"" })
    }

    static func paths(_ svg: String) throws -> [(classes: String, path: CGPath)] {
        try svg.matches(of: /<path class="([^"]*)" d="([^"]*)"\/>/).map {
            (String($0.1), try SVGPathData.parse(String($0.2)))
        }
    }

    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

    @Test func placesTheBoxOnBaselineAndCapline() throws {
        let svg = SymbolTemplate.svg(
            Self.symbol([(.outline, CGRect(x: 0, y: 0, width: 100, height: 100))]), sideBearing: 0)
        #expect(Self.attribute(svg, id: "Regular-M", "transform") == "matrix(1 0 0 1 1396.3 1126)")
        let paths = try Self.paths(svg)
        try #require(paths.count == 1)
        let box = paths[0].path.boundingBoxOfPath
        #expect(Self.near(box.minX, 0) && Self.near(box.minY, -70.46))
        #expect(Self.near(box.width, 70.46) && Self.near(box.height, 70.46))
    }

    @Test func marginsFromBounds() throws {
        let svg = SymbolTemplate.svg(
            Self.symbol([(.outline, CGRect(x: 20, y: 10, width: 40, height: 80))]), sideBearing: 4)
        let left = try #require(Self.attribute(svg, id: "left-margin-Regular-M", "x1"))
        let right = try #require(Self.attribute(svg, id: "right-margin-Regular-M", "x1"))
        #expect(Self.near(Double(left) ?? 0, 1396.3))
        #expect(Self.near(Double(right) ?? 0, 1396.3 + (40 + 8) * Self.k))
        let box = try #require(try Self.paths(svg).first).path.boundingBoxOfPath
        #expect(Self.near(box.minX, 4 * Self.k))
    }

    @Test func classesInOrder() throws {
        let three = SymbolTemplate.svg(
            Self.symbol([
                (.wash, CGRect(x: 0, y: 0, width: 100, height: 100)),
                (.outline, CGRect(x: 10, y: 10, width: 80, height: 80)),
                (.touch, CGRect(x: 30, y: 30, width: 40, height: 40)),
            ]), sideBearing: 4)
        #expect(
            try Self.paths(three).map(\.classes) == [
                "monochrome-0 hierarchical-0:tertiary",
                "monochrome-1 hierarchical-1:primary",
                "monochrome-2 hierarchical-2:secondary",
            ])
        let two = SymbolTemplate.svg(
            Self.symbol([
                (.outline, CGRect(x: 10, y: 10, width: 80, height: 80)),
                (.touch, CGRect(x: 30, y: 30, width: 40, height: 40)),
            ]), sideBearing: 4)
        #expect(
            try Self.paths(two).map(\.classes) == [
                "monochrome-0 hierarchical-0:primary",
                "monochrome-1 hierarchical-1:secondary",
            ])
        // Only the wash is dropped in monochrome, whatever index it took.
        #expect(!two.contains("opacity:0.0"))
        #expect(three.contains(".monochrome-0 {fill:#000000;opacity:0.0}"))
        #expect(!three.contains("clear-behind"))
    }

    @Test func noSmallGuides() {
        let svg = SymbolTemplate.svg(
            Self.symbol([(.outline, CGRect(x: 0, y: 0, width: 100, height: 100))]), sideBearing: 4)
        // The S and L baselines and cap lines stay: actool refuses a file without them.
        #expect(svg.matches(of: /id="[^"]*margin[^"]*-(S|L)"/).isEmpty)
        #expect(!svg.contains("Regular-S") && !svg.contains("Regular-L"))
    }

    @Test func numbersRounded() {
        let svg = SymbolTemplate.svg(
            Self.symbol([
                (.outline, CGRect(x: 1.23456, y: 99.9999, width: 33.3333, height: 0.001)),
                (.touch, CGRect(x: 1.0 / 3, y: 2.0 / 3, width: 7.0 / 9, height: 50)),
            ]), sideBearing: 4.4444)
        // Class names carry an index after a dash (monochrome-0), which is not a number.
        let numbers = svg.replacing(/[A-Za-z]-\d+/, with: "")
        for number in numbers.matches(of: /-?\d+(\.\d+)?/) {
            let text = String(number.0)
            #expect((number.1?.count ?? 0) <= 3, "\(text) has more than two decimals")
            #expect(text != "-0", "a -0 in the output")
        }
    }

    @Test func contentsNamesTheSVG() throws {
        let json =
            try JSONSerialization.jsonObject(
                with: SymbolTemplate.contentsJSON(svgName: "feature.test.svg")) as? [String: Any]
        let symbols = try #require(json?["symbols"] as? [[String: String]])
        #expect(symbols == [["filename": "feature.test.svg", "idiom": "universal"]])
    }

    static var hasActool: Bool { (try? SymbolCatalog.actool()) != nil }

    /// Writes `body`'s glyph as `feature.test` into a scratch folder of `.symbolset`s, as
    /// `--out` names one, and compiles it.
    static func compiled(_ body: String) throws -> Bundle {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = dir.appending(path: "Glyphs/feature.test.symbolset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let symbol = SymbolGeometry.outline(try SymbolGeometryTests.drawing(body), strokeWidth: 8)
        try SymbolTemplate.svg(symbol, sideBearing: 4)
            .write(to: set.appending(path: "feature.test.svg"), atomically: true, encoding: .utf8)
        try SymbolTemplate.contentsJSON(svgName: "feature.test.svg")
            .write(to: set.appending(path: "Contents.json"))
        return try SymbolCatalog.compile(dir.appending(path: "Glyphs")).bundle
    }

    /// `compile` leaves its bundle for the caller to load from; the scratch folder holds it.
    static func discard(_ bundle: Bundle) {
        try? FileManager.default.removeItem(at: bundle.bundleURL.deletingLastPathComponent())
    }

    @Test(.enabled(if: hasActool)) func compilesWithActool() throws {
        // A cube's reach: `cube` runs about 30 box units past the box's top and bottom, so
        // this ring's outer edge does too (r 76, plus half the stroke), with a wash under
        // it and a marked touch on it.
        let bundle = try Self.compiled(
            """
            <g id="wash"><circle cx="50" cy="50" r="50"/></g>
            <g id="outline"><circle cx="50" cy="50" r="76" fill="none" stroke="currentColor"/></g>
            <g id="touch"><circle cx="50" cy="50" r="16" data-knockout="true"/></g>
            """)
        defer { Self.discard(bundle) }
        let image = try #require(
            NSImage(symbolName: "feature.test", bundle: bundle, variableValue: 1))
        let cube = try #require(NSImage(systemSymbolName: "cube", accessibilityDescription: nil))
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let height = try #require(image.withSymbolConfiguration(config)).size.height
        let stock = try #require(cube.withSymbolConfiguration(config)).size.height
        #expect(abs(height - stock) <= 2, "\(height) against cube's \(stock)")
    }

    /// The colour at the middle of the glyph's top, middle and bottom bands.
    static func bands(_ image: NSImage, _ config: NSImage.SymbolConfiguration) throws -> [NSColor] {
        let sized = NSImage.SymbolConfiguration(pointSize: 100, weight: .regular).applying(config)
        let image = try #require(image.withSymbolConfiguration(sized))
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
                pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // The glyph is 100 box units tall here, inside about 7 points of padding each side.
        return try [0.2, 0.5, 0.8].map { fraction in
            try #require(rep.colorAt(x: rep.pixelsWide / 2, y: Int(Double(rep.pixelsHigh) * fraction)))
        }
    }

    static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.1 && abs(a.greenComponent - b.greenComponent) < 0.1
            && abs(a.blueComponent - b.blueComponent) < 0.1 && abs(a.alphaComponent - b.alphaComponent) < 0.1
    }

    /// The palette takes the outline, touch and wash colours in that order, and monochrome
    /// leaves the wash out: what Ruling 5's classes are for, seen in the compiled symbol.
    @Test(.enabled(if: hasActool)) func rendersTheLayersAsClassed() throws {
        let bundle = try Self.compiled(
            """
            <g id="wash"><rect x="0" y="30" width="100" height="40"/></g>
            <g id="outline"><rect x="0" y="0" width="100" height="20"/></g>
            <g id="touch"><rect x="0" y="80" width="100" height="20"/></g>
            """)
        defer { Self.discard(bundle) }
        let image = try #require(
            NSImage(symbolName: "feature.test", bundle: bundle, variableValue: 1))
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        let clear = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)

        let palette = try Self.bands(image, .init(paletteColors: [.black, .red, .green]))
        #expect(zip(palette, [black, green, red]).allSatisfy(Self.same), "\(palette)")
        let mono = try Self.bands(image, .preferringMonochrome())
        #expect(zip(mono, [black, clear, black]).allSatisfy(Self.same), "\(mono)")
    }

    @Test(.enabled(if: hasActool)) func refusedCatalogSaysWhy() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = dir.appending(path: "Glyphs/broken.symbolset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="3300" height="2200"/>"#
            .write(to: set.appending(path: "broken.svg"), atomically: true, encoding: .utf8)
        try SymbolTemplate.contentsJSON(svgName: "broken.svg")
            .write(to: set.appending(path: "Contents.json"))

        // A plain folder, as `--out` names one inside an app's catalog, is wrapped first.
        #expect {
            try SymbolCatalog.compile(dir.appending(path: "Glyphs"))
        } throws: { error in
            guard case .symbolCatalogRejected(let why) = error as? AppShotError else { return false }
            // It names the caller's folder, never the scratch copy actool was given.
            return why.contains("broken.symbolset") && !why.contains("Wrapper.xcassets")
        }
    }
}
