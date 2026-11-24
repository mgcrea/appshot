import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// What the template gets is filled outlines, so these pin that a stroke becomes the shape
/// it paints (caps and dashes included), and that a marked touch is cut out of the outline
/// with a gap of half the stroke round it, while an unmarked one and the wash are left alone.
struct SymbolGeometryTests {
    /// Reads `body` inside a 100 box and outlines it at the default stroke of 8.
    static func outline(_ body: String) throws -> OutlinedSymbol {
        try SymbolGeometry.outline(drawing(body), strokeWidth: 8)
    }

    static func drawing(_ body: String) throws -> SymbolDrawing {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "glyph.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
        \(body)
        </svg>
        """.write(to: url, atomically: true, encoding: .utf8)
        return try SymbolSource.read(url, prefix: "")
    }

    static func layer(_ symbol: OutlinedSymbol, _ layer: SymbolLayer) -> CGPath? {
        symbol.layers.first { $0.0 == layer }?.1
    }

    /// Bounds to a thousandth, since an outliner may leave a rounding crumb.
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    static let square =
        #"<g id="outline"><rect x="0" y="0" width="100" height="100"/></g>"#
    static let knockout =
        #"<g id="touch"><circle cx="50" cy="50" r="10" data-knockout="true"/></g>"#

    @Test func strokeIsOutlined() throws {
        let symbol = try Self.outline(
            #"<g id="outline"><line x1="10" y1="50" x2="90" y2="50" stroke="currentColor"/></g>"#)
        #expect(Self.close(symbol.bounds, CGRect(x: 10, y: 46, width: 80, height: 8)))
        #expect(symbol.layers.map(\.0) == [.outline])
    }

    @Test func roundCapGrowsTheEnds() throws {
        let symbol = try Self.outline(
            #"<g id="outline"><line x1="10" y1="50" x2="90" y2="50" stroke="currentColor" stroke-linecap="round"/></g>"#
        )
        #expect(Self.close(symbol.bounds, CGRect(x: 6, y: 46, width: 88, height: 8)))
    }

    @Test func filledAndStroked() throws {
        let symbol = try Self.outline(
            #"<g id="outline"><rect x="40" y="40" width="20" height="20" fill="black" stroke="currentColor"/></g>"#
        )
        #expect(Self.close(symbol.bounds, CGRect(x: 36, y: 36, width: 28, height: 28)))
        let path = try #require(Self.layer(symbol, .outline))
        #expect(path.contains(CGPoint(x: 50, y: 50)))
    }

    @Test func dashesBreakTheStroke() throws {
        let symbol = try Self.outline(
            #"<g id="outline"><line x1="0" y1="50" x2="100" y2="50" stroke="currentColor" stroke-dasharray="10 10"/></g>"#
        )
        let path = try #require(Self.layer(symbol, .outline))
        #expect(path.contains(CGPoint(x: 5, y: 50)))
        #expect(!path.contains(CGPoint(x: 15, y: 50)))
    }

    @Test func knockoutCutsTheOutline() throws {
        let symbol = try Self.outline(Self.square + Self.knockout)
        #expect(symbol.layers.map(\.0) == [.outline, .touch])
        let outline = try #require(Self.layer(symbol, .outline))
        #expect(!outline.contains(CGPoint(x: 50, y: 50)))
        // The gap is 10 + 4 (half of 8) = 14 from the centre.
        #expect(!outline.contains(CGPoint(x: 50, y: 63)))
        #expect(outline.contains(CGPoint(x: 50, y: 66)))
        let touch = try #require(Self.layer(symbol, .touch))
        #expect(touch.contains(CGPoint(x: 50, y: 50)))
    }

    @Test func noKnockoutDrawsFlush() throws {
        let symbol = try Self.outline(
            Self.square + #"<g id="touch"><circle cx="50" cy="50" r="10"/></g>"#)
        let outline = try #require(Self.layer(symbol, .outline))
        #expect(outline.contains(CGPoint(x: 50, y: 50)))
    }

    @Test func washIsNeverCut() throws {
        let symbol = try Self.outline(
            #"<g id="wash"><rect x="0" y="0" width="100" height="100"/></g>"# + Self.square + Self.knockout)
        #expect(symbol.layers.map(\.0) == [.wash, .outline, .touch])
        let wash = try #require(Self.layer(symbol, .wash))
        #expect(wash.contains(CGPoint(x: 50, y: 50)))
    }

    @Test func emptyLayersDropped() throws {
        let emptyTouch = try Self.outline(Self.square + #"<g id="touch"/>"#)
        #expect(emptyTouch.layers.map(\.0) == [.outline])

        let bareTouch = try Self.outline(#"<g id="outline"/>"# + Self.knockout)
        #expect(bareTouch.layers.map(\.0) == [.touch])
        #expect(Self.close(bareTouch.bounds, CGRect(x: 40, y: 40, width: 20, height: 20)))
    }

    @Test func deterministic() throws {
        let drawing = try Self.drawing(
            #"<g id="wash"><rect x="20" y="20" width="60" height="60"/></g>"# + Self.square + Self.knockout)
        let first = SymbolGeometry.outline(drawing, strokeWidth: 8)
        let second = SymbolGeometry.outline(drawing, strokeWidth: 8)
        #expect(first.layers.map(\.0) == second.layers.map(\.0))
        for (a, b) in zip(first.layers, second.layers) {
            #expect(a.1 == b.1)
        }
        #expect(first.bounds == second.bounds)
    }
}
