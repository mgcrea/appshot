import AppKit
import CoreGraphics
import Foundation

/// Build a macOS `.appiconset` from one vector mark, and audit an existing one.
///
/// This is the mechanical half of an app icon, deliberately not the design half.
/// It takes artwork you already have and does the part that silently fails: the
/// icon grid, all ten slots at exact pixel sizes, and `Contents.json`.
///
/// The audit exists because of a specific, expensive failure. An `.appiconset`
/// whose `Contents.json` declares every slot but contains no images builds fine,
/// runs fine, shows a blank icon nobody looks at, and is rejected by App Store
/// Connect only at upload with:
///
///     Missing required icon. The application bundle does not have an icon in
///     ICNS format containing a 512pt x 512pt @2x image. (90236)
///
/// That is one archive, one export and one upload round trip to learn something
/// `appshot doctor` can say in milliseconds — the same genre as the font check.
public enum Icon {
    // MARK: - Slots

    /// One entry in a macOS `.appiconset`.
    public struct Slot: Sendable, Equatable, Hashable {
        public let points: Int
        public let scale: Int

        public init(points: Int, scale: Int) {
            self.points = points
            self.scale = scale
        }

        public var pixels: Int { points * scale }

        /// Xcode's own naming. Kept literal because `Contents.json` references it and
        /// a renamed file is a slot Xcode quietly drops.
        public var filename: String {
            "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        }
    }

    /// Every slot a macOS app icon needs, in Xcode's order.
    ///
    /// All ten are required: Apple rejects a set missing any of them, and the
    /// 512@2x is the one whose absence produces error 90236.
    public static let macSlots: [Slot] = [16, 32, 128, 256, 512].flatMap {
        [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)]
    }

    // MARK: - Geometry

    /// Apple's macOS icon grid: an 824pt rounded square centred on a 1024pt canvas,
    /// corner radius 185.
    ///
    /// The margin is part of the artwork on macOS, unlike iOS where the system masks
    /// a full-bleed square. Drawing edge to edge here yields an icon visibly larger
    /// than every other one in the Dock.
    public static let canvas = 1024.0
    public static let plateSide = 824.0
    public static let plateRadius = 185.0

    /// How much of the canvas the mark spans, before aspect-fitting.
    public static let defaultMarkFraction = 480.0 / canvas

    /// What fraction of the *composed* plate a canvas fraction lands at.
    ///
    /// The plate is 824 of the 1024 canvas, so a mark measured against the canvas is
    /// always the smaller number — 0.57 of the canvas is 0.71 of the plate. Both are
    /// honest and they differ by a quarter, which is enough to move an icon out of the
    /// 70–80% band that peers sit in without anything looking wrong in the flag.
    ///
    /// `IconComposer` answers the same question for a `.icon`, where the layer *is* the
    /// plate and the two numbers coincide. Comparing formats means comparing these, not
    /// the raw fractions.
    public static func composedPlateFraction(_ markFraction: Double) -> Double {
        markFraction * canvas / plateSide
    }

    // MARK: - Plate

    public enum Plate: Sendable {
        case solid(String)
        /// Reuses the compositor's gradient model, so an icon and its store visuals
        /// can be given the same ramp without two ways to spell one.
        case gradient(Config.Background)
        /// Artwork that already carries its own background.
        case none

        /// Whether this plate puts anything on the canvas.
        ///
        /// The question a layered `.icon` and an SVG composition both have to ask: with
        /// no plate to draw there is no second layer to split off and no rectangle to
        /// emit, because the artwork arrived carrying its own background.
        public var isDrawn: Bool {
            if case .none = self { return false }
            return true
        }
    }

    /// A gradient plate from evenly spaced hex stops.
    ///
    /// Evenly spaced because a two-stop ramp is the overwhelmingly common case, and
    /// anything needing custom offsets has outgrown what a CLI flag should express —
    /// that belongs in a config, where `Compose` already reads full `Stop` offsets.
    ///
    /// Lives here rather than in the CLI so the stop maths is testable, and because
    /// `Config.Background`'s memberwise init is internal to this module.
    public static func gradientPlate(hexes: [String], angle: Double) throws -> Plate {
        guard hexes.count >= 2 else {
            throw AppShotError.invalidPlate(
                "a gradient needs at least two colours, got \(hexes.count)")
        }
        for hex in hexes where Image.color(hex: hex) == nil {
            throw AppShotError.invalidPlate(hex)
        }
        let stops = hexes.enumerated().map { index, hex in
            Config.Stop(offset: Double(index) / Double(hexes.count - 1), color: hex)
        }
        return .gradient(Config.Background(angle: angle, stops: stops))
    }

    public struct Options: Sendable {
        public var plate: Plate
        /// Fill the mark's alpha with this instead of its own colours. For a mark
        /// authored with `currentColor`, which renders black on its own.
        public var tint: String?
        public var markFraction: Double
        /// Drop and inner shadows applied to the mark, in the order given.
        ///
        /// Parameters rather than something authored in the mark, because a `<filter>`
        /// in an SVG mark is silently discarded when it is rasterised — see `IconEffect`.
        public var effects: [IconEffect]

        public init(
            plate: Plate = .none,
            tint: String? = nil,
            markFraction: Double = Icon.defaultMarkFraction,
            effects: [IconEffect] = []
        ) {
            self.plate = plate
            self.tint = tint
            self.markFraction = markFraction
            self.effects = effects
        }
    }

    // MARK: - Rasterising the mark

    /// Rasterise SVG, PDF or a bitmap to `pixels` square, aspect-fitted and centred.
    ///
    /// `NSImage` reads all three, so one path covers vector and raster sources. It is
    /// used rather than `CGImageSource` because the latter has no SVG support at all —
    /// `CGImageSourceGetType` returns nothing for an `.svg`.
    ///
    /// Rendered at the final size rather than once and downsampled, so a vector mark
    /// stays sharp at 16pt where a resampled 1024 would smear.
    static func rasterize(_ url: URL, into box: CGRect, ctx: CGContext) throws {
        guard let image = NSImage(contentsOf: url) else {
            throw AppShotError.imageDecodeFailed(url)
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            throw AppShotError.imageDecodeFailed(url)
        }
        // Aspect-fit: the mark's own proportions win, the box only bounds it.
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        let rect = CGRect(
            x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current = previous
    }

    /// The mark alone on a transparent layer: rasterised into `box`, tinted, effects applied.
    ///
    /// Every format goes through here rather than drawing the mark straight onto the plate,
    /// and the reason is the effects. A drop shadow has to be composited *behind* the mark
    /// and an inner shadow is defined by the mark's own alpha — neither survives the mark
    /// having already been painted onto a background. Doing it in one place also means the
    /// `.appiconset` slot, the `.icon` layer and the tinted variants cannot drift apart in
    /// how they place or shade the same artwork.
    static func markLayer(mark: URL, pixels: Int, box: CGRect, options: Options) throws -> CGImage {
        guard let layerCtx = Image.context(width: pixels, height: pixels) else {
            throw AppShotError.imageEncodeFailed(mark)
        }
        let full = CGRect(x: 0, y: 0, width: Double(pixels), height: Double(pixels))

        if let tint = options.tint {
            guard let color = Image.color(hex: tint) else {
                throw AppShotError.invalidPlate(tint)
            }
            // Draw the mark into its own layer, then use it as an alpha mask. A mark
            // written with `currentColor` has no colour of its own — NSImage renders it
            // black — so recolouring has to go through the shape, not the pixels.
            guard let maskCtx = Image.context(width: pixels, height: pixels) else {
                throw AppShotError.imageEncodeFailed(mark)
            }
            try rasterize(mark, into: box, ctx: maskCtx)
            guard let drawn = maskCtx.makeImage() else {
                throw AppShotError.imageEncodeFailed(mark)
            }
            layerCtx.saveGState()
            layerCtx.clip(to: full, mask: drawn)
            layerCtx.setFillColor(color)
            layerCtx.fill(full)
            layerCtx.restoreGState()
        } else {
            try rasterize(mark, into: box, ctx: layerCtx)
        }

        guard let drawn = layerCtx.makeImage() else {
            throw AppShotError.imageEncodeFailed(mark)
        }
        return try IconEffect.apply(options.effects, to: drawn, canvas: canvas)
    }

    /// Does this mark carry an SVG filter that will be silently dropped?
    ///
    /// `NSImage` rasterises SVG without any filter support, so a mark relying on one
    /// renders correctly in a browser and flat in the icon, with nothing to say why. That
    /// is worth a word from the build rather than a puzzled afternoon — and the fix is
    /// `--mark-shadow` / `--mark-inner-shadow`, which appshot applies to every rendering.
    public static func filterWarning(for mark: URL) -> String? {
        guard mark.pathExtension.lowercased() == "svg",
            let source = try? String(contentsOf: mark, encoding: .utf8),
            source.contains("<filter")
        else { return nil }
        return """
            \(mark.lastPathComponent) contains an SVG <filter>, which is dropped when the \
            mark is rasterised — the icon will be flat where the browser shows the effect. \
            Express it with --mark-shadow / --mark-inner-shadow instead, which appshot \
            applies to the raster formats and re-emits into the SVG.
            """
    }

    // MARK: - Rendering

    /// One icon at one pixel size.
    public static func render(mark: URL, pixels: Int, options: Options) throws -> CGImage {
        guard let ctx = Image.context(width: pixels, height: pixels) else {
            throw AppShotError.imageEncodeFailed(mark)
        }
        let k = Double(pixels) / canvas
        let inset = (Double(pixels) - plateSide * k) / 2
        let plateRect = CGRect(
            x: inset, y: inset, width: plateSide * k, height: plateSide * k)

        switch options.plate {
        case .solid(let hex):
            guard let color = Image.color(hex: hex) else {
                throw AppShotError.invalidPlate(hex)
            }
            ctx.addPath(
                CGPath(
                    roundedRect: plateRect, cornerWidth: plateRadius * k,
                    cornerHeight: plateRadius * k, transform: nil))
            ctx.setFillColor(color)
            ctx.fillPath()
        case .gradient(let background):
            ctx.saveGState()
            ctx.addPath(
                CGPath(
                    roundedRect: plateRect, cornerWidth: plateRadius * k,
                    cornerHeight: plateRadius * k, transform: nil))
            ctx.clip()
            Compose.drawGradient(
                ctx, background, width: Double(pixels), height: Double(pixels))
            ctx.restoreGState()
        case .none:
            break
        }

        let side = Double(pixels) * options.markFraction
        let box = CGRect(
            x: (Double(pixels) - side) / 2, y: (Double(pixels) - side) / 2,
            width: side, height: side)

        let layer = try markLayer(mark: mark, pixels: pixels, box: box, options: options)
        ctx.draw(layer, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

        guard let out = ctx.makeImage() else {
            throw AppShotError.imageEncodeFailed(mark)
        }
        return out
    }

    public struct Generated: Sendable {
        public let slot: Slot
        public let url: URL
    }

    /// Write every slot plus `Contents.json` into an `.appiconset`.
    public static func generate(
        mark: URL,
        into appiconset: URL,
        options: Options = Options(),
        slots: [Slot] = macSlots
    ) throws -> [Generated] {
        try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)

        var written: [Generated] = []
        for slot in slots {
            let image = try render(mark: mark, pixels: slot.pixels, options: options)
            let url = appiconset.appending(path: slot.filename)
            try Image.write(image, to: url)
            written.append(Generated(slot: slot, url: url))
        }
        try contentsJSON(for: slots)
            .write(to: appiconset.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
        return written
    }

    static func contentsJSON(for slots: [Slot]) -> String {
        let images = slots.map { slot in
            """
                {
                  "filename" : "\(slot.filename)",
                  "idiom" : "mac",
                  "scale" : "\(slot.scale)x",
                  "size" : "\(slot.points)x\(slot.points)"
                }
            """
        }
        return """
            {
              "images" : [
            \(images.joined(separator: ",\n"))
              ],
              "info" : {
                "author" : "appshot",
                "version" : 1
              }
            }

            """
    }

    // MARK: - Audit

    public struct Finding: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Declared with a filename, but that file is not there.
            case missingFile(String)
            /// Declared, but the entry carries no filename — Xcode's spelling of an
            /// empty slot. This is the shape a hollow `.appiconset` actually has.
            case emptySlot(String)
            case wrongSize(String, got: String, want: String)
            /// No entry for this size/scale at all.
            case notDeclared(String)
            /// A Git LFS pointer sitting where a PNG should be.
            case gitLFSPointer(String)
            /// Present, not a pointer, and still not decodable as an image.
            case unreadable(String)
        }
        public let kind: Kind

        public var message: String {
            switch kind {
            case .missingFile(let name):
                "\(name) is declared in Contents.json but the file is missing"
            case .emptySlot(let slot):
                "the \(slot) slot is declared but carries no image"
            case .wrongSize(let name, let got, let want):
                "\(name) is \(got), should be \(want)"
            case .notDeclared(let slot):
                "the \(slot) slot is required but Contents.json does not declare it"
            case .gitLFSPointer(let name):
                "\(name) is a Git LFS pointer, not an image — run `git lfs pull`"
            case .unreadable(let name):
                "\(name) cannot be decoded as an image"
            }
        }
    }

    /// Check an `.appiconset` the way App Store Connect will, before you upload.
    ///
    /// Returns findings rather than throwing: an icon set can be wrong in several
    /// ways at once and reporting the first is how you fix them one upload apiece.
    public static func audit(_ appiconset: URL, slots: [Slot] = macSlots) throws -> [Finding] {
        // Keyed by size and scale, not by filename. Xcode identifies a slot by those
        // two, and `filename` is optional — an entry without one is precisely how a
        // hollow icon set is spelled. Matching on filename instead would report every
        // slot twice (missing *and* undeclared) and would also fail any project that
        // names its images something other than Xcode's default.
        var declared: [Slot: String?] = [:]
        if let data = try? Data(contentsOf: appiconset.appending(path: "Contents.json")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        {
            for entry in images {
                guard let size = entry["size"] as? String,
                    let scale = entry["scale"] as? String,
                    let points = Int(size.split(separator: "x").first ?? ""),
                    let factor = Int(scale.dropLast())
                else { continue }
                declared[Slot(points: points, scale: factor)] = entry["filename"] as? String
            }
        }

        var findings: [Finding] = []
        for slot in slots {
            let label = "\(slot.points)x\(slot.points)@\(slot.scale)x"

            guard let filename = declared[slot] else {
                findings.append(Finding(kind: .notDeclared(label)))
                continue
            }
            guard let filename, !filename.isEmpty else {
                findings.append(Finding(kind: .emptySlot(label)))
                continue
            }

            let url = appiconset.appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                findings.append(Finding(kind: .missingFile(filename)))
                continue
            }
            // Checked before the size, and reported rather than skipped. A repo that
            // LFS-tracks its icons (`Assets.xcassets/**/*.png` is a common rule) has a
            // 130-byte text file here on any clone that has not run `git lfs pull` —
            // named .png, the right filename, declared in Contents.json. `Image.size`
            // returns nil for it, so an `if let` would pass the slot in silence and the
            // audit would bless an icon set that builds to a blank icon.
            guard !Image.isGitLFSPointer(url) else {
                findings.append(Finding(kind: .gitLFSPointer(filename)))
                continue
            }
            guard let size = Image.size(url) else {
                findings.append(Finding(kind: .unreadable(filename)))
                continue
            }
            if size.width != slot.pixels || size.height != slot.pixels {
                findings.append(
                    Finding(
                        kind: .wrongSize(
                            filename,
                            got: "\(size.width)x\(size.height)",
                            want: "\(slot.pixels)x\(slot.pixels)")))
            }
        }
        return findings
    }
}
