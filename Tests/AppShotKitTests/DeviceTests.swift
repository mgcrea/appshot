import Foundation
import Testing

@testable import AppShotKit

/// The device axis: how a config resolves to devices, and what that must not change
/// for the Mac projects that predate it.
struct DeviceTests {

    // MARK: - Backwards compatibility

    /// The invariant the whole iOS design rests on. swift-d1, swift-r2 and silhouette
    /// must not need a single edit, which means a config with no `platform` and no
    /// `devices[]` resolves to exactly one device with **no slug** — and a nil slug is
    /// what makes every path stay flat.
    @Test func aMacConfigResolvesToOneUnnamedDeviceWithFlatPaths() throws {
        let config = try ConfigTests.decode()
        let devices = try config.resolvedDevices()

        #expect(devices.count == 1)
        #expect(devices[0].slug == nil)
        #expect(devices[0].simulator == nil)
        #expect(devices[0].output == Config.Size(width: 2880, height: 1800))
        #expect(devices[0].screens.count == config.screens.count)
        #expect(devices[0].ignore.isEmpty)

        // The path is returned unchanged, not with a directory appended.
        let root = URL(fileURLWithPath: "/tmp/screenshots/source")
        #expect(devices[0].directory(under: root) == root)
    }

    @Test func absentPlatformMeansMac() throws {
        #expect(try ConfigTests.decode().resolvedPlatform == .mac)
    }

    // MARK: - iOS resolution

    static let iosJSON = """
        {
          "platform": "ios",
          "appearances": ["dark"],
          "fontFamily": "Helvetica",
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
          "screens": [
            { "id": "home", "title": "Home" },
            { "id": "detail", "title": "Detail" }
          ],
          "devices": [
            { "id": "iphone", "simulator": "iPhone 17 Pro Max",
              "output": { "width": 1320, "height": 2868 } },
            { "id": "ipad", "simulator": "iPad Pro 13-inch (M5)",
              "output": { "width": 2064, "height": 2752 },
              "screens": ["home"],
              "ignore": [{ "x": 0, "y": 0, "width": 600, "height": 70 }] }
          ]
        }
        """

    static func ios() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(iosJSON.utf8))
    }

    @Test func eachDeviceCarriesItsOwnCanvasAndDirectory() throws {
        let devices = try Self.ios().resolvedDevices()

        #expect(devices.map(\.slug) == ["iphone", "ipad"])
        #expect(devices[0].output == Config.Size(width: 1320, height: 2868))
        #expect(devices[1].output == Config.Size(width: 2064, height: 2752))

        let root = URL(fileURLWithPath: "/tmp/source")
        #expect(devices[0].directory(under: root).path == "/tmp/source/iphone")
        #expect(devices[1].directory(under: root).path == "/tmp/source/ipad")
    }

    /// A desktop-only feature has no iPhone screenshot, and an iPad may ship a subset.
    @Test func aDeviceMayShipASubsetOfScreens() throws {
        let devices = try Self.ios().resolvedDevices()

        #expect(devices[0].screens.map(\.id) == ["home", "detail"])
        #expect(devices[1].screens.map(\.id) == ["home"])
        #expect(
            Set(devices[1].expectedCaptures(appearances: ["dark"])) == ["home~dark.png"])
    }

    /// `screens[]` order is App Store order. A device naming its subset in a different
    /// order must not be able to reorder the listing as a side effect.
    @Test func aSubsetKeepsTheConfigsOrderNotTheDevices() throws {
        var config = try Self.ios()
        config.devices?[1].screens = ["detail", "home"]

        #expect(try config.resolvedDevices()[1].screens.map(\.id) == ["home", "detail"])
    }

    @Test func aDeviceInheritsTheSharedLayoutUnlessItOverridesIt() throws {
        var config = try Self.ios()
        #expect(try config.resolvedDevices()[0].layout.titleFontSize == 100)

        config.devices?[0].layout = config.layout
        config.devices?[0].layout?.titleFontSize = 64
        let devices = try config.resolvedDevices()
        #expect(devices[0].layout.titleFontSize == 64)
        // The override is per device: the other one still has the shared value.
        #expect(devices[1].layout.titleFontSize == 100)
    }

    // MARK: - Validation

    @Test func validIOSConfigPasses() throws {
        #expect(throws: Never.self) { try Self.ios().validate() }
    }

    /// The union used to be accepted for both platforms, so a Mac config could carry an
    /// iPhone canvas and pass — then be rejected by App Store Connect, which does not
    /// name the file.
    @Test func aMacConfigRejectsAnIOSSize() throws {
        var config = try ConfigTests.decode()
        config.output = Config.Size(width: 1320, height: 2868)
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func anIOSDeviceRejectsAMacSize() throws {
        var config = try Self.ios()
        config.devices?[0].output = Config.Size(width: 2880, height: 1800)
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func devicesWithoutTheIOSPlatformAreRejected() throws {
        var config = try Self.ios()
        config.platform = .mac
        // Otherwise the devices would be silently ignored and the run would use a
        // top-level `output` that an iOS config does not have.
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func iosWithoutDevicesIsRejected() throws {
        var config = try Self.ios()
        config.devices = []
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    /// The id becomes a directory name, so a duplicate means the second device's
    /// captures overwrite the first's.
    @Test func duplicateDeviceIDsAreRejected() throws {
        var config = try Self.ios()
        config.devices?[1].id = "iphone"
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    @Test func aDeviceIDThatIsNotAPathComponentIsRejected() throws {
        for bad in ["", "ip/hone", "..", "."] {
            var config = try Self.ios()
            config.devices?[0].id = bad
            #expect(throws: AppShotError.self) { try config.validate() }
        }
    }

    @Test func aDeviceCannotNameAScreenTheConfigDoesNotDeclare() throws {
        var config = try Self.ios()
        config.devices?[0].screens = ["home", "nope"]
        #expect(throws: AppShotError.self) { try config.validate() }
    }

    /// An ignore rect outside the canvas excludes nothing and one covering it excludes
    /// everything — both silently, which is the failure mode worth failing on.
    @Test func ignoreRectsMustFitTheCanvas() throws {
        let bad = [
            Config.Rect(x: 0, y: 0, width: 0, height: 10),  // empty
            Config.Rect(x: -5, y: 0, width: 10, height: 10),  // negative origin
            Config.Rect(x: 0, y: 0, width: 99_999, height: 10),  // wider than the canvas
            Config.Rect(x: 0, y: 2_700, width: 10, height: 999),  // past the bottom
        ]
        for rect in bad {
            var config = try Self.ios()
            config.devices?[1].ignore = [rect]
            #expect(throws: AppShotError.self) { try config.validate() }
        }
    }

    @Test func aValidIgnoreRectSurvivesResolution() throws {
        let devices = try Self.ios().resolvedDevices()
        #expect(devices[1].ignore == [Config.Rect(x: 0, y: 0, width: 600, height: 70)])
    }
}
