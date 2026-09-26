import CoreGraphics
import CoreImage
import Foundation

/// The `family.config.json` schema: one app shown on several platforms in one image.
///
/// It lives **above** the platform directories (`Screenshots/family.config.json`, beside
/// `macos/` and `ios/`), because it belongs to neither. It captures nothing: every input
/// is a capture the per-platform pipelines already took and gated, so a family composite
/// needs no goldens of its own. What it can get wrong is the pairing, and that is what the
/// checks here are about.
///
/// The drawing vocabulary is the per-platform config's, reused rather than restated —
/// `themes`, `layout` (fonts, margins, shadow) and `layout.bezel` mean exactly what they
/// mean there, so a family config reads like the two it sits beside.
public struct FamilyConfig: Codable, Sendable {
    /// How the devices are arranged. Named presets, never free coordinates: a config that
    /// places each device by hand is a Figma file in JSON, and it breaks the first time a
    /// capture changes aspect.
    public enum Arrangement: String, Codable, Sendable {
        /// The first device fills the frame; the second stands in front of its lower-right
        /// corner. Exactly two devices. The one arrangement where the first device is
        /// unambiguously the subject, which is why it is the only one `store` accepts.
        case continuity
        /// Side by side, vertical centres aligned. Two or three devices.
        case split
    }

    /// Which store listing a composite is meant to be uploaded to, when it is.
    public enum Store: String, Codable, Sendable {
        /// A slot in the Mac listing. App Review judges these on content: the Mac app must
        /// be the main subject and the other device must show real UI of the same product
        /// (Guideline 2.3.3). So: a Mac store size, `macos` first, and `continuity`.
        case mac
    }

    public struct Composite: Codable, Sendable {
        /// Output basename: `<id>~<appearance>.png`. A path component.
        public var id: String
        public var arrangement: Arrangement
        /// The screen id shown on every device. One id for all of them on purpose: the
        /// claim a family image makes is "the same thing, everywhere", and a per-device
        /// screen is how it ends up showing two unrelated screens.
        public var screen: String
        /// `<platform>[/<device>]` under `--root`: `macos`, `ios/iphone`, `ios/ipad`. The
        /// canonical `Screenshots/<platform>/source/[<device>/]` layout, spelled as the
        /// directories it names. First is the subject: back in `continuity`, left in `split`.
        public var devices: [String]
        public var output: Config.Size
        /// Caption. Absent ⇒ no caption, and the devices get the whole canvas.
        public var title: String?
        public var subtitle: String?
        /// Height of every device after the first, relative to the first. Visual balance,
        /// not physical scale: a true-to-life iPhone next to a Mac window is a thumbnail.
        /// Absent ⇒ 0.86 for `continuity`, 1.0 for `split`.
        public var ratio: Double?
        /// Full override of the shared `layout`, all-or-nothing like `devices[].layout`.
        /// What an OG card needs: 1200x630 cannot carry store-sized type.
        public var layout: Config.Layout?
        public var store: Store?

        public var resolvedRatio: Double {
            ratio ?? (arrangement == .continuity ? 0.86 : 1.0)
        }
    }

    public var appearances: [String]
    public var fontFamily: String
    public var layout: Config.Layout
    public var themes: [String: Config.Theme]
    public var composites: [Composite]

    public static func load(_ url: URL) throws -> FamilyConfig {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(FamilyConfig.self, from: data)
        } catch let error as DecodingError {
            throw AppShotError.invalidConfig(url, Config.describe(error))
        }
    }

    public func validate() throws {
        guard !composites.isEmpty else {
            throw AppShotError.invalidFamily(composite: "-", reason: "`composites` is empty")
        }
        guard !appearances.isEmpty else { throw AppShotError.noAppearancesRequested }
        for appearance in appearances where themes[appearance] == nil {
            throw AppShotError.missingTheme(appearance)
        }

        var seen = Set<String>()
        for composite in composites {
            func fail(_ reason: String) -> AppShotError {
                .invalidFamily(composite: composite.id, reason: reason)
            }
            guard !composite.id.isEmpty, !composite.id.contains("/"), !composite.id.contains("~")
            else { throw fail("id must be a file name with no `/` or `~`") }
            guard seen.insert(composite.id).inserted else { throw fail("duplicate id") }
            guard composite.output.width > 0, composite.output.height > 0 else {
                throw fail("output must be positive, got \(composite.output.description)")
            }
            guard composite.resolvedRatio > 0 else { throw fail("ratio must be positive") }

            let count = composite.devices.count
            switch composite.arrangement {
            case .continuity where count != 2:
                throw fail("`continuity` takes exactly 2 devices, got \(count)")
            case .split where !(2...3).contains(count):
                throw fail("`split` takes 2 or 3 devices, got \(count)")
            default: break
            }
            for device in composite.devices {
                _ = try FamilyDevice(device, composite: composite.id)
            }
            guard Set(composite.devices).count == count else {
                throw fail("a device is listed twice — one capture shown twice is not a family")
            }

            if composite.store == .mac {
                guard Config.macStoreSizes.contains(composite.output) else {
                    throw fail(
                        "`store: mac` needs a Mac store size ("
                            + Config.macStoreSizes.map(\.description).joined(separator: ", ")
                            + "), got \(composite.output.description)")
                }
                guard composite.arrangement == .continuity,
                    composite.devices.first.map({ FamilyDevice.isMac($0) }) == true
                else {
                    throw fail(
                        "`store: mac` needs `continuity` with `macos` first: App Review "
                            + "wants the Mac app to be the main subject of a Mac listing image")
                }
            }
        }
    }
}

/// One `devices[]` entry, resolved to the paths it names.
struct FamilyDevice: Equatable {
    /// `macos`, `ios`. The directory holding `source/` and its `run.json`.
    let platform: String
    /// `iphone`, `ipad`, or nil for a platform with no device axis.
    let device: String?

    init(_ spec: String, composite: String) throws {
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AppShotError.invalidFamily(
                composite: composite,
                reason: "device \"\(spec)\" is not `<platform>` or `<platform>/<device>`")
        }
        platform = parts[0]
        device = parts.count == 2 ? parts[1] : nil
    }

    static func isMac(_ spec: String) -> Bool {
        spec.split(separator: "/").first == "macos"
    }

    var isMac: Bool { platform == "macos" }

    /// `<root>/<platform>/source` — where `appshot capture` leaves its `run.json`.
    func sourceRoot(under root: URL) -> URL {
        root.appending(path: platform).appending(path: "source")
    }

    func capture(under root: URL, screen: String, appearance: String) -> URL {
        let dir = sourceRoot(under: root)
        return (device.map { dir.appending(path: $0) } ?? dir)
            .appending(path: "\(screen)~\(appearance).png")
    }
}

extension Compose {
    // MARK: - Family

    /// One `<id>~<appearance>.png` per composite x appearance, written flattened (no alpha
    /// channel), since the Mac listing refuses one.
    ///
    /// Every capture is checked before the output directory is touched, for the same
    /// reason `appStore` does: a half-written set is how a gap ships.
    public static func family(
        config: FamilyConfig,
        root: URL,
        outDir: URL,
        warnings: (String) -> Void = { _ in }
    ) throws -> [Output] {
        try config.validate()

        var expected: [URL] = []
        for composite in config.composites {
            for spec in composite.devices {
                let device = try FamilyDevice(spec, composite: composite.id)
                for appearance in config.appearances {
                    expected.append(
                        device.capture(
                            under: root, screen: composite.screen, appearance: appearance))
                }
            }
        }
        let missing = expected.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            // Paths relative to the root, since the devices differ and a bare file name
            // would not say which platform is missing it.
            throw AppShotError.missingCaptures(
                missing.map { String($0.path.dropFirst(root.path.count + 1)) }, dir: root)
        }
        try Image.rejectLFSPointers(expected)

        for composite in config.composites {
            let layout = composite.layout ?? config.layout
            _ = try Text.font(
                stack: config.fontFamily, weight: layout.titleWeight, size: layout.titleFontSize)
        }

        try wipePNGs(in: outDir)

        var outputs: [Output] = []
        for composite in config.composites {
            for appearance in config.appearances {
                let out = outDir.appending(path: "\(composite.id)~\(appearance).png")
                outputs.append(
                    try familyOne(
                        config: config, composite: composite, appearance: appearance,
                        root: root, out: out, warnings: warnings))
            }
        }
        return outputs
    }

    private static func familyOne(
        config: FamilyConfig,
        composite: FamilyConfig.Composite,
        appearance: String,
        root: URL,
        out: URL,
        warnings: (String) -> Void
    ) throws -> Output {
        let W = Double(composite.output.width)
        let H = Double(composite.output.height)
        let layout = composite.layout ?? config.layout
        guard let theme = config.themes[appearance] else {
            throw AppShotError.missingTheme(appearance)
        }

        // Caption, laid out exactly as `appStore` lays out its own.
        let maxTextWidth = W - layout.margin * 2
        var titleLines: [Text.Line] = []
        var subtitleLines: [Text.Line] = []
        if let title = composite.title {
            let titleFont = try Text.font(
                stack: config.fontFamily, weight: layout.titleWeight, size: layout.titleFontSize)
            let subtitleFont = try Text.font(
                stack: config.fontFamily, weight: layout.subtitleWeight,
                size: layout.subtitleFontSize)
            guard
                let titleColor = Image.color(hex: theme.title),
                let subtitleColor = Image.color(hex: theme.subtitle)
            else { throw AppShotError.invalidConfig(out, "bad title/subtitle colour") }
            titleLines = Text.wrap(
                title, font: titleFont, color: titleColor,
                kern: Config.Layout.titleLetterSpacing, maxWidth: maxTextWidth)
            subtitleLines =
                composite.subtitle.map {
                    Text.wrap(
                        $0, font: subtitleFont, color: subtitleColor, kern: 0,
                        maxWidth: maxTextWidth)
                } ?? []
            if titleLines.count > (layout.maxTitleLines ?? 2) {
                warnings(
                    "\(composite.id): title wraps to \(titleLines.count) lines "
                        + "(max \(layout.maxTitleLines ?? 2)). Shorten the copy.")
            }
        }
        let titleStep = layout.titleFontSize * layout.titleLineHeight
        let subtitleStep = layout.subtitleFontSize * Config.Layout.subtitleLineHeight
        let boxTop: Double
        if titleLines.isEmpty {
            boxTop = layout.margin
        } else {
            let titleBlock = layout.titleFontSize + Double(titleLines.count - 1) * titleStep
            let subtitleBlock =
                subtitleLines.isEmpty
                ? 0 : layout.textGap + Double(subtitleLines.count) * subtitleStep
            boxTop = layout.textTop + titleBlock + subtitleBlock + layout.screenshotGap
        }
        let box = CGRect(
            x: layout.margin, y: boxTop, width: W - layout.margin * 2,
            height: H - boxTop - layout.margin)
        guard box.height > 0, box.width > 0 else {
            throw AppShotError.noRoomForScreenshot(
                screen: composite.id, textBottom: Int(boxTop.rounded()),
                canvasHeight: composite.output.height)
        }

        let devices = try composite.devices.map { try FamilyDevice($0, composite: composite.id) }
        let captures = try devices.map {
            try Image.load(
                $0.capture(under: root, screen: composite.screen, appearance: appearance))
        }
        // The bezel is a phone's and a tablet's edge. A Mac window already has one.
        let bezels = devices.map { $0.isMac ? nil : layout.bezel }
        let rects = arrange(
            composite.arrangement,
            sizes: captures.map { CGSize(width: $0.width, height: $0.height) },
            bezels: bezels.map { $0?.width ?? 0 },
            ratio: composite.resolvedRatio,
            in: box)

        guard let ctx = Image.context(width: composite.output.width, height: composite.output.height)
        else { throw AppShotError.imageEncodeFailed(out) }
        drawGradient(ctx, theme.background, width: W, height: H)
        ctx.interpolationQuality = .high

        // Back to front, each device with its own shadow — so the front device's shadow
        // falls on the one behind it, which is most of what makes the overlap read as depth.
        for (index, capture) in captures.enumerated() {
            let rect = rects[index]
            let grow = bezels[index]?.width ?? 0
            drawSilhouetteShadow(
                ctx, capture: capture, rect: rect, grow: grow,
                fallbackRadius: layout.cornerRadius, shadow: layout.shadow, height: H)
            if let bezel = bezels[index] {
                drawBezel(
                    ctx, capture: capture, rect: rect, bezel: bezel,
                    fallbackRadius: layout.cornerRadius, height: H)
            }
            if Image.isOpaque(capture) && !devices[index].isMac {
                // Same clip `appStore` gives an opaque iOS capture.
                ctx.saveGState()
                ctx.addPath(
                    CGPath(
                        roundedRect: flip(rect, in: H), cornerWidth: layout.cornerRadius,
                        cornerHeight: layout.cornerRadius, transform: nil))
                ctx.clip()
                ctx.draw(capture, in: flip(rect, in: H))
                ctx.restoreGState()
            } else {
                ctx.draw(capture, in: flip(rect, in: H))
            }
        }

        if !titleLines.isEmpty {
            drawText(
                ctx, titleLines: titleLines, subtitleLines: subtitleLines, layout: layout,
                titleStep: titleStep, subtitleStep: subtitleStep, width: W, height: H)
        }

        guard let image = ctx.makeImage(), let flat = Image.flattened(image) else {
            throw AppShotError.imageEncodeFailed(out)
        }
        try Image.write(flat, to: out)
        return Output(url: out, size: composite.output, windowSize: composite.output)
    }

    // MARK: - Arrangement

    /// Where each capture lands, in canvas pixels, y-down, **excluding** its bezel.
    ///
    /// Pure geometry so it can be pinned by tests without drawing anything. Everything is
    /// worked out with the first device at height 1, then scaled once to fit `box` with
    /// every bezel still inside it — and never above a capture's own pixel size, since an
    /// upscaled capture is soft text on a marketing image.
    static func arrange(
        _ arrangement: FamilyConfig.Arrangement,
        sizes: [CGSize],
        bezels: [Double],
        ratio: Double,
        in box: CGRect
    ) -> [CGRect] {
        guard let first = sizes.first, first.height > 0 else { return [] }
        // Unit sizes: first device height 1, the rest `ratio`.
        let units = sizes.enumerated().map { index, size in
            let h = index == 0 ? 1.0 : ratio
            return CGSize(width: h * size.width / size.height, height: h)
        }
        let maxBezel = bezels.max() ?? 0

        var placed: [CGRect]  // unit space
        switch arrangement {
        case .continuity:
            // Front device overhangs the back one's right edge by 45% of its own width
            // and stands 7% of the back's height below it: enough to read as in front,
            // not so much that it covers what the back device is showing.
            let back = CGRect(origin: .zero, size: units[0])
            let front = units[1]
            placed = [
                back,
                CGRect(
                    x: back.maxX - front.width * 0.55, y: back.maxY + 0.07 - front.height,
                    width: front.width, height: front.height),
            ]
        case .split:
            let gap = 0.08
            var x = 0.0
            placed = units.map { unit in
                defer { x += unit.width + gap }
                return CGRect(x: x, y: -unit.height / 2, width: unit.width, height: unit.height)
            }
        }

        let union = placed.dropFirst().reduce(placed[0]) { $0.union($1) }
        // Split puts a bezel on each side of every device along the row; continuity's
        // devices overlap, so the outermost bezel is all that reaches the edge.
        let horizontalBezels =
            arrangement == .split ? bezels.reduce(0) { $0 + $1 * 2 } : maxBezel * 2
        var scale = min(
            (box.width - horizontalBezels) / union.width,
            (box.height - maxBezel * 2) / union.height)
        for (unit, size) in zip(units, sizes) where unit.height > 0 {
            scale = min(scale, size.height / unit.height)
        }
        scale = max(scale, 0)

        // Split also spends pixels on bezels between devices, which the unit layout did
        // not know about; walk the row again in pixels so neighbours never touch.
        let rects: [CGRect]
        switch arrangement {
        case .continuity:
            rects = placed.map {
                CGRect(
                    x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale,
                    height: $0.height * scale)
            }
        case .split:
            var x = 0.0
            rects = placed.enumerated().map { index, unit in
                x += bezels[index]
                defer { x += unit.width * scale + bezels[index] + 0.08 * scale }
                return CGRect(
                    x: x, y: unit.minY * scale, width: unit.width * scale,
                    height: unit.height * scale)
            }
        }

        // Centre the group (bezels included) in the box, and snap to whole pixels.
        let bounds = zip(rects, bezels).map { $0.insetBy(dx: -$1, dy: -$1) }
        let group = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
        let dx = box.midX - group.midX
        let dy = box.midY - group.midY
        return rects.map {
            CGRect(
                x: ($0.minX + dx).rounded(), y: ($0.minY + dy).rounded(),
                width: $0.width.rounded(), height: $0.height.rounded())
        }
    }

    // MARK: - Drawing

    /// A shadow in the capture's own shape, grown by `grow` (the bezel) first.
    ///
    /// `drawShadow` casts a rounded rect, which is right for a Mac window and wrong for a
    /// phone: the screen's corners are much rounder than any single `cornerRadius`, and in
    /// a family image the front device's shadow falls *on* the back one, where a square
    /// corner is plainly visible.
    static func drawSilhouetteShadow(
        _ ctx: CGContext,
        capture: CGImage,
        rect: CGRect,
        grow: Double,
        fallbackRadius: Double,
        shadow: Config.Shadow,
        height H: Double
    ) {
        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        guard w > 0, h > 0, let shapeCtx = Image.context(width: w, height: h) else { return }
        let bounds = CGRect(x: 0, y: 0, width: Double(w), height: Double(h))
        if Image.isOpaque(capture) {
            shapeCtx.addPath(
                CGPath(
                    roundedRect: bounds, cornerWidth: fallbackRadius,
                    cornerHeight: fallbackRadius, transform: nil))
            shapeCtx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            shapeCtx.fillPath()
        } else {
            shapeCtx.interpolationQuality = .high
            shapeCtx.draw(capture, in: bounds)
        }
        guard let shape = shapeCtx.makeImage() else { return }

        // Black at `opacity`, through the alpha column for the reason `drawBezel` gives.
        var image = CIImage(cgImage: shape).applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadow.opacity),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        if grow > 0 {
            image = image.applyingFilter(
                "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow])
        }
        image = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shadow.blur])

        let pad = grow + shadow.blur * 3
        let target = CGRect(
            x: -pad, y: -pad, width: Double(w) + pad * 2, height: Double(h) + pad * 2)
        let ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
        guard let result = ciContext.createCGImage(image, from: target) else { return }
        let drawn = rect.insetBy(dx: -pad, dy: -pad).offsetBy(dx: 0, dy: shadow.dy)
        ctx.draw(result, in: flip(drawn, in: H))
    }
}

extension Image {
    /// The same pixels with no alpha channel at all.
    ///
    /// Opaque is not the same as alpha-free: a PNG written from an RGBA context keeps its
    /// alpha channel even when every value in it is 255, and the Mac listing's upload
    /// rules say no alpha.
    static func flattened(_ image: CGImage) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
