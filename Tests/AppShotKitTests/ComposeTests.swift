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

    static func seed(_ dir: URL, ids: [String] = ["browser", "paywall"],
                     appearances: [String] = ["light", "dark"]) throws {
        for id in ids {
            for appearance in appearances {
                try Image.write(
                    GateTests.makeImage(), to: dir.appending(path: "\(id)~\(appearance).png"))
            }
        }
    }

    static func names(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".png") })
    }

    // MARK: - Naming

    /// The spelling swift-d1, swift-r2 and silhouette already import. If this moves,
    /// their sites 404 on the next compose.
    @Test func singleAppearanceKeepsTheBareBasename() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        let outputs = try Compose.website(
            config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["dark"], maxWidth: 2560)

        #expect(try Self.names(in: dirs.out) == ["browser.png"])
        #expect(outputs.count == 1)
    }

    @Test func multipleAppearancesSuffixTheBasename() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        let outputs = try Compose.website(
            config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
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
            config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
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
                config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
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
                config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
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
                config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
                appearances: ["drak"], maxWidth: 2560)
        }
    }

    @Test func noAppearancesIsRejected() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        #expect(throws: AppShotError.self) {
            try Compose.website(
                config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
                appearances: [], maxWidth: 2560)
        }
    }

    // MARK: - Scaling

    @Test func capturesAreDownscaledButNeverUpscaled() throws {
        let dirs = try Self.tempDirs()
        try Self.seed(dirs.source)

        let outputs = try Compose.website(
            config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["dark"], maxWidth: 10)
        #expect(outputs[0].size.width == 10)

        // The source is 40px wide; a 2560 ceiling must leave it alone rather than
        // blow it up into a soft image.
        let big = try Compose.website(
            config: Self.config(), sourceDir: dirs.source, outDir: dirs.out,
            appearances: ["dark"], maxWidth: 2560)
        #expect(big[0].size.width == 40)
    }
}
