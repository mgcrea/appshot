import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// A glyph's source is read once and outlined later, so what these pin is that nothing
/// in the file is lost or guessed on the way in: transforms and group attributes reach
/// each element, and what cannot be drawn is refused by name rather than dropped.
struct SymbolSourceTests {
    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `body` inside a 100 box (unless `viewBox` says otherwise) and reads it.
    static func read(
        _ body: String, name: String = "feature.extrude.svg", viewBox: String = "0 0 100 100",
        prefix: String = ""
    ) throws -> SymbolDrawing {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox)">
            \(body)
            </svg>
            """
        let url = dir.appending(path: name)
        try svg.write(to: url, atomically: true, encoding: .utf8)
        return try SymbolSource.read(url, prefix: prefix)
    }

    static let outline =
        #"<g id="outline"><rect x="10" y="10" width="80" height="80" stroke="currentColor"/></g>"#

    @Test func readsThreeLayers() throws {
        let drawing = try Self.read(
            """
            <g id="touch"><circle cx="50" cy="50" r="10"/></g>
            <g id="outline"><rect x="10" y="10" width="80" height="80" fill="none" stroke="currentColor"/></g>
            <g id="wash"><rect x="20" y="20" width="60" height="60"/></g>
            """)
        #expect(drawing.name == "feature.extrude")
        #expect(SymbolLayer.allCases == [.wash, .outline, .touch])
        for layer in SymbolLayer.allCases {
            #expect(drawing.layers[layer]?.count == 1)
        }
        #expect(
            drawing.layers[.wash]?.first?.path.boundingBoxOfPath
                == CGRect(x: 20, y: 20, width: 60, height: 60))
        #expect(drawing.layers[.touch]?.first?.description == "<circle> at line 2")
        let outline = try #require(drawing.layers[.outline]?.first)
        #expect(outline.paint.fill == false && outline.paint.stroke == true)
        #expect(outline.paint.strokeWidth == nil)
    }

    @Test func prefixNamesTheAsset() throws {
        let drawing = try Self.read(Self.outline, name: "extrude.svg", prefix: "feature.")
        #expect(drawing.name == "feature.extrude")
    }

    @Test func appliesTransforms() throws {
        let drawing = try Self.read(
            """
            <g id="outline">
              <g transform="translate(10 0) scale(2)"><rect x="3" y="4" width="5" height="6"/></g>
              <rect x="0" y="0" width="10" height="10" transform="rotate(90 5 5)"/>
              <line x1="0" y1="0" x2="10" y2="0" transform="matrix(1 0 0 1 0 7) skewX(45)"/>
            </g>
            """)
        let elements = try #require(drawing.layers[.outline])
        #expect(elements[0].path.boundingBoxOfPath == CGRect(x: 16, y: 8, width: 10, height: 12))
        let turned = elements[1].path.boundingBoxOfPath
        #expect(abs(turned.minX) < 1e-9 && abs(turned.minY) < 1e-9 && abs(turned.width - 10) < 1e-9)
        #expect(elements[2].path.boundingBoxOfPath == CGRect(x: 0, y: 7, width: 10, height: 0))
    }

    @Test func inheritsFromGroup() throws {
        let drawing = try Self.read(
            """
            <g id="outline" stroke="currentColor" stroke-width="5" stroke-linecap="round" stroke-linejoin="bevel"
               stroke-dasharray="4 2">
              <line x1="10" y1="10" x2="90" y2="10"/>
              <line x1="10" y1="20" x2="90" y2="20" stroke-width="3" stroke-linecap="square"/>
              <g fill="none"><polygon points="10,30 90,30 50,60"/></g>
              <polyline points="10,70 50,90 90,70"/>
              <circle cx="50" cy="50" r="5" stroke="none"/>
            </g>
            """)
        let elements = try #require(drawing.layers[.outline])
        #expect(elements[0].paint.strokeWidth == 5)
        #expect(elements[0].paint.lineCap == .round)
        #expect(elements[0].paint.lineJoin == .bevel)
        #expect(elements[0].paint.dash == [4, 2])
        #expect(elements[0].paint.stroke && !elements[0].paint.fill)
        #expect(elements[1].paint.strokeWidth == 3)
        #expect(elements[1].paint.lineCap == .square)
        #expect(!elements[2].paint.fill && elements[2].paint.stroke)
        #expect(!elements[3].paint.fill)
        #expect(elements[4].paint.fill && !elements[4].paint.stroke)
    }

    @Test func strokeScalesWithTheTransform() throws {
        // Lucide's layout: the width on the root, the 24 box scaled into the 100 one.
        let drawing = try Self.read(
            """
            <g id="outline" stroke="currentColor" stroke-width="3" stroke-dasharray="4 1">
              <g transform="scale(2)"><line x1="0" y1="0" x2="10" y2="0"/></g>
              <line x1="0" y1="0" x2="10" y2="0" transform="rotate(30) scale(-1.5 1.5)"/>
              <line x1="0" y1="0" x2="10" y2="0"/>
              <line x1="0" y1="0" x2="10" y2="0" stroke="none" transform="skewX(20)"/>
            </g>
            """)
        let elements = try #require(drawing.layers[.outline])
        #expect(elements[0].paint.strokeWidth == 6)
        #expect(elements[0].paint.dash == [8, 2])
        #expect(abs((elements[1].paint.strokeWidth ?? 0) - 4.5) < 1e-9)
        #expect(elements[1].paint.dash.map { ($0 * 1e6).rounded() / 1e6 } == [6, 1.5])
        #expect(elements[2].paint.strokeWidth == 3)
        // Not stroked, so the skew does not matter.
        #expect(!elements[3].paint.stroke)

        // The family's own width is already in box units: nil stays nil under a scale.
        let family = try Self.read(
            #"<g id="outline" stroke="currentColor" transform="scale(4)"><line x1="0" y1="0" x2="10" y2="0"/></g>"#
        )
        #expect(family.layers[.outline]?.first?.paint.strokeWidth == nil)
    }

    @Test(arguments: [
        #"<line x1="0" y1="0" x2="9" y2="0" stroke="currentColor" stroke-width="2" transform="skewX(20)"/>"#,
        #"<line x1="0" y1="0" x2="9" y2="0" stroke="currentColor" stroke-dasharray="2" transform="scale(1 2)"/>"#,
    ])
    func refusesStrokeUnderSkew(_ element: String) {
        #expect {
            try Self.read(
                """
                <g id="outline">
                  \(element)
                </g>
                """)
        } throws: { error in
            guard case .symbolBadAttribute(_, let line, let what, let fix) = error as? AppShotError else {
                return false
            }
            return what.contains("line") && what.contains("skew") && line == 3
                && fix.contains("into the coordinates")
        }
    }

    /// A value an attribute cannot take is not an attribute the subset lacks: the message
    /// says what to give, not to use the attributes the source already uses.
    @Test(arguments: [
        (#"<circle cx="5" cy="5"/>"#, "<circle> has no r", "give it one"),
        (#"<rect x="1" y="1" width="0" height="2"/>"#, "width=\"0\"", "above 0"),
        (#"<circle cx="a" cy="5" r="2"/>"#, "is not a number", "give a number"),
        (#"<polygon points="1 2 3"/>"#, "points=", "two points"),
        (#"<path d="M0 0 H9" stroke="currentColor" stroke-linecap="pointy"/>"#, "stroke-linecap", "butt"),
        (#"<path d="M0 0 H9" data-knockout="yes"/>"#, "data-knockout", "true or false"),
    ])
    func refusesABadValueSayingWhatToGive(_ element: String, what expected: String, fix expectedFix: String) {
        #expect {
            try Self.read(
                """
                <g id="outline">
                  \(element)
                </g>
                """)
        } throws: { error in
            guard case .symbolBadAttribute(_, let line, let what, let fix) = error as? AppShotError else {
                return false
            }
            let message = "\(error)"
            return what.contains(expected) && fix.contains(expectedFix) && line == 3
                && !message.contains("Draw it with those instead")
        }
    }

    @Test func defaultsWithNothingSet() throws {
        let drawing = try Self.read(#"<g id="outline"><rect x="1" y="1" width="2" height="2"/></g>"#)
        let paint = try #require(drawing.layers[.outline]?.first?.paint)
        #expect(
            paint
                == SymbolPaint(
                    fill: true, stroke: false, strokeWidth: nil, lineCap: .butt, lineJoin: .miter, dash: []))
    }

    @Test func knockoutFlag() throws {
        let drawing = try Self.read(
            Self.outline
                + """
                <g id="touch">
                  <circle cx="80" cy="80" r="10" data-knockout="true"/>
                  <circle cx="20" cy="20" r="10"/>
                </g>
                """)
        let touch = try #require(drawing.layers[.touch])
        #expect(touch[0].knockout)
        #expect(!touch[1].knockout)
    }

    @Test(arguments: [
        (#"<text x="1" y="1">A</text>"#, "text"),
        (#"<linearGradient id="g"/>"#, "linearGradient"),
        (##"<use href="#a"/>"##, "use"),
        (#"<rect x="1" y="1" width="2" height="2" clip-path="url(#c)"/>"#, "clip-path"),
        (#"<rect x="1" y="1" width="2" height="2" filter="url(#f)"/>"#, "filter"),
        (#"<rect x="1" y="1" width="2" height="2" fill="url(#g)"/>"#, "fill"),
    ])
    func refusesWhatItCannotDraw(_ element: String, named: String) {
        #expect {
            try Self.read(
                """
                <g id="outline">
                  <rect x="10" y="10" width="80" height="80"/>
                  \(element)
                </g>
                """)
        } throws: { error in
            guard case .symbolUnsupported(_, let what, let line) = error as? AppShotError else {
                return false
            }
            return what.contains(named) && line == 4
        }
    }

    @Test func refusesDrawingOutsideTheGroups() {
        #expect {
            try Self.read(Self.outline + #"<circle cx="5" cy="5" r="2"/>"#)
        } throws: { error in
            guard case .symbolUnsupported(_, let what, _) = error as? AppShotError else { return false }
            return what.contains("circle")
        }
    }

    @Test func refusesWrongBox() {
        #expect {
            try Self.read(Self.outline, viewBox: "0 0 24 24")
        } throws: { error in
            guard case .symbolBadViewBox(_, let found) = error as? AppShotError else { return false }
            return found == "0 0 24 24"
        }
    }

    @Test func outlineRequired() throws {
        #expect {
            try Self.read(#"<g id="touch"><circle cx="50" cy="50" r="10"/></g>"#)
        } throws: { error in
            guard case .symbolNoOutline = error as? AppShotError else { return false }
            return true
        }
        let alone = try Self.read(Self.outline)
        #expect(alone.layers[.wash] == nil && alone.layers[.touch] == nil)
    }

    @Test func refusesBadName() {
        #expect {
            try Self.read(Self.outline, name: "Feature Extrude.svg")
        } throws: { error in
            guard case .symbolBadName(_, let name) = error as? AppShotError else { return false }
            return name == "Feature Extrude"
        }
    }

    @Test func badPathDataNamesTheElement() {
        #expect {
            try Self.read(
                """
                <g id="outline">
                  <path d="M0 0 L10"/>
                </g>
                """)
        } throws: { error in
            guard case .symbolBadPathData(let url, let why) = error as? AppShotError else { return false }
            return url.lastPathComponent == "feature.extrude.svg" && why.contains("<path> at line 3")
        }
    }

    @Test func settingsDefaults() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try SymbolSettings.read(in: dir)
        #expect(defaults.strokeWidth == 8)
        #expect(defaults.sideBearing == 4)
        #expect(defaults.prefix == "")
        #expect(defaults.out == nil && defaults.companions.isEmpty)
        #expect(defaults.variants.isEmpty && defaults.references.isEmpty)

        try #"""
        {"strokeWidth": 6, "variants": [{"name": "selected", "colors": ["accent", "primary", "#00000022"], "tile": "#007AFF40"}]}
        """#.write(to: dir.appending(path: "symbols.json"), atomically: true, encoding: .utf8)
        let read = try SymbolSettings.read(in: dir)
        #expect(read.strokeWidth == 6)
        #expect(read.sideBearing == 4)
        let variant = try #require(read.variants.first)
        #expect(variant.name == "selected")
        #expect(variant.colors == ["accent", "primary", "#00000022"])
        #expect(variant.tile == "#007AFF40")
    }

    @Test(arguments: [
        #"{"strokeWidth": "wide"}"#,
        #"{"variants": [{"name": "x", "colors": ["red", "primary", "accent"]}]}"#,
        #"{"variants": [{"name": "x", "colors": ["primary"]}]}"#,
        #"{"variants": [{"name": "x", "colors": ["primary", "primary", "accent"], "tile": "blue"}]}"#,
    ])
    func settingsRefuseBadValues(_ json: String) throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try json.write(to: dir.appending(path: "symbols.json"), atomically: true, encoding: .utf8)
        #expect {
            try SymbolSettings.read(in: dir)
        } throws: { error in
            guard case .invalidConfig(let url, _) = error as? AppShotError else { return false }
            return url.lastPathComponent == "symbols.json"
        }
    }
}
