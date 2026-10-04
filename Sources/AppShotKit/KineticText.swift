import CoreGraphics
import CoreText
import Foundation

/// Captions set word by word, with `*accent*` marks.
public enum KineticText {
    public struct Token: Equatable, Sendable {
        public var text: String
        public var accent: Bool
    }

    /// The words of `text`, each flagged when an accent mark covers it.
    ///
    /// Every `*` toggles the accent, and a word takes the state at its first letter, so
    /// `*mess*.` is one accent word and `*artist and album*.` three. Nil when a mark is
    /// left open: an unclosed `*` would otherwise colour the rest of the caption.
    public static func tokens(_ text: String) -> [Token]? {
        var on = false
        var out: [Token] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            var word = ""
            var accent: Bool?
            for character in raw {
                if character == "*" {
                    on.toggle()
                    continue
                }
                if accent == nil { accent = on }
                word.append(character)
            }
            if !word.isEmpty { out.append(Token(text: word, accent: accent ?? false)) }
        }
        return on ? nil : out
    }

    /// The text as read: marks dropped.
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "")
    }

    public struct Placed {
        public let line: CTLine
        public let width: Double
        /// From the row's left edge.
        public let x: Double
        public let row: Int
    }

    public struct Layout {
        public let words: [Placed]
        public let rowWidths: [Double]
        public var rows: Int { rowWidths.count }
    }

    /// Greedy wrap at `maxWidth`, one `CTLine` per word so each can move on its own. A
    /// word wider than the line gets a row of its own rather than being cut.
    public static func layout(
        _ tokens: [Token], font: CTFont, color: CGColor, accent: CGColor, maxWidth: Double
    ) -> Layout {
        let space = CTLineGetTypographicBounds(line(" ", font: font, color: color), nil, nil, nil)
        var words: [Placed] = []
        var widths: [Double] = []
        var x = 0.0
        var row = 0
        for token in tokens {
            let ct = line(token.text, font: font, color: token.accent ? accent : color)
            let width = CTLineGetTypographicBounds(ct, nil, nil, nil)
            if x > 0, x + width > maxWidth {
                widths.append(x - space)
                row += 1
                x = 0
            }
            words.append(Placed(line: ct, width: width, x: x, row: row))
            x += width + space
        }
        if !words.isEmpty { widths.append(x - space) }
        return Layout(words: words, rowWidths: widths)
    }

    public static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .init(kCTFontAttributeName as String): font,
                    .init(kCTForegroundColorAttributeName as String): color,
                    .init(kCTKernAttributeName as String): Config.Layout.titleLetterSpacing,
                ]))
    }

    /// One word's entrance, `age` seconds after its caption appeared: its opacity, and
    /// how far below its resting baseline it still is, as a fraction of the font size.
    public static func entrance(
        age: Double, index: Int, stagger: Double, spring: Spring
    ) -> (alpha: Double, drop: Double) {
        let local = age - stagger * Double(index)
        return (Ease.clamp01(local / 0.15), (1 - spring.value(local)) * 0.6)
    }
}
