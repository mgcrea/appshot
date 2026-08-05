import CoreGraphics
import Foundation

/// The `screenshots.config.json` schema.
///
/// Decodes the existing files in swift-d1 / swift-r2 / silhouette **unchanged** —
/// migrating a project must never mean rewriting its config. Unknown keys (the
/// `//comment` entries some configs carry) are ignored for free by Decodable.
public struct Config: Codable, Sendable {
    public struct Size: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int

        public var description: String { "\(width)x\(height)" }
    }

    public struct Shadow: Codable, Sendable {
        /// Gaussian sigma, matching the SVG `feGaussianBlur stdDeviation` this
        /// replaces — NOT a CoreGraphics `setShadow(blur:)` value, which is ~2x.
        public var blur: Double
        public var opacity: Double
        /// Vertical offset only. There is no dx.
        public var dy: Double
    }

    /// A drawn device edge around the capture. Absent ⇒ no bezel, which is what every
    /// config written before this existed gets.
    ///
    /// It exists because `shadow` cannot separate a dark app from a dark gradient.
    /// Measured on an RXd composite: the pixel immediately outside the window read
    /// (18,15,13) against a background of (19,16,14) — one unit, on the setting whose
    /// entire job is to define that edge.
    ///
    /// **Deliberately not a photographic device frame.** That would mean an artwork
    /// asset per device kept in step with Apple's hardware cadence, a redistribution
    /// licence for images appshot does not own, and a screen aperture that has to align
    /// to the pixel with the capture's own alpha corners or show a seam. It would also
    /// cost real legibility: in a typical layout the window is *width*-bound, so every
    /// pixel of frame comes straight out of rendered app UI.
    ///
    /// The ring is the capture's own silhouette dilated outward by a disc, so it follows
    /// a squircle, a circular corner or a Mac window's corners exactly — by construction,
    /// with no per-device radius to configure and get wrong.
    public struct Bezel: Codable, Sendable {
        /// Ring thickness in output pixels. The window shrinks to make room, so the
        /// bezel's outer edge respects `margin` instead of eating into it.
        public var width: Double
        /// Ring body, `#RRGGBB`.
        public var color: String
        /// Brighter rim on the outermost `highlightWidth` pixels — the light a real
        /// device edge catches. Absent ⇒ a flat ring.
        public var highlight: String?
        /// Thickness of that rim. Absent ⇒ a quarter of `width`, never below 1px.
        public var highlightWidth: Double?

        public init(
            width: Double, color: String, highlight: String? = nil,
            highlightWidth: Double? = nil
        ) {
            self.width = width
            self.color = color
            self.highlight = highlight
            self.highlightWidth = highlightWidth
        }

        /// Clamped into `1...width`: a rim wider than the ring is just a differently
        /// coloured ring, and one of 0 is a config that reads as enabled and renders
        /// as nothing.
        public var resolvedHighlightWidth: Double {
            min(width, max(1, highlightWidth ?? width / 4))
        }
    }

    public struct Layout: Codable, Sendable {
        public var margin: Double
        public var textTop: Double
        public var titleFontSize: Double
        public var titleWeight: Int
        public var titleLineHeight: Double
        public var subtitleFontSize: Double
        public var subtitleWeight: Int
        public var textGap: Double
        public var screenshotGap: Double
        public var cornerRadius: Double
        public var shadow: Shadow
        /// Warn (don't fail) past this many wrapped title lines. Default 2.
        public var maxTitleLines: Int?
        /// Drawn device edge. Absent ⇒ none, so existing composites are unchanged.
        public var bezel: Bezel?

        /// Hard-coded in the JS original; kept as constants rather than invented
        /// config keys so existing configs render the same.
        public static let subtitleLineHeight: Double = 1.3
        public static let titleLetterSpacing: Double = -0.5
    }

    public struct Stop: Codable, Sendable {
        public var offset: Double
        public var color: String
    }

    public struct Background: Codable, Sendable {
        /// Degrees, clockwise, screen space (y-down).
        ///
        /// NOTE for anyone comparing against the old composites: the JS original
        /// fed this to an SVG `gradientTransform="rotate(A .5 .5)"` in
        /// objectBoundingBox units, which the renderer then skewed by the canvas
        /// aspect ratio. `angle: 145` measured ~135deg on the actual output. Here
        /// the angle means what it says, so a config carried over verbatim will
        /// render a slightly different — and now predictable — gradient.
        public var angle: Double
        public var stops: [Stop]
    }

    public struct Theme: Codable, Sendable {
        public var background: Background
        public var title: String
        public var subtitle: String
    }

    public struct Screen: Codable, Sendable {
        /// Matches `<id>~<appearance>.png` in the capture directory.
        public var id: String
        /// Basename emitted for the marketing site. Absent ⇒ store-only (this is
        /// how a paywall screen stays off the pricing page).
        public var website: String?
        public var title: String
        public var subtitle: String?
    }

    /// Which driver captures this project, and which store sizes apply.
    ///
    /// Absent ⇒ `.mac`, so every config written before iOS support decodes and behaves
    /// exactly as it did.
    public enum Platform: String, Codable, Sendable {
        case mac
        case ios
    }

    /// A region of a capture, in capture pixels, top-left origin.
    public struct Rect: Codable, Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var area: Int { max(0, width) * max(0, height) }
        public var description: String { "\(width)x\(height)+\(x)+\(y)" }
    }

    /// One simulator, and the store canvas its captures compose onto.
    ///
    /// The device is a **directory level** (`source/iphone/main~dark.png`), never a
    /// third `~` field in the filename. That keeps `Gate.reason()`, `Compose`'s naming
    /// and `Extractor`'s demangling working on `<id>~<appearance>` exactly as they do
    /// for Mac — and one config could not carry two canvas sizes any other way, since
    /// iPhone 6.9" is 1320x2868 and iPad 13" is 2064x2752.
    public struct Device: Codable, Sendable {
        /// Directory slug: `iphone`, `ipad`. Becomes a path component, so it may not
        /// contain a separator.
        public var id: String
        /// Simulator device type name, as `xcrun simctl list devicetypes` prints it:
        /// "iPhone 17 Pro Max".
        public var simulator: String
        /// Runtime to pin, e.g. "iOS 26.5". Absent ⇒ the newest installed iOS runtime.
        public var runtime: String?
        /// This device's store canvas. Must be one of `iosStoreSizes`.
        public var output: Size
        /// Full override of the shared `layout`. Deliberately all-or-nothing: a partial
        /// merge would mean two places to look for the value that actually rendered.
        public var layout: Layout?
        /// Subset of `screens[].id` this device ships, in `screens[]` order. Absent ⇒
        /// all of them. A desktop-only feature has no iPhone screenshot.
        public var screens: [String]?
        /// Regions the gate must not compare, in capture pixels.
        ///
        /// This exists because of one measured, unfixable case: **the iPad status bar
        /// shows a live date that `simctl status_bar` cannot pin.** `--time` sets the
        /// clock but not the date (its ISO form is accepted, shifts the clock by the
        /// host timezone, and still leaves the date live), and the date is present
        /// inside real apps, not just SpringBoard. Measured on iPad Pro 13", a
        /// clock/date change moves 0.0484% of the canvas — *under* the 0.1% tolerance,
        /// so it never fails outright; it silently spends half the drift budget every
        /// day and tips over only when combined with a real change.
        public var ignore: [Rect]?
    }

    /// Mac configs carry one canvas here; iOS configs carry one per `devices[]` entry
    /// and leave this absent, because each device has its own.
    public var output: Size?
    public var appearances: [String]
    public var fontFamily: String
    public var layout: Layout
    public var themes: [String: Theme]
    /// Array order **is** the App Store order: it stamps the `01-`, `02-` prefix on
    /// the composites, because App Store Connect sorts uploads by filename. The raw
    /// captures stay unnumbered so reordering the listing never renames an image.
    public var screens: [Screen]
    public var platform: Platform?
    public var devices: [Device]?

    public var resolvedPlatform: Platform { platform ?? .mac }

    public static func load(_ url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch let error as DecodingError {
            throw AppShotError.invalidConfig(url, describe(error))
        }
    }

    /// App Store Connect rejects anything else, and the rejection does not name the
    /// file — so fail here instead.
    public static let macStoreSizes: [Size] = [
        Size(width: 1280, height: 800),
        Size(width: 1440, height: 900),
        Size(width: 2560, height: 1600),
        Size(width: 2880, height: 1800),
    ]

    /// The sizes App Store Connect currently accepts for iPhone and iPad, in both
    /// orientations.
    public static let iosStoreSizes: [Size] = [
        Size(width: 1290, height: 2796), Size(width: 2796, height: 1290),  // iPhone 6.7"
        Size(width: 1320, height: 2868), Size(width: 2868, height: 1320),  // iPhone 6.9"
        Size(width: 1242, height: 2688), Size(width: 2688, height: 1242),  // iPhone 6.5"
        Size(width: 2048, height: 2732), Size(width: 2732, height: 2048),  // iPad 12.9"
        Size(width: 2064, height: 2752), Size(width: 2752, height: 2064),  // iPad 13"
    ]

    public static var storeSizes: [Size] { macStoreSizes + iosStoreSizes }

    public static func storeSizes(for platform: Platform) -> [Size] {
        switch platform {
        case .mac: return macStoreSizes
        case .ios: return iosStoreSizes
        }
    }

    // MARK: - Resolution

    /// One device's worth of the config, with every per-device override already applied.
    ///
    /// **The single place the flat-vs-nested directory decision lives.** `slug` is nil
    /// for a config with no `devices[]`, and every command appends it to its paths only
    /// when it is non-nil — which is what keeps a Mac config's directories exactly where
    /// they have always been.
    public struct ResolvedDevice: Sendable {
        /// Path component under source/golden/appstore, or nil for a flat layout.
        public let slug: String?
        /// Simulator device type name. Nil on macOS, where there is no device to pick.
        public let simulator: String?
        public let runtime: String?
        public let output: Size
        public let layout: Layout
        /// This device's screens, in `screens[]` order — which is store order.
        public let screens: [Screen]
        public let ignore: [Rect]

        /// A name for messages: the slug when there is one, else the platform.
        public let name: String

        /// Append this device's directory level to a path, if it has one.
        public func directory(under root: URL) -> URL {
            slug.map { root.appending(path: $0) } ?? root
        }

        /// Every `<id>~<appearance>.png` this device should produce.
        public func expectedCaptures(appearances: [String]) -> [String] {
            screens.flatMap { screen in
                appearances.map { "\(screen.id)~\($0).png" }
            }
        }
    }

    /// The devices to run, resolved. One entry with `slug == nil` when `devices[]` is
    /// absent — so a Mac config and a single-device config walk the same code path.
    ///
    /// Throws rather than returning a best effort: the failures here are the same ones
    /// `validate()` reports, and having two sources of truth for "is this config usable"
    /// is how they drift apart.
    public func resolvedDevices() throws -> [ResolvedDevice] {
        switch resolvedPlatform {
        case .mac:
            guard devices == nil else { throw AppShotError.devicesNeedIOS }
            guard let output else { throw AppShotError.missingOutput }
            return [
                ResolvedDevice(
                    slug: nil, simulator: nil, runtime: nil, output: output, layout: layout,
                    screens: screens, ignore: [], name: "mac")
            ]

        case .ios:
            guard let devices, !devices.isEmpty else { throw AppShotError.noDevices }
            let known = Set(screens.map(\.id))
            var seen = Set<String>()

            return try devices.map { device in
                guard !device.id.isEmpty, !device.id.contains("/"), device.id != ".",
                    device.id != ".."
                else {
                    throw AppShotError.invalidDeviceID(
                        device.id, reason: "it becomes a directory name")
                }
                guard seen.insert(device.id).inserted else {
                    throw AppShotError.duplicateDeviceID(device.id)
                }
                for id in device.screens ?? [] where !known.contains(id) {
                    throw AppShotError.unknownDeviceScreen(
                        device: device.id, screen: id, known: screens.map(\.id))
                }

                // Filtered in screens[] order, not in the order the device listed them:
                // that order is the App Store's, and a device must not be able to
                // reorder the listing as a side effect of naming a subset.
                let wanted = device.screens.map(Set.init)
                let mine = screens.filter { wanted?.contains($0.id) ?? true }

                return ResolvedDevice(
                    slug: device.id,
                    simulator: device.simulator,
                    runtime: device.runtime,
                    output: device.output,
                    layout: device.layout ?? layout,
                    screens: mine,
                    ignore: device.ignore ?? [],
                    name: device.id)
            }
        }
    }

    public func validate() throws {
        for appearance in appearances where themes[appearance] == nil {
            throw AppShotError.missingTheme(appearance)
        }

        let platform = resolvedPlatform
        let allowed = Config.storeSizes(for: platform)
        for device in try resolvedDevices() {
            guard allowed.contains(device.output) else {
                throw AppShotError.invalidOutputSize(
                    device.output.description, allowed: allowed.map(\.description))
            }
            // A bezel is drawn, not asserted against anything, so every way of getting
            // it wrong renders *something* — a zero-width ring, or a ring in the
            // fallback colour of whatever failed to parse. Fail here instead.
            if let bezel = device.layout.bezel {
                guard bezel.width > 0 else {
                    throw AppShotError.invalidBezel(
                        device: device.name, reason: "width must be positive, got \(bezel.width)")
                }
                guard Image.color(hex: bezel.color) != nil else {
                    throw AppShotError.invalidBezel(
                        device: device.name,
                        reason: "color \"\(bezel.color)\" is not #RRGGBB")
                }
                if let highlight = bezel.highlight, Image.color(hex: highlight) == nil {
                    throw AppShotError.invalidBezel(
                        device: device.name,
                        reason: "highlight \"\(highlight)\" is not #RRGGBB")
                }
                // The window has to survive the room the bezel takes from it. Left
                // unchecked this surfaces as a scale of zero and a blank canvas.
                let available =
                    min(
                        Double(device.output.width), Double(device.output.height))
                    - device.layout.margin * 2 - bezel.width * 2
                guard available > 0 else {
                    throw AppShotError.invalidBezel(
                        device: device.name,
                        reason:
                            "a \(Int(bezel.width))px bezel inside a \(Int(device.layout.margin))px "
                            + "margin leaves no room for the screenshot on a "
                            + "\(device.output.description) canvas")
                }
            }

            // An ignore rect outside the canvas excludes nothing, and one covering it
            // excludes everything. Both are silent — the gate would simply compare
            // fewer pixels than the reader thinks — so they fail here instead.
            for rect in device.ignore {
                guard rect.width > 0, rect.height > 0 else {
                    throw AppShotError.invalidIgnoreRect(
                        device: device.name, rect: rect.description,
                        reason: "width and height must be positive")
                }
                guard rect.x >= 0, rect.y >= 0,
                    rect.x + rect.width <= device.output.width,
                    rect.y + rect.height <= device.output.height
                else {
                    throw AppShotError.invalidIgnoreRect(
                        device: device.name, rect: rect.description,
                        reason: "it falls outside the \(device.output.description) canvas")
                }
            }
        }
    }

    /// Every `<id>~<appearance>.png` this config says should exist, ignoring the device
    /// axis. Callers that know their device use `ResolvedDevice.expectedCaptures`.
    public func expectedCaptures() -> [String] {
        screens.flatMap { screen in
            appearances.map { "\(screen.id)~\($0).png" }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)'" + path(ctx)
        case .typeMismatch(let type, let ctx):
            return "expected \(type)" + path(ctx)
        case .valueNotFound(let type, let ctx):
            return "null where \(type) expected" + path(ctx)
        case .dataCorrupted(let ctx):
            return ctx.debugDescription + path(ctx)
        @unknown default:
            return String(describing: error)
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let p = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "" : " at \(p)"
    }
}
