import CoreGraphics
import CoreText
import Foundation

/// One rendered video frame: the layers a preset asks for, at time t.
public enum VideoFrame {
    public enum Kind: Sendable { case promo, preview }

    public struct Style: @unchecked Sendable {
        public let kind: Kind
        public let size: Config.Size
        public let preset: MotionPreset
        /// The window at rest (zoom 1), y-down.
        public let stageRect: CGRect
        public let camera: VideoCamera
        /// The caption band's height; 0 for pill captions and previews.
        public let bandHeight: Double
        public let margin: Double
        public let captionFontSize: Double
        public var minDim: Double { Double(min(size.width, size.height)) }
        let captionFont: CTFont
        /// Previews: the caption strip's first baseline.
        let previewBaseline: Double
        let theme: Config.Theme
        let fontFamily: String
        let titleColor: CGColor
        let subtitleColor: CGColor
        let accent: CGColor
        let scrimColor: CGColor
        let card: Config.Card?
        let icon: CGImage?
    }

    static func luma(_ hex: String) -> Double {
        guard let c = Image.color(hex: hex)?.components, c.count >= 3 else { return 1 }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    /// The darkest stop by luma: the preview's surround, which must read as the app's
    /// own backdrop rather than as marketing.
    static func darkest(_ background: Config.Background) -> String {
        background.stops.min { luma($0.color) < luma($1.color) }?.color ?? "#000000"
    }

    /// The gradient stop that contrasts most with the caption colour. The scrim under a
    /// caption must keep it readable over the app, in light themes as in dark ones.
    public static func scrim(_ theme: Config.Theme) -> String {
        let title = luma(theme.title)
        return theme.background.stops.max {
            abs(luma($0.color) - title) < abs(luma($1.color) - title)
        }?.color ?? "#000000"
    }

    public static func style(
        kind: Kind, size: Config.Size, config: Config, appearance: String, video: Config.Video,
        stage: CGSize, icon: CGImage?, preset: MotionPreset, timeline: VideoTimeline
    ) throws -> Style {
        guard let theme = config.themes[appearance] else { throw AppShotError.missingTheme(appearance) }
        let W = Double(size.width)
        let H = Double(size.height)
        let minDim = min(W, H)
        let m = (minDim * 0.05).rounded()
        let titleColor = Image.color(hex: theme.title) ?? CGColor(gray: 1, alpha: 1)
        let accent = theme.accent.flatMap { Image.color(hex: $0) } ?? titleColor

        var box: CGRect
        var band = 0.0
        var fontSize: Double
        var weight = preset.captionWeight
        var previewBaseline = 0.0
        switch kind {
        case .promo:
            fontSize = (preset.captionSize * minDim).rounded()
            if preset.captions == .band {
                // Room for the longest caption, the hook included, so the window never
                // moves between captions.
                let font = try Text.font(stack: config.fontFamily, weight: weight, size: fontSize)
                let rows =
                    timeline.captions.compactMap { KineticText.tokens($0.text) }.map {
                        KineticText.layout(
                            $0, font: font, color: titleColor, accent: titleColor, maxWidth: W - 2 * m
                        ).rows
                    }.max() ?? 0
                band = rows == 0 ? m : Double(rows) * fontSize * 1.15 + 2 * m
                // A band taller than the frame would give the rect a negative height, which
                // CGRect standardizes into a positive one, so the scalar is what to check.
                guard H - band - m >= minDim * 0.5 else {
                    throw AppShotError.videoRenderFailed(
                        video: video.id,
                        reason: "\(size.description) leaves no room for the app under the caption")
                }
                box = CGRect(x: m, y: band, width: W - 2 * m, height: H - band - m)
            } else {
                box = CGRect(x: m, y: m, width: W - 2 * m, height: H - 2 * m)
            }
        case .preview:
            let strip = (H * 0.11).rounded()
            let inset = (m * 0.5).rounded()
            box = CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset - strip)
            fontSize = (strip * 0.42).rounded()
            weight = config.layout.titleWeight
            previewBaseline = H - strip / 2 + fontSize * 0.35
        }
        guard box.width > 1, box.height > 1 else {
            throw AppShotError.videoRenderFailed(
                video: video.id, reason: "\(size.description) leaves no room for the app under the caption")
        }
        let fit = min(box.width / stage.width, box.height / stage.height)
        let w = (stage.width * fit).rounded()
        let h = (stage.height * fit).rounded()
        let stageRect = CGRect(
            x: ((W - w) / 2).rounded(), y: (box.minY + (box.height - h) / 2).rounded(), width: w, height: h)
        let hookCard = kind == .promo && preset.hookCard && timeline.hook != nil
        // A preview's window is simply there from frame 0: no entry (far in the past), no exit.
        let camera = VideoCamera(
            preset: preset, stage: stage, canvas: CGSize(width: W, height: H), box: box,
            keys: timeline.focusKeys,
            entryAt: kind == .preview ? -1000 : hookCard ? MotionPreset.hookDuration - 0.25 : 0,
            exitAt: kind == .promo ? timeline.cardStart : nil)

        return Style(
            kind: kind, size: size, preset: preset, stageRect: stageRect, camera: camera, bandHeight: band,
            margin: m, captionFontSize: fontSize,
            captionFont: try Text.font(stack: config.fontFamily, weight: weight, size: fontSize),
            previewBaseline: previewBaseline, theme: theme, fontFamily: config.fontFamily,
            titleColor: titleColor, subtitleColor: Image.color(hex: theme.subtitle) ?? titleColor,
            accent: accent, scrimColor: Image.color(hex: scrim(theme)) ?? CGColor(gray: 0, alpha: 1),
            card: kind == .promo ? video.card : nil, icon: icon)
    }

    public static func render(
        stage: CGImage, t: Double, timeline: VideoTimeline, style: Style
    ) throws -> CGImage {
        try layers(stage: stage, t: t, timeline: timeline, style: style)
    }

    /// One sample of the frame, every layer at exactly `t`.
    static func layers(
        stage: CGImage, t: Double, timeline: VideoTimeline, style: Style
    ) throws -> CGImage {
        guard let canvas = VideoCanvas(width: style.size.width, height: style.size.height) else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no bitmap context")
        }
        drawBackground(canvas, t: t, style: style)
        let placed = style.camera.placement(at: t)
        drawWindow(canvas, stage: stage, placed: placed, style: style)
        try drawCaption(canvas, t: t, timeline: timeline, placed: placed, style: style)
        if style.kind == .promo {
            try drawHook(canvas, t: t, timeline: timeline, style: style)
            try drawCard(canvas, t: t, timeline: timeline, style: style)
        }
        guard let image = canvas.makeImage() else {
            throw AppShotError.videoRenderFailed(video: "", reason: "frame did not render")
        }
        return image
    }

    static func drawBackground(_ canvas: VideoCanvas, t: Double, style: Style) {
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        let ctx = canvas.ctx
        switch style.kind {
        case .preview:
            ctx.setFillColor(Image.color(hex: darkest(style.theme.background)) ?? CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        case .promo:
            var background = style.theme.background
            background.angle += style.preset.swing * sin(2 * .pi * t / 20)
            canvas.yUp { Compose.drawGradient(ctx, background, width: W, height: H) }
            guard style.preset.glow, let clear = style.accent.copy(alpha: 0),
                let glow = style.accent.copy(alpha: 0.28),
                let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [glow, clear] as CFArray,
                    locations: [0, 1])
            else { return }
            let p = CGPoint(
                x: W * (0.5 + 0.3 * sin(2 * .pi * t / 14)), y: H * (0.62 + 0.12 * cos(2 * .pi * t / 11)))
            ctx.drawRadialGradient(
                gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: max(W, H) * 0.55,
                options: [])
        }
    }

    static func drawWindow(
        _ canvas: VideoCanvas, stage: CGImage, placed: VideoCamera.Placement, style: Style
    ) {
        guard placed.alpha > 0.001, placed.rect.maxY > 0, placed.rect.minY < Double(style.size.height)
        else { return }
        canvas.ctx.saveGState()
        canvas.ctx.setShadow(
            offset: CGSize(width: 0, height: -style.minDim * 0.02), blur: style.minDim * 0.05,
            color: CGColor(gray: 0, alpha: 0.45))
        canvas.image(stage, in: placed.rect, alpha: placed.alpha)
        canvas.ctx.restoreGState()
    }

    // MARK: - Text

    static func drawCaption(
        _ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, placed: VideoCamera.Placement,
        style: Style
    ) throws {
        guard let span = timeline.captions.last(where: { $0.start <= t && t < $0.end }),
            let tokens = KineticText.tokens(span.text)
        else { return }
        // A hook card holds the screen first; its text joins the band as it leaves.
        let from =
            span.isHook && style.kind == .promo && style.preset.hookCard
            ? MotionPreset.hookDuration : span.start
        guard t >= from else { return }
        let age = t - from
        let left = span.end - t
        let W = Double(style.size.width)
        let fs = style.captionFontSize
        let ctx = canvas.ctx
        let exit = Ease.clamp01(left / 0.25)

        switch (style.kind, style.preset.captions) {
        case (.preview, _):
            let plain = tokens.map { KineticText.Token(text: $0.text, accent: false) }
            let layout = KineticText.layout(
                plain, font: style.captionFont, color: style.titleColor, accent: style.titleColor,
                maxWidth: W - 2 * style.margin)
            ctx.saveGState()
            ctx.setAlpha(min(Ease.clamp01(age / 0.25), exit))
            for word in layout.words {
                canvas.text(
                    word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                    baseline: style.previewBaseline + Double(word.row) * fs * 1.15)
            }
            ctx.restoreGState()

        case (.promo, .pill):
            let padX = fs * 0.9
            let padY = fs * 0.55
            let plain = tokens.map { KineticText.Token(text: $0.text, accent: false) }
            let layout = KineticText.layout(
                plain, font: style.captionFont, color: style.titleColor, accent: style.titleColor,
                maxWidth: W - 2 * style.margin - 2 * padX)
            let enter = Ease.out(age / 0.4)
            let w = (layout.rowWidths.max() ?? 0) + padX * 2
            let h = Double(layout.rows) * fs * 1.15 - fs * 0.15 + padY * 2
            let y = Double(style.size.height) - style.minDim * 0.07 - h + (1 - enter) * style.minDim * 0.025
            let pill = CGRect(x: (W - w) / 2, y: y, width: w, height: h)
            ctx.saveGState()
            ctx.setAlpha(min(enter, exit))
            ctx.addPath(
                CGPath(
                    roundedRect: pill, cornerWidth: min(h / 2, fs), cornerHeight: min(h / 2, fs),
                    transform: nil))
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 0.72))
            ctx.fillPath()
            for word in layout.words {
                canvas.text(
                    word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                    baseline: pill.minY + padY + fs * 0.8 + Double(word.row) * fs * 1.15)
            }
            ctx.restoreGState()

        case (.promo, .band):
            // A scrim under the band once the camera has pushed the window up into it.
            let intrude = Ease.clamp01((style.bandHeight - placed.rect.minY) / (style.bandHeight * 0.5))
            if intrude > 0, let top = style.scrimColor.copy(alpha: 0.88 * intrude * placed.alpha),
                let clear = style.scrimColor.copy(alpha: 0),
                let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, top, clear] as CFArray,
                    locations: [0, 0.55, 1])
            {
                ctx.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: style.bandHeight * 1.3), options: [])
            }
            let layout = KineticText.layout(
                tokens, font: style.captionFont, color: style.titleColor, accent: style.accent,
                maxWidth: W - 2 * style.margin)
            let step = fs * 1.15
            let top = (style.bandHeight - Double(layout.rows) * step) / 2 + fs * 0.85
            for (index, word) in layout.words.enumerated() {
                var alpha: Double
                var drop = -(1 - exit) * 0.3
                if style.preset.wordStagger > 0 {
                    let e = KineticText.entrance(
                        age: age, index: index, stagger: style.preset.wordStagger,
                        spring: style.preset.wordSpring)
                    alpha = min(e.alpha, exit)
                    drop += e.drop
                } else {
                    alpha = min(Ease.smooth(age / 0.35), exit)
                }
                ctx.saveGState()
                ctx.setAlpha(alpha)
                canvas.text(
                    word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                    baseline: top + Double(word.row) * step + drop * fs)
                ctx.restoreGState()
            }
        }
    }

    /// The hook card's type, its wrapped words and the row pitch. Shared by the drawing and
    /// by `style`, which refuses a hook the frame cannot hold.
    static func hookLayout(
        _ hook: String, size: Config.Size, fontFamily: String, preset: MotionPreset, color: CGColor,
        accent: CGColor
    ) throws -> (layout: KineticText.Layout, fontSize: Double, step: Double)? {
        guard let tokens = KineticText.tokens(hook) else { return nil }
        let minDim = Double(min(size.width, size.height))
        let font = try Text.font(stack: fontFamily, weight: 800, size: (preset.hookSize * minDim).rounded())
        let fontSize = CTFontGetSize(font)
        let layout = KineticText.layout(
            tokens, font: font, color: color, accent: accent, maxWidth: Double(size.width) * 0.84)
        return (layout, fontSize, fontSize * 1.08)
    }

    static func drawHook(_ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, style: Style) throws {
        guard style.preset.hookCard, let hook = timeline.hook, t < MotionPreset.hookDuration,
            let placed = try hookLayout(
                hook, size: style.size, fontFamily: style.fontFamily, preset: style.preset,
                color: style.titleColor, accent: style.accent)
        else { return }
        let (layout, size, step) = placed
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        let top = (H - Double(layout.rows) * step) / 2 + size * 0.8
        let exit = Ease.clamp01((t - (MotionPreset.hookDuration - 0.35)) / 0.3)
        for (index, word) in layout.words.enumerated() {
            let e = KineticText.entrance(
                age: t - 0.1, index: index, stagger: style.preset.hookStagger,
                spring: Spring(response: 0.45, damping: 0.65))
            canvas.ctx.saveGState()
            canvas.ctx.setAlpha(e.alpha * (1 - exit))
            canvas.text(
                word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                baseline: top + Double(word.row) * step + (e.drop - exit * exit * 0.8) * size)
            canvas.ctx.restoreGState()
        }
    }

    // MARK: - End card

    public struct CardLine {
        public enum Role: Sendable { case title, subtitle }
        public let line: CTLine
        public let width: Double
        /// Left edge, y-down canvas pixels.
        public let x: Double
        public let baseline: Double
        public let role: Role
    }

    static func cardGeometry(_ style: Style) -> (side: Double, midY: Double) {
        (style.minDim * 0.24, Double(style.size.height) * 0.38)
    }

    /// The card's title (accent marks honoured) and subtitle, wrapped inside the margins,
    /// one baseline per row so a long name stacks instead of overprinting itself.
    static func cardText(_ content: Config.Card, style: Style) throws -> [CardLine] {
        let W = Double(style.size.width)
        let maxWidth = W - 2 * style.margin
        let titleSize = (style.minDim * 0.085).rounded()
        let subSize = (style.minDim * 0.038).rounded()
        let titleFont = try Text.font(stack: style.fontFamily, weight: 800, size: titleSize)
        let subFont = try Text.font(stack: style.fontFamily, weight: 500, size: subSize)
        let card = cardGeometry(style)
        var out: [CardLine] = []
        var baseline = card.midY + card.side / 2 + style.minDim * 0.11
        let title = KineticText.layout(
            KineticText.tokens(content.title) ?? [], font: titleFont, color: style.titleColor,
            accent: style.accent, maxWidth: maxWidth)
        for word in title.words {
            out.append(
                CardLine(
                    line: word.line, width: word.width, x: (W - title.rowWidths[word.row]) / 2 + word.x,
                    baseline: baseline + Double(word.row) * titleSize * 1.08, role: .title))
        }
        baseline += Double(max(title.rows - 1, 0)) * titleSize * 1.08
        if let subtitle = content.subtitle {
            baseline += style.minDim * 0.065
            let lines = Text.wrap(
                subtitle, font: subFont, color: style.subtitleColor, kern: 0, maxWidth: maxWidth)
            for (i, line) in lines.enumerated() {
                if i > 0 { baseline += subSize * 1.3 }
                out.append(
                    CardLine(
                        line: line.ctLine, width: line.width,
                        x: (W - line.width + CTLineGetTrailingWhitespaceWidth(line.ctLine)) / 2,
                        baseline: baseline,
                        role: .subtitle))
            }
        }
        return out
    }

    static func drawCard(_ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, style: Style) throws {
        guard let start = timeline.cardStart, let content = style.card else { return }
        let q = t - start - 0.3
        guard q > 0 else { return }
        let W = Double(style.size.width)
        let ctx = canvas.ctx
        let card = cardGeometry(style)
        let springy = style.preset.card == .spring

        var iconScale = 1.0
        var iconAlpha: Double
        var iconDrop = 0.0
        if springy {
            iconScale = Spring(response: 0.55, damping: 0.55).value(q)
            iconAlpha = Ease.clamp01(q / 0.08)
        } else {
            iconAlpha = Ease.out(q / 0.7)
            iconDrop = (1 - iconAlpha) * style.minDim * 0.04
        }
        if let icon = style.icon {
            let s = card.side * iconScale
            let rect = CGRect(x: (W - s) / 2, y: card.midY - s / 2 + iconDrop, width: s, height: s)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -style.minDim * 0.015), blur: style.minDim * 0.04,
                color: CGColor(gray: 0, alpha: 0.4 * iconAlpha))
            canvas.image(icon, in: rect, alpha: iconAlpha)
            ctx.restoreGState()
        }

        func arrival(_ delay: Double) -> (alpha: Double, drop: Double) {
            let a = q - delay
            if springy {
                return (
                    Ease.clamp01(a / 0.12),
                    (1 - Spring(response: 0.5, damping: 0.7).value(a)) * style.minDim * 0.05
                )
            }
            let e = Ease.out(a / 0.6)
            return (e, (1 - e) * style.minDim * 0.03)
        }
        let lines = try cardText(content, style: style)
        for line in lines {
            let a = arrival(line.role == .title ? 0.15 : 0.3)
            ctx.saveGState()
            ctx.setAlpha(a.alpha)
            canvas.text(line.line, x: line.x, baseline: line.baseline + a.drop)
            ctx.restoreGState()
        }

        guard let cta = content.cta else { return }
        let a = arrival(0.6)
        guard a.alpha > 0 else { return }
        let font = try Text.font(stack: style.fontFamily, weight: 600, size: (style.minDim * 0.03).rounded())
        let fs = CTFontGetSize(font)
        let line = KineticText.line(
            cta, font: font, color: springy ? CGColor(gray: 1, alpha: 1) : style.titleColor)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let h = fs * 2.2
        let w = width + fs * 2.4
        let top = (lines.map(\.baseline).max() ?? card.midY) + style.minDim * 0.055 + a.drop
        let pill = CGRect(x: (W - w) / 2, y: top, width: w, height: h)
        ctx.saveGState()
        ctx.setAlpha(a.alpha)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        if springy {
            ctx.setFillColor(style.accent)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(style.titleColor.copy(alpha: 0.5) ?? style.titleColor)
            ctx.setLineWidth(style.minDim * 0.002)
            ctx.strokePath()
        }
        canvas.text(line, x: pill.minX + fs * 1.2, baseline: pill.minY + h / 2 + fs * 0.35)
        ctx.restoreGState()
    }
}
