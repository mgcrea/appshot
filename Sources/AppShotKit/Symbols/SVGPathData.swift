import CoreGraphics
import Foundation

/// SVG path data (`d`) to a `CGPath`, with every shorthand the grammar allows:
/// relative commands, implicit repeats, `H`/`V`, the `S`/`T` reflections and `A` arcs.
///
/// Arcs are converted, never approximated by their chord: a generator that draws a ring
/// as two arcs would otherwise get a flat line that only the sheet shows.
public enum SVGPathData {
    /// Stands in for the file when the data is parsed on its own; ``SymbolSource``
    /// rethrows with the real file and the element.
    static let standalone = URL(fileURLWithPath: "path data")

    public static func parse(_ d: String) throws -> CGPath {
        do {
            return try parseOrFail(d)
        } catch let failure as Failure {
            throw AppShotError.symbolBadPathData(standalone, failure.reason)
        }
    }

    struct Failure: Error {
        let reason: String
    }

    static func parseOrFail(_ d: String) throws -> CGPath {
        var scanner = NumberScanner(d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        // The control point S or T reflects, set only right after a curve of its kind.
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        var command: Character?
        var needsMove = false

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            let letter: Character
            if next.isLetter {
                scanner.advance()
                letter = next
            } else if let repeated = command {
                if repeated == "Z" || repeated == "z" {
                    throw Failure(reason: "a number after Z, with no command before it")
                }
                // Pairs after a moveto are linetos, of the same case.
                letter = repeated == "M" ? "L" : repeated == "m" ? "l" : repeated
            } else {
                throw Failure(reason: "path data must start with M, found \"\(next)\"")
            }
            if command == nil, letter != "M", letter != "m" {
                throw Failure(reason: "path data must start with M, found \"\(letter)\"")
            }
            command = letter

            let relative = letter.isLowercase
            let base = relative ? current : .zero
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: base.x + x, y: base.y + y)
            }
            if needsMove, letter != "M", letter != "m", letter != "Z", letter != "z" {
                path.move(to: current)
                needsMove = false
            }

            switch letter {
            case "M", "m":
                let p = point(try scanner.number(letter), try scanner.number(letter))
                path.move(to: p)
                current = p
                start = p
                needsMove = false
                lastCubic = nil
                lastQuad = nil
            case "L", "l":
                let p = point(try scanner.number(letter), try scanner.number(letter))
                path.addLine(to: p)
                current = p
                lastCubic = nil
                lastQuad = nil
            case "H", "h":
                let x = try scanner.number(letter)
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p)
                current = p
                lastCubic = nil
                lastQuad = nil
            case "V", "v":
                let y = try scanner.number(letter)
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p)
                current = p
                lastCubic = nil
                lastQuad = nil
            case "C", "c":
                let c1 = point(try scanner.number(letter), try scanner.number(letter))
                let c2 = point(try scanner.number(letter), try scanner.number(letter))
                let p = point(try scanner.number(letter), try scanner.number(letter))
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubic = c2
                lastQuad = nil
            case "S", "s":
                let c1 = reflect(lastCubic, about: current)
                let c2 = point(try scanner.number(letter), try scanner.number(letter))
                let p = point(try scanner.number(letter), try scanner.number(letter))
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubic = c2
                lastQuad = nil
            case "Q", "q":
                let c = point(try scanner.number(letter), try scanner.number(letter))
                let p = point(try scanner.number(letter), try scanner.number(letter))
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuad = c
                lastCubic = nil
            case "T", "t":
                let c = reflect(lastQuad, about: current)
                let p = point(try scanner.number(letter), try scanner.number(letter))
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuad = c
                lastCubic = nil
            case "A", "a":
                let rx = try scanner.number(letter)
                let ry = try scanner.number(letter)
                let rotation = try scanner.number(letter)
                let large = try scanner.flag(letter)
                let sweep = try scanner.flag(letter)
                let p = point(try scanner.number(letter), try scanner.number(letter))
                addArc(
                    to: path, from: current, radii: (rx, ry), rotation: rotation,
                    large: large, sweep: sweep, end: p)
                current = p
                lastCubic = nil
                lastQuad = nil
            case "Z", "z":
                path.closeSubpath()
                current = start
                needsMove = true
                lastCubic = nil
                lastQuad = nil
            default:
                throw Failure(reason: "\"\(letter)\" is not a path command")
            }
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, about p: CGPoint) -> CGPoint {
        guard let control else { return p }
        return CGPoint(x: 2 * p.x - control.x, y: 2 * p.y - control.y)
    }

    /// The SVG implementation notes' endpoint-to-centre conversion (F.6.5), radii scaled
    /// up when they cannot span the chord (F.6.6), emitted as cubics of at most 90° each.
    static func addArc(
        to path: CGMutablePath, from p0: CGPoint, radii: (Double, Double), rotation: Double,
        large: Bool, sweep: Bool, end p1: CGPoint
    ) {
        if p0 == p1 { return }
        var rx = abs(radii.0)
        var ry = abs(radii.1)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2
        let dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = (max(0, numerator / denominator)).squareRoot() * (large == sweep ? -1 : 1)
        let cxp = coefficient * rx * y1p / ry
        let cyp = coefficient * -ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let count = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(count)
        let k = 4.0 / 3.0 * tan(step / 4)
        func at(_ t: Double) -> CGPoint {
            CGPoint(
                x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func tangent(_ t: Double) -> CGPoint {
            CGPoint(
                x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        for i in 0..<count {
            let t1 = theta1 + Double(i) * step
            let t2 = t1 + step
            let a = at(t1)
            let b = i == count - 1 ? p1 : at(t2)
            let d1 = tangent(t1)
            let d2 = tangent(t2)
            path.addCurve(
                to: b,
                control1: CGPoint(x: a.x + k * d1.x, y: a.y + k * d1.y),
                control2: CGPoint(x: b.x - k * d2.x, y: b.y - k * d2.y))
        }
    }
}

/// Reads SVG numbers as the grammar packs them: `10-5.5.5` is three numbers, commas and
/// whitespace separate, and an arc flag is one character with no separator needed.
struct NumberScanner {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) {
        chars = Array(text)
    }

    var peek: Character? { index < chars.count ? chars[index] : nil }
    var atEnd: Bool {
        var copy = self
        copy.skipSeparators()
        return copy.peek == nil
    }

    mutating func advance() { index += 1 }

    mutating func skipSeparators() {
        while let c = peek, c.isWhitespace || c == "," { index += 1 }
    }

    /// The next number, or nil when the next thing is not one.
    mutating func scanNumber() -> Double? {
        skipSeparators()
        let begin = index
        if let c = peek, c == "+" || c == "-" { index += 1 }
        var digits = 0
        while let c = peek, c.isASCII, c.isNumber {
            index += 1
            digits += 1
        }
        if peek == "." {
            index += 1
            while let c = peek, c.isASCII, c.isNumber {
                index += 1
                digits += 1
            }
        }
        guard digits > 0 else {
            index = begin
            return nil
        }
        if let e = peek, e == "e" || e == "E" {
            let mark = index
            index += 1
            if let c = peek, c == "+" || c == "-" { index += 1 }
            var exponent = 0
            while let c = peek, c.isASCII, c.isNumber {
                index += 1
                exponent += 1
            }
            if exponent == 0 { index = mark }
        }
        return Double(String(chars[begin..<index]))
    }

    mutating func number(_ command: Character) throws -> Double {
        guard let value = scanNumber() else {
            let found = peek.map { "\"\($0)\"" } ?? "the end"
            throw SVGPathData.Failure(reason: "expected a number for \(command), found \(found)")
        }
        return value
    }

    mutating func flag(_ command: Character) throws -> Bool {
        skipSeparators()
        switch peek {
        case "0":
            index += 1
            return false
        case "1":
            index += 1
            return true
        default:
            let found = peek.map { "\"\($0)\"" } ?? "the end"
            throw SVGPathData.Failure(reason: "expected an arc flag (0 or 1) for \(command), found \(found)")
        }
    }

    /// Every number in `text`, or nil when anything else is in it.
    static func numbers(_ text: String) -> [Double]? {
        var scanner = NumberScanner(text)
        var out: [Double] = []
        while !scanner.atEnd {
            guard let value = scanner.scanNumber() else { return nil }
            out.append(value)
        }
        return out
    }
}
