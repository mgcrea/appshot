import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The real-device driver, asserted without a device.
///
/// Each of these is otherwise a round trip to a phone that has to be unlocked, awake and
/// held the right way up, and the `--` case is not discoverable at all until a launch
/// fails with an error about a timeout nobody set.
struct HardwareTests {
    static let udid = "00008150-000A43CE1447801C"

    // MARK: - Launch

    /// devicectl reads `-ScreenshotMode` as a bundle of its own short flags and fails with
    /// "The value 'YES' is invalid for '-t <seconds>'". Measured, on Xcode 27.
    @Test func appArgumentsFollowATerminator() {
        let argv = Hardware.Command.launch(
            Self.udid, bundleID: "io.example.App", args: ["-ScreenshotMode", "YES"]
        ).argv

        let terminator = try! #require(argv.firstIndex(of: "--"))
        #expect(argv[terminator - 1] == "io.example.App")
        #expect(Array(argv[(terminator + 1)...]) == ["-ScreenshotMode", "YES"])
    }

    /// Without it the running instance comes forward with the previous stage, and the
    /// same screen is photographed under the next screen's name.
    @Test func launchTerminatesTheRunningInstance() {
        let argv = Hardware.Command.launch(Self.udid, bundleID: "io.example.App", args: []).argv
        #expect(argv.contains("--terminate-existing"))
    }

    /// After the `--`, devicectl's own output flags would reach the app instead, and the
    /// launch's JSON — the only place its pid is reported — would never be written.
    @Test func outputFlagsGoBeforeTheTerminator() {
        let argv = Hardware.invocation(
            .launch(Self.udid, bundleID: "io.example.App", args: ["-ScreenshotStage", "fan"]),
            json: "/tmp/out.json")

        let terminator = try! #require(argv.firstIndex(of: "--"))
        let json = try! #require(argv.firstIndex(of: "-j"))
        #expect(json < terminator)
        #expect(argv[json + 1] == "/tmp/out.json")
        #expect(argv.last == "fan")
    }

    @Test func outputFlagsAreAppendedWhenThereIsNoTerminator() {
        let argv = Hardware.invocation(.list, json: "/tmp/out.json")
        #expect(argv.suffix(3) == ["-q", "-j", "/tmp/out.json"])
    }

    /// The stage, the appearance and the ready file come first, then the target, then the
    /// project's own arguments, so a project can still override any of them.
    @Test func launchArgumentsNameTheTargetAndTheTildeReadyFile() {
        let options = Hardware.Options(
            app: URL(fileURLWithPath: "/tmp/App.app"), outDir: URL(fileURLWithPath: "/tmp"),
            device: Self.resolvedDevice(), screens: [],
            extraArgs: ["-ScreenshotMode", "YES"], useReadyFile: true)
        let marker = Hardware.ReadyMarker(name: "appshot-ready-X")

        let args = Hardware.launchArguments(
            stage: "fan", appearance: "dark", ready: marker, options: options)

        #expect(
            args == [
                "-ScreenshotStage", "fan", "-ScreenshotAppearance", "dark",
                "-ScreenshotReadyFile", "~/tmp/appshot-ready-X",
                "-ScreenshotTarget", "hardware",
                "-ScreenshotMode", "YES",
            ])
    }

    /// devicectl never reports the container's absolute path, so the marker is named
    /// relative to the app's home, and the poll looks in the same directory.
    @Test func theReadyMarkerLivesInTheContainersTmp() {
        let marker = Hardware.ReadyMarker(name: "appshot-ready-X")
        #expect(marker.argument == "~/tmp/appshot-ready-X")

        let argv = Hardware.Command.findFile(
            Self.udid, bundleID: "io.example.App", directory: Hardware.ReadyMarker.directory,
            name: marker.name
        ).argv
        #expect(argv.contains("appDataContainer"))
        #expect(argv.contains("tmp"))
        #expect(argv.last == "appshot-ready-X")
    }

    /// Two shots must never share a marker, or one's signal would fire the other's shutter.
    @Test func everyMarkerIsFresh() {
        #expect(Hardware.ReadyMarker() != Hardware.ReadyMarker())
    }

    // MARK: - Which device

    static var listing: [String: Any] {
        [
            "result": [
                "devices": [
                    [
                        "hardwareProperties": [
                            "reality": "simulated", "platform": "iOS", "udid": "SIM-1",
                            "marketingName": "iPhone 17 Pro Max",
                        ],
                        "deviceProperties": ["name": "appshot-iphone"],
                    ],
                    [
                        "hardwareProperties": [
                            "reality": "physical", "platform": "watchOS", "udid": "WATCH-1",
                        ],
                        "deviceProperties": ["name": "Olivier’s Apple Watch"],
                    ],
                    [
                        "hardwareProperties": [
                            "reality": "physical", "platform": "iOS", "udid": udid,
                            "marketingName": "iPhone 17 Pro Max",
                        ],
                        "deviceProperties": [
                            "name": "Olivier’s iPhone", "developerModeStatus": "enabled",
                        ],
                        "connectionProperties": ["pairingState": "paired"],
                    ],
                ]
            ]
        ]
    }

    /// devicectl lists simulators and watches in the same array. Taking the first row
    /// would install onto a simulator.
    @Test func onlyPhysicalPhonesAndPadsAreListed() {
        let devices = Hardware.devices(in: Self.listing)
        #expect(devices.map(\.udid) == [Self.udid])
        #expect(devices[0].model == "iPhone 17 Pro Max")
    }

    /// Device names carry a typographic apostrophe nobody types.
    @Test func aNameMatchesWithAPlainApostrophe() throws {
        let devices = Hardware.devices(in: Self.listing)
        #expect(try Hardware.resolve("olivier's iphone", among: devices).udid == Self.udid)
        #expect(try Hardware.resolve(Self.udid, among: devices).udid == Self.udid)
    }

    @Test func anUnknownDeviceNamesTheOnesThatArePaired() {
        let devices = Hardware.devices(in: Self.listing)
        #expect {
            try Hardware.resolve("Someone else's iPad", among: devices)
        } throws: { error in
            "\(error)".contains("Olivier’s iPhone")
        }
    }

    @Test func developerModeOffIsNamed() {
        let device = Hardware.Device(
            udid: "X", name: "Phone", model: "", developerMode: "disabled", pairing: "paired")
        #expect(device.unusableReason?.contains("Developer Mode") == true)
    }

    // MARK: - The build

    @Test func aSimulatorBuildIsRefused() throws {
        let app = try Self.app(platform: "iphonesimulator")
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(throws: AppShotError.self) { try Hardware.bundleID(of: app) }
    }

    @Test func aDeviceBuildIsAccepted() throws {
        let app = try Self.app(platform: "iphoneos")
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(try Hardware.bundleID(of: app) == "io.example.App")
    }

    // MARK: - What a simulator never needed checking

    /// A phone lying on a desk photographs in landscape.
    @Test func orientationIsComparedNotSize() {
        let portrait = Config.Size(width: 1320, height: 2868)
        #expect(Hardware.orientationMatches(portrait, canvas: portrait))
        #expect(!Hardware.orientationMatches(Config.Size(width: 2868, height: 1320), canvas: portrait))
        // A smaller phone for the same canvas is composed like a simulator's would be.
        #expect(Hardware.orientationMatches(Config.Size(width: 1206, height: 2622), canvas: portrait))
    }

    /// The app ignored -ScreenshotAppearance: two plausible light images, one named dark.
    @Test func identicalAppearancesAreCaught() throws {
        let light = GateTests.makeImage(rgb: (240, 240, 240), transparentCorner: false)
        let dark = GateTests.makeImage(rgb: (20, 20, 20), transparentCorner: false)
        let shots = [
            Self.shot("fan", "light"), Self.shot("fan", "dark"),
            Self.shot("tree", "light"), Self.shot("tree", "dark"),
        ]
        let images: [String: CGImage] = [
            "fan~light": light, "fan~dark": light,
            "tree~light": light, "tree~dark": dark,
        ]

        let ignored = try Hardware.appearanceIgnored(shots) { url in
            images[url.deletingPathExtension().lastPathComponent]!
        }
        #expect(ignored == ["fan"])
    }

    /// One appearance has nothing to compare against, which is not a failure.
    @Test func aSingleAppearanceIsNeverCalledIgnored() throws {
        let image = GateTests.makeImage(transparentCorner: false)
        let ignored = try Hardware.appearanceIgnored([Self.shot("fan", "light")]) { _ in image }
        #expect(ignored.isEmpty)
    }

    /// Device frames are 16-bit; the goldens would double in LFS for nothing.
    @Test func sixteenBitFramesAreWrittenAtEight() throws {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 16, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let frame = try #require(ctx.makeImage())

        let written = Hardware.eightBit(frame)
        #expect(written.bitsPerComponent == 8)
        #expect(written.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Capture.isStill(frame, written))
    }

    /// The measured Dynamic Island case, shrunk: a small patch that changes between two
    /// frames of an otherwise still screen is located, not just detected.
    @Test func motionIsLocated() throws {
        let still = GateTests.makeImage(width: 100, height: 100, transparentCorner: false)
        let ctx = try #require(Image.context(width: 100, height: 100))
        ctx.draw(still, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        // CoreGraphics' origin is bottom-left; the box is reported top-left, as the gate's
        // ignore rects are.
        ctx.fill(CGRect(x: 10, y: 80, width: 5, height: 4))
        let moved = try #require(ctx.makeImage())

        #expect(Hardware.motion(still, still) == nil)
        #expect(Hardware.motion(still, moved) == Config.Rect(x: 10, y: 16, width: 5, height: 4))
    }

    /// The Home Screen's icon grid changed between two frames nobody touched. Only the
    /// strip the Dynamic Island draws into counts.
    @Test func idleMotionOutsideTheIslandIsIgnored() throws {
        let still = GateTests.makeImage(width: 100, height: 200, transparentCorner: false)
        func with(_ rect: CGRect) throws -> CGImage {
            let ctx = try #require(Image.context(width: 100, height: 200))
            ctx.draw(still, in: CGRect(x: 0, y: 0, width: 100, height: 200))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect)
            return try #require(ctx.makeImage())
        }
        // Bottom-left origin: y 20 is near the bottom of the screen, y 195 the top.
        #expect(Hardware.islandMotion(still, try with(CGRect(x: 10, y: 20, width: 80, height: 100))) == nil)
        #expect(
            Hardware.islandMotion(still, try with(CGRect(x: 40, y: 195, width: 20, height: 3)))
                == Config.Rect(x: 40, y: 2, width: 20, height: 3))
    }

    /// The Home Screen's clock ticked over between the two idle frames: the top-left
    /// corner changing is not the island.
    @Test func theStatusBarClockIsNotTheIsland() throws {
        let still = GateTests.makeImage(width: 100, height: 200, transparentCorner: false)
        let ctx = try #require(Image.context(width: 100, height: 200))
        ctx.draw(still, in: CGRect(x: 0, y: 0, width: 100, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 5, y: 194, width: 12, height: 4))  // top-left: the clock
        ctx.fill(CGRect(x: 85, y: 194, width: 10, height: 4))  // top-right: the battery
        #expect(Hardware.islandMotion(still, try #require(ctx.makeImage())) == nil)
    }

    /// In landscape the island is on whichever short side the device was turned towards.
    @Test func landscapeWatchesBothShortSides() {
        let regions = Hardware.islandRegions(width: 2868, height: 1320)
        #expect(regions.count == 2)
        #expect(regions[0].x == 0)
        #expect(regions[1].x + regions[1].width == 2868)
        #expect(Hardware.islandRegions(width: 1320, height: 2868).map(\.y) == [0])
    }

    @Test func theCoreDeviceIdentifierIsReadFromTheListing() {
        var listing = Self.listing
        var result = listing["result"] as! [String: Any]
        var rows = result["devices"] as! [[String: Any]]
        rows[2]["identifier"] = "DAC8"
        result["devices"] = rows
        listing["result"] = result
        #expect(Hardware.devices(in: listing).first?.identifier == "DAC8")
    }

    // MARK: - Config

    @Test func aHardwareDeviceResolves() throws {
        let config = try Self.config(device: #""hardware": "Olivier’s iPhone""#)
        let device = try #require(config.resolvedDevices().first)
        #expect(device.hardware == "Olivier’s iPhone")
        #expect(device.simulator == nil)
    }

    @Test func bothTargetsAreRefused() {
        #expect(throws: AppShotError.self) {
            try Self.config(
                device: #""simulator": "iPhone 17 Pro Max", "hardware": "Phone""#
            ).resolvedDevices()
        }
    }

    @Test func neitherTargetIsRefused() {
        #expect(throws: AppShotError.self) {
            try Self.config(device: #""runtime": "iOS 27.0""#).resolvedDevices()
        }
    }

    // MARK: - Helpers

    static func config(device fields: String) throws -> Config {
        let json = DeviceTests.iosJSON.replacingOccurrences(
            of: """
                    { "id": "iphone", "simulator": "iPhone 17 Pro Max",
                """,
            with: """
                    { "id": "iphone", \(fields),
                """)
        precondition(json != DeviceTests.iosJSON, "the fixture changed shape")
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    static func resolvedDevice() -> Config.ResolvedDevice {
        try! config(device: #""hardware": "Phone""#).resolvedDevices()[0]
    }

    static func shot(_ name: String, _ appearance: String) -> Capture.Shot {
        Capture.Shot(
            name: name, appearance: appearance,
            url: URL(fileURLWithPath: "/tmp/\(name)~\(appearance).png"),
            size: Config.Size(width: 40, height: 40), settled: true,
            timings: Capture.Timings(
                launch: 0, window: 0, ready: 0, floor: 0, lockWait: 0, poll: 0, frames: 2,
                encode: 0, teardown: 0))
    }

    static func app(platform: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appending(path: "appshot-hw-\(UUID().uuidString)/App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "io.example.App", "DTPlatformName": platform,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        return app
    }
}
