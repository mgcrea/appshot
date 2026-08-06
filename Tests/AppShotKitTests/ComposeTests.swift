import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// `Compose.website` feeds the marketing site, which is the one output nobody reviews
/// before it goes public — a wrong image there looks fine and stays up for months.
/// These pin the naming, since that is what the site's `<img src>` is coupled to.
struct ComposeTests {
    static func tempDirs() throws -> (root: URL, source: URL, out: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-compose-\(UUID().uuidString)")
        let source = root.appending(path: "source")
        let out = root.appending(path: "site")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (root, source, out)
    }

    /// The ConfigTests fixture declares `browser` with a website basename and `paywall`
    /// without one — the store-only case.
    static func config() throws -> Config {
        try ConfigTests.decode()
    }

    /// The single unnamed device a Mac config resolves to. Compose is per-device now;
    /// on Mac that device carries the config's own output, layout and screens, which is
    /// what keeps these assertions the same as before iOS existed.
    static func device() throws -> Config.ResolvedDevice {
        guard let device = try ConfigTests.decode().resolvedDevices().first else {
            throw AppShotError.noDevices
        }
        return device
    }

    static func seed(
        _ dir: URL, ids: [String] = ["browser", "paywall"],
        appearances: [String] = ["light", "dark"]
    ) throws {
        for id in ids {
            for appearance in appearances {
                try Image.write(
                    GateTests.makeImage(), to: dir.appending(path: "\(id)~\(appearance).png"))
            }
        }
    }

    static func names(in dir: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".png") })
    }

    // MARK: - Naming

    /// The spelling swift-d1, swift-r2 and silhouette already import. If this moves,
    /// their sites 404 on the next compose.
    @Test func singleAppearanceKeepsTheBareBasename() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        let outputs = try Compose.website(
            config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["dark"], maxWidth: 2560)

        #expect(try Self.names(in: dirs.out) == ["browser.png"])
        #expect(outputs.count == 1)
    }

    @Test func multipleAppearancesSuffixTheBasename() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        let outputs = try Compose.website(
            config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["light", "dark"], maxWidth: 2560)

        // Both survive. Unsuffixed, the second would silently overwrite the first and
        // the site would ship one appearance under both names.
        #expect(try Self.names(in: dirs.out) == ["browser~light.png", "browser~dark.png"])
        #expect(outputs.count == 2)
    }

    /// A screen with no `website` key is store-only — that is how a paywall stays off
    /// the pricing page.
    @Test func screensWithoutAWebsiteKeyAreSkipped() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        _ = try Compose.website(
            config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["light", "dark"], maxWidth: 2560)

        let names = try Self.names(in: dirs.out)
        #expect(!names.contains { $0.hasPrefix("paywall") })
    }

    // MARK: - Guards

    @Test func aMissingCaptureIsFatalForEveryRequestedAppearance() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, appearances: ["dark"])  // no light captures

        #expect(throws: AppShotError.self) {
            try Compose.website(
                config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
                appearances: ["light", "dark"], maxWidth: 2560)
        }
    }

    /// The gap must be found before the wipe. Emitting some appearances and then
    /// throwing would leave the site half-updated — the failure mode the check exists
    /// to prevent.
    @Test func aMissingCaptureLeavesTheExistingSiteImagesAlone() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, appearances: ["dark"])
        let previous = dirs.out.appending(path: "browser~dark.png")
        try Image.write(GateTests.makeImage(), to: previous)

        #expect(throws: AppShotError.self) {
            try Compose.website(
                config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
                appearances: ["light", "dark"], maxWidth: 2560)
        }
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }

    /// A typo would otherwise surface as "capture missing", pointing the reader at the
    /// capture run instead of at the flag they just mistyped.
    @Test func anAppearanceTheConfigDoesNotDeclareIsRejectedByName() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        #expect(throws: AppShotError.self) {
            try Compose.website(
                config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
                appearances: ["drak"], maxWidth: 2560)
        }
    }

    @Test func noAppearancesIsRejected() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        #expect(throws: AppShotError.self) {
            try Compose.website(
                config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
                appearances: [], maxWidth: 2560)
        }
    }

    // MARK: - Scaling

    @Test func capturesAreDownscaledButNeverUpscaled() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        let outputs = try Compose.website(
            config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["dark"], maxWidth: 10)
        #expect(outputs[0].size.width == 10)

        // The source is 40px wide; a 2560 ceiling must leave it alone rather than
        // blow it up into a soft image.
        let big = try Compose.website(
            config: Self.config(), device: Self.device(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["dark"], maxWidth: 2560)
        #expect(big[0].size.width == 40)
    }

    // MARK: - Locales

    /// A localized Mac config over the same two screens. Declares only `dark`, so the
    /// expected output set stays small enough to assert exactly.
    static func localizedConfig() throws -> Config {
        try LocaleTests.decode(
            LocaleTests.mac(
                locales: #"["fr-FR", "en-US"]"#,
                screens: #"""
                    { "id": "browser", "captions": {
                      "fr-FR": { "title": "Vos bases D1" },
                      "en-US": { "title": "Your D1 databases" } } },
                    { "id": "paywall", "captions": {
                      "fr-FR": { "title": "Un achat." },
                      "en-US": { "title": "One purchase." } } }
                    """#))
    }

    static func localizedDevice(_ config: Config) throws -> Config.ResolvedDevice {
        guard let device = try config.resolvedDevices().first else { throw AppShotError.noDevices }
        return device
    }

    static func composeAll(_ config: Config, from source: URL, into out: URL) throws -> [URL] {
        let device = try localizedDevice(config)
        return try config.resolvedLocales().flatMap { locale in
            try Compose.appStore(
                config: config, device: device, locale: locale,
                // Never locale-scoped — see `theSourceDirectoryIsNeverLocaleScoped`.
                sourceDir: source, outDir: locale.directory(under: out)
            ).map(\.url)
        }
    }

    /// The backwards-compat pin, asserted at the filesystem rather than at the type: an
    /// unlocalized config keeps writing flat names into the directory it was given, with
    /// no locale level appearing underneath it.
    @Test func anUnlocalizedComposeWritesTheFlatNamesItAlwaysHas() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)
        let config = try Self.config()

        _ = try Compose.appStore(
            config: config, device: Self.device(), locale: try config.resolvedLocales()[0],
            sourceDir: dirs.source, outDir: dirs.out)

        #expect(
            try Self.names(in: dirs.out) == [
                "01-browser~light.png", "01-browser~dark.png",
                "02-paywall~light.png", "02-paywall~dark.png",
            ])
        let subdirectories = try FileManager.default
            .contentsOfDirectory(atPath: dirs.out.path)
            .filter { !$0.hasSuffix(".png") }
        #expect(subdirectories.isEmpty)
    }

    @Test func aLocalizedComposeWritesOneSubdirectoryPerLocale() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, appearances: ["dark"])
        _ = try Self.composeAll(try Self.localizedConfig(), from: dirs.source, into: dirs.out)

        #expect(try Self.names(in: dirs.out.appending(path: "fr-FR")).contains("01-browser~dark.png"))
        #expect(try Self.names(in: dirs.out.appending(path: "en-US")).contains("01-browser~dark.png"))
        // Nothing loose in the root — that is the shape the stale-set warning looks for.
        #expect(try Self.names(in: dirs.out).isEmpty)
    }

    /// `screens[]` order is the App Store's. A locale carries different copy, and must
    /// not be able to reorder a listing as a side effect of that.
    @Test func theNumericPrefixIsIdenticalInEveryLocale() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, appearances: ["dark"])
        _ = try Self.composeAll(try Self.localizedConfig(), from: dirs.source, into: dirs.out)

        for locale in ["fr-FR", "en-US"] {
            #expect(
                try Self.names(in: dirs.out.appending(path: locale)) == [
                    "01-browser~dark.png", "02-paywall~dark.png",
                ])
        }
    }

    /// Without this the whole feature could be inert — every other locale test would
    /// still pass while both directories held the same composites.
    @Test func theCaptionReachesTheCanvas() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, ids: ["browser"], appearances: ["dark"])
        let config = try LocaleTests.decode(
            LocaleTests.mac(
                locales: #"["fr-FR", "en-US"]"#,
                screens: #"""
                    { "id": "browser", "captions": {
                      "fr-FR": { "title": "Vos bases de donnees D1" },
                      "en-US": { "title": "Your D1 databases" } } }
                    """#))

        let composed = try Self.composeAll(config, from: dirs.source, into: dirs.out)
        #expect(composed.count == 2)
        #expect(try Gate.sha256(of: composed[0]) != Gate.sha256(of: composed[1]))
    }

    /// "The gate is unaffected", as a filesystem fact: a localized config composes from a
    /// flat `source/` holding only `<id>~<appearance>.png`. If `sourceDir` ever picked up
    /// a locale level, this is what would catch it.
    @Test func theSourceDirectoryIsNeverLocaleScoped() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, appearances: ["dark"])
        #expect(throws: Never.self) {
            _ = try Self.composeAll(try Self.localizedConfig(), from: dirs.source, into: dirs.out)
        }
    }

    /// The reason locales became directories rather than a filename suffix: `appStore`
    /// wipes the directory it writes into, so a shared one would mean composing a single
    /// locale destroys the finished set for every other.
    @Test func narrowingToOneLocaleLeavesTheOthersOnDisk() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source, appearances: ["dark"])
        let config = try Self.localizedConfig()
        _ = try Self.composeAll(config, from: dirs.source, into: dirs.out)

        // Now recompose French alone, as `--locale fr-FR` would.
        let all = try config.resolvedLocales()
        guard let french = all.first(where: { $0.slug == "fr-FR" }) else {
            throw AppShotError.unknownLocale("fr-FR", known: all.compactMap(\.slug))
        }
        _ = try Compose.appStore(
            config: config, device: try Self.localizedDevice(config), locale: french,
            sourceDir: dirs.source, outDir: french.directory(under: dirs.out))

        #expect(try Self.names(in: dirs.out.appending(path: "en-US")).count == 2)
    }
}
