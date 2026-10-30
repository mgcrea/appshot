import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The simulator driver's argv, asserted as values.
///
/// The whole point of `Simulator.Command` being a pure value: every one of these is
/// otherwise only observable by booting a device, which costs ~30s and a working Xcode.
/// A wrong flag here is a 30-second round trip to discover and, in the `--mask` case,
/// not discoverable at all until the composites come out square.
struct SimulatorTests {
    static let udid = "246D0326-FC34-4885-A0CF-D93432A08EEC"

    // MARK: - Screenshot

    /// `--mask=alpha` is what gives the capture the device's real rounded corners.
    /// Without it simctl returns a hard opaque rectangle, the compositor has no alpha
    /// to rely on, and the store image is a square screenshot on a rounded shadow.
    @Test func screenshotAsksForAlphaAndAPath() {
        let argv = Simulator.Command.screenshot(Self.udid, to: "/tmp/f.png").argv

        #expect(argv.contains("--mask=alpha"))
        #expect(argv.contains("--type=png"))
        #expect(argv.last == "/tmp/f.png")
    }

    /// simctl documents `-` as stdout and then writes a file literally named `-`.
    /// Measured, not assumed — so the driver must always pass a real path.
    @Test func screenshotNeverWritesToStdout() {
        let argv = Simulator.Command.screenshot(Self.udid, to: "/tmp/f.png").argv
        #expect(!argv.contains("-"))
    }

    /// Every simulator frame goes through one scratch path, so an image loaded from it
    /// must not change when the next frame overwrites the file. A lazily decoded one
    /// did: the `before` frame decoded as the app's screen, and the run failed with
    /// "the app never appeared" while the app was on screen the whole time.
    @Test func aLoadedFrameSurvivesTheNextOneOverwritingItsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "appshot-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "frame.png")

        let springBoard = GateTests.makeImage(rgb: (10, 20, 30), transparentCorner: false)
        let app = GateTests.makeImage(rgb: (200, 210, 220), transparentCorner: false)
        try Image.write(springBoard, to: path)
        let before = try Image.load(path)
        try Image.write(app, to: path)
        let now = try Image.load(path)

        #expect(!Capture.isStill(before, now))
    }

    // MARK: - Launch

    /// Without --terminate-running-process the app is already up from the previous
    /// stage, so the new stage argument is ignored and the same screen is photographed
    /// twice — which the duplicate check would catch, but only after a full run.
    @Test func launchRelaunchesAndPassesStageArguments() {
        let argv = Simulator.Command.launch(
            Self.udid, bundleID: "com.example.App",
            args: ["-ScreenshotStage", "home", "-ScreenshotAppearance", "dark"]
        ).argv

        #expect(argv.contains("--terminate-running-process"))
        // Order matters: everything after the bundle id is the app's argv.
        let bundleIndex = argv.firstIndex(of: "com.example.App")
        let stageIndex = argv.firstIndex(of: "-ScreenshotStage")
        #expect(bundleIndex != nil && stageIndex != nil)
        #expect(bundleIndex! < stageIndex!)
        #expect(argv.suffix(4) == ["-ScreenshotStage", "home", "-ScreenshotAppearance", "dark"])
    }

    // MARK: - Determinism knobs

    /// Apple's marketing time, and the plain form rather than the ISO one: the ISO form
    /// shifts the clock by the host timezone (09:41Z renders as 10:41 in Paris), which
    /// would make goldens machine-dependent.
    @Test func statusBarPinsTheAppleMarketingBar() {
        let argv = Simulator.Command.statusBar(Self.udid, time: Simulator.statusBarTime).argv

        #expect(Simulator.statusBarTime == "9:41")
        #expect(argv.contains("override"))
        #expect(zip(argv, argv.dropFirst()).contains { $0 == "--time" && $1 == "9:41" })
        #expect(zip(argv, argv.dropFirst()).contains { $0 == "--batteryState" && $1 == "charged" })
        #expect(zip(argv, argv.dropFirst()).contains { $0 == "--wifiBars" && $1 == "3" })
        // No ISO date: it does not pin the iPad's date anyway, and it moves the clock.
        #expect(!argv.contains { $0.contains("T09:41") })
    }

    /// `boot` returns ~0.7s in while the device stays uninstallable for ~29s. The `-b`
    /// is what turns that race into a wait.
    @Test func bootStatusWaits() {
        #expect(Simulator.Command.bootStatus(Self.udid).argv.contains("-b"))
    }

    @Test func appearanceAndContentSizeGoThroughSimctlUI() {
        #expect(
            Simulator.Command.ui(Self.udid, key: "appearance", value: "dark").argv
                == ["simctl", "ui", Self.udid, "appearance", "dark"])
        #expect(
            Simulator.Command.ui(Self.udid, key: "content_size", value: "medium").argv
                == ["simctl", "ui", Self.udid, "content_size", "medium"])
    }

    @Test func listAsksForJSON() {
        #expect(Simulator.Command.list.argv.contains("-j"))
    }

    // MARK: - Runtime selection

    /// Newest by version components, not lexicographically — "26.10" must beat "26.5".
    @Test func theNewestRuntimeIsChosenNumerically() throws {
        let available = Simulator.Available(
            types: [
                Simulator.DeviceType(
                    name: "iPhone 17 Pro Max", identifier: "…SimDeviceType.iPhone-17-Pro-Max")
            ],
            runtimes: [
                Simulator.Runtime(
                    name: "iOS 26.5", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                    version: "26.5", isAvailable: true),
                Simulator.Runtime(
                    name: "iOS 26.10", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-10",
                    version: "26.10", isAvailable: true),
            ],
            devices: [:])

        let resolved = try available.resolve(type: "iPhone 17 Pro Max", runtime: nil)
        #expect(resolved.runtime.version == "26.10")
    }

    /// A tvOS runtime is not a fallback for an iOS app.
    @Test func nonIOSRuntimesAreNeverChosen() throws {
        let available = Simulator.Available(
            types: [Simulator.DeviceType(name: "iPhone 17", identifier: "type.iPhone-17")],
            runtimes: [
                Simulator.Runtime(
                    name: "tvOS 26.5", identifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-5",
                    version: "26.5", isAvailable: true)
            ],
            devices: [:])

        #expect(throws: AppShotError.self) {
            try available.resolve(type: "iPhone 17", runtime: nil)
        }
    }

    @Test func anUnknownDeviceTypeIsNamed() throws {
        let available = Simulator.Available(
            types: [Simulator.DeviceType(name: "iPhone 17", identifier: "type.iPhone-17")],
            runtimes: [
                Simulator.Runtime(
                    name: "iOS 26.5", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                    version: "26.5", isAvailable: true)
            ],
            devices: [:])

        #expect(throws: AppShotError.self) {
            try available.resolve(type: "iPhone 99 Ultra", runtime: nil)
        }
    }

    /// An unavailable runtime (a stale Xcode leftover) must not be picked, or the run
    /// fails at `create` with a much less specific error.
    @Test func unavailableRuntimesAreSkipped() throws {
        let available = Simulator.Available(
            types: [Simulator.DeviceType(name: "iPhone 17", identifier: "type.iPhone-17")],
            runtimes: [
                Simulator.Runtime(
                    name: "iOS 26.3", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
                    version: "26.3", isAvailable: false),
                Simulator.Runtime(
                    name: "iOS 26.5", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                    version: "26.5", isAvailable: true),
            ],
            devices: [:])

        #expect(try available.resolve(type: "iPhone 17", runtime: nil).runtime.version == "26.5")
    }

    // MARK: - Runtime support for the device type

    static let proMax = Simulator.DeviceType(
        name: "iPhone 17 Pro Max",
        identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max")
    static let duo = Simulator.DeviceType(
        name: "iPhone Duo", identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")

    static func runtime(
        _ version: String, supports: [Simulator.DeviceType]?
    ) -> Simulator.Runtime {
        Simulator.Runtime(
            name: "iOS \(version)",
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-"
                + version.replacingOccurrences(of: ".", with: "-"),
            version: version, isAvailable: true, supportedDeviceTypes: supports)
    }

    /// Xcode 27.1 on this Mac: a 27.1 runtime that runs the iPhone Duo and nothing else,
    /// beside the 27.0 that runs the rest of the lineup. Newest is not "runs my device".
    static let xcode271 = Simulator.Available(
        types: [proMax, duo],
        runtimes: [
            runtime("27.0", supports: [proMax]),
            runtime("27.1", supports: [duo]),
        ],
        devices: [:])

    @Test func runtimesDecodeTheirSupportedDeviceTypes() throws {
        let json = """
            {"name": "iOS 27.1", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
             "version": "27.1", "isAvailable": true,
             "supportedDeviceTypes": [{"bundlePath": "/x", "name": "iPhone Duo",
               "productFamily": "iPhone",
               "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]}
            """
        let runtime = try JSONDecoder().decode(Simulator.Runtime.self, from: Data(json.utf8))
        #expect(runtime.supportedDeviceTypes?.map(\.identifier) == [Self.duo.identifier])
    }

    @Test func aNewerRuntimeThatDoesNotRunTheTypeIsPassedOver() throws {
        let resolved = try Self.xcode271.resolve(type: "iPhone 17 Pro Max", runtime: nil)
        #expect(resolved.runtime.version == "27.0")
    }

    @Test func theNewestRuntimeIsKeptWhenItRunsTheType() throws {
        let available = Simulator.Available(
            types: [Self.proMax],
            runtimes: [
                Self.runtime("27.0", supports: [Self.proMax]),
                Self.runtime("27.1", supports: [Self.proMax, Self.duo]),
            ],
            devices: [:])
        #expect(try available.resolve(type: "iPhone 17 Pro Max", runtime: nil).runtime.version == "27.1")
    }

    /// Older simctl output has no `supportedDeviceTypes`; such a runtime is taken to run
    /// everything, which is how it was chosen before the list existed.
    @Test func aRuntimeThatListsNoSupportIsAssumedToRunEverything() throws {
        let available = Simulator.Available(
            types: [Self.proMax],
            runtimes: [
                Self.runtime("26.5", supports: [Self.proMax]),
                Self.runtime("26.6", supports: nil),
            ],
            devices: [:])
        #expect(try available.resolve(type: "iPhone 17 Pro Max", runtime: nil).runtime.version == "26.6")
    }

    @Test func noRuntimeRunningTheTypeNamesItAndWhatIsInstalled() {
        let available = Simulator.Available(
            types: [Self.proMax, Self.duo],
            runtimes: [Self.runtime("27.1", supports: [Self.duo])],
            devices: [:])
        #expect {
            try available.resolve(type: "iPhone 17 Pro Max", runtime: nil)
        } throws: { error in
            let message = "\(error)"
            return message.contains("iPhone 17 Pro Max") && message.contains("iOS 27.1")
                && message.contains("iPhone Duo")
        }
    }

    /// A pinned runtime that cannot run the type fails here, naming both, instead of at
    /// `simctl create` with "Incompatible device" (code 403).
    @Test func aPinnedRuntimeThatDoesNotRunTheTypeNamesBoth() {
        #expect {
            try Self.xcode271.resolve(type: "iPhone 17 Pro Max", runtime: "27.1")
        } throws: { error in
            let message = "\(error)"
            return message.contains("iPhone 17 Pro Max") && message.contains("iOS 27.1")
        }
    }

    /// What `doctor` prints beside the runtime it picked: the newer ones it passed over.
    @Test func theNewerRuntimesPassedOverAreNamed() throws {
        let resolved = try Self.xcode271.resolve(type: "iPhone 17 Pro Max", runtime: nil)
        let skipped = Self.xcode271.skipped(newerThan: resolved.runtime, for: resolved.type)
        #expect(skipped.map(\.version) == ["27.1"])
    }

    /// A long support list is shortened in the error, not dumped whole.
    @Test func aLongSupportListIsShortened() {
        let many = (1...40).map {
            Simulator.DeviceType(name: "Phone \($0)", identifier: "type.Phone-\($0)")
        }
        let available = Simulator.Available(
            types: [Self.proMax] + many, runtimes: [Self.runtime("27.0", supports: many)],
            devices: [:])
        #expect {
            try available.resolve(type: "iPhone 17 Pro Max", runtime: nil)
        } throws: { error in
            let message = "\(error)"
            return message.contains("Phone 1,") && !message.contains("Phone 40")
                && message.contains("more")
        }
    }

    // MARK: - The safe area

    /// The keys the insets are read from, as each device type's capabilities.plist has
    /// them. `HomeButtonType` 2 is the home indicator, 1 a physical button.
    static func capabilities(island: Bool?, homeButton: Int, scale: Double) -> [String: Any] {
        var capabilities: [String: Any] = [
            "HomeButtonType": homeButton,
            "ScreenDimensionsCapability": ["main-screen-scale": scale],
        ]
        capabilities["DeviceSupportsDynamicIsland"] = island
        return capabilities
    }

    @Test func aDynamicIslandPhoneSkipsItsStatusBarAndHomeIndicator() {
        let area = Simulator.safeArea(
            capabilities: Self.capabilities(island: true, homeButton: 2, scale: 3),
            family: "iPhone")
        #expect(area == Capture.SafeArea(top: 186, bottom: 102))
    }

    @Test func anIPadSkipsItsThinnerBars() {
        let area = Simulator.safeArea(
            capabilities: Self.capabilities(island: false, homeButton: 2, scale: 2),
            family: "iPad")
        #expect(area == Capture.SafeArea(top: 48, bottom: 40))
    }

    @Test func aHomeButtonPhoneHasOnlyAStatusBar() {
        let area = Simulator.safeArea(
            capabilities: Self.capabilities(island: nil, homeButton: 1, scale: 2),
            family: "iPhone")
        #expect(area == Capture.SafeArea(top: 40, bottom: 0))
    }

    @Test func aDeviceTypeDecodesWhereItsProfileLives() throws {
        let json = """
            {"name": "iPhone 17 Pro Max", "productFamily": "iPhone",
             "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
             "bundlePath": "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17 Pro Max.simdevicetype"}
            """
        let type = try JSONDecoder().decode(Simulator.DeviceType.self, from: Data(json.utf8))
        #expect(type.productFamily == "iPhone")
        #expect(type.bundlePath?.hasSuffix("iPhone 17 Pro Max.simdevicetype") == true)
    }

    /// Out of settle time on a blank window: fail that screen by name rather than write
    /// the blank PNG, which the gate would then compare as if it were a screenshot.
    @Test func aScreenThatNeverDrewFailsByName() {
        #expect {
            try Simulator.requireDrawn(
                CaptureSafeAreaTests.proMax(page: nil), within: CaptureSafeAreaTests.safeArea,
                screen: "person~light", device: "appshot-iphone", seconds: 8)
        } throws: { error in
            "\(error)".contains("person~light") && "\(error)".contains("appshot-iphone")
        }
    }

    @Test func aDrawnScreenIsKept() throws {
        try Simulator.requireDrawn(
            CaptureSafeAreaTests.proMax(page: 1), within: CaptureSafeAreaTests.safeArea,
            screen: "person~light", device: "appshot-iphone", seconds: 8)
    }

    // MARK: - Is the app on screen

    static func solid(_ shade: Double) -> CGImage {
        let ctx = Image.context(width: 40, height: 80)!
        ctx.setFillColor(CGColor(srgbRed: shade, green: shade, blue: shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        return ctx.makeImage()!
    }

    /// The case that shipped a home screen: `before` was the previous screen's app still
    /// animating out, the home screen differed from it, and that counted as "the app
    /// appeared".
    @Test func theHomeScreenIsNeverTheAppEvenWhenItDiffersFromBefore() {
        let outgoing = Self.solid(0.2)
        let home = Self.solid(0.8)
        #expect(!Simulator.showsApp(home, before: outgoing, home: home))
    }

    @Test func theAppIsOnScreenWhenItIsNeitherHomeNorBefore() {
        #expect(Simulator.showsApp(Self.solid(0.5), before: Self.solid(0.2), home: Self.solid(0.8)))
    }

    @Test func anUnchangedScreenIsNotYetTheApp() {
        let before = Self.solid(0.2)
        #expect(!Simulator.showsApp(Self.solid(0.2), before: before, home: Self.solid(0.8)))
    }

    /// At the shutter there is no `before`; only the home-screen check applies.
    @Test func atTheShutterOnlyTheHomeScreenFails() {
        let home = Self.solid(0.8)
        #expect(!Simulator.showsApp(home, before: nil, home: home))
        #expect(Simulator.showsApp(Self.solid(0.5), before: nil, home: home))
    }
}
