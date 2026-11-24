import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Path data from a generator uses every shorthand SVG allows, and a command parsed wrong
/// is not an error anywhere: it is a glyph that looks slightly off on the sheet. So each
/// shorthand is pinned to the geometry it must make, not to "it parsed".
struct SVGPathDataTests {
    enum Segment: Equatable {
        case move(CGPoint), line(CGPoint), quad(CGPoint, CGPoint), cubic(CGPoint, CGPoint, CGPoint), close
    }

    static func segments(_ path: CGPath) -> [Segment] {
        var out: [Segment] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: out.append(.move(e.points[0]))
            case .addLineToPoint: out.append(.line(e.points[0]))
            case .addQuadCurveToPoint: out.append(.quad(e.points[0], e.points[1]))
            case .addCurveToPoint: out.append(.cubic(e.points[0], e.points[1], e.points[2]))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }

    @Test func absoluteAndRelativeAgree() throws {
        let absolute = try SVGPathData.parse("M10 10 L20 10 L20 20 Z")
        let relative = try SVGPathData.parse("m10 10 l10 0 l0 10 z")
        #expect(absolute.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 10, height: 10))
        #expect(relative.boundingBoxOfPath == absolute.boundingBoxOfPath)
        #expect(Self.segments(relative) == Self.segments(absolute))
    }

    @Test func implicitRepeats() throws {
        let path = try SVGPathData.parse("M0 0 l10 0 0 10")
        #expect(
            Self.segments(path) == [
                .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)),
            ])
        #expect(path.currentPoint == CGPoint(x: 10, y: 10))

        // Pairs after a moveto are linetos, relative after a relative one.
        let afterMove = try SVGPathData.parse("m5 5 10 0")
        #expect(Self.segments(afterMove) == [.move(CGPoint(x: 5, y: 5)), .line(CGPoint(x: 15, y: 5))])

        // Numbers packed the way minifiers write them.
        let packed = try SVGPathData.parse("M0,0L10-5.5.5.5")
        #expect(
            Self.segments(packed) == [
                .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: -5.5)), .line(CGPoint(x: 0.5, y: 0.5)),
            ])
    }

    @Test func horizontalVertical() throws {
        let path = try SVGPathData.parse("M0 0 H30 V40")
        #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 30, height: 40))
        let relative = try SVGPathData.parse("M5 5 h10 v10 h-10")
        #expect(relative.currentPoint == CGPoint(x: 5, y: 15))
    }

    @Test func smoothCurves() throws {
        let path = try SVGPathData.parse("M0 0 C0 10 10 10 10 0 S20 -10 20 0")
        #expect(path.currentPoint == CGPoint(x: 20, y: 0))
        // The second curve's first control point is the first's second, reflected.
        let spelledOut = try SVGPathData.parse("M0 0 C0 10 10 10 10 0 C10 -10 20 -10 20 0")
        #expect(Self.segments(path) == Self.segments(spelledOut))
        let second = try SVGPathData.parse("M10 0 C10 -10 20 -10 20 0")
        #expect(second.boundingBoxOfPath.minY < 0)

        // S with no curve before it takes the current point as its first control.
        let lone = try SVGPathData.parse("M0 0 S10 10 20 0")
        #expect(
            Self.segments(lone)[1] == .cubic(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0))
        )

        // T reflects the quadratic control, relative t too.
        let quads = try SVGPathData.parse("M0 0 Q5 10 10 0 t10 0")
        #expect(
            Self.segments(quads) == [
                .move(CGPoint(x: 0, y: 0)), .quad(CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 0)),
                .quad(CGPoint(x: 15, y: -10), CGPoint(x: 20, y: 0)),
            ])
    }

    @Test func arcs() throws {
        let half = try SVGPathData.parse("M0 50 A50 50 0 0 1 100 50")
        let box = half.boundingBoxOfPath
        #expect(abs(box.minX - 0) < 0.01 && abs(box.minY - 0) < 0.01)
        #expect(abs(box.width - 100) < 0.01 && abs(box.height - 50) < 0.01)
        #expect(half.boundingBox.height > 49)
        #expect(abs(half.currentPoint.x - 100) < 1e-9 && abs(half.currentPoint.y - 50) < 1e-9)
        // At most 90° a curve: two curves for a half turn.
        #expect(Self.segments(half).filter { if case .cubic = $0 { true } else { false } }.count == 2)

        // The other sweep takes the lower half.
        let lower = try SVGPathData.parse("M0 50 A50 50 0 0 0 100 50")
        #expect(abs(lower.boundingBoxOfPath.maxY - 100) < 0.01)

        // A radius too small for the chord is scaled up, as SVG says.
        let small = try SVGPathData.parse("M0 50 a1 1 0 0 1 100 0")
        #expect(abs(small.boundingBoxOfPath.height - 50) < 0.01)

        // Packed flags: "a25 25 0 1110 0" is large 1, sweep 1, then 10 0.
        let packed = try SVGPathData.parse("M0 0 a25 25 0 1110 0")
        #expect(abs(packed.currentPoint.x - 10) < 1e-9)
        #expect(packed.boundingBoxOfPath.height > 40)

        let flat = try SVGPathData.parse("M0 0 A0 5 0 0 1 10 0")
        #expect(Self.segments(flat) == [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 0))])
    }

    @Test func closeReturnsToTheSubpathStart() throws {
        let path = try SVGPathData.parse("M10 10 h10 z l0 10")
        #expect(path.currentPoint == CGPoint(x: 10, y: 20))
    }

    @Test(arguments: ["M0 0 L10", "L10 10", "M0 0 X5", "M0 0 A5 5 0 2 1 10 0", "M0 0 z 5 5", "M"])
    func garbageThrows(_ d: String) {
        #expect {
            try SVGPathData.parse(d)
        } throws: { error in
            guard case .symbolBadPathData = error as? AppShotError else { return false }
            return true
        }
    }
}
