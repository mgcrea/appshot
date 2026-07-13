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

        public init(name: String, stage: String) {
            self.name = name
            self.stage = stage
        }

        /// Parse a `name:stage` pair (or a bare `name`, meaning stage == name).
        public init(pair: String) {
            let parts = pair.split(separator: ":", maxSplits: 1)
            name = String(parts[0])
            stage = parts.count > 1 ? String(parts[1]) : String(parts[0])
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
        /// Seconds to let async content render after the window appears.
        public var settle: Double

        public init(
            app: URL,
            outDir: URL,
            screens: [Screen],
            appearances: [String] = ["dark", "light"],
            extraArgs: [String] = [],
            stageArg: String = "-ScreenshotStage",
            appearanceArg: String = "-ScreenshotAppearance",
            settle: Double = 2.5
        ) {
            self.app = app
            self.outDir = outDir
            self.screens = screens
            self.appearances = appearances
            self.extraArgs = extraArgs
            self.stageArg = stageArg
            self.appearanceArg = appearanceArg
            self.settle = settle
        }
    }

    public struct Shot: Sendable {
        public let name: String
        public let appearance: String
        public let url: URL
        public let size: Config.Size
    }

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

        // Re-snapshot the PIDs *every iteration*, not once at startup. The previous
        // screen's instance may still be shutting down: it is neither pre-existing
        // nor gone, and pgrep lists ascending pids so it would be picked first. That
        // bug shipped a paywall shot named help~light.
        let before = pids(named: appName)

        try launch(screen: screen, appearance: appearance, options: options)

        guard let pid = try await waitForNewPID(named: appName, excluding: before) else {
            throw AppShotError.appNeverStarted(screen: label)
        }
        // Whatever happens next, don't leave the instance on screen.
        defer { terminate(pid) }

        guard try await waitForWindow(pid: pid) != nil else {
            throw AppShotError.windowNeverAppeared(screen: label)
        }
        try await Task.sleep(for: .seconds(options.settle))

        Window.parkCursor()
        // Re-front immediately before the shot. `open` activated it, but that was an
        // age ago in window-server terms and anything that stole focus since — a
        // dying previous instance, the terminal taking it back — would leave the
        // capture subtly dead.
        guard Window.activate(pid: pid) else {
            throw AppShotError.wouldNotComeToFront(pid: pid, screen: label)
        }
        guard let base = Window.base(pid: pid) else {
            throw AppShotError.windowNeverAppeared(screen: label)
        }

        let image = try await image(pid: pid, base: base, label: label)
        let out = options.outDir.appending(path: "\(label).png")
        try Image.write(image, to: out)

        return Shot(
            name: screen.name,
            appearance: appearance,
            url: out,
            size: Config.Size(width: image.width, height: image.height))
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
