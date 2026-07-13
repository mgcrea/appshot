import CoreGraphics
import CoreText
import Foundation

/// Font resolution and metric-driven line breaking.
///
/// The JS pipeline this replaces guessed at both: it wrapped text by
/// `approxCharWidth = fontSize * 0.52` because librsvg exposes no metrics at
/// rasterize time, and it "checked" the font with `fc-match` — a check that only
/// warned, and that was in fact never called. Both problems are structural to that
/// stack and both simply disappear here: CoreText knows the real advances, and it
/// can refuse a font that isn't installed instead of quietly substituting one.
public enum Text {
    /// Resolve the first family in a CSS-style font stack at a CSS weight.
    ///
    /// Throws if the family is not installed. librsvg would substitute silently and
    /// ship store captions in the wrong typeface; the whole point of doing this in
    /// CoreText is that we can make it a hard failure.
    public static func font(stack: String, weight: Int, size: Double) throws -> CTFont {
        let family = primaryFamily(stack)
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family as CFString,
            kCTFontTraitsAttribute: [
                kCTFontWeightTrait: ctWeight(fromCSS: weight)
            ] as CFDictionary,
        ] as CFDictionary)

        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let resolved = CTFontCopyFamilyName(font) as String
        guard resolved.caseInsensitiveCompare(family) == .orderedSame else {
            throw AppShotError.fontNotResolved(requested: family, got: resolved)
        }
        return font
    }

    /// First entry of `"'SF Pro Display', -apple-system, Helvetica, sans-serif"`,
    /// unquoted.
    public static func primaryFamily(_ stack: String) -> String {
        let first = stack.split(separator: ",").first.map(String.init) ?? stack
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }

    /// CSS numeric weight → CoreText's -1...1 scale (matching NSFont.Weight).
    static func ctWeight(fromCSS weight: Int) -> CGFloat {
        switch weight {
        case ..<200: return -0.8   // ultraLight
        case 200..<300: return -0.6  // thin
        case 300..<400: return -0.4  // light
        case 400..<500: return 0.0   // regular
        case 500..<600: return 0.23  // medium
        case 600..<700: return 0.3   // semibold
        case 700..<800: return 0.4   // bold
        case 800..<900: return 0.56  // heavy
        default: return 0.62         // black
        }
    }

    /// One rendered line: its typeset content and its measured width.
    public struct Line {
        public let ctLine: CTLine
        public let width: Double
    }

    /// Break `text` into lines that fit `maxWidth`, using real font metrics.
    ///
    /// Explicit `\n` is a hard break and is always honoured (the config uses it to
    /// force a title onto two lines).
    public static func wrap(
        _ text: String,
        font: CTFont,
        color: CGColor,
        kern: Double,
        maxWidth: Double
    ) -> [Line] {
        var lines: [Line] = []
        for paragraph in text.components(separatedBy: "\n") {
            let attributed = NSAttributedString(
                string: paragraph,
                attributes: [
                    .init(kCTFontAttributeName as String): font,
                    .init(kCTForegroundColorAttributeName as String): color,
                    .init(kCTKernAttributeName as String): kern,
                ])
            guard attributed.length > 0 else {
                lines.append(Line(ctLine: CTLineCreateWithAttributedString(attributed), width: 0))
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            while start < attributed.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, maxWidth)
                guard count > 0 else { break }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                lines.append(Line(ctLine: line, width: CTLineGetTypographicBounds(line, nil, nil, nil)))
                start += count
            }
        }
        return lines
    }
}
