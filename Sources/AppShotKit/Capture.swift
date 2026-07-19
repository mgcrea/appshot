import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The capture driver: launch the app staged onto a screen, photograph its window,
/// quit it, repeat.
///
/// Deliberately not an XCUITest. Under `xcodebuild test` a Mac app launches behind
/// the test runner, and unless the app raises *itself* it never receives keystrokes,
/// so UI-test navigation is inert — the run passes and captures nothing. `open
/// --args` activates the app unconditionally, so each screen is staged by launch
/// argument instead and the app is relaunched once per screen.
///
/// Captures via ScreenCaptureKit rather than `screencapture -l`, which buys one
/// thing that shell-out cannot do: the capture rect is the **union** of the base
/// window and everything in front of it, so a popover or menu overhanging the window
/// edge is not cropped.
public enum Capture {
    public struct Screen: Sendable {
        /// Output basename.
        public let name: String
        /// What the app receives as `-ScreenshotStage`.
        public let stage: String
        /// Seconds to settle for *this* screen; nil ⇒ whatever `Options.settle` says.
        ///
        /// One slow screen otherwise sets the settle for all of them, and every launch
        /// pays it — a 16-shot run at 2.5s spends 40s waiting so that one async pane
        /// finishes drawing.
        public let settle: Double?

        public init(name: String, stage: String, settle: Double? = nil) {
            self.name = name
            self.stage = stage
            self.settle = settle
        }

        /// Parse a `name[:stage[:settle]]` spec.
        ///
        /// A bare `name` means stage == name; an empty stage (`name::4`) means the same,
        /// which is how a screen asks for its own settle without restating its stage.
        public init(spec: String) throws {
            let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)

            func fail(_ why: String) -> AppShotError {
                .invalidScreenSpec(spec, reason: why)
            }

            name = String(parts[0])
            guard !name.isEmpty else { throw fail("the name is empty") }

            let rawStage = parts.count > 1 ? String(parts[1]) : ""
            stage = rawStage.isEmpty ? name : rawStage

            guard parts.count > 2 else {
                settle = nil
                return
            }
            let rawSettle = String(parts[2])
            guard let seconds = Double(rawSettle), seconds.isFinite, seconds >= 0 else {
                throw fail("\"\(rawSettle)\" is not a settle in seconds")
            }
            settle = seconds
        }
    }

    public struct Options: Sendable {
        public var app: URL
        public var outDir: URL
        public var screens: [Screen]
        public var appearances: [String]
        public var extraArgs: [String]
        public var stageArg: String
        public var appearanceArg: String
        /// Minimum seconds to wait after the window appears, before the frame poll
        /// starts looking. A screen carrying its own `settle` overrides this.
        ///
        /// Still a floor rather than a pure poll because quiescence cannot tell
        /// "finished" from "hasn't started": an empty state or a skeleton row is
        /// perfectly still, and a poll alone would photograph it and call it settled.
        public var settle: Double
        /// Hard cap on the frame poll. A window that never holds still — a spinner
        /// outliving its data, a live clock — rides this out and is reported.
        public var settleMax: Double

        public init(
            app: URL,
            outDir: URL,
            screens: [Screen],
            appearances: [String] = ["dark", "light"],
            extraArgs: [String] = [],
            stageArg: String = "-ScreenshotStage",
            appearanceArg: String = "-ScreenshotAppearance",
            settle: Double = Capture.defaultSettle,
            settleMax: Double = Capture.defaultSettleMax
        ) {
            self.app = app
            self.outDir = outDir
            self.screens = screens
            self.appearances = appearances
            self.extraArgs = extraArgs
            self.stageArg = stageArg
            self.appearanceArg = appearanceArg
            self.settle = settle
            self.settleMax = settleMax
        }
    }

    public struct Shot: Sendable {
        public let name: String
        public let appearance: String
        public let url: URL
        public let size: Config.Size
        /// False ⇒ the window was still changing when the ceiling ran out, and this
        /// image is whatever it happened to look like at that moment.
        public let settled: Bool
        public let timings: Timings

        func with(teardown: Double) -> Shot {
            Shot(
                name: name, appearance: appearance, url: url, size: size, settled: settled,
                timings: Timings(
                    launch: timings.launch, window: timings.window, floor: timings.floor,
                    poll: timings.poll, frames: timings.frames, encode: timings.encode,
                    teardown: teardown))
        }
    }

    /// Seconds spent in each phase of one shot.
    ///
    /// Exists because the settle was tuned by reasoning about the loop rather than
    /// watching it, and the two ways that reasoning could be wrong are invisible
    /// without numbers: the frame poll might cost more than the sleep it replaced,
    /// and per-shot launch/teardown might dominate both — in which case the settle
    /// was never the thing worth optimising.
    public struct Timings: Sendable {
        /// `open` through the new pid appearing. Includes the 200ms pgrep poll.
        public let launch: Double
        /// Pid through its first window. Includes the 250ms poll.
        public let window: Double
        /// The settle floor: `--settle`, or this screen's own.
        public let floor: Double
        /// Cursor parking, re-activation, and the frame poll itself.
        public let poll: Double
        /// Frames the poll captured. The tuning signal — at the minimum, the floor
        /// dominates and could go lower; at the ceiling, the window never held still.
        public let frames: Int
        /// Encoding and writing the PNG.
        public let encode: Double
        /// SIGTERM through the process actually being gone.
        public let teardown: Double

        public var total: Double { launch + window + floor + poll + encode + teardown }
    }

    /// Phase medians and worst cases across a run.
    ///
    /// Median rather than mean: one screen that rides the ceiling would drag a mean
    /// far enough to hide what the typical shot costs, and the typical shot is what
    /// the defaults are tuned against. The worst case is reported alongside precisely
    /// so that outlier stays visible.
    public struct Profile: Sendable {
        public struct Phase: Sendable {
            public let name: String
            public let median: Double
            public let worst: Double
            /// Share of the run's total, 0...1.
            public let share: Double
        }

        public let phases: [Phase]
        public let shots: Int
        public let total: Double
        public let framesMedian: Int
        public let framesWorst: Int
    }

    public static func profile(_ timings: [Timings]) -> Profile? {
        guard !timings.isEmpty else { return nil }

        let total = timings.reduce(0) { $0 + $1.total }
        let phases: [(String, (Timings) -> Double)] = [
            ("launch", \.launch), ("window", \.window), ("floor", \.floor),
            ("poll", \.poll), ("encode", \.encode), ("teardown", \.teardown),
        ]

        return Profile(
            phases: phases.map { name, value in
                let values = timings.map(value)
                return Profile.Phase(
                    name: name,
                    median: median(values) ?? 0,
                    worst: values.max() ?? 0,
                    share: total > 0 ? values.reduce(0, +) / total : 0)
            },
            shots: timings.count,
            total: total,
            framesMedian: median(timings.map(\.frames)) ?? 0,
            framesWorst: timings.map(\.frames).max() ?? 0)
    }

    /// Lower median on an even count — no interpolation, so a frame count stays a
    /// whole number of frames.
    static func median<T: Comparable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }

    /// Enough for a window to lay itself out, no more. The frame poll covers what
    /// takes longer, so this no longer has to be sized for the slowest screen.
    public static let defaultSettle = 1.0
    public static let defaultSettleMax = 8.0

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Run

    /// Capture every screen x appearance. Progress is reported per shot so a caller
    /// can render it however it likes.
    public static func run(
        _ options: Options,
        progress: (Shot) -> Void = { _ in }
    ) async throws -> [Shot] {
        guard FileManager.default.fileExists(atPath: options.app.path) else {
            throw AppShotError.appNotFound(options.app)
        }
        guard hasScreenRecordingPermission() else {
            throw AppShotError.screenRecordingDenied
        }

        let lock = try Lock.acquire()
        defer { lock.release() }

        let appName = options.app.deletingPathExtension().lastPathComponent
        try Compose.wipePNGs(in: options.outDir)

        // Whatever copy of the app the developer already has open. Never killed,
        // never photographed.
        let preexisting = pids(named: appName)

        // Kill anything we launched, however we leave — including the path where PID
        // resolution itself failed, which has no pid to defer a teardown on. A leaked
        // instance keeps running with its screenshot launch arguments, holds focus and
        // automation state, and quietly breaks the *next* run (it took an XCUITest
        // "timed out while enabling automation mode" to notice).
        defer {
            for pid in pids(named: appName).subtracting(preexisting) {
                terminate(pid)
            }
        }

        var shots: [Shot] = []
        for appearance in options.appearances {
            for screen in options.screens {
                let shot = try await capture(
                    screen: screen,
                    appearance: appearance,
                    appName: appName,
                    preexisting: preexisting,
                    options: options)
                shots.append(shot)
                progress(shot)
            }
        }
        return shots
    }

    private static func capture(
        screen: Screen,
        appearance: String,
        appName: String,
        preexisting: Set<pid_t>,
        options: Options
    ) async throws -> Shot {
        let label = "\(screen.name)~\(appearance)"
        let clock = ContinuousClock()

        // Re-snapshot the PIDs *every iteration*, not once at startup. The previous
        // screen's instance may still be shutting down: it is neither pre-existing
        // nor gone, and pgrep lists ascending pids so it would be picked first. That
        // bug shipped a paywall shot named help~light.
        let before = pids(named: appName)

        let launchStart = clock.now
        try launch(screen: screen, appearance: appearance, options: options)

        guard let pid = try await waitForNewPID(named: appName, excluding: before) else {
            throw AppShotError.appNeverStarted(screen: label)
        }
        let launched = seconds(since: launchStart, clock)

        // Terminated explicitly on the way out rather than in a `defer`, so the wait
        // for the process to actually die is measured rather than charged to nobody.
        // The catch is what keeps the original guarantee: never leave the instance on
        // screen, however this exits. (`run`'s own defer is the backstop for the paths
        // that have no pid at all.)
        do {
            let shot = try await photograph(
                pid: pid, screen: screen, appearance: appearance, label: label,
                launch: launched, options: options)

            let teardownStart = clock.now
            terminate(pid)
            return shot.with(teardown: seconds(since: teardownStart, clock))
        } catch {
            terminate(pid)
            throw error
        }
    }

    /// Everything between a live pid and a written PNG.
    private static func photograph(
        pid: pid_t,
        screen: Screen,
        appearance: String,
        label: String,
        launch: Double,
        options: Options
    ) async throws -> Shot {
        let clock = ContinuousClock()

        let windowStart = clock.now
        guard try await waitForWindow(pid: pid) != nil else {
            throw AppShotError.windowNeverAppeared(screen: label)
        }
        let windowed = seconds(since: windowStart, clock)

        let floor = screen.settle ?? options.settle
        let floorStart = clock.now
        try await Task.sleep(for: .seconds(floor))
        let floored = seconds(since: floorStart, clock)

        let pollStart = clock.now
        Window.parkCursor()
        // Re-front immediately before the shot. `open` activated it, but that was an
        // age ago in window-server terms and anything that stole focus since — a
        // dying previous instance, the terminal taking it back — would leave the
        // capture subtly dead.
        guard Window.activate(pid: pid) else {
            throw AppShotError.wouldNotComeToFront(pid: pid, screen: label)
        }

        // Re-read the base window per frame rather than once: the poll spans seconds,
        // and a window that resizes mid-poll would otherwise be captured through a
        // stale rect. A changed size also reads as "not still", which is correct.
        var frames = 0
        let (image, settled) = try await settledImage(
            quiescence(floor: floor, ceiling: options.settleMax)
        ) {
            guard let base = Window.base(pid: pid) else {
                throw AppShotError.windowNeverAppeared(screen: label)
            }
            frames += 1
            return try await self.image(pid: pid, base: base, label: label)
        }
        let polled = seconds(since: pollStart, clock)

        let encodeStart = clock.now
        let out = options.outDir.appending(path: "\(label).png")
        try Image.write(image, to: out)
        let encoded = seconds(since: encodeStart, clock)

        // teardown is filled in by the caller, which is the only place that can time it.
        return Shot(
            name: screen.name,
            appearance: appearance,
            url: out,
            size: Config.Size(width: image.width, height: image.height),
            settled: settled,
            timings: Timings(
                launch: launch, window: windowed, floor: floored, poll: polled,
                frames: frames, encode: encoded, teardown: 0))
    }

    private static func seconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock)
        -> Double
    {
        let d = clock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // MARK: - Quiescence

    /// Seconds between comparison frames.
    static let pollInterval = 0.25
    /// Consecutive still comparisons required. Two, not one: a single match is also
    /// what you get from catching an animation at the moment it reverses.
    public static let pollMatches = 2

    /// Fraction of pixels that may differ between two frames and still count as still.
    ///
    /// Sized to sit between the things that legitimately move in a *finished* window
    /// and the thing that means it isn't finished. On a ~5M-pixel capture a blinking
    /// caret is ~160 pixels (0.003%) and a 32pt spinner is ~4,000 (0.08%) — so a caret
    /// reads as settled while a spinner keeps the poll running, which is the
    /// discrimination that actually matters here.
    static let stabilityTolerance = 0.0001

    struct Quiescence: Sendable {
        let interval: Duration
        let maxFrames: Int
        let matchesRequired: Int
    }

    /// The floor is already spent by the time the poll starts, so the ceiling only
    /// funds what's left. Never fewer than the frames a match needs, or a tight
    /// ceiling would return the very first frame and defeat the whole mechanism.
    static func quiescence(floor: Double, ceiling: Double) -> Quiescence {
        Quiescence(
            interval: .milliseconds(Int(pollInterval * 1000)),
            maxFrames: max(pollMatches + 1, Int(max(0, ceiling - floor) / pollInterval)),
            matchesRequired: pollMatches)
    }

    /// Poll frames until the window holds still, or the ceiling runs out.
    ///
    /// The settled frame *is* the screenshot — proving the window stopped changing
    /// requires capturing it, so there is nothing to re-capture afterwards.
    ///
    /// Generic over the frame source so the decision is testable without a window
    /// server; the real caller passes a ScreenCaptureKit capture.
    static func settledImage(
        _ quiescence: Quiescence,
        frame: () async throws -> CGImage
    ) async throws -> (image: CGImage, settled: Bool) {
        var current = try await frame()
        var matches = 0

        for _ in 1..<max(quiescence.maxFrames, 1) {
            try await Task.sleep(for: quiescence.interval)
            let next = try await frame()

            if isStill(current, next) {
                matches += 1
                if matches >= quiescence.matchesRequired { return (next, true) }
            } else {
                matches = 0
            }
            current = next
        }
        // Out of ceiling. Return the last frame anyway — this is what the fixed sleep
        // always did — but say so, because a screen that never settles is a finding.
        return (current, false)
    }

    /// Whether two frames are the same window in the same state.
    ///
    /// Counts alpha alongside RGB, unlike the gate's drift comparison: a window that
    /// hasn't finished drawing its rounded corners differs from a finished one *only*
    /// in alpha, and that is exactly the half-drawn state worth waiting out.
    static func isStill(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let x = Image.pixels(a), let y = Image.pixels(b) else { return false }

        let limit = Int(Double(x.count) * stabilityTolerance)
        var changed = 0
        for i in 0..<x.count {
            let p = x[i]
            let q = y[i]
            let dr = p.r > q.r ? p.r - q.r : q.r - p.r
            let dg = p.g > q.g ? p.g - q.g : q.g - p.g
            let db = p.b > q.b ? p.b - q.b : q.b - p.b
            let da = p.a > q.a ? p.a - q.a : q.a - p.a
            if max(max(dr, dg), max(db, da)) > Gate.channelNoiseFloor {
                changed += 1
                // Early out: the exact fraction is of no interest, only the verdict,
                // and this runs once per frame per shot.
                if changed > limit { return false }
            }
        }
        return true
    }

    // MARK: - Launch / teardown

    private static func launch(
        screen: Screen,
        appearance: String,
        options: Options
    ) throws {
        // LaunchServices, not `xcodebuild test`: `open` activates the app.
        // -n forces a new instance even if the developer already has one open.
        // Everything after --args lands in NSArgumentDomain, readable by UserDefaults
        // with no plumbing, and only for this launch.
        var args = [
            "-n", options.app.path, "--args",
            options.stageArg, screen.stage,
            options.appearanceArg, appearance,
            // Without this, macOS restores the *previous* staged launch's window
            // frame and the app's own pinning loses the race.
            "-ApplePersistenceIgnoreState", "YES",
            "-NSAutomaticWindowAnimationsEnabled", "NO",
            // The developer's system-wide "prefer tabs when opening documents"
            // setting otherwise leaks into the captures: with it on `always`, macOS
            // attaches a tab bar to the window, and whether it does is timing
            // dependent — so a store screenshot grows a stray tab strip on some runs
            // and not others. Pin it per-launch so the capture never depends on how
            // this Mac happens to be configured.
            "-AppleWindowTabbingMode", "manual",
        ]
        args.append(contentsOf: options.extraArgs)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try process.run()
        process.waitUntilExit()
    }

    /// SIGTERM, then poll, then SIGKILL. Blocking, because the next screen must not
    /// launch while this window is still on screen.
    ///
    /// `waitpid` cannot be used: the app is a child of LaunchServices, not of us.
    private static func terminate(_ pid: pid_t) {
        kill(pid, SIGTERM)
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Live PIDs for a process name.
    ///
    /// `pgrep`, not `NSWorkspace.runningApplications`: that list is only refreshed
    /// when the run loop pumps workspace notifications, and a CLI never does — so it
    /// reports the app as never having started, however long you poll.
    private static func pids(named name: String) -> Set<pid_t> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
    }

    private static func waitForNewPID(
        named name: String,
        excluding before: Set<pid_t>
    ) async throws -> pid_t? {
        for _ in 0..<50 {
            if let pid = pids(named: name).subtracting(before).first { return pid }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func waitForWindow(pid: pid_t) async throws -> Window.Info? {
        for _ in 0..<60 {
            if let info = Window.base(pid: pid) { return info }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    // MARK: - ScreenCaptureKit

    /// Transparent capture background.
    ///
    /// Held in a `let` rather than assigned inline because
    /// `SCStreamConfiguration.backgroundColor` is `unowned(unsafe)` — a temporary
    /// gets freed by ARC and the background comes back opaque.
    private static let clearColor = CGColor(gray: 0, alpha: 0)

    private static func image(pid: pid_t, base: Window.Info, label: String) async throws -> CGImage {
        let all = Window.windows(pid: pid)
        guard let baseIndex = all.firstIndex(where: { $0.id == base.id }) else {
            throw AppShotError.captureFailed(screen: label, reason: "base window vanished")
        }

        // The list is front-to-back, so everything at or before baseIndex is the base
        // window plus what sits in front of it. Windows *behind* are excluded, which
        // is what keeps the base window's rounded corners transparent instead of
        // picking up whatever was underneath.
        let included = all[...baseIndex].filter { !$0.bounds.intersection(base.bounds).isNull }
        let ids = Set(included.map(\.id))

        // Union, not the base window's frame: a popover or menu can extend past the
        // window edge, and a base-sized sourceRect would crop it. The overflow stays
        // transparent thanks to the clear background.
        let rect = included.reduce(base.bounds) { $0.union($1.bounds) }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let windows = content.windows.filter { ids.contains($0.windowID) }
            guard
                !windows.isEmpty,
                let display = content.displays.first(where: { $0.frame.intersects(base.bounds) })
                    ?? content.displays.first
            else {
                throw AppShotError.captureFailed(screen: label, reason: "no matching SC window")
            }

            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.backgroundColor = clearColor
            config.sourceRect = rect.offsetBy(
                dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int((rect.width * scale).rounded())
            config.height = Int((rect.height * scale).rounded())

            let filter = SCContentFilter(display: display, including: windows)
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch let error as AppShotError {
            throw error
        } catch {
            throw AppShotError.captureFailed(screen: label, reason: "\(error)")
        }
    }

    // MARK: - Lock

    /// A machine-wide lock, not a per-app one.
    ///
    /// Activation is global: two capture runs in parallel — even of different apps —
    /// steal focus from each other and photograph the wrong windows.
    struct Lock {
        static let path = URL(fileURLWithPath: "/tmp/appshot-capture.lock")

        static func acquire() throws -> Lock {
            let fm = FileManager.default
            if fm.fileExists(atPath: path.path) {
                let holder = (try? String(contentsOf: path.appending(path: "pid"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let holder, let pid = pid_t(holder), kill(pid, 0) == 0 {
                    throw AppShotError.captureLockHeld(by: holder)
                }
                // The holder is dead (or unknowable): clear the stale lock.
                try? fm.removeItem(at: path)
            }
            try fm.createDirectory(at: path, withIntermediateDirectories: false)
            try? "\(ProcessInfo.processInfo.processIdentifier)"
                .write(to: path.appending(path: "pid"), atomically: true, encoding: .utf8)
            return Lock()
        }

        func release() {
            try? FileManager.default.removeItem(at: Lock.path)
        }
    }
}
