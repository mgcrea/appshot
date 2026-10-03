import CoreGraphics
import CoreText
import Foundation

/// One rendered video frame.
///
/// Everything that does not move — gradient, shadow, the stage's place on the canvas —
/// is rendered once into `Style.backdrop`. The shadow alone is a Gaussian blur over the
/// whole canvas, and doing it 720 times per output is most of a render.
public enum VideoFrame {
    public enum Kind: Sendable { case promo, preview }

    public struct Style: @unchecked Sendable {
        public let kind: Kind
        public let size: Config.Size
        /// Where the stage lands, y-down.
        public let stageRect: CGRect
        public let backdrop: CGImage
        let layout: Config.Layout
        let fontFamily: String
        let theme: Config.Theme
        let captionBaseline: Double
        let captionFontSize: Double
        let card: Config.Card?
        let icon: CGImage?
    }

    /// The config's layout is tuned for its own `output` canvas; scale it to this one.
    static func scaled(_ layout: Config.Layout, by s: Double) -> Config.Layout {
        var l = layout
        l.margin *= s
        l.textTop *= s
        l.titleFontSize *= s
        l.subtitleFontSize *= s
        l.textGap *= s
        l.screenshotGap *= s
        l.cornerRadius *= s
        l.shadow.blur *= s
        l.shadow.dy *= s
        return l
    }

    /// The darkest stop by luma: the preview's surround, which must read as the app's
    /// own backdrop rather than as marketing.
    static func darkest(_ background: Config.Background) -> String {
        func luma(_ hex: String) -> Double {
            guard let c = Image.color(hex: hex)?.components, c.count >= 3 else { return 1 }
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        return background.stops.min { luma($0.color) < luma($1.color) }?.color ?? "#000000"
    }

    /// The box the stage must fit in, plus where and how large the caption is drawn.
    private struct Plan {
        var box: CGRect
        var captionBaseline: Double
        var captionFontSize: Double
    }

    private static func plan(
        kind: Kind, size: Config.Size, config: Config, layout: Config.Layout, video: Config.Video
    ) throws -> Plan {
        let W = Double(size.width)
        let H = Double(size.height)
        switch kind {
        case .promo:
            // Room for the longest caption, so the window never moves between captions.
            let font = try Text.font(
                stack: config.fontFamily, weight: layout.titleWeight, size: layout.titleFontSize)
            let white = CGColor(gray: 1, alpha: 1)
            let maxWidth = W - layout.margin * 2
            let counts = video.beats.compactMap(\.caption).map { caption -> Int in
                let kern = Config.Layout.titleLetterSpacing
                return Text.wrap(caption, font: font, color: white, kern: kern, maxWidth: maxWidth).count
            }
            let lines = counts.max() ?? 0
            let step = layout.titleFontSize * layout.titleLineHeight
            let block: Double = lines == 0 ? 0 : layout.titleFontSize + Double(lines - 1) * step
            let gap: Double = lines == 0 ? 0 : layout.screenshotGap
            let top = layout.textTop + block + gap
            let box = CGRect(x: layout.margin, y: top, width: maxWidth, height: H - top - layout.margin)
            return Plan(
                box: box, captionBaseline: layout.textTop + layout.titleFontSize,
                captionFontSize: layout.titleFontSize)
        case .preview:
            let strip = (H * 0.11).rounded()
            let inset = (layout.margin * 0.5).rounded()
            let box = CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset - strip)
            let fontSize = (strip * 0.42).rounded()
            return Plan(
                box: box, captionBaseline: H - strip / 2 + fontSize * 0.35, captionFontSize: fontSize)
        }
    }

    public static func style(
        kind: Kind, size: Config.Size, config: Config, appearance: String,
        video: Config.Video, stage: CGSize, icon: CGImage?
    ) throws -> Style {
        guard let theme = config.themes[appearance] else { throw AppShotError.missingTheme(appearance) }
        let W = Double(size.width)
        let H = Double(size.height)
        let reference = config.output ?? Config.Size(width: 2880, height: 1800)
        let s = min(W / Double(reference.width), H / Double(reference.height))
        let layout = scaled(config.layout, by: s)

        let plan = try plan(kind: kind, size: size, config: config, layout: layout, video: video)
        let box = plan.box
        guard box.width > 0, box.height > 0 else {
            throw AppShotError.videoRenderFailed(
                video: video.id, reason: "\(size.description) leaves no room for the app under the caption")
        }
        let fit = min(box.width / stage.width, box.height / stage.height)
        let w = (stage.width * fit).rounded()
        let h = (stage.height * fit).rounded()
        let x = ((W - w) / 2).rounded()
        let y = (box.minY + (box.height - h) / 2).rounded()
        let stageRect = CGRect(x: x, y: y, width: w, height: h)

        guard let ctx = Image.context(width: size.width, height: size.height) else {
            throw AppShotError.videoRenderFailed(video: video.id, reason: "no bitmap context")
        }
        switch kind {
        case .promo:
            Compose.drawGradient(ctx, theme.background, width: W, height: H)
        case .preview:
            ctx.setFillColor(Image.color(hex: darkest(theme.background)) ?? CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        Compose.drawShadow(
            ctx, rect: stageRect, radius: layout.cornerRadius, shadow: layout.shadow, width: W, height: H)
        guard let backdrop = ctx.makeImage() else {
            throw AppShotError.videoRenderFailed(video: video.id, reason: "backdrop did not render")
        }

        return Style(
            kind: kind, size: size, stageRect: stageRect, backdrop: backdrop, layout: layout,
            fontFamily: config.fontFamily, theme: theme, captionBaseline: plan.captionBaseline,
            captionFontSize: plan.captionFontSize, card: kind == .promo ? video.card : nil, icon: icon)
    }

    public static func render(
        stage: CGImage, t: Double, timeline: VideoTimeline, style: Style
    ) throws -> CGImage {
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        guard let ctx = Image.context(width: style.size.width, height: style.size.height) else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no bitmap context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(style.backdrop, in: CGRect(x: 0, y: 0, width: W, height: H))

        // Camera: crop the stage around the eased center, clamped inside it.
        let stageSize = CGSize(width: stage.width, height: stage.height)
        let camera = timeline.camera(at: t, stage: stageSize)
        let cw = stageSize.width / camera.scale
        let ch = stageSize.height / camera.scale
        let cropX = min(max(camera.center.x - cw / 2, 0), stageSize.width - cw)
        let cropY = min(max(camera.center.y - ch / 2, 0), stageSize.height - ch)
        let crop = CGRect(x: cropX, y: cropY, width: cw, height: ch).integral
        let dest = Compose.flip(style.stageRect, in: H)
        if camera.scale > 1.001, let cropped = stage.cropping(to: crop) {
            // A zoomed crop has lost the window's own rounded corners; put them back.
            let radius = style.layout.cornerRadius
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: dest, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            ctx.draw(cropped, in: dest)
            ctx.restoreGState()
        } else {
            ctx.draw(stage, in: dest)
        }

        // Pointer, mapped from stage pixels through the same crop.
        let k = style.stageRect.width / crop.width
        if let cursor = timeline.cursor(at: t) {
            let x = style.stageRect.minX + (cursor.point.x - crop.minX) * k
            let y = style.stageRect.minY + (cursor.point.y - crop.minY) * k
            drawPointer(ctx, at: CGPoint(x: x, y: H - y), size: min(W, H) * 0.035, ripple: cursor.ripple)
        }

        if let caption = timeline.caption(at: t) {
            try drawCaption(ctx, caption.text, opacity: caption.opacity, style: style)
        }

        let card = timeline.cardOpacity(at: t)
        if style.kind == .promo, card > 0, let content = style.card {
            try drawCard(ctx, content, opacity: card, style: style)
        }

        guard let image = ctx.makeImage() else {
            throw AppShotError.videoRenderFailed(video: "", reason: "frame did not render")
        }
        return image
    }

    private static func drawCaption(
        _ ctx: CGContext, _ text: String, opacity: Double, style: Style
    ) throws {
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        ctx.saveGState()
        ctx.setAlpha(opacity)
        let font = try Text.font(
            stack: style.fontFamily, weight: style.layout.titleWeight, size: style.captionFontSize)
        let color = Image.color(hex: style.theme.title) ?? CGColor(gray: 1, alpha: 1)
        let lines = Text.wrap(
            text, font: font, color: color, kern: Config.Layout.titleLetterSpacing,
            maxWidth: W - style.layout.margin * 2)
        let step = style.captionFontSize * style.layout.titleLineHeight
        for (i, line) in lines.enumerated() {
            let baseline = style.captionBaseline + Double(i) * step
            Compose.draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
        }
        ctx.restoreGState()
    }

    /// The end card: the theme's gradient over the whole frame, then icon, title, subtitle.
    private static func drawCard(
        _ ctx: CGContext, _ content: Config.Card, opacity: Double, style: Style
    ) throws {
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        ctx.saveGState()
        ctx.setAlpha(opacity)
        Compose.drawGradient(ctx, style.theme.background, width: W, height: H)
        let side = min(W, H) * 0.22
        let midY = H * 0.38
        if let icon = style.icon {
            let iconRect = CGRect(x: (W - side) / 2, y: midY - side / 2, width: side, height: side)
            ctx.draw(icon, in: Compose.flip(iconRect, in: H))
        }
        let titleFont = try Text.font(
            stack: style.fontFamily, weight: style.layout.titleWeight, size: style.captionFontSize)
        let subFont = try Text.font(
            stack: style.fontFamily, weight: style.layout.subtitleWeight, size: style.captionFontSize * 0.5)
        let titleColor = Image.color(hex: style.theme.title) ?? CGColor(gray: 1, alpha: 1)
        let subColor = Image.color(hex: style.theme.subtitle) ?? titleColor
        var baseline = midY + side / 2 + style.captionFontSize * 1.4
        for line in Text.wrap(content.title, font: titleFont, color: titleColor, kern: 0, maxWidth: W) {
            Compose.draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
        }
        if let subtitle = content.subtitle {
            baseline += style.captionFontSize * 0.9
            for line in Text.wrap(subtitle, font: subFont, color: subColor, kern: 0, maxWidth: W) {
                Compose.draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
            }
        }
        ctx.restoreGState()
    }

    /// A plain arrow, drawn rather than borrowed: Apple's cursor artwork is not ours to
    /// ship. `origin` is the tip, in CoreGraphics' y-up space.
    static func drawPointer(_ ctx: CGContext, at origin: CGPoint, size: Double, ripple: Double?) {
        if let ripple {
            ctx.saveGState()
            let r = size * (0.6 + ripple)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6 * (1 - ripple)))
            ctx.setLineWidth(size * 0.12)
            ctx.strokeEllipse(in: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
        let path = CGMutablePath()
        let points: [(Double, Double)] = [
            (0, 0), (0, -1), (0.28, -0.74), (0.46, -1.1), (0.6, -1.04), (0.43, -0.68), (0.78, -0.68),
        ]
        path.addLines(between: points.map { CGPoint(x: origin.x + $0.0 * size, y: origin.y + $0.1 * size) })
        path.closeSubpath()
        ctx.saveGState()
        let shadowOffset = CGSize(width: 0, height: -size * 0.04)
        ctx.setShadow(offset: shadowOffset, blur: size * 0.15, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(size * 0.06)
        ctx.strokePath()
    }
}
