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

    public var output: Size
    public var appearances: [String]
    public var fontFamily: String
    public var layout: Layout
    public var themes: [String: Theme]
    /// Array order **is** the App Store order: it stamps the `01-`, `02-` prefix on
    /// the composites, because App Store Connect sorts uploads by filename. The raw
    /// captures stay unnumbered so reordering the listing never renames an image.
    public var screens: [Screen]

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

    public func validate() throws {
        guard Config.macStoreSizes.contains(output) else {
            throw AppShotError.invalidOutputSize(
                output.description,
                allowed: Config.macStoreSizes.map(\.description))
        }
        for appearance in appearances where themes[appearance] == nil {
            throw AppShotError.missingTheme(appearance)
        }
    }

    /// Every `<id>~<appearance>.png` this config says should exist.
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
