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

    /// One screen's copy, in one language.
    public struct Caption: Codable, Sendable, Equatable {
        public var title: String
        public var subtitle: String?

        public init(title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public struct Screen: Codable, Sendable {
        /// Matches `<id>~<appearance>.png` in the capture directory.
        public var id: String
        /// Basename emitted for the marketing site. Absent ⇒ store-only (this is
        /// how a paywall screen stays off the pricing page).
        public var website: String?
        /// The copy, when this screen has one language. Nil ⇔ `captions` carries it
        /// per locale — exactly one of the two is always present, enforced at decode.
        public var title: String?
        public var subtitle: String?
        /// Locale code → copy. Absent ⇒ this screen is unlocalized, which is every
        /// config written before this existed.
        public var captions: [String: Caption]?
        /// What window chrome this screen's capture carries. Absent ⇒ `.standard`.
        ///
        /// `.none` is for a stage that photographs a borderless window — a menu bar
        /// panel's content hosted for the capture, a HUD — and it is per screen on
        /// purpose: `capture --recolor-traffic-lights` fails a shot whose window has no
        /// buttons, which is exactly right for every *other* screen, where missing
        /// buttons mean something drew over them or the wrong window was captured.
        /// Declaring it here keeps that failure loud everywhere it was not declared.
        public var chrome: Chrome?
        /// The id of a composite in `family.config.json` to put in this slot, instead of a
        /// capture of this app. Absent ⇒ an ordinary screen.
        ///
        /// A slot rather than a separate upload so that the listing has one order and one
        /// directory: `compose family` alone writes beside the store set, unnumbered, and
        /// the family image's place in the listing is then decided by hand every release.
        /// Here it takes the `NN-` prefix of its position in `screens[]` like any other.
        ///
        /// A family screen has no capture, so it is left out of every capture set (the
        /// capture, the gate, extract), and no caption, because the family config already
        /// carries one: two captions for one image is two sources of truth.
        public var family: String?

        public var isFamily: Bool { family != nil }

        public init(
            id: String, website: String? = nil, title: String? = nil,
            subtitle: String? = nil, captions: [String: Caption]? = nil, chrome: Chrome? = nil,
            family: String? = nil
        ) {
            self.id = id
            self.website = website
            self.title = title
            self.subtitle = subtitle
            self.captions = captions
            self.chrome = chrome
            self.family = family
        }

        enum CodingKeys: String, CodingKey {
            case id, website, title, subtitle, captions, chrome, family
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            website = try c.decodeIfPresent(String.self, forKey: .website)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            captions = try c.decodeIfPresent([String: Caption].self, forKey: .captions)
            chrome = try c.decodeIfPresent(Chrome.self, forKey: .chrome)
            family = try c.decodeIfPresent(String.self, forKey: .family)

            if let family {
                // Everything else a screen can say is about a capture of this app, and a
                // family screen has none: its caption, its window and its web image all
                // belong to the family composite.
                let stray = [
                    title.map { _ in "title" }, subtitle.map { _ in "subtitle" },
                    captions.map { _ in "captions" }, website.map { _ in "website" },
                    chrome.map { _ in "chrome" },
                ].compactMap { $0 }
                if let key = stray.first {
                    throw DecodingError.dataCorruptedError(
                        forKey: .family, in: c,
                        debugDescription: "screen \"\(id)\" is the family composite "
                            + "\"\(family)\" and also has `\(key)`. A family screen's caption "
                            + "lives in family.config.json, and it has no capture of its own.")
                }
                return
            }

            // Byte-identical to what synthesized `Decodable` threw before `captions`
            // existed. An unlocalized config that forgets a title must keep failing the
            // same way, with the same message, at the same coding path — `describe` and
            // `path` render it as `missing key 'title' at screens.Index 0`.
            if captions == nil, title == nil {
                throw DecodingError.keyNotFound(
                    CodingKeys.title,
                    .init(
                        codingPath: c.codingPath,
                        debugDescription: "screen \"\(id)\" has neither `title` nor `captions`"))
            }
            // No fallback, on purpose: a leftover `title` beside a `captions` block is two
            // sources of truth for one string, and the loser is invisible in the output —
            // which is how a French listing ships English copy.
            if captions != nil, title != nil || subtitle != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .captions, in: c,
                    debugDescription: "screen \"\(id)\" has both a plain `title` and per-locale "
                        + "`captions`. Move the plain copy into `captions` under its locale — "
                        + "there is no fallback, on purpose.")
            }
        }
    }

    /// The window chrome a screen's capture carries. See `Screen.chrome`.
    public enum Chrome: String, Codable, Sendable {
        /// A titled window with close, minimise and zoom buttons.
        case standard
        /// A borderless window: nothing for `--recolor-traffic-lights` to repaint.
        case none
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
        /// "iPhone 17 Pro Max". Exactly one of this and `hardware`.
        public var simulator: String?
        /// A real, connected iPhone or iPad, by the name or UDID `xcrun devicectl list
        /// devices` prints. Exactly one of this and `simulator`.
        ///
        /// For an app the simulator cannot render: a Metal 4 canvas, the camera, anything
        /// whose Simulator SDK is stubs. It costs what a simulator does not: the status
        /// bar and the appearance cannot be pinned from outside, so the app does both
        /// under the demo flag, and the device must be unlocked, awake and held in the
        /// canvas's orientation for the whole run. See `Hardware`.
        public var hardware: String?
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
    /// The locales to compose captions in, in order. Absent ⇒ every screen carries a
    /// plain `title` and the output stays exactly where it has always been.
    ///
    /// This is the `appearances` / `themes` shape the config already uses for its other
    /// fan-out-with-data axis: an ordered array declares the axis, a keyed object per
    /// screen supplies the data, and a gap between them is a hard failure. Declaring the
    /// axis here rather than inferring it from the union of `captions` keys is what makes
    /// a typo name itself — mistyping "de" as "dr" is one error pointing at the typo,
    /// instead of inventing a locale and marking every other screen incomplete.
    public var locales: [String]?

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
        /// Simulator device type name. Nil on macOS, where there is no device to pick,
        /// and for a hardware device.
        public let simulator: String?
        /// A connected device's name or UDID, when this entry is real hardware.
        public let hardware: String?
        public let runtime: String?
        public let output: Size
        public let layout: Layout
        /// This device's screens, in `screens[]` order — which is store order. Includes
        /// family screens; anything about captures wants `captured`.
        public let screens: [Screen]
        public let ignore: [Rect]

        /// A name for messages: the slug when there is one, else the platform.
        public let name: String

        /// Append this device's directory level to a path, if it has one.
        public func directory(under root: URL) -> URL {
            slug.map { root.appending(path: $0) } ?? root
        }

        /// The screens a capture run photographs: every one but the family slots.
        public var captured: [Screen] { screens.filter { !$0.isFamily } }

        /// Every `<id>~<appearance>.png` this device should produce.
        public func expectedCaptures(appearances: [String]) -> [String] {
            captured.flatMap { screen in
                appearances.map { "\(screen.id)~\($0).png" }
            }
        }
    }

    /// One locale's worth of the config, with every screen's copy already resolved.
    ///
    /// The locale twin of `ResolvedDevice`, and it earns the same "one place decides
    /// flat-vs-nested" property: `slug` is nil for a config with no `locales[]`, and the
    /// only caller appends it to the *appstore* path when it is non-nil.
    ///
    /// A locale is a directory for different reasons than a device is, and the difference
    /// is worth knowing before anyone collapses the two. `Device.id`'s argument — that a
    /// third `~` field would break `<id>~<appearance>` demangling, and that one config
    /// cannot carry two canvas sizes — does **not** transfer: a locale never appears in a
    /// capture filename and needs no canvas of its own. What decides it here is that
    /// `Compose.appStore` wipes its output directory before writing, so locales sharing
    /// one directory would mean `--locale fr-FR` destroying a complete, correct set for a
    /// locale the run was explicitly told not to touch.
    public struct ResolvedLocale: Sendable {
        /// Path component under the appstore root, or nil for a flat layout.
        public let slug: String?
        /// A name for messages: the slug when there is one, else the platform's default.
        public let name: String
        /// screen id → the copy this locale renders. Total over `config.screens`, because
        /// resolution has already failed on any gap.
        let captions: [String: Caption]

        /// Append this locale's directory level to a path, if it has one.
        public func directory(under root: URL) -> URL {
            slug.map { root.appending(path: $0) } ?? root
        }

        /// Throwing rather than falling back: there is deliberately no code path in this
        /// tool that renders one locale's copy under another locale's name.
        public func caption(for screen: Screen) throws -> Caption {
            guard let caption = captions[screen.id] else {
                throw AppShotError.missingCaption(screen: screen.id, locale: name)
            }
            return caption
        }
    }

    /// The locales to compose, resolved. One entry with `slug == nil` when `locales[]` is
    /// absent — so an unlocalized config and a localized one walk the same code path, and
    /// the unlocalized one's output cannot move.
    public func resolvedLocales() throws -> [ResolvedLocale] {
        guard let locales else {
            // A screen with `captions` but no declared axis would compose nothing at all.
            for screen in screens where screen.captions != nil {
                throw AppShotError.captionsNeedLocales(screen: screen.id)
            }
            var captions: [String: Caption] = [:]
            // A family screen's caption is the family config's; see `Screen.family`.
            for screen in screens where !screen.isFamily {
                // `title` is non-nil here: decode rejects a screen with neither.
                captions[screen.id] = Caption(title: screen.title ?? "", subtitle: screen.subtitle)
            }
            return [ResolvedLocale(slug: nil, name: resolvedPlatform.rawValue, captions: captions)]
        }

        guard !locales.isEmpty else { throw AppShotError.noLocales }

        var seen = Set<String>()
        return try locales.map { locale in
            guard !locale.isEmpty, !locale.contains("/"), locale != ".", locale != ".." else {
                throw AppShotError.invalidLocaleID(locale, reason: "it becomes a directory name")
            }
            guard seen.insert(locale).inserted else {
                throw AppShotError.duplicateLocaleID(locale)
            }

            var captions: [String: Caption] = [:]
            for screen in screens where !screen.isFamily {
                guard let declared = screen.captions else {
                    throw AppShotError.unlocalizedScreen(screen: screen.id, locales: locales)
                }
                // Checked here rather than at decode, because only now is the declared set
                // known — and naming the offending key is the whole point of declaring it.
                for key in declared.keys where !locales.contains(key) {
                    throw AppShotError.unknownScreenLocale(
                        screen: screen.id, locale: key, known: locales)
                }
                guard let caption = declared[locale] else {
                    throw AppShotError.missingCaption(screen: screen.id, locale: locale)
                }
                captions[screen.id] = caption
            }
            return ResolvedLocale(slug: locale, name: locale, captions: captions)
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
                    slug: nil, simulator: nil, hardware: nil, runtime: nil, output: output,
                    layout: layout,
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
                // Both would be two answers to "where does this run", and neither is no
                // answer at all. Checked here rather than left to the driver, so `doctor`
                // and `compose` refuse the config too, not only `capture`.
                switch (device.simulator, device.hardware) {
                case (.some, .none), (.none, .some): break
                case (.some, .some):
                    throw AppShotError.invalidDeviceTarget(device.id, both: true)
                case (.none, .none):
                    throw AppShotError.invalidDeviceTarget(device.id, both: false)
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
                    hardware: device.hardware,
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

        // Resolution is where every locale failure lives, so calling it here is what makes
        // `doctor` and `ConfigOption.load()` report a bad caption block before anything is
        // captured, launched or wiped.
        _ = try resolvedLocales()

        // `store: mac` is the only listing a family composite is checked for, so it is
        // the only one it may take a slot in.
        if resolvedPlatform != .mac, let screen = screens.first(where: \.isFamily) {
            throw AppShotError.familyScreen(
                screen: screen.id, reason: "family composites are for the Mac listing only")
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
        capturedScreenIDs.flatMap { id in
            appearances.map { "\(id)~\($0).png" }
        }
    }

    /// The ids a capture run photographs, in `screens[]` order: every screen but the
    /// family slots, which are composed from other captures and never captured.
    public var capturedScreenIDs: [String] {
        screens.filter { !$0.isFamily }.map(\.id)
    }

    static func describe(_ error: DecodingError) -> String {
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
