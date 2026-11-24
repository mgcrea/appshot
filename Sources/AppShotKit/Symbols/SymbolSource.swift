import CoreGraphics
import Foundation

/// The three groups a glyph's SVG may hold, in drawing order.
public enum SymbolLayer: String, CaseIterable, Sendable {
    case wash, outline, touch
}

/// How an element is painted, after what its groups set.
public struct SymbolPaint: Equatable, Sendable {
    public var fill: Bool
    public var stroke: Bool
    /// In box units; nil means the family's own (`symbols.json`'s `strokeWidth`).
    public var strokeWidth: Double?
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    public var dash: [Double]

    public init(
        fill: Bool, stroke: Bool, strokeWidth: Double? = nil, lineCap: CGLineCap = .butt,
        lineJoin: CGLineJoin = .miter, dash: [Double] = []
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.dash = dash
    }
}

/// One drawn element of a layer.
///
/// Unchecked because `CGPath` is not marked `Sendable`; a `CGPath` (as against a
/// `CGMutablePath`) is immutable, and nothing here keeps a mutable one.
public struct SymbolElement: @unchecked Sendable {
    /// In box units, y down, with every transform above it applied.
    public let path: CGPath
    public let paint: SymbolPaint
    /// A touch element that cuts the outline away under it.
    public let knockout: Bool
    /// "<circle> at line 7", for messages.
    public let description: String
}

/// A glyph as its source draws it, before any outlining.
public struct SymbolDrawing: Sendable {
    /// The asset name: the prefix and the file name without `.svg`.
    public let name: String
    /// Only the groups the file has; `outline` is always there.
    public let layers: [SymbolLayer: [SymbolElement]]
}

/// Reads one glyph's layered SVG on the 100 box.
///
/// Only what a symbol template can hold is read, and everything else is refused by name
/// with its line: dropping a gradient or a clip path silently would give a glyph that
/// differs from its source in a way nobody sees until the sheet.
public enum SymbolSource {
    static var namePattern: Regex<(Substring, Substring?)> { /^[a-z0-9]+([._-][a-z0-9]+)*$/ }

    public static func read(_ url: URL, prefix: String) throws -> SymbolDrawing {
        let name = prefix + url.deletingPathExtension().lastPathComponent
        guard name.wholeMatch(of: namePattern) != nil else {
            throw AppShotError.symbolBadName(url, name: name)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AppShotError.symbolUnreadable(url, reason: error.localizedDescription)
        }
        let reader = Reader(url)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        let parsed = parser.parse()
        if let failure = reader.failure { throw failure }
        guard parsed else {
            let why = parser.parserError?.localizedDescription ?? "not well-formed XML"
            throw AppShotError.symbolUnreadable(url, reason: "line \(parser.lineNumber): \(why)")
        }
        guard reader.sawRoot else {
            throw AppShotError.symbolUnreadable(url, reason: "no <svg> element")
        }
        guard reader.layers[.outline] != nil else { throw AppShotError.symbolNoOutline(url) }
        return SymbolDrawing(name: name, layers: reader.layers)
    }

    /// What a group passes down to its children.
    struct Inherited {
        var transform = CGAffineTransform.identity
        var fill: Bool?
        var stroke: Bool?
        var strokeWidth: Double?
        var lineCap: CGLineCap?
        var lineJoin: CGLineJoin?
        var dash: [Double]?
        var knockout: Bool?
        var layer: SymbolLayer?
        /// Inside `<title>`, `<desc>`, `<metadata>` or an editor's own namespaced element.
        var ignored = false
    }

    static let shapes: [String: Set<String>] = [
        "path": ["d"],
        "line": ["x1", "y1", "x2", "y2"],
        "polyline": ["points"],
        "polygon": ["points"],
        "rect": ["x", "y", "width", "height", "rx", "ry"],
        "circle": ["cx", "cy", "r"],
        "ellipse": ["cx", "cy", "rx", "ry"],
    ]
    static let paintAttributes: Set<String> = [
        "transform", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
        "stroke-dasharray", "data-knockout",
    ]
    static let ignoredElements: Set<String> = ["title", "desc", "metadata"]

    final class Reader: NSObject, XMLParserDelegate {
        let url: URL
        var failure: AppShotError?
        var sawRoot = false
        var layers: [SymbolLayer: [SymbolElement]] = [:]
        private var stack: [Inherited] = []

        init(_ url: URL) {
            self.url = url
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            do {
                try start(name, attributes, line: parser.lineNumber)
            } catch let error as AppShotError {
                failure = error
                parser.abortParsing()
            } catch {
                failure = .symbolUnreadable(url, reason: "\(error)")
                parser.abortParsing()
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
        ) {
            stack.removeLast()
        }

        private func start(_ name: String, _ attributes: [String: String], line: Int) throws {
            guard let parent = stack.last else {
                guard name == "svg" else {
                    throw AppShotError.symbolUnreadable(
                        url, reason: "the root element is <\(name)>, not <svg>")
                }
                sawRoot = true
                let box = attributes["viewBox"]
                guard let box, NumberScanner.numbers(box) == [0, 0, 100, 100] else {
                    throw AppShotError.symbolBadViewBox(url, found: box ?? "none")
                }
                // The root's paint passes down as a group's does (Figma writes fill="none" there).
                var root = Inherited()
                try inherit(
                    attributes.filter { $0.key != "transform" && Self.isPaint($0.key) }, into: &root, name,
                    line)
                stack.append(root)
                return
            }
            var here = parent
            if parent.ignored || SymbolSource.ignoredElements.contains(name) || name.contains(":") {
                here.ignored = true
                stack.append(here)
                return
            }
            if name == "g" {
                try check(attributes, allowed: [], name, line)
                try inherit(attributes, into: &here, name, line)
                if let id = attributes["id"], let layer = SymbolLayer(rawValue: id) {
                    here.layer = layer
                    if layers[layer] == nil { layers[layer] = [] }
                }
                stack.append(here)
                return
            }
            if name == "defs" {
                stack.append(here)
                return
            }
            guard let geometry = SymbolSource.shapes[name] else {
                throw AppShotError.symbolUnsupported(url, element: "<\(name)>", line: line)
            }
            guard let layer = parent.layer else {
                throw AppShotError.symbolUnsupported(
                    url, element: "<\(name)> outside the wash, outline and touch groups", line: line)
            }
            try check(attributes, allowed: geometry, name, line)
            try inherit(attributes, into: &here, name, line)
            stack.append(here)

            let description = "<\(name)> at line \(line)"
            let local = try shape(name, attributes, description, line)
            var transform = here.transform
            let path = local.copy(using: &transform) ?? local.copy() ?? local
            let isLine = name == "line" || name == "polyline"
            let paint = SymbolPaint(
                fill: name == "line" ? false : here.fill ?? !isLine,
                stroke: here.stroke ?? false,
                strokeWidth: here.strokeWidth,
                lineCap: here.lineCap ?? .butt,
                lineJoin: here.lineJoin ?? .miter,
                dash: here.dash ?? [])
            layers[layer, default: []].append(
                SymbolElement(
                    path: path, paint: paint, knockout: here.knockout ?? false, description: description))
        }

        static func isPaint(_ attribute: String) -> Bool {
            SymbolSource.paintAttributes.contains(attribute)
        }

        private func check(_ attributes: [String: String], allowed: Set<String>, _ name: String, _ line: Int)
            throws
        {
            for key in attributes.keys.sorted() {
                if key == "id" || key.hasPrefix("xmlns") || allowed.contains(key) || Self.isPaint(key) {
                    continue
                }
                throw AppShotError.symbolUnsupported(url, element: "\(key) on <\(name)>", line: line)
            }
        }

        private func refuse(_ key: String, _ value: String, _ name: String, _ line: Int) -> AppShotError {
            .symbolUnsupported(url, element: "\(key)=\"\(value)\" on <\(name)>", line: line)
        }

        private func inherit(
            _ attributes: [String: String], into state: inout Inherited, _ name: String, _ line: Int
        ) throws {
            for (key, raw) in attributes {
                let value = raw.trimmingCharacters(in: .whitespaces)
                switch key {
                case "transform":
                    guard let local = SVGTransform.parse(value) else { throw refuse(key, value, name, line) }
                    // The element's own transform applies first, then its parents'.
                    state.transform = local.concatenating(state.transform)
                case "fill", "stroke":
                    if value.hasPrefix("url(") { throw refuse(key, value, name, line) }
                    let painted = value != "none"
                    if key == "fill" { state.fill = painted } else { state.stroke = painted }
                case "stroke-width":
                    guard let width = Self.length(value), width >= 0 else {
                        throw refuse(key, value, name, line)
                    }
                    state.strokeWidth = width
                case "stroke-linecap":
                    let caps: [String: CGLineCap] = ["butt": .butt, "round": .round, "square": .square]
                    guard let cap = caps[value] else { throw refuse(key, value, name, line) }
                    state.lineCap = cap
                case "stroke-linejoin":
                    let joins: [String: CGLineJoin] = ["miter": .miter, "round": .round, "bevel": .bevel]
                    guard let join = joins[value] else { throw refuse(key, value, name, line) }
                    state.lineJoin = join
                case "stroke-dasharray":
                    if value == "none" {
                        state.dash = []
                        continue
                    }
                    guard let dash = NumberScanner.numbers(value), dash.allSatisfy({ $0 >= 0 }),
                        dash.contains(where: { $0 > 0 })
                    else { throw refuse(key, value, name, line) }
                    // An odd list repeats to make it even, as SVG says.
                    state.dash = dash.count.isMultiple(of: 2) ? dash : dash + dash
                case "data-knockout":
                    guard value == "true" || value == "false" else { throw refuse(key, value, name, line) }
                    state.knockout = value == "true"
                default:
                    continue
                }
            }
        }

        /// A plain number, or one in `px`, which is the same unit in a viewBox.
        static func length(_ value: String) -> Double? {
            Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value)
        }

        private func shape(
            _ name: String, _ a: [String: String], _ description: String, _ line: Int
        ) throws -> CGPath {
            func number(_ key: String, default fallback: Double? = 0) throws -> Double {
                guard let raw = a[key] else {
                    if let fallback { return fallback }
                    throw AppShotError.symbolUnsupported(url, element: "<\(name)> without \(key)", line: line)
                }
                guard let value = Self.length(raw.trimmingCharacters(in: .whitespaces)) else {
                    throw AppShotError.symbolUnsupported(
                        url, element: "\(key)=\"\(raw)\" on <\(name)>", line: line)
                }
                return value
            }
            func positive(_ key: String) throws -> Double {
                let value = try number(key, default: nil)
                guard value > 0 else {
                    throw AppShotError.symbolUnsupported(
                        url, element: "\(key)=\"\(a[key] ?? "")\" on <\(name)>, which draws nothing",
                        line: line)
                }
                return value
            }
            switch name {
            case "path":
                do {
                    return try SVGPathData.parseOrFail(a["d"] ?? "")
                } catch let failure as SVGPathData.Failure {
                    throw AppShotError.symbolBadPathData(url, "\(description): \(failure.reason)")
                }
            case "line":
                let path = CGMutablePath()
                path.move(to: CGPoint(x: try number("x1"), y: try number("y1")))
                path.addLine(to: CGPoint(x: try number("x2"), y: try number("y2")))
                return path
            case "polyline", "polygon":
                guard let values = NumberScanner.numbers(a["points"] ?? ""), values.count >= 4,
                    values.count.isMultiple(of: 2)
                else {
                    throw AppShotError.symbolUnsupported(
                        url, element: "points=\"\(a["points"] ?? "")\" on <\(name)>", line: line)
                }
                let points = stride(from: 0, to: values.count, by: 2).map {
                    CGPoint(x: values[$0], y: values[$0 + 1])
                }
                let path = CGMutablePath()
                path.addLines(between: points)
                if name == "polygon" { path.closeSubpath() }
                return path
            case "rect":
                let rect = CGRect(
                    x: try number("x"), y: try number("y"), width: try positive("width"),
                    height: try positive("height"))
                // One radius given stands for both; each is clamped to half its side.
                let rx = a["rx"] == nil ? nil : try number("rx")
                let ry = a["ry"] == nil ? nil : try number("ry")
                let cornerX = min(max(rx ?? ry ?? 0, 0), rect.width / 2)
                let cornerY = min(max(ry ?? rx ?? 0, 0), rect.height / 2)
                if cornerX == 0 || cornerY == 0 { return CGPath(rect: rect, transform: nil) }
                return CGPath(roundedRect: rect, cornerWidth: cornerX, cornerHeight: cornerY, transform: nil)
            case "circle":
                let r = try positive("r")
                return CGPath(
                    ellipseIn: CGRect(
                        x: try number("cx") - r, y: try number("cy") - r, width: 2 * r, height: 2 * r),
                    transform: nil)
            case "ellipse":
                let rx = try positive("rx")
                let ry = try positive("ry")
                return CGPath(
                    ellipseIn: CGRect(
                        x: try number("cx") - rx, y: try number("cy") - ry, width: 2 * rx, height: 2 * ry),
                    transform: nil)
            default:
                throw AppShotError.symbolUnsupported(url, element: "<\(name)>", line: line)
            }
        }
    }
}

/// An SVG `transform` list: `matrix`, `translate`, `scale`, `rotate` (with an optional
/// centre), `skewX` and `skewY`, composed left to right as SVG does.
enum SVGTransform {
    static func parse(_ text: String) -> CGAffineTransform? {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            if rest.isEmpty { return result }
            guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"), open < close
            else { return nil }
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            guard let args = NumberScanner.numbers(String(rest[rest.index(after: open)..<close])) else {
                return nil
            }
            guard let local = make(name, args) else { return nil }
            // `a b` maps a point by b, then by a.
            result = local.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
    }

    private static func make(_ name: String, _ v: [Double]) -> CGAffineTransform? {
        let radians = { (degrees: Double) in degrees * .pi / 180 }
        switch (name, v.count) {
        case ("matrix", 6):
            return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        case ("translate", 1), ("translate", 2):
            return CGAffineTransform(translationX: v[0], y: v.count == 2 ? v[1] : 0)
        case ("scale", 1), ("scale", 2):
            return CGAffineTransform(scaleX: v[0], y: v.count == 2 ? v[1] : v[0])
        case ("rotate", 1):
            return CGAffineTransform(rotationAngle: radians(v[0]))
        case ("rotate", 3):
            // translate(cx cy) rotate(a) translate(-cx -cy)
            return CGAffineTransform(translationX: -v[1], y: -v[2])
                .concatenating(CGAffineTransform(rotationAngle: radians(v[0])))
                .concatenating(CGAffineTransform(translationX: v[1], y: v[2]))
        case ("skewX", 1):
            return CGAffineTransform(a: 1, b: 0, c: tan(radians(v[0])), d: 1, tx: 0, ty: 0)
        case ("skewY", 1):
            return CGAffineTransform(a: 1, b: tan(radians(v[0])), c: 0, d: 1, tx: 0, ty: 0)
        default:
            return nil
        }
    }
}
