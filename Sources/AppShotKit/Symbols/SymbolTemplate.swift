import CoreGraphics
import Foundation

/// Writes an outlined glyph as the SVG template a `.symbolset` holds, in the Regular-M slot
/// only, which Xcode accepts and uses at every weight and scale.
///
/// The skeleton is the SF Symbols app's own (`Resources/badge.plus.svg`, template writer
/// version 101), cut to what `actool` reads. It is kept here rather than read from the app,
/// which CI does not have. What `actool` demanded, tried on 2026-11-24 (Xcode 26):
/// - all six baseline and cap-line guides, S, M and L, even with only Regular-M drawn: it
///   refuses the file, naming the first missing one ("missing a baseline guide for
///   Baseline-S", then Baseline-L, then "missing a capline guide for Capline-S");
/// - the margin guides named for the slot drawn, `left-margin-Regular-M` and
///   `right-margin-Regular-M`, and no S margin guides;
/// - of the `Notes` group, only its `template-version` text. Without it the file compiles but
///   is read as an older template, whose monochrome ignores a class's `opacity`, so the wash
///   draws in monochrome; the artboard, captions and sample glyphs are left out;
/// - not the `multicolor-N` classes, which are left out too.
public enum SymbolTemplate {
    /// At point size 100: Regular-M's baseline is at y 1126 and its cap line at 1055.54.
    public static let capHeight = 70.459
    public static let baselineM = 1126.0
    /// The reference template's left margin guide; the glyph's group is placed on it.
    public static let leftMargin = 1396.3

    /// Template points per box unit: the 100 box is one cap height tall.
    static var unit: Double { capHeight / 100 }

    /// - Parameter sideBearing: the room left and right of the outlined bounds, in box
    ///   units, between the paths and the margin guides.
    public static func svg(_ symbol: OutlinedSymbol, sideBearing: Double) -> String {
        let k = unit
        let bounds = symbol.bounds
        // Box (x, y), y down, to the group's space: the box's bottom on the baseline (y 0),
        // its top on the cap line, the outlined left edge `sideBearing` in from the guide.
        let place = { (p: CGPoint) in
            CGPoint(x: (p.x - bounds.minX + sideBearing) * k, y: (p.y - 100) * k)
        }
        let right = leftMargin + (bounds.width + 2 * sideBearing) * k

        var style: [String] = []
        var paths: [String] = []
        for (index, (layer, path)) in symbol.layers.enumerated() {
            let role = hierarchicalRole(layer)
            // Monochrome draws one colour, so the wash would fill the glyph's inside: it is
            // hidden there, and no layer uses -sfsymbols-clear-behind, since the knockout is
            // already cut into the geometry.
            let hidden = layer == .wash ? ";opacity:0.0" : ""
            style.append(".monochrome-\(index) {fill:#000000\(hidden)}")
            style.append(".hierarchical-\(index):\(role) {fill:#212121}")
            paths.append(
                "   <path class=\"monochrome-\(index) hierarchical-\(index):\(role)\" d=\"\(pathData(path, place))\"/>"
            )
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE svg
            PUBLIC "-//W3C//DTD SVG 1.1//EN"
                   "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
             <!--glyph: "", point size: 100.0, template writer version: "101"-->
             <style>\(style.joined(separator: "\n"))
            </style>
             <g id="Notes">
              <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.4.0</text>
             </g>
             <g id="Guides">
            \(guide("Baseline-S", y: 696))
            \(guide("Capline-S", y: 625.54))
            \(guide("Baseline-M", y: baselineM))
            \(guide("Capline-M", y: baselineM - capHeight))
            \(guide("Baseline-L", y: 1556))
            \(guide("Capline-L", y: 1485.54))
            \(margin("left-margin-Regular-M", x: leftMargin))
            \(margin("right-margin-Regular-M", x: right))
             </g>
             <g id="Symbols">
              <g id="Regular-M" transform="matrix(1 0 0 1 \(number(leftMargin)) \(number(baselineM)))">
            \(paths.joined(separator: "\n"))
              </g>
             </g>
            </svg>

            """
    }

    /// The `.symbolset`'s `Contents.json`, naming its one SVG.
    public static func contentsJSON(svgName: String) -> Data {
        struct Info: Encodable {
            let author = "xcode"
            let version = 1
        }
        struct Entry: Encodable {
            let filename: String
            let idiom = "universal"
        }
        struct Contents: Encodable {
            let info = Info()
            let symbols: [Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Contents(symbols: [Entry(filename: svgName)]))) ?? Data()
        return data + Data("\n".utf8)
    }

    /// The palette maps primary, secondary and tertiary to an app's first, second and third
    /// colour, so the outline takes the first, the touch the second and the wash the third.
    static func hierarchicalRole(_ layer: SymbolLayer) -> String {
        switch layer {
        case .outline: "primary"
        case .touch: "secondary"
        case .wash: "tertiary"
        }
    }

    static func guide(_ id: String, y: Double) -> String {
        let y = number(y)
        return
            "  <line id=\"\(id)\" style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\" y1=\"\(y)\" y2=\"\(y)\"/>"
    }

    static func margin(_ id: String, x: Double) -> String {
        let x = number(x)
        return
            "  <line id=\"\(id)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(x)\" x2=\"\(x)\" y1=\"1030\" y2=\"1150\"/>"
    }

    /// Absolute `M`, `L`, `Q`, `C` and `Z`, each point placed by `place`.
    static func pathData(_ path: CGPath, _ place: (CGPoint) -> CGPoint) -> String {
        var d = ""
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            func point(_ i: Int) -> String {
                let p = place(element.points[i])
                return "\(number(p.x)) \(number(p.y))"
            }
            switch element.type {
            case .moveToPoint: d += "M" + point(0)
            case .addLineToPoint: d += "L" + point(0)
            case .addQuadCurveToPoint: d += "Q" + point(0) + " " + point(1)
            case .addCurveToPoint: d += "C" + point(0) + " " + point(1) + " " + point(2)
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    /// At most two decimals, trailing zeros dropped and `-0` written `0`, so the same
    /// geometry always gives the same bytes.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
