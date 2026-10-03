import CoreGraphics
import CoreText
import Foundation

/// The whole video as one image, so an agent that cannot watch a video can still look
/// at it: one settled frame per beat, one in the middle of each caption, each labeled.
public enum ContactSheet {
    public struct Cell {
        public let time: Double
        public let label: String
        public let image: CGImage

        public init(time: Double, label: String, image: CGImage) {
            self.time = time
            self.label = label
            self.image = image
        }
    }

    /// After a beat, the UI may still be animating; 0.8s is past every transition this
    /// pipeline draws itself (the longest is the 0.6s zoom).
    static let settle = 0.8

    public static func times(for timeline: VideoTimeline, beats: [Double]) -> [Double] {
        let raw =
            beats.map { min($0 + settle, timeline.duration - 0.01) }
            + timeline.captions.map { ($0.start + $0.end) / 2 }
        var out: [Double] = []
        for t in raw.sorted() where out.last.map({ t - $0 >= 0.1 }) ?? true {
            out.append((t * 100).rounded() / 100)
        }
        return out
    }

    public static func render(
        _ cells: [Cell],
        columns: Int = 3,
        cellWidth: Int = 640
    ) throws -> CGImage {
        guard let first = cells.first else {
            throw AppShotError.videoRenderFailed(
                video: "",
                reason: "no frames for the contact sheet"
            )
        }
        let thumb = Int(
            (Double(cellWidth) * Double(first.image.height) / Double(first.image.width))
                .rounded()
        )
        let band = max(40, cellWidth / 16)
        let rows = (cells.count + columns - 1) / columns
        let W = columns * cellWidth
        let H = rows * (thumb + band)
        guard let ctx = Image.context(width: W, height: H) else {
            throw AppShotError.videoRenderFailed(
                video: "",
                reason: "no bitmap context"
            )
        }
        ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Helvetica ships with every macOS; the sheet is a working image, not a store one.
        let font = try Text.font(stack: "Helvetica", weight: 500, size: Double(band) * 0.5)
        let white = CGColor(gray: 0.92, alpha: 1)
        ctx.interpolationQuality = .high
        for (i, cell) in cells.enumerated() {
            let x = Double((i % columns) * cellWidth)
            let top = Double((i / columns) * (thumb + band))
            ctx.draw(
                cell.image,
                in: Compose.flip(
                    CGRect(x: x, y: top, width: Double(cellWidth), height: Double(thumb)),
                    in: Double(H)
                )
            )
            let label = String(format: "%.1fs  ", cell.time) + cell.label
            if let line = Text.wrap(
                label,
                font: font,
                color: white,
                kern: 0,
                maxWidth: Double(cellWidth) - 24
            ).first {
                ctx.textPosition = CGPoint(
                    x: x + 12,
                    y: Double(H) - (top + Double(thumb) + Double(band) * 0.68)
                )
                CTLineDraw(line.ctLine, ctx)
            }
        }
        guard let image = ctx.makeImage() else {
            throw AppShotError.videoRenderFailed(
                video: "",
                reason: "contact sheet did not render"
            )
        }
        return image
    }
}
