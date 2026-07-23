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
}
