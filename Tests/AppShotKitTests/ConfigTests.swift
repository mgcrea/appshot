import CoreText
import Foundation
import Testing
@testable import AppShotKit

struct ConfigTests {
    /// Verbatim from swift-d1, trimmed to one screen. Migrating a project must never
    /// mean rewriting its config, so this is the real shape — including the `//`
    /// comment keys some configs carry, which must be ignored rather than rejected.
    static let json = """
        {
          "//screens": "array order is the store order",
          "output": { "width": 2880, "height": 1800 },
          "appearances": ["light", "dark"],
          "fontFamily": "'SF Pro Display', -apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif",
          "layout": {
            "margin": 140, "textTop": 120,
            "titleFontSize": 100, "titleWeight": 700, "titleLineHeight": 1.12,
            "subtitleFontSize": 46, "subtitleWeight": 500,
            "textGap": 28, "screenshotGap": 72, "cornerRadius": 28,
            "shadow": { "blur": 48, "opacity": 0.3, "dy": 24 },
            "maxTitleLines": 2
          },
          "themes": {
            "light": {
              "background": { "angle": 145, "stops": [
                { "offset": 0, "color": "#F7F8FA" }, { "offset": 1, "color": "#E2E5EA" }] },
              "title": "#0E1116", "subtitle": "#5B6472"
            },
            "dark": {
              "background": { "angle": 145, "stops": [
                { "offset": 0, "color": "#24272C" }, { "offset": 1, "color": "#0D0E11" }] },
              "title": "#F5F6F8", "subtitle": "#99A1AD"
            }
          },
          "screens": [
            { "id": "browser", "website": "browser",
              "title": "Your D1 databases, finally native",
              "subtitle": "Cloudflare D1 and local SQLite in one Mac app." },
            { "id": "paywall", "title": "One purchase. Every Mac. Forever." }
          ]
        }
        """

    static func decode() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func decodesTheExistingSchemaUnchanged() throws {
        let config = try Self.decode()
        #expect(config.output == Config.Size(width: 2880, height: 1800))
        #expect(config.appearances == ["light", "dark"])
        #expect(config.layout.maxTitleLines == 2)
        #expect(config.layout.shadow.blur == 48)
        #expect(config.screens.count == 2)
        #expect(config.themes["dark"]?.title == "#F5F6F8")
    }

    /// A screen with no `website` key is store-only — that is how a paywall stays off
    /// the pricing page.
    @Test func websiteKeyIsOptionalAndMeansStoreOnly() throws {
        let config = try Self.decode()
        #expect(config.screens[0].website == "browser")
        #expect(config.screens[1].website == nil)
        #expect(config.screens[1].subtitle == nil)
    }

    @Test func expectedCapturesIsScreensTimesAppearances() throws {
        let config = try Self.decode()
        #expect(Set(config.expectedCaptures()) == [
            "browser~light.png", "browser~dark.png",
            "paywall~light.png", "paywall~dark.png",
        ])
    }

    /// App Store Connect rejects anything else, and the rejection does not name the
    /// file.
    @Test func rejectsAnInvalidOutputSize() throws {
        var config = try Self.decode()
        config.output = Config.Size(width: 1920, height: 1080)
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func rejectsAnAppearanceWithNoTheme() throws {
        var config = try Self.decode()
        config.appearances = ["light", "dark", "sepia"]
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func validConfigPasses() throws {
        #expect(throws: Never.self) { try Self.decode().validate() }
    }
}

struct TextTests {
    @Test func parsesTheFirstFamilyOutOfACSSStack() {
        #expect(
            Text.primaryFamily("'SF Pro Display', -apple-system, Helvetica, sans-serif")
                == "SF Pro Display")
        #expect(Text.primaryFamily("Helvetica") == "Helvetica")
    }

    /// librsvg would substitute silently and ship captions in the wrong typeface. The
    /// point of CoreText is that we can refuse.
    @Test func refusesAFontThatIsNotInstalled() {
        #expect(throws: AppShotError.self) {
            try Text.font(stack: "'__no_such_font__'", weight: 700, size: 100)
        }
    }

    @Test func resolvesAnInstalledFont() throws {
        let font = try Text.font(stack: "Helvetica", weight: 700, size: 100)
        #expect(font.familyName == "Helvetica")
    }

    /// Real metrics, not `fontSize * 0.52`: a long line must break, a short one must
    /// not.
    @Test func wrapsOnMeasuredWidth() throws {
        let font = try Text.font(stack: "Helvetica", weight: 400, size: 40)
        let color = Image.color(hex: "#000000")!

        let short = Text.wrap("Hi", font: font, color: color, kern: 0, maxWidth: 1000)
        #expect(short.count == 1)

        let long = Text.wrap(
            String(repeating: "wide ", count: 40),
            font: font, color: color, kern: 0, maxWidth: 300)
        #expect(long.count > 1)
        for line in long {
            #expect(line.width <= 300)
        }
    }

    /// An explicit \n is a hard break — the config uses it to force a title onto two
    /// lines.
    @Test func honoursExplicitLineBreaks() throws {
        let font = try Text.font(stack: "Helvetica", weight: 400, size: 40)
        let color = Image.color(hex: "#000000")!
        let lines = Text.wrap("one\ntwo", font: font, color: color, kern: 0, maxWidth: 5000)
        #expect(lines.count == 2)
    }
}

extension CTFont {
    var familyName: String { CTFontCopyFamilyName(self) as String }
}
