import CoreGraphics
import Foundation

/// The real-device capture driver: install on a connected iPhone or iPad, relaunch the
/// app staged onto each screen, photograph the display, repeat.
///
/// The `Simulator` driver's model on `devicectl` instead of `simctl`, for an app the
/// simulator cannot render at all. The case that forced it was a Metal 4 canvas: the iOS
/// Simulator SDK ships the MTL4 headers as stubs, so the app compiles its canvas out and
/// every simulator capture is a placeholder. The camera and anything else whose simulator
/// SDK is a stub are the same case.
///
/// ## What it reuses
///
/// Everything after "a frame arrived": `Capture.settledImage`, the quiescence poll and the
/// `Timings` breakdown are the same code the other two drivers use, and so are the gate
/// and the compositor downstream. The captures land in `source/<device>/` exactly as a
/// simulator's do.
///
/// ## What a real device cannot do, and what stands in for it
///
/// - **The status bar cannot be pinned.** There is no `status_bar override` for hardware,
///   so the clock and the battery are live in every frame. The app hides the status bar
///   under the demo flag; appshot tells it which kind of run this is with
///   `-ScreenshotTarget hardware`.
/// - **The appearance cannot be set.** There is no `simctl ui appearance`. The app must
///   apply `-ScreenshotAppearance` itself, and because an app that ignores it produces a
///   plausible light image under a `~dark` name, the run fails when a screen's
///   appearances come back identical (`appearanceIgnored`).
/// - **The orientation is however the device is held.** A phone lying on a desk
///   photographs in landscape. A capture whose orientation disagrees with the canvas fails
///   rather than being rotated: a rotated landscape layout is not a portrait screen.
/// - **The ready file cannot be named absolutely.** devicectl lists a container's
///   contents but never reports where the container is, so the app is told
///   `~/tmp/appshot-ready-<uuid>` and must expand the tilde, which on iOS is its own
///   sandbox (`(path as NSString).expandingTildeInPath`). An absolute path from the other
///   drivers passes through that call unchanged, so one line serves all three.
/// - **No transparent corners.** A device screenshot is an opaque rectangle. The
///   compositor rounds opaque iOS captures to `layout.cornerRadius`, so the store image is
///   right, and the gate's alpha check compares opaque with opaque.
///
/// ## Measured facts this driver is built around (Xcode 27, iOS 27.0, iPhone 17 Pro Max)
///
/// - App arguments go after `--`. devicectl reads `-ScreenshotMode` as a bundle of its own
///   short flags and fails with "The value 'YES' is invalid for '-t <seconds>'". The `--`
///   reaches the app as its first argument, and `NSArgumentDomain` still reads every
///   `-Key value` pair after it.
/// - A frame costs ~0.8s over the tunnel, twice a simulator's, and two consecutive frames
///   of a still screen are byte-identical, so the quiescence poll works unchanged.
/// - Frames are 16-bit RGBA, twice the bytes of an 8-bit capture for nothing a store image
///   shows; they are written at 8 bits.
public enum Hardware {

    // MARK: - Commands

    /// Every devicectl invocation this driver makes, as a value, so the wiring can be
    /// asserted without a device. `run` appends `-q -j <file>` to each.
    public enum Command: Sendable, Equatable {
        case list
        case install(String, app: String)
        case launch(String, bundleID: String, args: [String])
        case terminate(String, pid: Int)
        case screenshot(String, to: String)
        case findFile(String, bundleID: String, directory: String, name: String)

        public var argv: [String] {
            switch self {
            case .list:
                return ["devicectl", "list", "devices"]
            case .install(let udid, let app):
                return ["devicectl", "device", "install", "app", "--device", udid, app]

            case .launch(let udid, let bundleID, let args):
                // --terminate-existing is what makes this a staged relaunch: without it
                // the running instance comes forward with the previous stage.
                //
                // The `--` is not optional. Without it devicectl parses the app's
                // arguments as its own and fails before launching anything.
                return [
                    "devicectl", "device", "process", "launch", "--device", udid,
                    "--terminate-existing", bundleID, "--",
                ] + args
            case .terminate(let udid, let pid):
                return [
                    "devicectl", "device", "process", "terminate", "--device", udid,
                    "--pid", String(pid),
                ]

            case .screenshot(let udid, let path):
                return [
                    "devicectl", "device", "capture", "screenshot", "--device", udid,
                    "--destination", path,
                ]

            case .findFile(let udid, let bundleID, let directory, let name):
                // The ready poll. `--search` filters the listing to the one name, so the
                // answer is "is the list empty", which does not depend on the shape of
                // devicectl's per-file entries.
                return [
                    "devicectl", "device", "info", "files", "--device", udid,
                    "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                    "--subdirectory", directory, "--search", name,
                ]
            }
        }
    }

    /// What the app is told to write, and where the poll then looks for it.
    ///
    /// Relative to the app's home via `~`, because devicectl never reports the
    /// container's absolute path. `tmp`, because iOS may clear it, and a leftover marker
    /// must never be mistaken for a fresh one: each shot gets its own name for the same
    /// reason.
    public struct ReadyMarker: Sendable, Equatable {
        public let name: String

        public init(name: String = "appshot-ready-\(UUID().uuidString)") {
            self.name = name
        }

        public static let directory = "tmp"
        /// The launch argument's value.
        public var argument: String { "~/\(Self.directory)/\(name)" }
    }

    /// Tells the app this is a real device, which is what it keys the status bar and the
    /// appearance on. The simulator driver pins both itself and passes nothing.
    public static let targetArgs = ["-ScreenshotTarget", "hardware"]

    // MARK: - Running devicectl

    struct Output {
        let status: Int32
        let json: [String: Any]?
        let raw: String
        let stderr: String
    }

    /// The argv `run` hands to xcrun: the command plus `-q -j <json>`, placed before any
    /// `--`. After it, the app would receive them as launch arguments and devicectl would
    /// write no JSON, so a launch would lose its pid.
    static func invocation(_ command: Command, json: String) -> [String] {
        var argv = command.argv
        let split = argv.firstIndex(of: "--") ?? argv.endIndex
        argv.insert(contentsOf: ["-q", "-j", json], at: split)
        return argv
    }

    /// Run with `-q -j <tmp>` and hand back the JSON document, which is devicectl's only
    /// stable output: its human-readable text is a table that changes between releases.
    static func run(_ command: Command) throws -> Output {
        let jsonURL = FileManager.default.temporaryDirectory
            .appending(path: "appshot-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = invocation(command, json: jsonURL.path)

        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw AppShotError.devicectlFailed(
                command: command.argv.dropFirst().joined(separator: " "), reason: "\(error)")
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let data = (try? Data(contentsOf: jsonURL)) ?? Data()
        return Output(
            status: process.terminationStatus,
            json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            raw: String(decoding: data, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    @discardableResult
    static func require(_ command: Command) throws -> Output {
        let result = try run(command)
        guard result.status == 0 else {
            throw AppShotError.devicectlFailed(
                command: command.argv.dropFirst().prefix(3).joined(separator: " "),
                reason: failureReason(result))
        }
        return result
    }

    /// devicectl puts the useful sentence in the JSON's error, not on stderr.
    static func failureReason(_ result: Output) -> String {
        if let error = result.json?["error"] as? [String: Any] {
            let user = error["userInfo"] as? [String: Any]
            let description =
                (user?["NSLocalizedDescription"] as? [String: Any])?["string"] as? String
                ?? user?["NSLocalizedDescription"] as? String
            let failure =
                (user?["NSLocalizedFailureReason"] as? [String: Any])?["string"] as? String
                ?? user?["NSLocalizedFailureReason"] as? String
            let parts = [description, failure].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "exit \(result.status)" : stderr
    }

    // MARK: - The device

    /// A paired iPhone or iPad, as devicectl lists it.
    public struct Device: Sendable, Equatable {
        public let udid: String
        /// CoreDevice's own identifier, which is not the UDID; what `devices://` URLs and
        /// the DeviceFS mount are keyed by.
        public var identifier: String? = nil
        public let name: String
        public let model: String
        public let developerMode: String?
        public let pairing: String?

        /// Why a listed device still cannot be driven, or nil when it can.
        public var unusableReason: String? {
            if let pairing, pairing != "paired" {
                return "it is not paired with this Mac (\(pairing))"
            }
            if let developerMode, developerMode != "enabled" {
                return """
                    Developer Mode is \(developerMode) (Settings → Privacy & Security → \
                    Developer Mode)
                    """
            }
            return nil
        }
    }

    /// Every physical iOS or iPadOS device devicectl knows, from its JSON listing.
    ///
    /// Pure, over the decoded document, so the filtering is testable: devicectl lists
    /// simulators and watches in the same array, and a driver that took the first row
    /// would install onto a simulator.
    public static func devices(in listing: [String: Any]) -> [Device] {
        let rows = (listing["result"] as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let hw = row["hardwareProperties"] as? [String: Any] ?? [:]
            let dp = row["deviceProperties"] as? [String: Any] ?? [:]
            let cp = row["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["reality"] as? String == "physical",
                ["iOS", "iPadOS"].contains(hw["platform"] as? String ?? ""),
                let udid = hw["udid"] as? String
            else { return nil }
            return Device(
                udid: udid,
                identifier: row["identifier"] as? String,
                name: dp["name"] as? String ?? udid,
                model: hw["marketingName"] as? String ?? hw["productType"] as? String ?? "",
                developerMode: dp["developerModeStatus"] as? String,
                pairing: cp["pairingState"] as? String)
        }
    }

    public static func available() throws -> [Device] {
        let result = try require(.list)
        return devices(in: result.json ?? [:])
    }

    /// Match by UDID or by name, case-insensitively, since names carry typographic
    /// apostrophes ("Olivier’s iPhone") that nobody types.
    public static func resolve(_ wanted: String, among devices: [Device]) throws -> Device {
        func fold(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        }
        guard
            let device = devices.first(where: {
                $0.udid == wanted || fold($0.name) == fold(wanted)
            })
        else {
            throw AppShotError.hardwareNotFound(
                wanted, connected: devices.map { "\($0.name) (\($0.udid))" })
        }
        if let reason = device.unusableReason {
            throw AppShotError.hardwareUnavailable(device.name, reason: reason)
        }
        return device
    }

    // MARK: - The app bundle

    /// Read the bundle id, and refuse a simulator or Mac build before devicectl does it
    /// less clearly.
    public static func bundleID(of app: URL) throws -> String {
        let plist = app.appending(path: "Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { throw AppShotError.bundleIDUnreadable(app) }

        let platform = (info["DTPlatformName"] as? String)?.lowercased()
        guard platform == nil || platform == "iphoneos" else {
            throw AppShotError.notADeviceBuild(app, platform: platform ?? "unknown")
        }
        return identifier
    }

    // MARK: - Checks a simulator never needed

    /// Portrait against landscape. Only the orientation is compared: a device whose
    /// screen is not exactly the canvas (a 6.3" phone for a 6.9" canvas) composes like a
    /// simulator does, scaled into the frame.
    public static func orientationMatches(_ captured: Config.Size, canvas: Config.Size) -> Bool {
        (captured.width > captured.height) == (canvas.width > canvas.height)
    }

    /// The screens whose appearances all came back as the same picture: the app did not
    /// apply `-ScreenshotAppearance`. Pure over the shots and a loader, so it is testable
    /// without a device.
    public static func appearanceIgnored(
        _ shots: [Capture.Shot], load: (URL) throws -> CGImage = Image.load
    ) throws -> [String] {
        let byScreen = Dictionary(grouping: shots, by: \.name)
        var ignored: [String] = []
        for (name, group) in byScreen where group.count > 1 {
            let images = try group.map { try load($0.url) }
            if images.dropFirst().allSatisfy({ Capture.isStill(images[0], $0) }) {
                ignored.append(name)
            }
        }
        return ignored.sorted()
    }

    /// Where two frames differ, as the smallest rectangle holding every changed pixel, or
    /// nil when they are still by the same measure the settle poll uses.
    ///
    /// For the idle check: a real device carries state no simulator has, and some of it
    /// moves in every frame. The measured case was a Dynamic Island animating a music
    /// waveform, 0.017% of the screen, which is just over the poll's stillness tolerance:
    /// the poll ran to 25 frames, settled on a lucky one, and baked the island into the
    /// store image.
    public static func motion(_ a: CGImage, _ b: CGImage) -> Config.Rect? {
        guard !Capture.isStill(a, b) else { return nil }
        guard a.width == b.width, a.height == b.height,
            let x = Image.pixels(a), let y = Image.pixels(b)
        else { return Config.Rect(x: 0, y: 0, width: b.width, height: b.height) }
        var minX = x.width, minY = x.height, maxX = -1, maxY = -1
        for i in 0..<x.count {
            let p = x[i], q = y[i]
            guard p.r != q.r || p.g != q.g || p.b != q.b || p.a != q.a else { continue }
            let px = i % x.width, py = i / x.width
            minX = min(minX, px); maxX = max(maxX, px)
            minY = min(minY, py); maxY = max(maxY, py)
        }
        guard maxX >= 0 else { return nil }
        return Config.Rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The strips of the screen the Dynamic Island can draw into: the top in portrait,
    /// both short sides in landscape (which one depends on which way the device is
    /// turned). As a fraction of the long edge, generously past the island itself.
    ///
    /// The idle check looks only here, and that is not a shortcut. Measured: a Home Screen
    /// nobody was touching changed over most of its icon grid between two frames, twice,
    /// in boxes of 1218x2535 and 1254x2004. The Home Screen is never in a capture, so
    /// motion there says nothing about the captures; the island draws over the app, and
    /// is the motion that did end up in one.
    ///
    /// Along that edge, only the middle half: the island and a compact live activity's two
    /// halves either side of it sit there, and the status bar's clock and battery do not.
    /// Measured again: a whole edge strip failed a run because the Home Screen's clock
    /// ticked over between the two frames, and the clock is never in a capture, since the
    /// app hides the status bar. The music waveform that started this sat 65-68% of the way
    /// along the edge.
    public static let islandBand = 0.07
    public static let islandSpan = (from: 0.25, to: 0.75)

    public static func islandRegions(width: Int, height: Int) -> [Config.Rect] {
        let band = Int((Double(max(width, height)) * islandBand).rounded(.up))
        func span(_ length: Int) -> (start: Int, length: Int) {
            let start = Int(Double(length) * islandSpan.from)
            return (start, Int(Double(length) * islandSpan.to) - start)
        }
        if height >= width {
            let x = span(width)
            return [Config.Rect(x: x.start, y: 0, width: x.length, height: band)]
        }
        let y = span(height)
        return [
            Config.Rect(x: 0, y: y.start, width: band, height: y.length),
            Config.Rect(x: width - band, y: y.start, width: band, height: y.length),
        ]
    }

    /// Motion inside the island strips only, or nil when they are still.
    public static func islandMotion(_ a: CGImage, _ b: CGImage) -> Config.Rect? {
        for region in islandRegions(width: b.width, height: b.height) {
            let rect = CGRect(
                x: region.x, y: region.y, width: region.width, height: region.height)
            guard let x = a.cropping(to: rect), let y = b.cropping(to: rect) else { continue }
            if let box = motion(x, y) {
                return Config.Rect(
                    x: box.x + region.x, y: box.y + region.y, width: box.width,
                    height: box.height)
            }
        }
        return nil
    }

    /// Redraw a frame at 8 bits per component in its own colour space.
    ///
    /// A device frame is 16-bit, which doubles every golden's size in LFS for precision a
    /// store PNG never shows. The colour space is kept: a P3 frame stays P3.
    static func eightBit(_ image: CGImage) -> CGImage {
        guard image.bitsPerComponent > 8 else { return image }
        let space =
            image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
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
        public var useReadyFile: Bool
        public var readyArg: String
        public var partial: Bool

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
            useReadyFile: Bool = false,
            readyArg: String = "-ScreenshotReadyFile",
            partial: Bool = false
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
            self.useReadyFile = useReadyFile
            self.readyArg = readyArg
            self.partial = partial
        }
    }

    /// The launch arguments for one shot, in order. Pure, for the tests.
    public static func launchArguments(
        stage: String, appearance: String, ready: ReadyMarker?, options: Options
    ) -> [String] {
        var args = [options.stageArg, stage, options.appearanceArg, appearance]
        if let ready { args += [options.readyArg, ready.argument] }
        return args + targetArgs + options.extraArgs
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
        guard let wanted = options.device.hardware else { throw AppShotError.noDevices }
        let device = try resolve(wanted, among: available())

        // Per device, like the simulator's: two runs on one phone would relaunch the app
        // under each other, and two phones steal nothing from each other.
        let clock = ContinuousClock()
        let lockStart = clock.now
        let root = CaptureLock.defaultRoot.appending(path: "appshot-hw-\(device.udid)")
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

        // Before any shot, and before the app is on screen: two frames of the idle device,
        // compared where the Dynamic Island draws. A live activity there moves over the
        // app too, and would be in every capture. Once per run, since it costs two frames.
        try await requireIdle(device)

        if !options.partial {
            try Compose.wipePNGs(in: options.outDir)
        }

        var shots: [Capture.Shot] = []
        for appearance in options.appearances {
            for screen in options.screens {
                let shot = try await capture(
                    screen: screen, appearance: appearance, device: device,
                    bundleID: bundleID, lockWait: shots.isEmpty ? lockWait : 0,
                    options: options)
                shots.append(shot)
                progress(shot)
            }
        }

        // After the run rather than per shot, because it needs every appearance of a
        // screen. Failing here still leaves the images on disk to look at.
        let ignored = try appearanceIgnored(shots)
        if let first = ignored.first {
            throw AppShotError.appearanceIgnored(screen: first, appearances: options.appearances)
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

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "appshot-hw-\(device.udid)-\(label).png")
        defer { try? FileManager.default.removeItem(at: scratch) }

        func frame() throws -> CGImage {
            try require(.screenshot(device.udid, to: scratch.path))
            return try Image.load(scratch)
        }

        // Whatever is on the device before the app: the Home Screen, or the previous
        // stage. "The app appeared" is "the screen stopped looking like this".
        let before = try frame()

        let ready = options.useReadyFile ? ReadyMarker() : nil
        let launchStart = clock.now
        let launched = try require(
            .launch(
                device.udid, bundleID: bundleID,
                args: launchArguments(
                    stage: screen.stage, appearance: appearance, ready: ready,
                    options: options)))
        let pid =
            ((launched.json?["result"] as? [String: Any])?["process"] as? [String: Any])?[
                "processIdentifier"] as? Int
        let launchTime = seconds(since: launchStart, clock)

        // Never leave the app running with its screenshot arguments, on the way out of a
        // failure or a success: the next launch terminates it anyway, but the last one of
        // a run would sit on the phone showing the demo tree.
        defer { if let pid { try? require(.terminate(device.udid, pid: pid)) } }

        let appearStart = clock.now
        guard try await waitForApp(differingFrom: before, frame: frame) else {
            throw AppShotError.appNeverAppeared(screen: label, device: device.name)
        }
        let appeared = seconds(since: appearStart, clock)

        var readied = 0.0
        if let ready {
            let readyStart = clock.now
            guard try await waitForReady(ready, device: device, bundleID: bundleID,
                ceiling: options.settleMax)
            else {
                throw AppShotError.hardwareNeverSignalledReady(
                    screen: label, argument: ready.argument, seconds: options.settleMax)
            }
            readied = seconds(since: readyStart, clock)
        }

        let floor = screen.settle ?? (ready == nil ? options.settle : 0)
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

        let captured = Config.Size(width: image.width, height: image.height)
        guard orientationMatches(captured, canvas: options.device.output) else {
            // Kept, outside the source directory so the gate never sees it: whether the
            // layout turned or only the picture did is the whole diagnosis, and it can only
            // be read off the frame.
            let rejected = FileManager.default.temporaryDirectory
                .appending(path: "appshot-rejected-\(label).png")
            try? Image.write(eightBit(image), to: rejected)
            throw AppShotError.orientationMismatch(
                screen: label, captured: captured, canvas: options.device.output,
                frame: rejected)
        }

        let encodeStart = clock.now
        let out = options.outDir.appending(path: "\(label).png")
        try Image.write(eightBit(image), to: out)
        let encoded = seconds(since: encodeStart, clock)

        return Capture.Shot(
            name: screen.name,
            appearance: appearance,
            url: out,
            size: captured,
            settled: settled,
            timings: Capture.Timings(
                launch: launchTime, window: appeared, ready: readied, floor: floored,
                lockWait: lockWait, poll: polled, frames: frames, encode: encoded,
                teardown: 0))
    }

    private static func requireIdle(_ device: Device) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "appshot-hw-\(device.udid)-idle.png")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func frame() throws -> CGImage {
            try require(.screenshot(device.udid, to: scratch.path))
            return try Image.load(scratch)
        }
        let first = try frame()
        try await Task.sleep(for: .milliseconds(Int(Capture.pollInterval * 1000)))
        if let box = islandMotion(first, try frame()) {
            throw AppShotError.deviceNotIdle(device.name, motion: box)
        }
    }

    /// Poll the app's container for its marker, through devicectl. Each poll is a round
    /// trip over the tunnel, so this looks every half second rather than every 50ms.
    ///
    /// Not through DeviceFS, CoreDevice's FSKit mount of the same containers under
    /// ~/Library/Developer/CoreDevice/DeviceFS, although it looks like the fast route. It
    /// was tried and measured: a marker the app had written never appeared there within
    /// the 8s ceiling, on six shots out of six, and devicectl found each one at once. The
    /// mount serves a cached view, so waiting on it cost 8s a shot.
    private static func waitForReady(
        _ marker: ReadyMarker, device: Device, bundleID: String, ceiling: Double
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        repeat {
            let found = try require(
                .findFile(
                    device.udid, bundleID: bundleID, directory: ReadyMarker.directory,
                    name: marker.name))
            if found.raw.contains(marker.name) { return true }
            try await Task.sleep(for: .milliseconds(500))
        } while seconds(since: start, clock) < ceiling
        return false
    }

    /// Poll until the screen stops looking like it did before the launch. 20 frames at
    /// ~0.8s each is the same ~15s budget the simulator driver allows.
    private static func waitForApp(
        differingFrom before: CGImage,
        frame: () throws -> CGImage
    ) async throws -> Bool {
        for _ in 0..<20 {
            if !Capture.isStill(before, try frame()) { return true }
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
