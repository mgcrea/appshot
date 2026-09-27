import Foundation
import Testing

@testable import AppShotKit

/// `"store": false` keeps a screen off the listing and nothing else. Found on a Mac
/// listing already at App Store Connect's ten, whose family image needed a slot: every
/// screen but the paywall was also on the marketing site, so deleting one to make room
/// deleted its website image with it.
struct StoreScreenTests {
    /// The ConfigTests fixture with `browser`, the website screen, taken off the listing.
    static func offListing() throws -> Config {
        let json = ConfigTests.json.replacingOccurrences(
            of: #"{ "id": "browser", "website": "browser","#,
            with: #"{ "id": "browser", "website": "browser", "store": false,"#)
        var config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        // About naming, not the caption face. See `MaskingTests.installedFont`.
        config.fontFamily = "Helvetica"
        return config
    }

    static func device(_ config: Config) throws -> Config.ResolvedDevice {
        guard let device = try config.resolvedDevices().first else { throw AppShotError.noDevices }
        return device
    }

    /// `n` screens, each with a title, and `offListing` of them marked `store: false`.
    static func config(screens n: Int, offListing: Int = 0) throws -> Config {
        let screens = (0..<n).map { i in
            let store = i < offListing ? #", "store": false"# : ""
            return #"{ "id": "s\#(i)", "title": "Screen \#(i)"\#(store) }"#
        }
        let json = ConfigTests.json.replacing(
            #/"screens": \[[\s\S]*\]\s*\}\s*$/#,
            with: #""screens": [\#(screens.joined(separator: ", "))] }"#)
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func absentMeansOnTheListing() throws {
        let config = try ConfigTests.decode()
        #expect(config.screens.allSatisfy { $0.store == nil && $0.inStore })
    }

    /// Off the listing is not off the pipeline: the gate still guards it, and the site
    /// still gets it.
    @Test func itIsStillCapturedAndGated() throws {
        let device = try Self.device(try Self.offListing())
        #expect(device.captured.map(\.id) == ["browser", "paywall"])
        #expect(device.storeScreens.map(\.id) == ["paywall"])
    }

    /// The numbering closes over the gap, because App Store Connect orders by filename
    /// and a listing that reads 02, 03… reads as a screenshot gone missing.
    @Test func composeAppStoreSkipsItAndNumbersWithoutAGap() throws {
        let dirs = try ComposeTests.tempDirs()
        try ComposeTests.seed(dirs.source)
        let config = try Self.offListing()

        _ = try Compose.appStore(
            config: config, device: Self.device(config),
            locale: try config.resolvedLocales()[0],
            sourceDir: dirs.source, outDir: dirs.out)

        #expect(try ComposeTests.names(in: dirs.out) == ["01-paywall~light.png", "01-paywall~dark.png"])
    }

    @Test func theWebsiteStillGetsIt() throws {
        let dirs = try ComposeTests.tempDirs()
        try ComposeTests.seed(dirs.source)
        let config = try Self.offListing()

        _ = try Compose.website(
            config: config, device: Self.device(config), sourceDir: dirs.source,
            outDir: dirs.out, appearances: ["dark"], maxWidth: 2560)

        #expect(try ComposeTests.names(in: dirs.out) == ["browser.png"])
    }

    /// An eleventh screenshot composes like the other ten and is refused only at upload.
    @Test func moreThanTheListingHoldsIsRefused() throws {
        #expect(throws: Never.self) { try Self.config(screens: Config.maxStoreScreens).validate() }

        let error = #expect(throws: AppShotError.self) {
            try Self.config(screens: Config.maxStoreScreens + 1).validate()
        }
        guard case .tooManyStoreScreens(_, let count, let limit) = error else {
            Issue.record("expected tooManyStoreScreens, got \(String(describing: error))")
            return
        }
        #expect(count == Config.maxStoreScreens + 1)
        #expect(limit == Config.maxStoreScreens)
    }

    @Test func onlyListedScreensCountTowardTheLimit() throws {
        let config = try Self.config(screens: Config.maxStoreScreens + 1, offListing: 1)
        #expect(throws: Never.self) { try config.validate() }
    }

    /// A family slot is nothing but a place in the listing.
    @Test func aFamilySlotCannotLeaveTheListing() throws {
        let json = ConfigTests.json.replacingOccurrences(
            of: #"{ "id": "paywall", "title": "One purchase. Every Mac. Forever." }"#,
            with: #"{ "id": "everywhere", "family": "everywhere", "store": false }"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
    }
}
