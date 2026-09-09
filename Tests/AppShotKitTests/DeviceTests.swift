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

/// The error a Mac-shaped command gives when pointed at an iOS golden tree.
///
/// Worth its own suite because the wrong message here is *destructive*: the old text
/// said "no goldens … seed them with `appshot accept`", and following that advice on a
/// directory full of real goldens overwrites the reviewed baseline with whatever
/// happens to be sitting in source/.
struct NestedGoldenHintTests {

    private func tmpDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A one-pixel PNG is enough: the scan only asks whether a subdirectory holds one.
    private func writePNG(_ url: URL) throws {
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        try png.write(to: url)
    }

    @Test func anIOSGoldenTreeIsNamedAsSuchInsteadOfLookingEmpty() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for device in ["iphone", "ipad"] {
            let sub = root.appending(path: device)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try writePNG(sub.appending(path: "browser~dark.png"))
        }

        let message = AppShotError.noGoldens(root).description

        #expect(message.contains("iphone"))
        #expect(message.contains("ipad"))
        #expect(message.contains("--config"))
        // The destructive suggestion must be warned against, never offered.
        #expect(message.contains("Do NOT run `appshot accept`"))
        #expect(!message.contains("Seed them with"))
    }

    /// The Mac case is untouched: a genuinely empty directory still points at `accept`,
    /// which is genuinely the right answer there.
    @Test func anEmptyDirectoryStillPointsAtAccept() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let message = AppShotError.noGoldens(root).description

        #expect(message.contains("Seed them with"))
        #expect(!message.contains("--config"))
    }

    /// Subdirectories that hold no PNGs are not devices — a stray `diff/` or `.DS_Store`
    /// sibling must not turn the empty case into the nested one.
    @Test func aSubdirectoryWithNoPNGsDoesNotCountAsADevice() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appending(path: "notes")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: sub.appending(path: "README.md"))

        #expect(AppShotError.noGoldens(root).description.contains("Seed them with"))
    }
}
