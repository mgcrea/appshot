import CoreGraphics
import Foundation

/// The outline of a spotlight or a pop, in stage pixels (y-down). A `rect` region keeps
/// the rounded rectangle it always had; a circle or a ring follows the app's own round
/// elements, such as a fan chart's root and its rings of generations.
public enum VideoShape: Sendable, Equatable {
    case rect
    case circle(center: CGPoint, radius: Double)
    /// An annular sector. Angles are degrees clockwise from east (y-down), `from` < `to`;
    /// 0 to 360 is a whole ring. An inner radius of 0 makes a pie slice.
    case ring(center: CGPoint, inner: Double, outer: Double, from: Double, to: Double)

    /// The smallest rectangle holding the shape: what a pop crops and lifts, and what a
    /// spotlight checks against the stage.
    public var bounds: CGRect? {
        switch self {
        case .rect:
            return nil
        case .circle(let c, let r):
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .ring(let c, let inner, let outer, let from, let to):
            // The extremes of a sector lie at its two end angles or at a quarter turn
            // inside it, on either radius.
            var angles = [from, to]
            var q = (from / 90).rounded(.up) * 90
            while q < to {
                angles.append(q)
                q += 90
            }
            var points = angles.flatMap { a -> [CGPoint] in
                let r = a * .pi / 180
                return [inner, outer].map { CGPoint(x: c.x + $0 * cos(r), y: c.y + $0 * sin(r)) }
            }
            if inner == 0 { points.append(c) }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(
                x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// The outline drawn through `transform` (stage pixels to wherever it lands), grown by
    /// `pad` stage pixels. Fill and clip it even-odd: a whole ring is two circles.
    func path(transform: CGAffineTransform, pad: Double = 0) -> CGPath {
        let path = CGMutablePath()
        switch self {
        case .rect:
            break
        case .circle(let c, let r):
            path.addEllipse(
                in: CGRect(x: c.x - r - pad, y: c.y - r - pad, width: 2 * (r + pad), height: 2 * (r + pad)),
                transform: transform)
        case .ring(let c, let inner, let outer, let from, let to):
            let rIn = max(0, inner - pad)
            let rOut = outer + pad
            if to - from >= 360 {
                path.addEllipse(
                    in: CGRect(x: c.x - rOut, y: c.y - rOut, width: 2 * rOut, height: 2 * rOut),
                    transform: transform)
                if rIn > 0 {
                    path.addEllipse(
                        in: CGRect(x: c.x - rIn, y: c.y - rIn, width: 2 * rIn, height: 2 * rIn),
                        transform: transform)
                }
            } else {
                // Grow the angles by the same pad in pixels, measured at the middle radius.
                let widen = pad / max((rIn + rOut) / 2, 1)
                let a = from * .pi / 180 - widen
                let b = to * .pi / 180 + widen
                path.addArc(
                    center: c, radius: rOut, startAngle: a, endAngle: b, clockwise: false,
                    transform: transform)
                if rIn > 0 {
                    path.addArc(
                        center: c, radius: rIn, startAngle: b, endAngle: a, clockwise: true,
                        transform: transform)
                } else {
                    path.addLine(to: c, transform: transform)
                }
                path.closeSubpath()
            }
        }
        return path
    }
}
