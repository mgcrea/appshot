import AppKit
import Foundation

/// `record --clips`: one moving clip per screen, with no cue handler.
///
/// Each stage is launched the way `capture` launches it, plus `-ScreenshotClip YES`. The
/// app stages, writes the ready file, and starts moving through its own code; appshot
/// films it until the clip's length. Nothing is clicked or typed.
public enum ClipRecorder {
    public struct Options: Sendable {
        /// The app, appearances, launch arguments, placement flags, `--screens`, the lock
        /// and `settleMax` (the ceiling on waiting for the ready file).
        public var capture: Capture.Options
        /// For `chrome: none` screens and the iOS refusal.
        public var config: Config
        /// Their `screen` beats decide which clips are recorded, and for how long.
        public var videos: [Config.Video]
        public var clipArg: String

        public init(
            capture: Capture.Options, config: Config, videos: [Config.Video],
            clipArg: String = "-ScreenshotClip"
        ) {
            self.capture = capture
            self.config = config
            self.videos = videos
            self.clipArg = clipArg
        }
    }

    public struct Clip: Sendable {
        public let screen: String
        public let appearance: String
        public let movie: URL
        public let info: URL
        /// Distinct pictures filmed, as in the sidecar.
        public let frames: Int
    }

    /// Which screens to film, with their stage and length, in name order. `--screens`
    /// narrows the set and maps stages; without it, every screen the videos name.
    public static func plan(_ options: Options) throws -> [(screen: Capture.Screen, length: Double)] {
        // Refused here rather than recorded as nothing: `run` would otherwise take the
        // machine-wide lock to film no clip at all.
        guard !options.videos.isEmpty else {
            throw AppShotError.invalidVideo(
                id: "", reason: "no video is chosen, so there is no clip to record")
        }
        let lengths = ClipPlan.lengths(for: options.videos)
        if lengths.isEmpty, let video = options.videos.first {
            throw AppShotError.invalidVideo(
                id: video.id, reason: "names no screen, so there is no clip to record")
        }
        let screens: [Capture.Screen]
        if options.capture.screens.isEmpty {
            screens = lengths.keys.sorted().map { Capture.Screen(name: $0, stage: $0) }
        } else {
            for screen in options.capture.screens where lengths[screen.name] == nil {
                throw AppShotError.invalidScreenSpec(
                    screen.name, reason: "no chosen video names screen \(screen.name), so it has no clip")
            }
            screens = options.capture.screens.sorted { $0.name < $1.name }
        }
        return Capture.Screen.applyingChrome(screens, from: options.config).map {
            ($0, lengths[$0.name] ?? 0)
        }
    }

    /// Everything `open` is given for one clip: capture's arguments, then the clip flag,
    /// last so appshot's value wins over a project's.
    static func arguments(
        screen: Capture.Screen, appearance: String, readyFile: URL, display: UInt32?, options: Options
    ) -> [String] {
        Capture.openArguments(
            screen: screen, appearance: appearance, readyFile: readyFile, display: display,
            options: options.capture) + [options.clipArg, "YES"]
    }

    /// Whether a clip holds the app to `--no-activate`'s promise, as capture does: only a
    /// background launch. `--foreground-launch` activates the app itself, so there is no
    /// promise to hold it to.
    static func guardsForeground(_ capture: Capture.Options) -> Bool {
        capture.noActivate && !capture.foregroundLaunch
    }

    /// The base window's top-left in crop pixels, where `TrafficLights` looks for the
    /// buttons. Not (0, 0): a popover or second window can push the crop past the corner.
    static func trafficLightsOrigin(base: CGRect, display: CGRect, scale: Double, crop: [Double]) -> [Double]
    {
        [
            ((base.minX - display.minX) * scale - crop[0]).rounded(),
            ((base.minY - display.minY) * scale - crop[1]).rounded(),
        ]
    }

    public static func run(_ options: Options, progress: (Clip) -> Void = { _ in }) async throws -> [Clip] {
        try Recorder.requireMac(options.config)
        // Before the lock and any launch: a bad --screens found at its own clip would fail
        // after the earlier clips had held the screen for nothing.
        let plan = try plan(options)
        let app = options.capture.app
        guard FileManager.default.fileExists(atPath: app.path) else { throw AppShotError.appNotFound(app) }
        guard Capture.hasScreenRecordingPermission() else { throw AppShotError.screenRecordingDenied }
        try FileManager.default.createDirectory(at: options.capture.outDir, withIntermediateDirectories: true)

        let appName = app.deletingPathExtension().lastPathComponent
        let holder = CaptureLock.Holder.current(
            app: appName, appPath: app.path, shots: plan.count * options.capture.appearances.count)
        let lock = try await CaptureLock.acquire(
            holder, root: options.capture.lockRoot, wait: options.capture.wait,
            timeout: options.capture.waitTimeout)
        defer { lock.release() }

        // As capture does: give the person their setting back however we leave.
        try GlobalBoolOverride.recoverStale(
            key: GlobalBoolOverride.wallpaperTintKey, stateDir: options.capture.overrideStateDir)
        let tint =
            options.capture.noWallpaperTint
            ? try GlobalBoolOverride.acquire(
                key: GlobalBoolOverride.wallpaperTintKey, value: true,
                stateDir: options.capture.overrideStateDir)
            : nil
        defer { tint?.release() }
        let interrupted = Interrupt.onInterrupt { tint?.release() }
        defer { Interrupt.remove(interrupted) }

        var clips: [Clip] = []
        for appearance in options.capture.appearances {
            for (screen, length) in plan {
                let name = ClipInfo.name(screen: screen.name, appearance: appearance)
                let clip: Clip
                do {
                    clip = try await record(
                        screen: screen, length: length, appearance: appearance, appName: appName,
                        options: options)
                } catch {
                    throw Recorder.takeError(error, video: name)
                }
                clips.append(clip)
                progress(clip)
            }
        }
        return clips
    }

    static func record(
        screen: Capture.Screen, length: Double, appearance: String, appName: String, options: Options
    ) async throws -> Clip {
        let name = ClipInfo.name(screen: screen.name, appearance: appearance)
        let out = options.capture.outDir
        let movie = ClipInfo.movieURL(in: out, screen: screen.name, appearance: appearance)
        let partial = movie.appendingPathExtension("partial")
        let readyFile = Capture.readyFileURL(for: options.capture.app)

        let before = Capture.pids(named: appName)
        let cleanup: @Sendable () -> Void = {
            for pid in Capture.pids(named: appName).subtracting(before) { Capture.terminate(pid) }
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: readyFile)
        }
        let interrupted = Interrupt.onInterrupt(cleanup)
        defer {
            Interrupt.remove(interrupted)
            cleanup()
        }

        // Under --no-activate, as capture does: started before the launch, so the app
        // holding the front is already known when the launched one could take it; stopped
        // once filming ends, before the teardown, which moves the front by itself. The
        // defer covers every other way out. The guard watches; it never takes the screen.
        let watch = guardsForeground(options.capture) ? ForegroundGuard.Watch.start() : nil
        defer { watch?.stop() }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments(
            screen: screen, appearance: appearance, readyFile: readyFile,
            display: options.capture.captureDisplay.resolve(), options: options)
        try open.run()
        open.waitUntilExit()

        guard let pid = try await Capture.waitForNewPID(named: appName, excluding: before) else {
            throw AppShotError.appNeverStarted(screen: name)
        }
        watch?.track(pid)
        guard let launched = try await Capture.waitForWindow(pid: pid) else {
            throw AppShotError.windowNeverAppeared(screen: name)
        }
        // No stillness poll: the screen is supposed to move from here on.
        guard await Capture.waitForReady(readyFile, ceiling: options.capture.settleMax) else {
            throw AppShotError.appNeverSignalledReady(
                screen: name, file: readyFile, seconds: options.capture.settleMax)
        }
        // Read again once staged, as capture reads it at the shutter: the app may pin its
        // window's frame after it first appears, and the traffic lights sit at the corner
        // of the window as filmed.
        let base = Window.base(pid: pid) ?? launched

        let film = try await Recorder.film(pid: pid, base: base, partial: partial, label: name) { now in
            now() < length
        }
        let violation = watch?.stop()

        let lights: ClipInfo.TrafficLights? =
            options.capture.recolorTrafficLights && !screen.chromeless
            ? .init(
                origin: trafficLightsOrigin(
                    base: base.bounds, display: film.display, scale: film.scale, crop: film.crop),
                scale: film.scale)
            : nil
        let info = ClipInfo(
            screen: screen.name, stage: screen.stage, appearance: appearance, length: film.stopped,
            crop: film.crop, trafficLights: lights, frames: film.pictures, maxFrameGap: film.maxGap,
            appshotVersion: AppShotVersion.current,
            recordedAt: ISO8601DateFormatter().string(from: Date()))

        try? FileManager.default.removeItem(at: movie)
        try FileManager.default.moveItem(at: partial, to: movie)
        let infoURL = ClipInfo.url(in: out, screen: screen.name, appearance: appearance)
        try info.write(to: infoURL)
        // Thrown here, and the defer above tears the app down before the caller reads it,
        // so the offending window is gone by then. As with capture's PNG, the clip is
        // written and may well be fine; the run is what failed.
        if let violation { throw violation.error(screen: name) }
        return Clip(
            screen: screen.name, appearance: appearance, movie: movie, info: infoURL, frames: film.pictures)
    }
}
