import CoreGraphics
import Foundation

/// The iOS / iPadOS capture driver: boot a simulator, install the app, relaunch it
/// staged onto each screen, photograph the display, repeat.
///
/// The same staged-relaunch model as the Mac driver, and deliberately not an XCUITest:
/// a stage argument cannot be broken by a renamed label or a moved view, and the
/// screens stay reachable from a cold launch. `appshot extract` remains the route for
/// screens that genuinely need in-session navigation.
///
/// ## What it reuses, and why that was free
///
/// Everything after "a frame arrived" is shared with macOS: `Capture.settledImage` is
/// generic over an `async` frame source, so the settle floor, the quiescence poll, the
/// two-consecutive-match rule and the `Timings` breakdown are the *same code* reaching
/// the same verdicts. Only launch, teardown and the frame source are new.
///
/// ## Where it deliberately differs
///
/// - **The lock is per-device, not machine-wide.** The Mac lock is global because
///   activation is global — two runs steal focus from each other. A headless simulator
///   steals nothing, so two devices can be captured at once, and a capture run does not
///   take over the developer's machine. That is also why this can run in CI.
/// - **Identity is device + bundle id, not a pid.** The Mac driver matches strictly on
///   the pid it launched, because the developer's own copy of the app is usually running
///   under the same name. Here the driver owns a dedicated `appshot-<slug>` device that
///   the developer's copy is never on, which makes the question moot.
///
/// ## Measured facts this driver is built around (Xcode / iOS 26.5)
///
/// - `simctl boot` returns in ~0.7s; the device is not installable for ~29s. Hence the
///   mandatory `bootstatus -b`.
/// - `simctl io … screenshot -` **does not write to stdout** despite `--help` saying so;
///   it creates a file named `-`. Frames therefore go through a temp file.
/// - A frame costs ~0.40s, against ~90ms for ScreenCaptureKit.
/// - `--mask=alpha` yields the device's real rounded-corner alpha (0.878% of an iPhone
///   canvas, 0.064% of an iPad's). Without it captures are hard rectangles, and the
///   compositor would place a square image on a rounded shadow.
public enum Simulator {

    // MARK: - Commands

    /// Every simctl invocation this driver makes, as a value.
    ///
    /// Pure argv, so the wiring can be asserted in a unit test with no simulator, no
    /// Xcode and no window server — the same reason `Run.plan` is a pure value. Getting
    /// one of these wrong is otherwise a 30-second boot away from being discovered.
    public enum Command: Sendable, Equatable {
        case list
        case create(name: String, type: String, runtime: String)
        case boot(String)
        case bootStatus(String)
        case erase(String)
        case shutdown(String)
        case delete(String)
        case statusBar(String, time: String)
        case clearStatusBar(String)
        case ui(String, key: String, value: String)
        case install(String, app: String)
        case launch(String, bundleID: String, args: [String])
        case terminate(String, bundleID: String)
        case screenshot(String, to: String)

        public var argv: [String] {
            switch self {
            case .list:
                return ["simctl", "list", "-j", "devicetypes", "runtimes", "devices"]
            case .create(let name, let type, let runtime):
                return ["simctl", "create", name, type, runtime]
            case .boot(let udid):
                return ["simctl", "boot", udid]
            case .bootStatus(let udid):
                // -b waits for the device to actually be ready. Without it, install
                // races the boot and fails as "Unable to launch" on a slow machine.
                return ["simctl", "bootstatus", udid, "-b"]
            case .erase(let udid):
                return ["simctl", "erase", udid]
            case .shutdown(let udid):
                return ["simctl", "shutdown", udid]
            case .delete(let udid):
                return ["simctl", "delete", udid]

            case .statusBar(let udid, let time):
                // Apple's own marketing shows 9:41, full bars, charged. A real
                // simulator shows the host clock, which changes between captures and
                // defeats a golden gate on its own.
                //
                // `--time` takes the plain form on purpose. Its ISO form (which only
                // parses with fractional seconds, `2026-01-09T09:41:00.000Z`) is
                // *worse*: it shifts the rendered clock by the host timezone, so two
                // machines in different timezones produce different goldens — and it
                // still does not pin the iPad's date. See `Config.Device.ignore`.
                return [
                    "simctl", "status_bar", udid, "override",
                    "--time", time,
                    "--dataNetwork", "wifi",
                    "--wifiMode", "active", "--wifiBars", "3",
                    "--cellularMode", "active", "--cellularBars", "4",
                    "--batteryState", "charged", "--batteryLevel", "100",
                ]
            case .clearStatusBar(let udid):
                return ["simctl", "status_bar", udid, "clear"]
            case .ui(let udid, let key, let value):
                return ["simctl", "ui", udid, key, value]
            case .install(let udid, let app):
                return ["simctl", "install", udid, app]

            case .launch(let udid, let bundleID, let args):
                // --terminate-running-process is what makes this a *staged relaunch*
                // rather than a no-op on the second screen: the app is already running
                // from the previous stage and would otherwise be brought forward
                // unchanged, with the new stage argument silently ignored.
                //
                // Everything after the bundle id reaches the app as argv, which lands
                // in NSArgumentDomain exactly as `open --args` does on macOS — so the
                // app-side demo harness is identical on both platforms.
                return ["simctl", "launch", "--terminate-running-process", udid, bundleID]
                    + args
            case .terminate(let udid, let bundleID):
                return ["simctl", "terminate", udid, bundleID]

            case .screenshot(let udid, let path):
                // --mask=alpha gives the device's real rounded corners as alpha. The
                // default (and `ignored`, and `black`) return a hard opaque rectangle.
                //
                // The path is a real file because `-` does not work: simctl documents
                // it as stdout and then writes a file literally named `-`.
                return ["simctl", "io", udid, "screenshot", "--type=png", "--mask=alpha", path]
            }
        }
    }

    /// Apple's marketing time, and the default this driver pins.
    public static let statusBarTime = "9:41"

    // MARK: - Running simctl

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(_ command: Command, timeout: Double? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = command.argv

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw AppShotError.simctlFailed(
                command: command.argv.joined(separator: " "), reason: "\(error)")
        }

        // Read before waiting. A `simctl list -j` of a machine with many runtimes
        // overflows the 64KB pipe buffer, and waiting first deadlocks: simctl blocks
        // writing, we block waiting for it to exit.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Run and throw unless it exited cleanly.
    @discardableResult
    static func require(_ command: Command) throws -> Output {
        let result = try run(command)
        guard result.status == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppShotError.simctlFailed(
                command: command.argv.dropFirst().joined(separator: " "),
                reason: reason.isEmpty ? "exit \(result.status)" : reason)
        }
        return result
    }

    // MARK: - Inventory

    public struct DeviceType: Decodable, Sendable {
        public let name: String
        public let identifier: String
    }

    public struct Runtime: Decodable, Sendable {
        public let name: String
        public let identifier: String
        public let version: String
        public let isAvailable: Bool?

        /// "26.5" → [26, 5], for picking the newest without lexicographic surprises
        /// ("26.10" must beat "26.5").
        var ordering: [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
        var isIOS: Bool { identifier.contains("SimRuntime.iOS") }
    }

    public struct Existing: Decodable, Sendable {
        public let udid: String
        public let name: String
        public let state: String
        public let isAvailable: Bool?

        public var isBooted: Bool { state == "Booted" }
    }

    /// What this Mac has installed.
    public struct Available: Sendable {
        public let types: [DeviceType]
        public let runtimes: [Runtime]
        /// Keyed by runtime identifier, as `simctl list -j` reports it.
        public let devices: [String: [Existing]]

        /// Match a device type by name and a runtime by name, or pick the newest iOS
        /// runtime. Both failures name what *is* installed, because the answer to
        /// "iPhone 17 Pro Max not found" is always a list.
        public func resolve(
            type requestedType: String, runtime requestedRuntime: String?
        ) throws -> (type: DeviceType, runtime: Runtime) {
            guard
                let type = types.first(where: {
                    $0.name.compare(requestedType, options: .caseInsensitive) == .orderedSame
                })
            else { throw AppShotError.simulatorTypeNotFound(requestedType) }

            let usable = runtimes.filter { $0.isAvailable != false && $0.isIOS }
            if let requestedRuntime {
                guard
                    let runtime = usable.first(where: {
                        $0.name.compare(requestedRuntime, options: .caseInsensitive)
                            == .orderedSame
                            || $0.identifier == requestedRuntime
                            || $0.version == requestedRuntime
                    })
                else { throw AppShotError.simulatorRuntimeNotFound(requestedRuntime) }
                return (type, runtime)
            }

            guard
                let newest = usable.max(by: { a, b in
                    a.ordering.lexicographicallyPrecedes(b.ordering)
                })
            else { throw AppShotError.simulatorRuntimeNotFound("any iOS runtime") }
            return (type, newest)
        }
    }

    public static func available() throws -> Available {
        let result = try require(.list)

        struct Listing: Decodable {
            let devicetypes: [DeviceType]
            let runtimes: [Runtime]
            let devices: [String: [Existing]]
        }
        guard
            let data = result.stdout.data(using: .utf8),
            let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else {
            throw AppShotError.simctlFailed(
                command: "list", reason: "could not parse the device list as JSON")
        }
        return Available(
            types: listing.devicetypes, runtimes: listing.runtimes, devices: listing.devices)
    }

    // MARK: - The dedicated device

    /// A simulator this driver owns, named `appshot-<slug>`.
    ///
    /// Never the developer's own simulators. This driver erases state, pins the status
    /// bar and force-quits apps; doing that to a device someone is using would be the
    /// simulator equivalent of photographing their real data — and `--erase` would throw
    /// away whatever they had set up. Creating our own costs one boot, once.
    public struct Device: Sendable {
        public let udid: String
        public let name: String
        public let runtime: String
    }

    public static func device(
        for resolved: Config.ResolvedDevice, erase: Bool
    ) throws -> Device {
        guard let simulator = resolved.simulator else {
            throw AppShotError.noDevices
        }
        let inventory = try available()
        let (type, runtime) = try inventory.resolve(
            type: simulator, runtime: resolved.runtime)

        let name = "appshot-\(resolved.slug ?? "device")"
        let existing = inventory.devices[runtime.identifier]?
            .first { $0.name == name && $0.isAvailable != false }

        let udid: String
        if let existing {
            udid = existing.udid
            if erase {
                // Only meaningful on a shut-down device, and this is the strongest
                // determinism lever there is: no prior container, no granted
                // permissions, no leftover onboarding, and it clears the simulator's
                // own "slow animations" setting.
                try? require(.shutdown(udid))
                try require(.erase(udid))
            }
        } else {
            udid = try require(.create(name: name, type: type.identifier, runtime: runtime.identifier))
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else {
                throw AppShotError.simctlFailed(command: "create", reason: "no udid returned")
            }
        }

        return Device(udid: udid, name: name, runtime: runtime.name)
    }

    /// Boot if needed, then wait until the device can actually accept an install.
    public static func boot(_ device: Device) throws {
        let listed = try available().devices.values.flatMap { $0 }
            .first { $0.udid == device.udid }
        if listed?.isBooted != true {
            // Already-booted is not an error worth failing on: a previous run left it
            // up, which is the fast path this driver wants.
            try? require(.boot(device.udid))
        }
        let status = try run(.bootStatus(device.udid))
        guard status.status == 0 else {
            throw AppShotError.deviceNeverBooted(device.name)
        }
    }

    // MARK: - The app bundle

    /// Read the bundle id, and refuse a device build before simctl does it less clearly.
    public static func bundleID(of app: URL) throws -> String {
        let plist = app.appending(path: "Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { throw AppShotError.bundleIDUnreadable(app) }

        // A device build installs onto a simulator with an error that names neither the
        // app nor the reason. The platform is right there in the plist.
        if let platform = info["DTPlatformName"] as? String,
            platform.lowercased() == "iphoneos"
        {
            throw AppShotError.notASimulatorBuild(app, platform: platform)
        }
        return identifier
    }

    // MARK: - Options

    public struct Options: Sendable {
        public var app: URL
        public var outDir: URL
        public var device: Config.ResolvedDevice
        public var screens: [Capture.Screen]
        public var appearances: [String]
        public var extraArgs: [String]
        public var stageArg: String
        public var appearanceArg: String
        public var settle: Double
        public var settleMax: Double
        /// `simctl erase` before booting. Slow (a full device reset), so it is opt-in
        /// and happens once per device per run rather than per screen.
        public var erase: Bool
        /// Pin Dynamic Type, which otherwise follows whatever the device was left at.
        public var contentSize: String

        public init(
            app: URL,
            outDir: URL,
            device: Config.ResolvedDevice,
            screens: [Capture.Screen],
            appearances: [String] = ["dark", "light"],
            extraArgs: [String] = [],
            stageArg: String = "-ScreenshotStage",
            appearanceArg: String = "-ScreenshotAppearance",
            settle: Double = Capture.defaultSettle,
            settleMax: Double = Capture.defaultSettleMax,
            erase: Bool = false,
            contentSize: String = "medium"
        ) {
            self.app = app
            self.outDir = outDir
            self.device = device
            self.screens = screens
            self.appearances = appearances
            self.extraArgs = extraArgs
            self.stageArg = stageArg
            self.appearanceArg = appearanceArg
            self.settle = settle
            self.settleMax = settleMax
            self.erase = erase
            self.contentSize = contentSize
        }
    }

    // MARK: - Run

    public static func run(
        _ options: Options,
        onWait: (CaptureLock.Held, Double) -> Void = { _, _ in },
        progress: (Capture.Shot) -> Void = { _ in }
    ) async throws -> [Capture.Shot] {
        guard FileManager.default.fileExists(atPath: options.app.path) else {
            throw AppShotError.appNotFound(options.app)
        }
        let bundleID = try bundleID(of: options.app)

        let device = try device(for: options.device, erase: options.erase)
        try boot(device)

        // Per-device, not machine-wide: see the type doc. Two devices may be captured
        // concurrently because neither steals anything from the other.
        let clock = ContinuousClock()
        let lockStart = clock.now
        let root = CaptureLock.defaultRoot.appending(path: "appshot-sim-\(device.udid)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try await CaptureLock.acquire(
            CaptureLock.Holder.current(
                app: device.name, appPath: options.app.path,
                shots: options.screens.count * options.appearances.count),
            root: root,
            onWait: onWait)
        defer { lock.release() }
        let lockWait = seconds(since: lockStart, clock)

        try require(.install(device.udid, app: options.app.path))
        try require(.statusBar(device.udid, time: statusBarTime))
        try? require(.ui(device.udid, key: "content_size", value: options.contentSize))
        // Leave the override in place on the way out only if it was ours to set — the
        // device is ours, so clearing it keeps a re-used device from carrying state
        // between runs of different projects.
        defer { try? require(.clearStatusBar(device.udid)) }

        try Compose.wipePNGs(in: options.outDir)

        var shots: [Capture.Shot] = []
        for appearance in options.appearances {
            // Through simctl rather than only the launch argument, because it also
            // moves system UI — the keyboard, share sheets, alerts — which does appear
            // in captures. The launch argument is passed too, so an app that forces its
            // own appearance still agrees with the system.
            try? require(.ui(device.udid, key: "appearance", value: appearance))

            for screen in options.screens {
                let shot = try await capture(
                    screen: screen,
                    appearance: appearance,
                    device: device,
                    bundleID: bundleID,
                    lockWait: shots.isEmpty ? lockWait : 0,
                    options: options)
                shots.append(shot)
                progress(shot)
            }
        }
        return shots
    }

    private static func capture(
        screen: Capture.Screen,
        appearance: String,
        device: Device,
        bundleID: String,
        lockWait: Double,
        options: Options
    ) async throws -> Capture.Shot {
        let label = "\(screen.name)~\(appearance)"
        let clock = ContinuousClock()

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-sim-\(device.udid)-\(label).png")
        defer { try? FileManager.default.removeItem(at: scratch) }

        func frame() throws -> CGImage {
            try require(.screenshot(device.udid, to: scratch.path))
            return try Image.load(scratch)
        }

        // What the screen looks like *before* the app is on it. The Mac driver waits
        // for a window to exist; there is no such thing here — the display always has
        // something on it — so "the app appeared" is "the screen stopped looking like
        // SpringBoard".
        let before = try frame()

        let launchStart = clock.now
        var args = [
            options.stageArg, screen.stage,
            options.appearanceArg, appearance,
        ]
        args.append(contentsOf: options.extraArgs)
        try require(.launch(device.udid, bundleID: bundleID, args: args))
        let launched = seconds(since: launchStart, clock)

        do {
            let appearStart = clock.now
            guard try await waitForApp(differingFrom: before, frame: frame) else {
                throw AppShotError.appNeverAppeared(screen: label, device: device.name)
            }
            let appeared = seconds(since: appearStart, clock)

            let floor = screen.settle ?? options.settle
            let floorStart = clock.now
            try await Task.sleep(for: .seconds(floor))
            let floored = seconds(since: floorStart, clock)

            var frames = 0
            let pollStart = clock.now
            let (image, settled) = try await Capture.settledImage(
                Capture.quiescence(floor: floor, ceiling: options.settleMax)
            ) {
                frames += 1
                return try frame()
            }
            let polled = seconds(since: pollStart, clock)

            let encodeStart = clock.now
            let out = options.outDir.appending(path: "\(label).png")
            try Image.write(image, to: out)
            let encoded = seconds(since: encodeStart, clock)

            let teardownStart = clock.now
            try? require(.terminate(device.udid, bundleID: bundleID))
            let teardown = seconds(since: teardownStart, clock)

            return Capture.Shot(
                name: screen.name,
                appearance: appearance,
                url: out,
                size: Config.Size(width: image.width, height: image.height),
                settled: settled,
                timings: Capture.Timings(
                    launch: launched, window: appeared, ready: 0, floor: floored,
                    lockWait: lockWait, poll: polled, frames: frames, encode: encoded,
                    teardown: teardown))
        } catch {
            // Never leave the app running with its screenshot arguments: the next
            // screen's launch would inherit a foreground instance and, worse, a later
            // run would photograph it.
            try? require(.terminate(device.udid, bundleID: bundleID))
            throw error
        }
    }

    /// Poll until the screen stops looking like it did before the launch.
    ///
    /// Reuses the gate's own notion of "changed" rather than inventing a second one, so
    /// "the app appeared" and "the screenshot drifted" cannot disagree about what a
    /// difference is.
    private static func waitForApp(
        differingFrom before: CGImage,
        frame: () throws -> CGImage
    ) async throws -> Bool {
        // 15s at ~0.4s a frame. The launch itself is fast; what this covers is a first
        // screen that takes a while to draw anything at all.
        for _ in 0..<40 {
            if !Capture.isStill(before, try frame()) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func seconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock)
        -> Double
    {
        let d = clock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
