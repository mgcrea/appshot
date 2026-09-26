import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// `compose family` puts captures from two platform pipelines in one image. Each half is
/// gated on its own; what these pin is what only the pairing can get wrong — geometry that
/// pushes a device off the canvas, a store image App Review would judge on the wrong
/// subject, and a half-written set.
struct FamilyTests {
    static let mac = CGSize(width: 2560, height: 1600)
    static let phone = CGSize(width: 1320, height: 2868)
    static let tablet = CGSize(width: 2064, height: 2752)
    static let box = CGRect(x: 180, y: 440, width: 2520, height: 1180)

    static func config(_ composites: String, locales: String? = nil) throws -> FamilyConfig {
        let json = """
            {
              "appearances": ["light", "dark"],
              "fontFamily": "Helvetica",
              "layout": {
                "margin": 100, "textTop": 80, "titleFontSize": 60, "titleWeight": 700,
                "titleLineHeight": 1.1, "subtitleFontSize": 30, "subtitleWeight": 500,
                "textGap": 20, "screenshotGap": 40, "cornerRadius": 20,
                "shadow": { "blur": 10, "opacity": 0.3, "dy": 6 },
                "bezel": { "width": 8, "color": "#111111" }
              },
              "themes": {
                "light": { "background": { "angle": 150, "stops": [
                  { "offset": 0, "color": "#FFFFFF" }, { "offset": 1, "color": "#EEEEEE" }] },
                  "title": "#000000", "subtitle": "#333333" },
                "dark": { "background": { "angle": 150, "stops": [
                  { "offset": 0, "color": "#000000" }, { "offset": 1, "color": "#222222" }] },
                  "title": "#FFFFFF", "subtitle": "#CCCCCC" }
              },
              "composites": \(composites)\(locales.map { ", \"locales\": \($0)" } ?? "")
            }
            """
        return try JSONDecoder().decode(FamilyConfig.self, from: Data(json.utf8))
    }

    static let everywhere = """
        [{ "id": "everywhere", "arrangement": "continuity", "screen": "home",
           "devices": ["macos", "ios/iphone"], "output": { "width": 1280, "height": 800 },
           "store": "mac", "title": "Everywhere" }]
        """

    static func tempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-family-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func seed(_ root: URL, _ relative: [String]) throws {
        for path in relative {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Image.write(GateTests.makeImage(width: 200, height: 125), to: url)
        }
    }

    // MARK: - Arrangement

    @Test func continuityFitsTheBoxAndOverlaps() {
        let rects = Compose.arrange(
            .continuity, sizes: [Self.mac, Self.phone], bezels: [0, 18], ratio: 0.86, in: Self.box)
        #expect(rects.count == 2)
        let (back, front) = (rects[0], rects[1])
        #expect(Self.box.contains(back))
        #expect(Self.box.insetBy(dx: -1, dy: -1).contains(front.insetBy(dx: -18, dy: -18)))
        // The front device stands over the back one's corner, and sticks out past it.
        #expect(back.intersects(front))
        #expect(front.maxX > back.maxX)
        #expect(front.maxY > back.maxY)
        #expect(abs(front.height / back.height - 0.86) < 0.01)
    }

    @Test func splitKeepsDevicesApartAndInsideTheBox() {
        let bezels = [8.0, 0, 8]
        let rects = Compose.arrange(
            .split, sizes: [Self.tablet, Self.mac, Self.phone], bezels: bezels, ratio: 1,
            in: Self.box)
        #expect(rects.count == 3)
        let outer = zip(rects, bezels).map { $0.insetBy(dx: -$1, dy: -$1) }
        for rect in outer {
            #expect(Self.box.insetBy(dx: -1, dy: -1).contains(rect))
        }
        // Bezels included, neighbours never touch.
        #expect(outer[0].maxX < outer[1].minX)
        #expect(outer[1].maxX < outer[2].minX)
        // Vertical centres aligned.
        #expect(abs(rects[0].midY - rects[2].midY) <= 1)
    }

    /// A 200px capture on a 2520px box stays 200px: upscaled captures are soft text.
    @Test func neverUpscalesACapture() {
        let rects = Compose.arrange(
            .split, sizes: [CGSize(width: 200, height: 125), CGSize(width: 100, height: 200)],
            bezels: [0, 0], ratio: 1, in: Self.box)
        #expect(rects[0].height <= 125)
        #expect(rects[1].height <= 200)
    }

    // MARK: - Validation

    @Test func storeMacNeedsTheMacAsSubject() throws {
        let phoneFirst = try Self.config(
            """
            [{ "id": "x", "arrangement": "continuity", "screen": "home",
               "devices": ["ios/iphone", "macos"], "output": { "width": 1280, "height": 800 },
               "store": "mac" }]
            """)
        #expect(throws: AppShotError.self) { try phoneFirst.validate() }

        let split = try Self.config(
            """
            [{ "id": "x", "arrangement": "split", "screen": "home",
               "devices": ["macos", "ios/iphone"], "output": { "width": 1280, "height": 800 },
               "store": "mac" }]
            """)
        #expect(throws: AppShotError.self) { try split.validate() }
    }

    @Test func storeMacNeedsAStoreSize() throws {
        let og = try Self.config(
            """
            [{ "id": "x", "arrangement": "continuity", "screen": "home",
               "devices": ["macos", "ios/iphone"], "output": { "width": 1200, "height": 630 },
               "store": "mac" }]
            """)
        #expect(throws: AppShotError.self) { try og.validate() }
        try Self.config(Self.everywhere).validate()
    }

    @Test func rejectsBadDeviceLists() throws {
        for devices in [
            #"["macos"]"#,  // continuity needs two
            #"["macos", "macos"]"#,  // one capture twice
            #"["macos", "../ios"]"#,  // escapes the root
            #"["macos", "ios/iphone/x"]"#,
        ] {
            let config = try Self.config(
                """
                [{ "id": "x", "arrangement": "continuity", "screen": "home",
                   "devices": \(devices), "output": { "width": 1000, "height": 600 } }]
                """)
            #expect(throws: AppShotError.self, "\(devices)") { try config.validate() }
        }
    }

    // MARK: - Compose

    @Test func composesFlattenedStoreSizedImages() throws {
        let root = try Self.tempRoot()
        try Self.seed(
            root,
            [
                "macos/source/home~light.png", "macos/source/home~dark.png",
                "ios/source/iphone/home~light.png", "ios/source/iphone/home~dark.png",
            ])
        let out = root.appending(path: "family")

        let outputs = try Compose.family(
            config: Self.config(Self.everywhere), root: root, outDir: out)

        #expect(outputs.map(\.url.lastPathComponent) == ["everywhere~light.png", "everywhere~dark.png"])
        for output in outputs {
            let image = try Image.load(output.url)
            #expect(image.width == 1280 && image.height == 800)
            // The Mac listing takes no alpha channel — not merely an opaque one.
            #expect(
                [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo),
                "\(output.url.lastPathComponent) carries alpha")
        }
    }

    /// Every capture is checked before the output directory is wiped, so a missing iOS
    /// half leaves last run's complete set in place instead of half a new one.
    @Test func aMissingCaptureFailsBeforeTouchingTheOutput() throws {
        let root = try Self.tempRoot()
        try Self.seed(root, ["macos/source/home~light.png", "macos/source/home~dark.png"])
        let out = root.appending(path: "family")
        try Self.seed(out, ["everywhere~light.png"])

        #expect {
            try Compose.family(config: Self.config(Self.everywhere), root: root, outDir: out)
        } throws: { error in
            guard case AppShotError.missingCaptures(let missing, _) = error else { return false }
            return missing.contains("ios/source/iphone/home~light.png")
        }
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "everywhere~light.png").path))
    }

    // MARK: - Locales

    static let bilingual = #"[{ "id": "fr-FR", "language": "fr" }, { "id": "en-US", "language": "en" }]"#

    static func localized(_ captions: String) -> String {
        """
        [{ "id": "map", "arrangement": "continuity", "screen": "map",
           "devices": ["macos", "ios/iphone"], "output": { "width": 1280, "height": 800 },
           "captions": \(captions) }]
        """
    }

    /// French captions over French captures on both devices, English over English, each
    /// locale in its own directory. The pairing is the point: the demo data differs per
    /// language, so a crossed pair shows two different apps under one caption.
    @Test func eachLocaleReadsItsOwnLanguageAndWritesItsOwnDirectory() throws {
        let root = try Self.tempRoot()
        var paths: [String] = []
        for language in ["fr", "en"] {
            for appearance in ["light", "dark"] {
                paths.append("macos/source/\(language)/map~\(appearance).png")
                paths.append("ios/source/\(language)/iphone/map~\(appearance).png")
            }
        }
        try Self.seed(root, paths)
        let out = root.appending(path: "family")
        let config = try Self.config(
            Self.localized(#"{ "fr-FR": { "title": "La carte" }, "en-US": { "title": "The map" } }"#),
            locales: Self.bilingual)

        let outputs = try Compose.family(config: config, root: root, outDir: out)

        let written = Set(
            outputs.map {
                "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.url.lastPathComponent)"
            })
        #expect(
            written == [
                "fr-FR/map~light.png", "fr-FR/map~dark.png", "en-US/map~light.png", "en-US/map~dark.png",
            ])
    }

    @Test func aMissingLanguageCaptureNamesItsLanguage() throws {
        let root = try Self.tempRoot()
        try Self.seed(
            root,
            ["fr", "en"].flatMap { language in
                ["light", "dark"].map { "macos/source/\(language)/map~\($0).png" }
            } + ["light", "dark"].map { "ios/source/fr/iphone/map~\($0).png" })
        let config = try Self.config(
            Self.localized(#"{ "fr-FR": { "title": "La carte" }, "en-US": { "title": "The map" } }"#),
            locales: Self.bilingual)

        #expect {
            try Compose.family(config: config, root: root, outDir: root.appending(path: "family"))
        } throws: { error in
            guard case AppShotError.missingCaptures(let missing, _) = error else { return false }
            return missing.contains("ios/source/en/iphone/map~light.png")
        }
    }

    @Test func captionsMustCoverEveryLocaleWithNoFallback() throws {
        // A gap.
        let gap = try Self.config(
            Self.localized(#"{ "fr-FR": { "title": "La carte" } }"#), locales: Self.bilingual)
        #expect(throws: AppShotError.self) { try gap.validate() }
        // A locale nobody declared: the typo case.
        let typo = try Self.config(
            Self.localized(
                #"{ "fr-FR": { "title": "a" }, "en-US": { "title": "b" }, "en-GB": { "title": "c" } }"#),
            locales: Self.bilingual)
        #expect(throws: AppShotError.self) { try typo.validate() }
        // A plain title beside locales: two sources of truth for one string.
        let plain = try Self.config(
            """
            [{ "id": "map", "arrangement": "continuity", "screen": "map",
               "devices": ["macos", "ios/iphone"], "output": { "width": 1280, "height": 800 },
               "title": "The map" }]
            """, locales: Self.bilingual)
        #expect(throws: AppShotError.self) { try plain.validate() }
        // Captions with no locales declared.
        let orphan = try Self.config(Self.localized(#"{ "fr-FR": { "title": "La carte" } }"#))
        #expect(throws: AppShotError.self) { try orphan.validate() }
        // No captions at all is fine: a captionless composite in every language.
        let bare = try Self.config(
            """
            [{ "id": "map", "arrangement": "continuity", "screen": "map",
               "devices": ["macos", "ios/iphone"], "output": { "width": 1280, "height": 800 } }]
            """, locales: Self.bilingual)
        try bare.validate()
    }
}
