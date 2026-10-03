import AppKit
import ScreenCaptureKit

/// One take per video × appearance: launch the app staged, record its windows, play the
/// cues on appshot's clock, and write the master and the track.
///
/// Nothing is clicked or typed. The pointer is drawn later from what the app reports,
/// so a take never touches the input of whoever is using the Mac.
public enum Recorder {
    public struct Options: Sendable {
        /// Reused for the app, appearances, launch arguments, `--no-activate`, the lock and
        /// `settleMax` (the ceiling on waiting for `ready`).
        public var capture: Capture.Options
        public var videos: [Config.Video]
        public var cueArg: String
        public var eventArg: String

        public init(
            capture: Capture.Options, videos: [Config.Video],
            cueArg: String = "-ScreenshotCueFile", eventArg: String = "-ScreenshotEventFile"
        ) {
            self.capture = capture
            self.videos = videos
            self.cueArg = cueArg
            self.eventArg = eventArg
        }
    }

    public struct Take: Sendable {
        public let video: String
        public let appearance: String
        public let master: URL
        public let track: URL
        public let warnings: [String]
    }

    /// How long ScreenCaptureKit gets to deliver the first frame. A filter that matches
    /// no window streams nothing at all, and that must fail rather than hang.
    static let firstFrameTimeout = 5.0

    public static func cueLines(for video: Config.Video) -> [(seq: Int, beat: Int, line: CueLine)] {
        video.beats.enumerated()
            .compactMap { index, beat in beat.cue.map { (index, beat, $0) } }
            .enumerated()
            .map { seq, item in
                (seq, item.0, CueLine(seq: seq, t: item.1.at, cue: item.2, args: item.1.args ?? [:]))
            }
    }

    /// Throws on a cue never acknowledged within `ackTimeout`, or acknowledged later than
    /// `failLatency`; returns a warning per ack later than `warnLatency`.
    public static func judge(
        sent: [Int: Double], acked: [Int: Double], now: Double,
        lines: [(seq: Int, beat: Int, line: CueLine)], video: String
    ) throws -> [String] {
        var warnings: [String] = []
        for item in lines {
            guard let s = sent[item.seq] else { continue }
            guard let a = acked[item.seq] else {
                if now - s > CuePolicy.ackTimeout {
                    throw AppShotError.cueFailed(
                        video: video, seq: item.seq, cue: item.line.cue,
                        reason: "no ack within \(CuePolicy.ackTimeout)s. The app received it and did"
                            + " nothing, or does not watch the cue file")
                }
                continue
            }
            let latency = a - item.line.t
            let ms = Int(latency * 1000)
            if latency > CuePolicy.failLatency {
                let limit = Int(CuePolicy.failLatency * 1000)
                throw AppShotError.cueFailed(
                    video: video, seq: item.seq, cue: item.line.cue,
                    reason: "acked \(ms)ms after its time; the limit is \(limit)ms")
            }
            if latency > CuePolicy.warnLatency {
                warnings.append("cue #\(item.seq) \(item.line.cue) acked \(ms)ms late")
            }
        }
        return warnings
    }

    /// The union of every window the app showed, in master pixels relative to the display.
    public static func stageCrop(windows: [CGRect], display: CGRect, scale: Double) -> [Double] {
        guard let first = windows.first else {
            return [0, 0, display.width * scale, display.height * scale]
        }
        let union = windows.dropFirst().reduce(first) { $0.union($1) }
        let x: Double = ((union.minX - display.minX) * scale).rounded()
        let y: Double = ((union.minY - display.minY) * scale).rounded()
        let width: Double = (union.width * scale).rounded()
        let height: Double = (union.height * scale).rounded()
        return [x, y, width, height]
    }

    public static func run(_ options: Options, progress: (Take) -> Void = { _ in }) async throws -> [Take] {
        let app = options.capture.app
        guard FileManager.default.fileExists(atPath: app.path) else { throw AppShotError.appNotFound(app) }
        guard Capture.hasScreenRecordingPermission() else { throw AppShotError.screenRecordingDenied }
        try FileManager.default.createDirectory(at: options.capture.outDir, withIntermediateDirectories: true)

        let appName = app.deletingPathExtension().lastPathComponent
        let holder = CaptureLock.Holder.current(
            app: appName, appPath: app.path, shots: options.videos.count * options.capture.appearances.count)
        // The whole run, not each shutter: a take needs the screen for its full duration.
        let lock = try await CaptureLock.acquire(
            holder, root: options.capture.lockRoot, wait: options.capture.wait,
            timeout: options.capture.waitTimeout)
        defer { lock.release() }

        var takes: [Take] = []
        for video in options.videos {
            for appearance in options.capture.appearances {
                let take: Take
                do {
                    take = try await record(
                        video: video, appearance: appearance, appName: appName, options: options)
                } catch {
                    throw takeError(error, video: video.id)
                }
                takes.append(take)
                progress(take)
            }
        }
        return takes
    }

    /// Every error out of a take as an `AppShotError` naming the video: ScreenCaptureKit,
    /// AVFoundation and the file system throw NSErrors, and `check --json` callers branch
    /// on the slug. Lower layers that do not know the video throw `recordFailed` without
    /// one, and get it here.
    static func takeError(_ error: any Error, video: String) -> AppShotError {
        switch error as? AppShotError {
        case .recordFailed(let named, let reason)? where named.isEmpty:
            return .recordFailed(video: video, reason: reason)
        case let known?:
            return known
        case nil:
            return .recordFailed(video: video, reason: describe(error))
        }
    }

    /// An NSError's message with its domain and code, which is what a search for the
    /// failure needs.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    /// Hands a ScreenCaptureKit object across the deadline's task boundary. The calling
    /// task is suspended until the work answers, and abandons it if it never does, so the
    /// object is never used from two tasks at once.
    struct Unchecked<T>: @unchecked Sendable {
        let value: T
    }

    /// One ScreenCaptureKit call, bounded like `Capture`'s. When replayd drops a request
    /// the call never returns, and an unbounded take would sit forever holding the
    /// machine-wide capture lock, with the launched app still up.
    static func bounded<T>(
        video: String, _ step: String, timeout: Duration = Capture.screenCaptureTimeout,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let answer: Unchecked<T>?
        do {
            answer = try await Capture.withDeadline(timeout) { Unchecked(value: try await work()) }
        } catch let error as AppShotError {
            throw error
        } catch {
            throw AppShotError.recordFailed(video: video, reason: "\(step): \(describe(error))")
        }
        guard let answer else {
            throw AppShotError.recordFailed(
                video: video,
                reason: "ScreenCaptureKit did not answer \(step) within \(timeout). replayd dropped the"
                    + " request; re-run, and if it recurs, restart replayd (killall replayd)")
        }
        return answer.value
    }

    /// The windows that make up the stage. The menu bar strips an app owns (its status
    /// item, for an agent app) are left out: they sit at the top of the display, and
    /// their union with the window would make the stage most of the screen.
    static func stageWindows(pid: pid_t) -> [Window.Info] {
        let menuBar: Set<Int> = [
            Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow)),
        ]
        return Window.windows(pid: pid).filter {
            !menuBar.contains($0.layer) && $0.bounds.width > 1 && $0.bounds.height > 1
        }
    }

    static func record(
        video: Config.Video, appearance: String, appName: String, options: Options
    ) async throws -> Take {
        guard let stage = video.stage else {
            throw AppShotError.invalidVideo(
                id: video.id, reason: "record needs `stage`, the -ScreenshotStage to launch")
        }
        let name = "\(video.id)~\(appearance)"
        let masterURL = options.capture.outDir.appending(path: "\(name).mov")
        let partial = masterURL.appendingPathExtension("partial")
        let channel = try CueChannel(directory: Capture.handshakeDirectory(for: options.capture.app))

        // Kill what we launched and drop the half-written master however we leave,
        // Ctrl-C included. The signal handler runs on another queue, so the cleanup holds
        // only values: the two file URLs rather than the channel, whose read offset is
        // the recording loop's alone.
        let before = Capture.pids(named: appName)
        let cueFile = channel.cueFile
        let eventFile = channel.eventFile
        let cleanup: @Sendable () -> Void = {
            for pid in Capture.pids(named: appName).subtracting(before) { Capture.terminate(pid) }
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: cueFile)
            try? FileManager.default.removeItem(at: eventFile)
        }
        let interrupted = Interrupt.onInterrupt(cleanup)
        defer {
            Interrupt.remove(interrupted)
            cleanup()
        }

        var args = Capture.openArguments(
            screen: Capture.Screen(name: video.id, stage: stage), appearance: appearance, readyFile: nil,
            display: options.capture.captureDisplay.resolve(), options: options.capture)
        // After extraArgs: NSArgumentDomain keeps the last occurrence of a key, so
        // appshot's own files win over anything a project passes.
        args += [options.cueArg, cueFile.path, options.eventArg, eventFile.path]
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = args
        try open.run()
        open.waitUntilExit()

        guard let pid = try await Capture.waitForNewPID(named: appName, excluding: before) else {
            throw AppShotError.appNeverStarted(screen: name)
        }
        guard let base = try await Capture.waitForWindow(pid: pid) else {
            throw AppShotError.recordFailed(video: video.id, reason: "the app showed no window")
        }

        // `ready` before anything is recorded: t = 0 must be a finished first screen.
        let readyDeadline = Date().addingTimeInterval(options.capture.settleMax)
        while try !channel.poll().contains(where: { $0.kind == "ready" }) {
            guard Date() < readyDeadline else {
                throw AppShotError.recordFailed(
                    video: video.id,
                    reason: "no ready event within \(options.capture.settleMax)s; does the app read"
                        + " \(options.eventArg)?")
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let content = try await bounded(video: video.id, "listing windows") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard
            let display = content.displays.first(where: { $0.frame.intersects(base.bounds) })
                ?? content.displays.first
        else { throw AppShotError.recordFailed(video: video.id, reason: "no display") }

        var ids = Set(stageWindows(pid: pid).map(\.id))
        var seen = stageWindows(pid: pid).map(\.bounds)
        func filter(_ content: SCShareableContent) -> SCContentFilter {
            SCContentFilter(display: display, including: content.windows.filter { ids.contains($0.windowID) })
        }
        let initial = filter(content)

        // The display's own scale, not the main screen's: on a Mac with a Retina laptop
        // and a 1x external display, the app may be on either.
        let scale = Double(initial.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((display.frame.width * scale).rounded())
        config.height = Int((display.frame.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.backgroundColor = Capture.clearColor
        config.showsCursor = false
        // A display stream otherwise draws the system shadow under each window, and the
        // stage crop cuts it at the window frame: dark wedges in the rounded corners
        // (alpha up to ~40 measured on the fixture) that the stills never have. Compose
        // draws its own shadow around the stage, as it does for the PNGs.
        config.ignoreShadowsDisplay = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6

        let recorder = try StreamRecorder(url: partial, width: config.width, height: config.height)
        let stream = Unchecked(value: SCStream(filter: initial, configuration: config, delegate: recorder))

        let lines = cueLines(for: video)
        var sent: [Int: Double] = [:]
        var acked: [Int: Double] = [:]
        var targets: [(seq: Int, name: String, rect: [Double])] = []
        var warnings: [String] = []

        // Everything from here on runs with the stream live, so every way out stops it.
        // The defer above kills the app and removes the partial, but a stream left
        // running would keep ScreenCaptureKit capturing until the process exits.
        do {
            try stream.value.addStreamOutput(
                recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "appshot.record"))
            try await bounded(video: video.id, "starting the stream") {
                try await stream.value.startCapture()
            }
            guard let origin = try await recorder.waitForFirstFrame(timeout: firstFrameTimeout) else {
                throw AppShotError.recordFailed(
                    video: video.id, reason: "ScreenCaptureKit sent no frame within \(firstFrameTimeout)s")
            }

            // t = 0 is the first frame's own timestamp, on the host clock SCStream stamps
            // samples with, rather than the moment the frame reached us: the master's
            // timeline starts there, and every ack is measured on it.
            let host = CMClockGetHostTimeClock()
            func now() -> Double { (CMClockGetTime(host) - origin).seconds }
            // A frame stamped on some other clock would put every cue at a nonsense time
            // and could keep the loop below running forever. Fail instead. The lower
            // bound is not 0: SCStream stamps a frame with its display time, measured
            // up to a couple of milliseconds ahead of the moment it reaches us.
            guard (-0.1...firstFrameTimeout).contains(now()) else {
                throw AppShotError.recordFailed(
                    video: video.id, reason: "the first frame is not stamped on the host clock (\(now())s)")
            }

            func pollEvents() throws {
                for event in try channel.poll() {
                    switch event.kind {
                    case "ack":
                        // Matched by seq: an ack can arrive after a later cue's events.
                        if let seq = event.seq, acked[seq] == nil { acked[seq] = now() }
                    case "target":
                        if let seq = event.seq, let name = event.name, let rect = event.rect, rect.count == 4
                        {
                            targets.append((seq, name, rect))
                        }
                    case "unknown":
                        throw AppShotError.cueFailed(
                            video: video.id, seq: event.seq ?? -1, cue: event.cue ?? "?",
                            reason: "the app does not implement it")
                    default: continue
                    }
                }
            }

            var pending = lines[...]
            var lastWindowCheck = 0.0
            while now() < video.duration {
                try recorder.throwIfStopped(video: video.id)
                let t = now()
                while let next = pending.first, next.line.t <= t {
                    try channel.send(next.line)
                    sent[next.seq] = t
                    pending = pending.dropFirst()
                }
                try pollEvents()
                warnings = try judge(sent: sent, acked: acked, now: now(), lines: lines, video: video.id)
                if t - lastWindowCheck >= 0.25 {
                    lastWindowCheck = t
                    let current = stageWindows(pid: pid)
                    seen += current.map(\.bounds)
                    let currentIDs = Set(current.map(\.id))
                    if currentIDs != ids {
                        ids = currentIDs
                        let refreshed = try await bounded(video: video.id, "listing windows") {
                            try await SCShareableContent.excludingDesktopWindows(
                                false, onScreenWindowsOnly: true)
                        }
                        let updated = Unchecked(value: filter(refreshed))
                        try await bounded(video: video.id, "updating the window filter") {
                            try await stream.value.updateContentFilter(updated.value)
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(5))
            }

            // A cue sent just before the end still owes its ack, and the take is not
            // judged until it answers or times out. The stream keeps running so its
            // effect lands in the master.
            while sent.keys.contains(where: { acked[$0] == nil }) {
                try recorder.throwIfStopped(video: video.id)
                try pollEvents()
                warnings = try judge(sent: sent, acked: acked, now: now(), lines: lines, video: video.id)
                try await Task.sleep(for: .milliseconds(5))
            }

            try recorder.throwIfStopped(video: video.id)
            try await bounded(video: video.id, "stopping the stream") { try await stream.value.stopCapture() }
            try await recorder.finish()
        } catch {
            // Bounded too: a stop that never answers must not keep the defer from killing
            // the app and releasing the lock.
            _ = try? await bounded(video: video.id, "stopping the stream") {
                try await stream.value.stopCapture()
            }
            recorder.cancel()
            throw error
        }

        let crop = stageCrop(windows: seen, display: display.frame, scale: scale)
        let clicks = Set(lines.filter { $0.line.cue == "pointer.click" }.map(\.seq))
        // Per cue, never per beat: a beat added to the config after the take must not
        // shift a recorded time onto another beat.
        let cues: [VideoTrack.Cue] = lines.map {
            .init(seq: $0.seq, cue: $0.line.cue, args: $0.line.args, at: $0.line.t, acked: acked[$0.seq])
        }
        let reported: [VideoTrack.Target] = targets.compactMap { target in
            guard let line = lines.first(where: { $0.seq == target.seq }) else { return nil }
            // Global points → master pixels → stage pixels.
            let x: Double = (target.rect[0] - display.frame.minX) * scale - crop[0]
            let y: Double = (target.rect[1] - display.frame.minY) * scale - crop[1]
            let width: Double = target.rect[2] * scale
            let height: Double = target.rect[3] * scale
            return .init(
                seq: target.seq, name: target.name, at: line.line.t, rect: [x, y, width, height],
                click: clicks.contains(target.seq))
        }
        let track = VideoTrack(
            video: video.id, appearance: appearance, duration: video.duration, stage: crop,
            cues: cues, targets: reported, frames: recorder.frames, maxFrameGap: recorder.maxGap)

        try? FileManager.default.removeItem(at: masterURL)
        try FileManager.default.moveItem(at: partial, to: masterURL)
        let trackURL = VideoTrack.url(in: options.capture.outDir, video: video.id, appearance: appearance)
        try track.write(to: trackURL)
        return Take(
            video: video.id, appearance: appearance, master: masterURL, track: trackURL, warnings: warnings)
    }
}
