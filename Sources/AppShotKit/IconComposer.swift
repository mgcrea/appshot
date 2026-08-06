import CoreGraphics
import Foundation

/// Build an Icon Composer `.icon` bundle from one vector mark, and audit an existing one.
///
/// The macOS 26 / iOS 26 counterpart to `Icon`, which builds the `.appiconset` that
/// preceded it. Both take the same mark and the same plate; what differs is the grid,
/// and the difference is not a detail:
///
/// * An `.appiconset` slot is an 824pt **rounded** plate centred on a 1024pt canvas.
///   Nothing masks it on the systems that format exists to support, so the artwork
///   carries its own corner radius and its own margin.
/// * A `.icon` layer is 1024pt **square and fully opaque, corners included**. The
///   system applies the squircle, the shadow and the material. Any radius baked in
///   here is masked a second time, which at best does nothing and at worst leaves a
///   sliver at each corner where the two curves disagree.
///
/// So the two formats want the *same* mark and *opposite* plates, and the word
/// "full-bleed" means something different in each. Do not copy a radius across.
///
/// ## The mark fraction means two different things
///
/// `Options.markFraction` is a fraction of the canvas in both formats, but the canvas
/// is not the plate in both formats, so the same number produces two different-looking
/// icons:
///
/// * `.appiconset` — the plate is 824 of the 1024 canvas, and macOS 26 renders that
///   artwork at 1:1. A mark at fraction *f* lands at *f* × 1024 ÷ 824 of the plate.
/// * `.icon` — the layer *is* the plate, and the system scales it to the same 824.
///   A mark at fraction *f* lands at *f* of the plate.
///
/// Migrating an icon between the formats at the same apparent size therefore means
/// multiplying the fraction by 1024/824 ≈ 1.243. Getting this wrong is silent: the
/// icon simply reads small, which is indistinguishable by eye from a timid mark and
/// trivial to tell apart by measuring. `composedPlateFraction(_:)` is that number, and
/// both build commands print it.
public enum IconComposer {
    /// The one size a `.icon` layer is authored at. Unlike an `.appiconset` there are
    /// no slots — the system derives every rendering from this single image.
    public static let layerPixels = 1024

    /// The default layer filename, which is also its `name` in `icon.json`.
    public static let layerImageName = "1024.png"

    /// What fraction of the *composed* plate a canvas fraction lands at.
    ///
    /// The identity, for the reason in the type's own documentation: a `.icon` layer is
    /// the plate. Present anyway so callers can ask both formats the same question and
    /// get comparable answers, instead of open-coding the denominator per format —
    /// which is exactly how the two drift.
    public static func composedPlateFraction(_ markFraction: Double) -> Double {
        markFraction
    }

    // MARK: - Rendering

    /// The single full-bleed layer: plate to all four edges, mark centred on it.
    ///
    /// Deliberately shares `Icon.Options` rather than defining its own. The plate and
    /// the mark are the design, and the design does not change between the two formats
    /// — only the grid does, and the grid is this function.
    public static func renderLayer(
        mark: URL,
        pixels: Int = layerPixels,
        options: Icon.Options = Icon.Options()
    ) throws -> CGImage {
        guard let ctx = Image.context(width: pixels, height: pixels) else {
            throw AppShotError.imageEncodeFailed(mark)
        }
        let full = CGRect(x: 0, y: 0, width: Double(pixels), height: Double(pixels))

        // No rounded path and no clip, which is the whole difference from `Icon.render`.
        switch options.plate {
        case .solid(let hex):
            guard let color = Image.color(hex: hex) else {
                throw AppShotError.invalidPlate(hex)
            }
            ctx.setFillColor(color)
            ctx.fill(full)
        case .gradient(let background):
            Compose.drawGradient(
                ctx, background, width: Double(pixels), height: Double(pixels))
        case .none:
            break
        }

        let side = Double(pixels) * options.markFraction
        let box = CGRect(
            x: (Double(pixels) - side) / 2, y: (Double(pixels) - side) / 2,
            width: side, height: side)

        if let tint = options.tint {
            guard let color = Image.color(hex: tint) else {
                throw AppShotError.invalidPlate(tint)
            }
            guard let maskCtx = Image.context(width: pixels, height: pixels) else {
                throw AppShotError.imageEncodeFailed(mark)
            }
            try Icon.rasterize(mark, into: box, ctx: maskCtx)
            guard let drawn = maskCtx.makeImage() else {
                throw AppShotError.imageEncodeFailed(mark)
            }
            ctx.saveGState()
            ctx.clip(to: full, mask: drawn)
            ctx.setFillColor(color)
            ctx.fill(full)
            ctx.restoreGState()
        } else {
            try Icon.rasterize(mark, into: box, ctx: ctx)
        }

        guard let out = ctx.makeImage() else {
            throw AppShotError.imageEncodeFailed(mark)
        }
        return out
    }

    // MARK: - Generating

    public struct Generated: Sendable {
        public let layer: URL
        public let manifest: URL
    }

    /// Write `icon.json` and `Assets/1024.png` into a `.icon` directory.
    ///
    /// A `.icon` is a plain directory, not an archive, so this needs no Icon Composer
    /// and the result stays diffable in review.
    public static func generate(
        mark: URL,
        into bundle: URL,
        options: Icon.Options = Icon.Options(),
        pixels: Int = layerPixels
    ) throws -> Generated {
        let assets = bundle.appending(path: "Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let image = try renderLayer(mark: mark, pixels: pixels, options: options)
        let layer = assets.appending(path: layerImageName)
        try Image.write(image, to: layer)

        let manifest = bundle.appending(path: "icon.json")
        try iconJSON().write(to: manifest, atomically: true, encoding: .utf8)

        return Generated(layer: layer, manifest: manifest)
    }

    /// The minimal single-layer manifest, verified against Xcode 26.6's own output.
    ///
    /// `glass: false` keeps flat artwork flat — opting a plate into the material
    /// treatment gives it specular highlights it was not drawn for. Splitting the plate
    /// and the mark into two layers is what buys the parallax the format is for, and is
    /// the next thing to reach for once a flat icon is confirmed rendering.
    static func iconJSON(imageName: String = layerImageName) -> String {
        let name = imageName.hasSuffix(".png") ? String(imageName.dropLast(4)) : imageName
        return """
            {
              "fill-specializations" : [
                {
                  "value" : "automatic"
                },
                {
                  "appearance" : "dark",
                  "value" : "automatic"
                }
              ],
              "groups" : [
                {
                  "layers" : [
                    {
                      "glass" : false,
                      "hidden" : false,
                      "image-name" : "\(imageName)",
                      "name" : "\(name)"
                    }
                  ],
                  "shadow" : {
                    "kind" : "neutral",
                    "opacity" : 0.5
                  },
                  "translucency" : {
                    "enabled" : true,
                    "value" : 0.5
                  }
                }
              ],
              "supported-platforms" : {
                "circles" : [
                  "watchOS"
                ],
                "squares" : "shared"
              }
            }

            """
    }

    // MARK: - Audit

    public struct Finding: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case missingManifest
            case malformedManifest(String)
            /// A manifest that parses but names no layer — the `.icon` equivalent of an
            /// `.appiconset` whose Contents.json declares slots holding no images.
            case noLayers
            case missingLayerImage(String)
            case gitLFSPointer(String)
            case unreadable(String)
            case notSquare(String, got: String)
            case wrongSize(String, got: String, want: String)
            /// The base layer has transparent pixels. Almost always a corner radius
            /// carried over from `.appiconset` artwork, which the system then masks
            /// again.
            case baseLayerNotOpaque(String, transparentPixels: Int, roundedCorners: Bool)
        }
        public let kind: Kind

        public var message: String {
            switch kind {
            case .missingManifest:
                "icon.json is missing — a .icon is that file plus an Assets/ directory"
            case .malformedManifest(let why):
                "icon.json cannot be read: \(why)"
            case .noLayers:
                "icon.json declares no layers, so the bundle renders nothing"
            case .missingLayerImage(let name):
                "icon.json references \(name) but Assets/\(name) is not there"
            case .gitLFSPointer(let name):
                "\(name) is a Git LFS pointer, not an image — run `git lfs pull`"
            case .unreadable(let name):
                "\(name) cannot be decoded as an image"
            case .notSquare(let name, let got):
                "\(name) is \(got) — a .icon layer must be square"
            case .wrongSize(let name, let got, let want):
                "\(name) is \(got), should be \(want)"
            case .baseLayerNotOpaque(let name, let count, let rounded):
                rounded
                    ? """
                    \(name) has transparent corners (\(count) transparent pixels) — \
                    the plate is rounded, and the system rounds it again
                    """
                    : "\(name) has \(count) transparent pixels; the base layer must be opaque"
            }
        }
    }

    /// Check a `.icon` the way the system will render it.
    ///
    /// Like `Icon.audit`, returns findings rather than throwing: a bundle can be wrong
    /// in several ways at once, and the corner-transparency check in particular is the
    /// one people hit while migrating, so it must not be hidden behind an earlier stop.
    public static func audit(_ bundle: URL, pixels: Int = layerPixels) throws -> [Finding] {
        let manifestURL = bundle.appending(path: "icon.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return [Finding(kind: .missingManifest)]
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [Finding(kind: .malformedManifest("not a JSON object"))]
        }
        guard let groups = root["groups"] as? [[String: Any]] else {
            return [Finding(kind: .malformedManifest("no `groups` array"))]
        }

        // Draw order, back to front, flattened across groups. The first entry is the
        // base layer and the only one required to be opaque; the rest sit on top of it
        // and are meant to carry alpha.
        let names = groups.flatMap { group in
            (group["layers"] as? [[String: Any]] ?? []).compactMap {
                $0["image-name"] as? String
            }
        }
        guard !names.isEmpty else {
            return [Finding(kind: .noLayers)]
        }

        var findings: [Finding] = []
        for (index, name) in names.enumerated() {
            let url = bundle.appending(path: "Assets").appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                findings.append(Finding(kind: .missingLayerImage(name)))
                continue
            }
            guard !Image.isGitLFSPointer(url) else {
                findings.append(Finding(kind: .gitLFSPointer(name)))
                continue
            }
            guard let size = Image.size(url) else {
                findings.append(Finding(kind: .unreadable(name)))
                continue
            }
            guard size.width == size.height else {
                findings.append(
                    Finding(kind: .notSquare(name, got: "\(size.width)x\(size.height)")))
                continue
            }
            if size.width != pixels {
                findings.append(
                    Finding(
                        kind: .wrongSize(
                            name,
                            got: "\(size.width)x\(size.height)",
                            want: "\(pixels)x\(pixels)")))
            }

            guard index == 0 else { continue }
            // Counted in full rather than sampled at the corners. `Image.isOpaque` samples
            // four pixels because it runs per capture; this runs once per build, and the
            // count is what tells a stray antialiased edge from a baked-in radius.
            guard let image = try? Image.load(url), let px = Image.pixels(image) else {
                findings.append(Finding(kind: .unreadable(name)))
                continue
            }
            var transparent = 0
            for i in 0..<px.count where px[i].a < 255 { transparent += 1 }
            if transparent > 0 {
                findings.append(
                    Finding(
                        kind: .baseLayerNotOpaque(
                            name,
                            transparentPixels: transparent,
                            roundedCorners: !Image.isOpaque(image))))
            }
        }
        return findings
    }
}
