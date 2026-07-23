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
        /// The launch argument carrying the path the app should touch once its screen
        /// is genuinely ready. Configurable like the other two, for an app that
        /// already has a name for this.
        public var readyArg: String
        /// Wait for the app to say it is ready, instead of guessing with `settle`.
        ///
        /// The frame poll sees *stillness*, not *readiness* — an empty state, a
        /// skeleton row, or a pane whose data has not arrived is perfectly still — and
        /// the floor exists only to cover that gap. An app that can say "the cost
        /// figure has landed" closes it exactly, instead of everyone padding the
        /// timeout defensively and still not being sure.
        public var useReadyFile: Bool
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
        /// Block until a concurrent run releases the capture lock, rather than
        /// failing. What an agent driving this from one of several terminals wants:
        /// the alternative is a polling loop written by hand at every call site.
        public var wait: Bool
        public var waitTimeout: Double
        /// Where the machine-wide lock lives. Injectable so a test never touches the
        /// real one and cannot wedge a run happening on the same machine.
        public var lockRoot: URL
        /// Launch the app frontmost and hold the lock for the whole run — what this
        /// did before the lock was narrowed to the shutter. The escape hatch for an
        /// app whose window never appears from a background launch.
        public var foregroundLaunch: Bool

        public init(
            app: URL,
            outDir: URL,
            screens: [Screen],
            appearances: [String] = ["dark", "light"],
            extraArgs: [String] = [],
            stageArg: String = "-ScreenshotStage",
            appearanceArg: String = "-ScreenshotAppearance",
            readyArg: String = "-ScreenshotReadyFile",
            useReadyFile: Bool = false,
            settle: Double = Capture.defaultSettle,
            settleMax: Double = Capture.defaultSettleMax,
            wait: Bool = false,
            waitTimeout: Double = CaptureLock.defaultWaitTimeout,
            lockRoot: URL = CaptureLock.defaultRoot,
            foregroundLaunch: Bool = false
        ) {
            self.app = app
            self.outDir = outDir
            self.screens = screens
            self.appearances = appearances
            self.extraArgs = extraArgs
            self.stageArg = stageArg
            self.appearanceArg = appearanceArg
            self.readyArg = readyArg
            self.useReadyFile = useReadyFile
            self.settle = settle
            self.settleMax = settleMax
            self.wait = wait
            self.waitTimeout = waitTimeout
            self.lockRoot = lockRoot
            self.foregroundLaunch = foregroundLaunch
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
                    launch: timings.launch, window: timings.window, ready: timings.ready,
                    floor: timings.floor, lockWait: timings.lockWait, poll: timings.poll,
                    frames: timings.frames, encode: timings.encode, teardown: teardown))
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
        /// Window through the app's own ready signal. Zero without `--ready-file` —
        /// and when it is non-zero, this is the number the settle floor was a guess at.
        public let ready: Double
        /// The settle floor: `--settle`, or this screen's own.
        public let floor: Double
        /// Blocked on another project's capture run. Zero on an idle machine — it is
        /// here so contention reads as contention, rather than as an inexplicably
        /// slow poll.
        public let lockWait: Double
        /// Cursor parking, re-activation, and the frame poll itself.
        public let poll: Double
        /// Frames the poll captured. The tuning signal — at the minimum, the floor
        /// dominates and could go lower; at the ceiling, the window never held still.
        public let frames: Int
        /// Encoding and writing the PNG.
        public let encode: Double
        /// SIGTERM through the process actually being gone.
        public let teardown: Double

        public var total: Double {
            launch + window + ready + floor + lockWait + poll + encode + teardown
        }
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
            ("launch", \.launch), ("window", \.window), ("ready", \.ready),
            ("floor", \.floor), ("lock", \.lockWait), ("poll", \.poll),
            ("encode", \.encode), ("teardown", \.teardown),
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
    ///
    /// Measured rather than guessed, on a 16-shot run of a real app (D1Explorer):
    /// at a 1.0s floor every window was already still on arrival — the poll never
    /// waited for anything — and at 0.2s the poll started doing real work (3 frames
    /// median rising to 4) while the captures still matched goldens accepted under
    /// the old fixed 2.5s sleep. 0.3s keeps a margin over the value that was proven
    /// to work, and is not zero because the poll cannot tell a finished window from
    /// a still-but-unloaded one.
    public static let defaultSettle = 0.3
    public static let defaultSettleMax = 8.0

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Run

    /// Everything a single shot needs that is not the screen itself.
    ///
    /// A struct rather than six more parameters: `capture` and `photograph` both take
    /// the whole of it and neither has any business picking pieces out.
    private struct Session: Sendable {
        let options: Options
        let appName: String
        /// Whatever copy of the app the developer already has open. Never killed,
        /// never photographed.
        let preexisting: Set<pid_t>
        let holder: CaptureLock.Holder
        /// The run already holds the machine-wide lock (`--foreground-launch`), so a
        /// shot must not take it again.
        let runHoldsLock: Bool
        let onLockWait: @Sendable (CaptureLock.Held, Double) -> Void
    }

    /// Capture every screen x appearance. Progress is reported per shot so a caller
    /// can render it however it likes.
    ///
    /// `onLockWait` fires when another project's run holds the capture lock: once when
    /// the wait starts, then every 30s. The library never prints, so this is the only
    /// way a caller can say what it is waiting for.
    public static func run(
        _ options: Options,
        progress: (Shot) -> Void = { _ in },
        onLockWait: @escaping @Sendable (CaptureLock.Held, Double) -> Void = { _, _ in }
    ) async throws -> [Shot] {
        guard FileManager.default.fileExists(atPath: options.app.path) else {
            throw AppShotError.appNotFound(options.app)
        }
        guard hasScreenRecordingPermission() else {
            throw AppShotError.screenRecordingDenied
        }

        let appName = options.app.deletingPathExtension().lastPathComponent
        let holder = CaptureLock.Holder.current(
            app: appName,
            appPath: options.app.path,
            shots: options.screens.count * options.appearances.count)

        // The escape hatch: one lock for the whole run and an activating launch, which
        // is what this did before the lock was narrowed to the shutter. For an app
        // whose window never materialises from a background launch.
        let runLock =
            options.foregroundLaunch
            ? try await CaptureLock.acquire(
                holder, root: options.lockRoot, wait: options.wait,
                timeout: options.waitTimeout, onWait: onLockWait)
            : nil
        defer { runLock?.release() }

        try Compose.wipePNGs(in: options.outDir)

        let preexisting = pids(named: appName)
        let session = Session(
            options: options,
            appName: appName,
            preexisting: preexisting,
            holder: holder,
            runHoldsLock: runLock != nil,
            onLockWait: onLockWait)

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
                    screen: screen, appearance: appearance, session: session)
                shots.append(shot)
                progress(shot)
            }
        }
        return shots
    }

    private static func capture(
        screen: Screen,
        appearance: String,
        session: Session
    ) async throws -> Shot {
        let label = "\(screen.name)~\(appearance)"
        let clock = ContinuousClock()
        let appName = session.appName

        // Re-snapshot the PIDs *every iteration*, not once at startup. The previous
        // screen's instance may still be shutting down: it is neither pre-existing
        // nor gone, and pgrep lists ascending pids so it would be picked first. That
        // bug shipped a paywall shot named help~light.
        let before = pids(named: appName)

        // A fresh path per shot, so a file left behind by the previous screen can never
        // be mistaken for this one's signal.
        let readyFile = session.options.useReadyFile ? readyFileURL(for: session.options.app) : nil
        defer { readyFile.map { try? FileManager.default.removeItem(at: $0) } }

        let launchStart = clock.now
        try launch(
            screen: screen, appearance: appearance, readyFile: readyFile,
            options: session.options)

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
                launch: launched, readyFile: readyFile, session: session)

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
        readyFile: URL?,
        session: Session
    ) async throws -> Shot {
        let options = session.options
        let clock = ContinuousClock()

        let windowStart = clock.now
        guard try await waitForWindow(pid: pid) != nil else {
            throw AppShotError.windowNeverAppeared(screen: label)
        }
        let windowed = seconds(since: windowStart, clock)

        // The app's own word for it. A signal that never comes is a hard failure
        // rather than a quiet fall back to the floor: reverting to the guess is
        // exactly the state this flag was reached for to escape, and a run that does
        // it silently is worse than one that stops.
        var readied = 0.0
        if let readyFile {
            let readyStart = clock.now
            guard await waitForReady(readyFile, ceiling: options.settleMax) else {
                throw AppShotError.appNeverSignalledReady(
                    screen: label, file: readyFile, seconds: options.settleMax)
            }
            readied = seconds(since: readyStart, clock)
        }

        // With a ready signal the global floor is pure superstition — the gap it
        // covers has just been closed by something that actually knows. A screen's
        // *own* settle is kept: that is a deliberate instruction about one screen,
        // not a guess applied to all of them.
        let floor = screen.settle ?? (readyFile == nil ? options.settle : 0)
        let floorStart = clock.now
        try await Task.sleep(for: .seconds(floor))
        let floored = seconds(since: floorStart, clock)

        // The exclusive section starts here and ends at the shutter. Everything above —
        // launching, waiting for the window, the settle floor — needs neither the
        // pointer nor the active app, so another project's run overlaps it freely.
        // Everything below is pixels already in hand.
        var frames = 0
        let pollStart = clock.now
        let (shot, lockWaited) = try await exclusively(session) {
            Window.parkCursor()
            // Front it here, not at launch: the app was started in the background
            // precisely so it could not steal focus from a run photographing right
            // now, and an inactive window renders grey traffic lights and a dimmed
            // toolbar — plausible-looking and wrong.
            guard Window.activate(pid: pid) else {
                throw AppShotError.wouldNotComeToFront(pid: pid, screen: label)
            }

            // Re-read the base window per frame rather than once: the poll spans
            // seconds, and a window that resizes mid-poll would otherwise be captured
            // through a stale rect. A changed size also reads as "not still", which
            // is correct.
            let result = try await settledImage(
                quiescence(floor: floor, ceiling: options.settleMax)
            ) {
                guard let base = Window.base(pid: pid) else {
                    throw AppShotError.windowNeverAppeared(screen: label)
                }
                frames += 1
                return try await self.image(pid: pid, base: base, label: label)
            }

            // Still ours at the shutter? The poll spans seconds, and the one thing
            // that can move focus in that window is *another* project's run tearing
            // down its app — the newly-frontmost app is chosen by the window server,
            // not by us. A shot taken after that renders inactive chrome, which looks
            // plausible and is wrong. Checked rather than assumed, because the whole
            // claim that two runs can overlap rests on it.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw AppShotError.wouldNotComeToFront(pid: pid, screen: label)
            }
            return result
        }
        let polled = seconds(since: pollStart, clock) - lockWaited

        let encodeStart = clock.now
        let out = options.outDir.appending(path: "\(label).png")
        try Image.write(shot.image, to: out)
        let encoded = seconds(since: encodeStart, clock)

        // teardown is filled in by the caller, which is the only place that can time it.
        return Shot(
            name: screen.name,
            appearance: appearance,
            url: out,
            size: Config.Size(width: shot.image.width, height: shot.image.height),
            settled: shot.settled,
            timings: Timings(
                launch: launch, window: windowed, ready: readied, floor: floored,
                lockWait: lockWaited, poll: polled, frames: frames, encode: encoded,
                teardown: 0))
    }

    // MARK: - Readiness

    /// Where the app should write its ready marker.
    ///
    /// Inside the app's sandbox container when it has one, because a sandboxed app —
    /// which is every App Store app, the exact audience for this tool — cannot write
    /// to `/tmp`. It *can* write to its own container by absolute path, and appshot is
    /// not sandboxed, so it can read it from outside. An unsandboxed app gets the
    /// ordinary temporary directory.
    static func readyFileURL(for app: URL) -> URL {
        let name = "appshot-ready-\(UUID().uuidString)"
        guard
            let bundleID = Bundle(url: app)?.bundleIdentifier,
            case let container = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers/\(bundleID)/Data/tmp"),
            FileManager.default.fileExists(atPath: container.path)
        else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: name)
        }
        return container.appending(path: name)
    }

    /// 50ms: an in-process `stat`, no fork, and the whole point is to spend as little
    /// time as possible past the moment the app says it is done.
    private static func waitForReady(_ file: URL, ceiling: Double) async -> Bool {
        for _ in 0..<max(1, Int(ceiling / 0.05)) {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Run `body` holding the machine-wide capture lock, and report what the wait for
    /// it cost.
    ///
    /// A no-op when the run already holds the lock for its whole duration
    /// (`--foreground-launch`) — taking it twice from one process would deadlock
    /// against itself, which no amount of waiting resolves.
    private static func exclusively<T>(
        _ session: Session,
        _ body: () async throws -> T
    ) async throws -> (value: T, waited: Double) {
        guard !session.runHoldsLock else { return (try await body(), 0) }

        let clock = ContinuousClock()
        let start = clock.now
        let lock = try await CaptureLock.acquire(
            session.holder,
            root: session.options.lockRoot,
            wait: session.options.wait,
            timeout: session.options.waitTimeout,
            onWait: session.onLockWait)
        defer { lock.release() }

        let waited = seconds(since: start, clock)
        return (try await body(), waited)
    }

    private static func seconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock)
        -> Double
    {
        let d = clock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // MARK: - Quiescence

    /// Seconds between comparison frames.
    ///
    /// Left at 250ms after measuring the alternative. A frame costs ~90ms, so the
    /// interval — not the capture — is what the poll spends; dropping it to 150ms
    /// would save ~0.2s per shot. But two matches at 250ms prove 500ms of stillness
    /// and at 150ms only 300ms, and restoring the guarantee with a third match costs
    /// an extra frame that gives the saving straight back (0.81s vs 0.77s). So the
    /// cheaper poll is only available by weakening what it proves, for ~10% of a run.
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
        readyFile: URL?,
        options: Options
    ) throws {
        // LaunchServices, not `xcodebuild test`: `open` starts the app for real.
        // -n forces a new instance even if the developer already has one open.
        // Everything after --args lands in NSArgumentDomain, readable by UserDefaults
        // with no plumbing, and only for this launch.
        //
        // -g keeps the launch *out* of the foreground. `open` otherwise activates
        // unconditionally, which is what forced the capture lock to cover a whole run:
        // a second run's launch would yank focus out of the first run's shutter. The
        // app is fronted deliberately later, inside the lock, immediately before the
        // frame poll — so activation happens exactly once per shot and only while this
        // process owns the screen.
        var args = [
            options.foregroundLaunch ? "-n" : "-gn", options.app.path, "--args",
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
        if let readyFile {
            args.append(contentsOf: [options.readyArg, readyFile.path])
        }
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

    /// 100ms, not 50: each poll forks `pgrep`, so the granularity is paid in process
    /// spawns. Measured launch is ~0.05s, so this almost always returns on the first
    /// look and the interval only bounds the unlucky case. Ceiling unchanged at 10s.
    private static func waitForNewPID(
        named name: String,
        excluding before: Set<pid_t>
    ) async throws -> pid_t? {
        for _ in 0..<100 {
            if let pid = pids(named: name).subtracting(before).first { return pid }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// 50ms, because this poll is an in-process `CGWindowList` call rather than a
    /// fork, and waiting for a window was measured at ~0.5s median — a fifth of a
    /// real run, most of it granularity rather than the window genuinely being slow.
    /// Detecting existence has no stillness guarantee to trade away, unlike the frame
    /// poll, so this is free. Ceiling unchanged at 15s.
    private static func waitForWindow(pid: pid_t) async throws -> Window.Info? {
        for _ in 0..<300 {
            if let info = Window.base(pid: pid) { return info }
            try await Task.sleep(for: .milliseconds(50))
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

}
