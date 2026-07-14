import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Builds the framed, captioned store visuals and the bare website captures from
/// the raw window screenshots.
///
/// Coordinates below are **y-down**, matching the config (which was written for
/// SVG). `flip(_:)` converts to CoreGraphics' y-up at the point of drawing, so the
/// layout arithmetic reads the same as the original.
public enum Compose {
    public struct Output: Sendable {
        public let url: URL
        public let size: Config.Size
        public let windowSize: Config.Size
    }

    // MARK: - App Store

    /// One framed 2880x1800 (or whatever `output` says) visual per screen x
    /// appearance.
    ///
    /// Fails if any capture is missing, and does not touch the output directory
    /// until every input has been checked: emitting five of six store images is how
    /// a listing ships with a gap, and wiping first then discovering the gap is how
    /// a whole set gets destroyed.
    public static func appStore(
        config: Config,
        sourceDir: URL,
        outDir: URL,
        warnings: (String) -> Void = { _ in }
    ) throws -> [Output] {
        try config.validate()
        try requireCaptures(config: config, sourceDir: sourceDir)
        // Resolve the font before wiping anything — a missing font is the most
        // likely reason a run is about to produce garbage.
        _ = try Text.font(
            stack: config.fontFamily, weight: config.layout.titleWeight,
            size: config.layout.titleFontSize)

        try wipePNGs(in: outDir)

        var outputs: [Output] = []
        for (index, screen) in config.screens.enumerated() {
            for appearance in config.appearances {
                let source = sourceDir.appending(path: "\(screen.id)~\(appearance).png")
                // App Store Connect sorts uploads by filename, so the screen's
                // position in screens[] becomes its numeric prefix. The raw captures
                // stay unnumbered, so reordering the listing never renames an image.
                let prefix = String(format: "%02d", index + 1)
                let out = outDir.appending(path: "\(prefix)-\(screen.id)~\(appearance).png")

                let output = try composeOne(
                    config: config,
                    screen: screen,
                    appearance: appearance,
                    source: source,
                    out: out,
                    warnings: warnings)
                outputs.append(output)
            }
        }
        return outputs
    }

    private static func composeOne(
        config: Config,
        screen: Config.Screen,
        appearance: String,
        source: URL,
        out: URL,
        warnings: (String) -> Void
    ) throws -> Output {
        let W = Double(config.output.width)
        let H = Double(config.output.height)
        let layout = config.layout
        guard let theme = config.themes[appearance] else {
            throw AppShotError.missingTheme(appearance)
        }

        let titleFont = try Text.font(
            stack: config.fontFamily, weight: layout.titleWeight, size: layout.titleFontSize)
        let subtitleFont = try Text.font(
            stack: config.fontFamily, weight: layout.subtitleWeight, size: layout.subtitleFontSize)
        guard
            let titleColor = Image.color(hex: theme.title),
            let subtitleColor = Image.color(hex: theme.subtitle)
        else { throw AppShotError.invalidConfig(out, "bad title/subtitle colour") }

        let maxTextWidth = W - layout.margin * 2
        let titleLines = Text.wrap(
            screen.title, font: titleFont, color: titleColor,
            kern: Config.Layout.titleLetterSpacing, maxWidth: maxTextWidth)
        let subtitleLines = screen.subtitle.map {
            Text.wrap(
                $0, font: subtitleFont, color: subtitleColor, kern: 0, maxWidth: maxTextWidth)
        } ?? []

        if titleLines.count > (layout.maxTitleLines ?? 2) {
            warnings(
                "\(screen.id): title wraps to \(titleLines.count) lines "
                    + "(max \(layout.maxTitleLines ?? 2)) — it will squeeze the screenshot. "
                    + "Shorten the copy or add an explicit \\n.")
        }

        // Layout arithmetic, carried over verbatim — including the asymmetry where
        // the title block spans (n-1) line-steps but the subtitle block spans n full
        // ones, so the subtitle carries a line of trailing slack. Changing it moves
        // the window.
        let titleStep = layout.titleFontSize * layout.titleLineHeight
        let subtitleStep = layout.subtitleFontSize * Config.Layout.subtitleLineHeight
        let titleBlockHeight = layout.titleFontSize + Double(titleLines.count - 1) * titleStep
        let subtitleBlockHeight = subtitleLines.isEmpty
            ? 0
            : layout.textGap + Double(subtitleLines.count) * subtitleStep
        let textBottom = layout.textTop + titleBlockHeight + subtitleBlockHeight

        let boxTop = textBottom + layout.screenshotGap
        let boxWidth = W - layout.margin * 2
        let boxHeight = H - boxTop - layout.margin
        guard boxHeight > 0 else {
            throw AppShotError.noRoomForScreenshot(
                screen: screen.id, textBottom: Int(textBottom.rounded()),
                canvasHeight: config.output.height)
        }

        let capture = try Image.load(source)
        let srcW = Double(capture.width)
        let srcH = Double(capture.height)
        // Fit inside the box, never upscale.
        let scale = min(boxWidth / srcW, boxHeight / srcH, 1)
        let winW = (srcW * scale).rounded()
        let winH = (srcH * scale).rounded()
        let winX = ((W - winW) / 2).rounded()
        let winY = (boxTop + (boxHeight - winH) / 2).rounded()

        guard let ctx = Image.context(width: config.output.width, height: config.output.height)
        else { throw AppShotError.imageEncodeFailed(out) }

        drawGradient(ctx, theme.background, width: W, height: H)

        // The window keeps its own transparent rounded corners, so the shadow shows
        // through them — which is why it is a blurred black shape underneath, not a
        // CG shadow attached to the image.
        let windowRect = CGRect(x: winX, y: winY, width: winW, height: winH)
        drawShadow(
            ctx, rect: windowRect, radius: layout.cornerRadius, shadow: layout.shadow,
            width: W, height: H)

        // No masking: the capture already has transparent rounded corners.
        ctx.interpolationQuality = .high
        ctx.draw(capture, in: flip(windowRect, in: H))

        drawText(
            ctx, titleLines: titleLines, subtitleLines: subtitleLines,
            layout: layout, titleStep: titleStep, subtitleStep: subtitleStep,
            width: W, height: H)

        guard let image = ctx.makeImage() else { throw AppShotError.imageEncodeFailed(out) }
        try Image.write(image, to: out)

        return Output(
            url: out,
            size: config.output,
            windowSize: Config.Size(width: Int(winW), height: Int(winH)))
    }

    // MARK: - Website

    /// The bare app captures for the marketing site: no frame, no caption. Only
    /// screens declaring a `website` basename, and only the one appearance the site
    /// actually renders.
    ///
    /// A missing capture is fatal here too. The site would otherwise keep the last
    /// image it had for that feature, which looks fine and is wrong.
    public static func website(
        config: Config,
        sourceDir: URL,
        outDir: URL,
        appearance: String,
        maxWidth: Int
    ) throws -> [Output] {
        let screens = config.screens.filter { $0.website != nil }
        let expected = screens.map { "\($0.id)~\(appearance).png" }
        let missing = expected.filter {
            !FileManager.default.fileExists(atPath: sourceDir.appending(path: $0).path)
        }
        guard missing.isEmpty else {
            throw AppShotError.missingCaptures(missing, dir: sourceDir)
        }

        try wipePNGs(in: outDir)

        var outputs: [Output] = []
        for (index, screen) in config.screens.enumerated() {
            guard let basename = screen.website else { continue }
            let source = sourceDir.appending(path: "\(screen.id)~\(appearance).png")
            let capture = try Image.load(source)

            // Downscale only; never upscale. Aspect preserved.
            let scale = min(Double(maxWidth) / Double(capture.width), 1)
            let w = Int((Double(capture.width) * scale).rounded())
            let h = Int((Double(capture.height) * scale).rounded())

            let out = outDir.appending(path: "\(basename).png")
            let image: CGImage
            if scale == 1 {
                image = capture
            } else {
                guard let ctx = Image.context(width: w, height: h) else {
                    throw AppShotError.imageEncodeFailed(out)
                }
                ctx.interpolationQuality = .high
                ctx.draw(capture, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let scaled = ctx.makeImage() else {
                    throw AppShotError.imageEncodeFailed(out)
                }
                image = scaled
            }
            try Image.write(image, to: out)
            outputs.append(Output(
                url: out,
                size: Config.Size(width: w, height: h),
                windowSize: Config.Size(width: w, height: h)))
            _ = index
        }
        return outputs
    }

    // MARK: - Drawing

    /// y-down rect → CoreGraphics' y-up.
    private static func flip(_ rect: CGRect, in height: Double) -> CGRect {
        CGRect(
            x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Linear gradient across the canvas at `angle` degrees, clockwise, y-down.
    ///
    /// The angle now means what it says. (The SVG original fed it through
    /// `gradientTransform` in objectBoundingBox units, which the renderer skewed by
    /// the canvas aspect ratio — `angle: 145` measured ~135deg on the real output.
    /// A config carried over verbatim will therefore render a slightly different,
    /// and finally predictable, gradient.)
    private static func drawGradient(
        _ ctx: CGContext,
        _ background: Config.Background,
        width W: Double,
        height H: Double
    ) {
        let colors = background.stops.compactMap { Image.color(hex: $0.color) }
        let locations = background.stops.map { CGFloat($0.offset) }
        guard colors.count == background.stops.count, !colors.isEmpty,
              let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors as CFArray,
                locations: locations)
        else { return }

        // Project the canvas corners onto the gradient axis so the ramp spans the
        // whole canvas regardless of angle.
        let radians = background.angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)  // y-down
        let center = CGPoint(x: W / 2, y: H / 2)
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0),
            CGPoint(x: 0, y: H), CGPoint(x: W, y: H),
        ]
        let projections = corners.map { ($0.x - center.x) * dx + ($0.y - center.y) * dy }
        let low = projections.min() ?? 0
        let high = projections.max() ?? 0

        let start = CGPoint(x: center.x + dx * low, y: center.y + dy * low)
        let end = CGPoint(x: center.x + dx * high, y: center.y + dy * high)

        ctx.saveGState()
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: start.x, y: H - start.y),
            end: CGPoint(x: end.x, y: H - end.y),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// A blurred black rounded rect under the window.
    ///
    /// `shadow.blur` is a Gaussian sigma (it was an SVG `stdDeviation`), which is
    /// what `CIGaussianBlur.inputRadius` takes — unlike `CGContext.setShadow(blur:)`,
    /// whose parameter is roughly 2x sigma and would render half as soft.
    private static func drawShadow(
        _ ctx: CGContext,
        rect: CGRect,
        radius: Double,
        shadow: Config.Shadow,
        width W: Double,
        height H: Double
    ) {
        let offset = rect.offsetBy(dx: 0, dy: shadow.dy)
        guard
            let scratch = Image.context(width: Int(W), height: Int(H)),
            let black = Image.color(hex: "#000000", alpha: shadow.opacity)
        else { return }

        scratch.addPath(
            CGPath(
                roundedRect: flip(offset, in: H),
                cornerWidth: radius, cornerHeight: radius, transform: nil))
        scratch.setFillColor(black)
        scratch.fillPath()

        guard let shape = scratch.makeImage() else { return }
        let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard
            let blur = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: CIImage(cgImage: shape),
                kCIInputRadiusKey: shadow.blur,
            ]),
            let blurred = blur.outputImage,
            // The blur grows the extent; crop back to the canvas.
            let result = ciContext.createCGImage(
                blurred, from: CGRect(x: 0, y: 0, width: W, height: H))
        else { return }

        ctx.draw(result, in: CGRect(x: 0, y: 0, width: W, height: H))
    }

    private static func drawText(
        _ ctx: CGContext,
        titleLines: [Text.Line],
        subtitleLines: [Text.Line],
        layout: Config.Layout,
        titleStep: Double,
        subtitleStep: Double,
        width W: Double,
        height H: Double
    ) {
        // Baseline of the first title line. This treats `textTop` as the top of the
        // text by assuming ascent == fontSize, which is not true of any real font —
        // but it is what the original did, and "fixing" it would shift every caption.
        var baseline = layout.textTop + layout.titleFontSize
        for (i, line) in titleLines.enumerated() {
            if i > 0 { baseline += titleStep }
            draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
        }

        guard !subtitleLines.isEmpty else { return }
        baseline = layout.textTop + layout.titleFontSize
            + Double(titleLines.count - 1) * titleStep
            + layout.textGap + layout.subtitleFontSize
        for (i, line) in subtitleLines.enumerated() {
            if i > 0 { baseline += subtitleStep }
            draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
        }
    }

    private static func draw(
        _ line: Text.Line,
        ctx: CGContext,
        baselineYDown: Double,
        width W: Double,
        height H: Double
    ) {
        ctx.textPosition = CGPoint(x: (W - line.width) / 2, y: H - baselineYDown)
        CTLineDraw(line.ctLine, ctx)
    }

    // MARK: - Files

    static func requireCaptures(config: Config, sourceDir: URL) throws {
        let expected = config.expectedCaptures()
        let missing = expected.filter {
            !FileManager.default.fileExists(atPath: sourceDir.appending(path: $0).path)
        }
        guard missing.isEmpty else {
            throw AppShotError.missingCaptures(missing, dir: sourceDir)
        }
        // "Exists" is not "is an image": a Git LFS pointer passes the check above and
        // fails, much less legibly, several steps later.
        try Image.rejectLFSPointers(expected.map { sourceDir.appending(path: $0) })
    }

    /// Reordering screens[] renames the outputs, and a stale leftover would sit
    /// beside its renamed twin and ship.
    static func wipePNGs(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in (try? Gate.pngs(in: dir)) ?? [] {
            try FileManager.default.removeItem(at: file)
        }
    }
}
