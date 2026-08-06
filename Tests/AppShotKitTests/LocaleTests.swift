import Foundation
import Testing

@testable import AppShotKit

/// The locale axis: how a config resolves to locales, and what that must not change for
/// the unlocalized projects that predate it.
///
/// Modelled on `DeviceTests`, because the two axes resolve the same way — a `slug` that
/// is nil for a flat layout. What they do *not* share is the reason each ends up as a
/// directory; see `Config.ResolvedLocale`.
struct LocaleTests {

    // MARK: - Backwards compatibility

    /// The invariant everything else here rests on. swift-d1, swift-r2 and silhouette
    /// must not need a single edit, which means a config with no `locales[]` resolves to
    /// exactly one locale with **no slug** — and a nil slug is what keeps every appstore
    /// path exactly where it has always been.
    @Test func aConfigWithNoLocalesResolvesToOneUnnamedLocaleWithFlatPaths() throws {
        let config = try ConfigTests.decode()
        let locales = try config.resolvedLocales()

        #expect(locales.count == 1)
        #expect(locales[0].slug == nil)

        // The copy is the screen's own, verbatim — which is why the composed pixels are
        // unchanged rather than merely similar.
        let browser = try locales[0].caption(for: config.screens[0])
        #expect(browser.title == "Your D1 databases, finally native")
        #expect(browser.subtitle == "Cloudflare D1 and local SQLite in one Mac app.")
        let paywall = try locales[0].caption(for: config.screens[1])
        #expect(paywall.title == "One purchase. Every Mac. Forever.")
        #expect(paywall.subtitle == nil)

        // The path is returned unchanged, not with a directory appended.
        let root = URL(fileURLWithPath: "/tmp/screenshots/appstore")
        #expect(locales[0].directory(under: root) == root)
    }

    @Test func theExistingSchemaDecodesUnchanged() throws {
        let config = try ConfigTests.decode()
        #expect(config.locales == nil)
        #expect(config.screens[0].title == "Your D1 databases, finally native")
        #expect(config.screens[0].captions == nil)
        #expect(config.screens[1].subtitle == nil)
        #expect(config.screens[0].website == "browser")
    }

    /// `title` went from `String` to `String?`, so the "you forgot a title" failure is
    /// now hand-written rather than synthesized. It has to come out byte-identical: the
    /// same `DecodingError` case, at the same coding path, so `Config.describe` and
    /// `Config.path` still render `missing key 'title' at screens.Index 0`.
    @Test func aScreenWithNoCaptionAtAllStillFailsWithTheSameMessage() throws {
        let json = Self.mac(screens: #"{ "id": "browser" }"#)
        let url = try Self.write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: AppShotError.self) { try Config.load(url) }
        do {
            _ = try Config.load(url)
        } catch let error as AppShotError {
            #expect("\(error)".contains("missing key 'title' at screens.Index 0"))
        }
    }

    /// A leftover plain title beside a `captions` block is two sources of truth for one
    /// string, and the loser would be invisible in the output.
    @Test func aScreenWithBothATitleAndCaptionsFailsToDecode() throws {
        let json = Self.mac(
            locales: #"["fr-FR"]"#,
            screens: #"""
                { "id": "browser", "title": "Left over",
                  "captions": { "fr-FR": { "title": "La copie" } } }
                """#)
        let url = try Self.write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try Config.load(url)
            Issue.record("expected a decode failure")
        } catch let error as AppShotError {
            let message = "\(error)"
            #expect(message.contains("`title`"))
            #expect(message.contains("`captions`"))
        }
    }

    // MARK: - Resolution

    @Test func eachLocaleCarriesItsOwnCaptionsAndDirectory() throws {
        let config = try Self.localized()
        let locales = try config.resolvedLocales()

        #expect(locales.compactMap(\.slug) == ["fr-FR", "en-US"])
        #expect(try locales[0].caption(for: config.screens[0]).title == "La carte")
        #expect(try locales[1].caption(for: config.screens[0]).title == "The map")
        #expect(try locales[0].caption(for: config.screens[0]).subtitle == "Tout le relief.")
        // A subtitle in one language and not the other is legitimate, and visible.
        #expect(try locales[1].caption(for: config.screens[0]).subtitle == nil)

        let root = URL(fileURLWithPath: "/tmp/appstore")
        #expect(locales[0].directory(under: root).path == "/tmp/appstore/fr-FR")
    }

    /// JSON object key order is not preserved by `Decodable`, so the declaring array is
    /// the only thing that can fix the order composites are emitted in.
    @Test func localeOrderIsTheDeclarationsNotTheCaptionDictionarys() throws {
        let config = try Self.localized(locales: #"["en-US", "fr-FR"]"#)
        #expect(try config.resolvedLocales().compactMap(\.slug) == ["en-US", "fr-FR"])
    }

    // MARK: - Validation

    @Test func aScreenMissingACaptionForADeclaredLocaleIsRejected() throws {
        let config = try Self.decode(
            Self.mac(
                locales: #"["fr-FR", "en-US"]"#,
                screens: #"""
                    { "id": "map", "captions": { "fr-FR": { "title": "La carte" } } }
                    """#))
        do {
            _ = try config.resolvedLocales()
            Issue.record("expected a missing-caption failure")
        } catch let error as AppShotError {
            #expect("\(error)".contains("no caption for locale \"en-US\""))
        }
    }

    /// The typo catcher, and the whole reason `locales[]` is declared rather than
    /// inferred from the union of `captions` keys. Mistyping "en-US" must produce one
    /// error naming the offending key — not N errors saying every screen is incomplete.
    @Test func aScreenCaptionForAnUndeclaredLocaleIsRejectedByName() throws {
        let config = try Self.decode(
            Self.mac(
                locales: #"["fr-FR", "en-US"]"#,
                screens: #"""
                    { "id": "map", "captions": {
                      "fr-FR": { "title": "La carte" },
                      "en-UK": { "title": "The map" } } }
                    """#))
        do {
            _ = try config.resolvedLocales()
            Issue.record("expected an unknown-locale failure")
        } catch let error as AppShotError {
            let message = "\(error)"
            #expect(message.contains("\"en-UK\""))
            #expect(message.contains("map"))
        }
    }

    @Test func aPlainTitleUnderDeclaredLocalesIsRejected() throws {
        let config = try Self.decode(
            Self.mac(locales: #"["fr-FR"]"#, screens: #"{ "id": "map", "title": "Carte" }"#))
        #expect(throws: AppShotError.self) { try config.resolvedLocales() }
    }

    @Test func captionsWithNoDeclaredLocalesAreRejected() throws {
        let config = try Self.decode(
            Self.mac(screens: #"{ "id": "map", "captions": { "fr-FR": { "title": "Carte" } } }"#))
        #expect(throws: AppShotError.self) { try config.resolvedLocales() }
    }

    @Test func anEmptyLocalesArrayIsRejected() throws {
        let config = try Self.decode(
            Self.mac(
                locales: "[]",
                screens: #"{ "id": "map", "captions": { "fr-FR": { "title": "Carte" } } }"#))
        #expect(throws: AppShotError.self) { try config.resolvedLocales() }
    }

    @Test func duplicateLocalesAreRejected() throws {
        let config = try Self.localized(locales: #"["fr-FR", "fr-FR"]"#)
        #expect(throws: AppShotError.self) { try config.resolvedLocales() }
    }

    /// A locale becomes a directory name, so the same guard `Device.id` needs applies —
    /// otherwise "../.." writes composites outside the output tree.
    @Test func aLocaleThatIsNotAPathComponentIsRejected() throws {
        for bad in ["", "fr/FR", ".", ".."] {
            let config = try Self.localized(locales: "[\"\(bad)\"]", captionLocale: bad)
            #expect(throws: AppShotError.self) { try config.resolvedLocales() }
        }
    }

    /// `validate()` is what `doctor` and `ConfigOption.load()` call, so a bad caption
    /// block has to fail there — before anything is captured, launched or wiped.
    @Test func validateRejectsABadLocaleBlock() throws {
        let config = try Self.decode(
            Self.mac(locales: #"["fr-FR"]"#, screens: #"{ "id": "map", "title": "Carte" }"#))
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func validateAcceptsAValidLocalizedConfig() throws {
        #expect(throws: Never.self) { try Self.localized().validate() }
    }

    // MARK: - Fixtures

    static func mac(locales: String? = nil, screens: String) -> String {
        """
        {
          "output": { "width": 2880, "height": 1800 },
          "appearances": ["dark"],
          "fontFamily": "Helvetica",
          \(locales.map { "\"locales\": \($0)," } ?? "")
          "layout": {
            "margin": 140, "textTop": 120, "titleFontSize": 100, "titleWeight": 700,
            "titleLineHeight": 1.12, "subtitleFontSize": 46, "subtitleWeight": 500,
            "textGap": 28, "screenshotGap": 72, "cornerRadius": 28,
            "shadow": { "blur": 48, "opacity": 0.3, "dy": 24 }
          },
          "themes": {
            "dark": {
              "background": { "angle": 145, "stops": [
                { "offset": 0, "color": "#000000" }, { "offset": 1, "color": "#111111" }] },
              "title": "#FFFFFF", "subtitle": "#AAAAAA"
            }
          },
          "screens": [\(screens)]
        }
        """
    }

    /// Two screens, two locales — `map` has a subtitle in French only, `paywall` in
    /// neither, so the optional-subtitle path is exercised without a dedicated fixture.
    static func localized(
        locales: String = #"["fr-FR", "en-US"]"#, captionLocale: String? = nil
    ) throws -> Config {
        let fr = captionLocale ?? "fr-FR"
        let en = captionLocale ?? "en-US"
        return try decode(
            mac(
                locales: locales,
                screens: """
                    { "id": "map", "captions": {
                      "\(fr)": { "title": "La carte", "subtitle": "Tout le relief." },
                      "\(en)": { "title": "The map" } } },
                    { "id": "paywall", "captions": {
                      "\(fr)": { "title": "Un achat." },
                      "\(en)": { "title": "One purchase." } } }
                    """))
    }

    static func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    /// `Config.load` rather than a bare `JSONDecoder`, because the assertions about the
    /// *rendered* message go through `Config.describe`, which only `load` applies.
    static func write(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-locale-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }
}
