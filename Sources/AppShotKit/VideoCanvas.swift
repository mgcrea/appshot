import CoreGraphics
import CoreText

/// A bitmap drawn in y-down pixels, the space every rect in a config and a track uses.
final class VideoCanvas {
    let ctx: CGContext
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard let ctx = Image.context(width: width, height: height) else { return nil }
        self.ctx = ctx
        self.width = width
        self.height = height
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
    }

    /// Draws `image` upright in `rect`.
    func image(_ image: CGImage, in rect: CGRect, alpha: Double = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Draws a line of text with its left edge at `x` and its baseline at `baseline`.
    func text(_ line: CTLine, x: Double, baseline: Double) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Runs `draw` in CoreGraphics' own y-up space, for helpers written for it.
    func yUp(_ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: 1, y: -1)
        draw()
        ctx.restoreGState()
    }

    func makeImage() -> CGImage? { ctx.makeImage() }
}
