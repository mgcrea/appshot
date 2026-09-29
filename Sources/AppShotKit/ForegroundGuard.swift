import AppKit
import CoreGraphics
import Foundation

/// Holds the app to the promise `--no-activate` makes on its behalf: the run never takes
/// the screen from whoever is using the Mac.
///
/// appshot keeps its half — `open -g`, no activation, `-ScreenshotActivation none` — but
/// the app can break the promise from inside, and the capture never notices, because
/// ScreenCaptureKit photographs the window just as well either way. Measured: a demo mode
/// calling `NSWindow.orderFrontRegardless()` unconditionally put the app over the person's
/// editor on every launch of a `--no-activate` run that captured perfectly and reported
/// success. Nothing in appshot saw it; the person did. An unconditional
/// `NSApplication.activate(ignoringOtherApps:)` is the other way to do the same.
///
/// So under `--no-activate` each launched app is sampled from launch until teardown, and
/// the shot fails if the app made itself frontmost (`took_foreground`) or put a window
/// above the frontmost app's (`raised_above_front_app`). No warn-only mode: a warning is
/// what the run that hijacked the screen would have printed, and nobody would have read
/// it. An app that cannot be fixed is an app that cannot be captured unobtrusively, and
/// the honest flag for that run is to drop `--no-activate`.
///
/// The app is identified by the pid appshot launched, never by bundle id — the
/// developer's own running copy is someone else as far as this is concerned.
public enum ForegroundGuard {
    /// One on-screen window, reduced to what the two checks read.
    public struct Entry: Equatable, Sendable {
        public let pid: pid_t
        public let layer: Int
        /// For the message: "ordered above Safari's" says which app was covered.
        public let owner: String

        public init(pid: pid_t, layer: Int, owner: String) {
            self.pid = pid
            self.layer = layer
            self.owner = owner
        }
    }

    /// What the window server looked like at one instant.
    public struct Sample: Equatable, Sendable {
        public let frontmost: pid_t?
        /// Front-to-back, as `CGWindowListCopyWindowInfo` lists them.
        public let windows: [Entry]

        public init(frontmost: pid_t?, windows: [Entry]) {
            self.frontmost = frontmost
            self.windows = windows
        }
    }

    public enum Violation: Equatable, Sendable {
        case tookForeground
        case raisedAbove(frontApp: String)

        public func error(screen: String) -> AppShotError {
            switch self {
            case .tookForeground: .tookForeground(screen: screen)
            case .raisedAbove(let front): .raisedAboveFrontApp(screen: screen, frontApp: front)
            }
        }
    }

    /// Whether any normal window of `launched` sits above `front`'s frontmost one.
    ///
    /// Layer 0 only. The menu-bar strips every app owns live on other layers, and so does
    /// a panel the app deliberately floats; what the incident did was lift an ordinary
    /// window over another app's ordinary windows, which is a question of order within
    /// layer 0 and nothing else.
    ///
    /// No verdict when the front app has no normal window on screen — Finder over an
    /// empty desktop, say. There is nothing to be above, and the frontmost check still
    /// covers the app activating itself there.
    ///
    /// The order is global, not per display. A well-behaved inactive app's window is
    /// ordered behind the active app's wherever it lands (`orderFront` does not reorder
    /// across apps for an inactive one), so a window ahead of it on another display got
    /// there the same way, and is the same bug the moment the person looks at that display.
    public static func isRaisedAbove(launched: pid_t, front: pid_t, windows: [Entry]) -> Bool {
        guard front != launched else { return false }
        let normal = windows.filter { $0.layer == 0 }
        guard let frontIndex = normal.firstIndex(where: { $0.pid == front }) else { return false }
        return normal[..<frontIndex].contains { $0.pid == launched }
    }

    /// Samples in, one verdict out. Pure, so the decisions — which of them are the app's
    /// doing and which are not — are pinned by tests over window-list fixtures rather
    /// than by capture runs.
    public struct Monitor: Sendable {
        /// Nil until the launched pid is known: samples taken before that only learn who
        /// held the front, so that a takeover in the first instant is still attributed.
        public private(set) var launched: pid_t?
        /// Consecutive samples needed before a window above the front app counts.
        ///
        /// Two, not one. The front app and the window list are read a moment apart and
        /// do not change in the same instant, so a person switching apps can produce one
        /// sample that pairs the new order with the old front app. A window
        /// lifted by `orderFrontRegardless()` stays there until someone clicks, so a
        /// second sample costs the real case nothing.
        public static let raisedSamplesRequired = 2

        /// The app that held the front most recently, other than the launched one.
        private var holder: pid_t?
        /// Whether `holder` has been seen with a normal window on screen while it held
        /// the front.
        private var holderHadWindows = false
        /// The launched app was frontmost at the last sample that named one.
        private var inFront = false
        private var raisedStreak = 0
        private var raised: Violation?
        private var takeovers: [Takeover] = []

        /// The launched app became frontmost, taking the front from `from`.
        private struct Takeover: Sendable {
            let from: pid_t?
            let fromHadWindows: Bool
            /// `from` lost its windows at or just after the takeover: it quit or hid
            /// itself, and macOS handed the front to the next app in line, which was ours.
            var handedOff = false
            /// Samples since the takeover. A handoff shows within a few: the holder's
            /// windows go as it hides or quits, not seconds later — and one hidden long
            /// after the app took the front must not excuse the taking.
            var age = 0
        }

        /// Samples after a takeover within which the holder losing its windows still
        /// reads as the cause. A second: a quitting app can take a moment to close them.
        static let handoffSamples = 10

        public init(launched: pid_t? = nil) {
            self.launched = launched
        }

        public mutating func track(_ pid: pid_t) {
            launched = pid
        }

        public mutating func observe(_ sample: Sample) {
            let hasWindows = { (pid: pid_t) in
                sample.windows.contains { $0.pid == pid && $0.layer == 0 }
            }

            // A handoff rather than a takeover. When the front app quits or hides, macOS
            // gives the front to whichever app is next in line, and a window parked just
            // behind the front app's is exactly that — so the person pressing ⌘Q, or
            // another project's run tearing its app down, would otherwise read as ours
            // grabbing it. The tell is the previous holder's windows: gone when it
            // quit or hid, still on screen (just behind) when ours activated itself.
            for i in takeovers.indices where !takeovers[i].handedOff {
                takeovers[i].age += 1
                if takeovers[i].age <= Self.handoffSamples, let from = takeovers[i].from,
                    takeovers[i].fromHadWindows, !hasWindows(from)
                {
                    takeovers[i].handedOff = true
                }
            }

            guard let front = sample.frontmost else {
                raisedStreak = 0
                return
            }

            if let launched, front == launched {
                raisedStreak = 0
                // Once per stretch in front, not once per sample.
                if !inFront {
                    inFront = true
                    var takeover = Takeover(from: holder, fromHadWindows: holderHadWindows)
                    // The takeover sample itself may already show the holder windowless.
                    if let from = holder, holderHadWindows, !hasWindows(from) {
                        takeover.handedOff = true
                    }
                    takeovers.append(takeover)
                }
                return
            }
            inFront = false

            if front != holder {
                holder = front
                holderHadWindows = false
            }
            if hasWindows(front) { holderHadWindows = true }

            guard let launched, raised == nil else { return }
            if isRaisedAbove(launched: launched, front: front, windows: sample.windows) {
                raisedStreak += 1
                if raisedStreak >= Self.raisedSamplesRequired {
                    let owner = sample.windows.first { $0.pid == front }?.owner
                    raised = .raisedAbove(frontApp: owner ?? "pid \(front)")
                }
            } else {
                raisedStreak = 0
            }
        }

        /// What the app did, if anything.
        ///
        /// Taking the front outranks a raised window: activating raises the app's windows
        /// as a side effect, and if the two reads straddle that moment the raise can be
        /// seen first. The activation is the cause, and the one line to fix.
        ///
        /// A takeover from an app that never showed a window — nothing else on screen —
        /// is still a takeover: the app made itself active, which is the thing it must
        /// not do, and "nobody was covered" does not survive the person opening a window.
        ///
        /// The person clicking the app's window mid-run also reads as a takeover. Not
        /// worth telling apart: there is no reason to click it, and a re-run settles it.
        public var verdict: Violation? {
            if takeovers.contains(where: { !$0.handedOff }) { return .tookForeground }
            return raised
        }
    }

    /// How often the watch samples. A sample measured 0.7ms (the window list, ~30 windows)
    /// plus ~0.04ms per front-app read, so ten a second is under 1% of a core, and far
    /// finer than the incident, which stays on screen until the person clicks elsewhere.
    public static let interval = 0.1

    /// Read the window server once: every on-screen window, then who is frontmost.
    ///
    /// The same window query `Window.windows(pid:)` makes, unfiltered: the check is about
    /// the launched app's windows *relative to another app's*, so it needs everyone's.
    /// Windows first, because an app taking the front is recorded as frontmost a moment
    /// before its windows move, so this order never pairs a raised window with a front
    /// app that has not caught up yet.
    public static func sample(launched: pid_t?) -> Sample {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return Sample(frontmost: frontmost(candidates: launched.map { [$0] } ?? []), windows: [])
        }

        let windows = list.compactMap { entry -> Entry? in
            guard
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let layer = entry[kCGWindowLayer as String] as? Int
            else { return nil }
            // A fully transparent window covers nothing, and some frameworks keep one.
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha == 0 { return nil }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
            return Entry(pid: pid, layer: layer, owner: owner)
        }
        let candidates = (launched.map { [$0] } ?? []) + windows.map(\.pid)
        return Sample(frontmost: frontmost(candidates: candidates), windows: windows)
    }

    /// The frontmost app, as of now.
    ///
    /// Not `NSWorkspace.frontmostApplication` on its own: that is a cache, refreshed by
    /// notifications this process's threads do not reliably receive. Measured on the
    /// activation control: LaunchServices logged the fixture taking the front, and the
    /// cache went on naming the editor for the 0.9s the shot had left, so the activation
    /// read as a raised window. A passive probe agreed: while another app held the front
    /// for 3.7s, the cache named the old one throughout, and an `NSRunningApplication`
    /// made fresh for a pid answered `isActive` in step with `lsappinfo front`. So the
    /// cached answer is only a first guess, confirmed fresh; when the confirmation fails,
    /// the launched app and the owners of on-screen windows are asked in turn.
    static func frontmost(candidates: [pid_t]) -> pid_t? {
        func isActive(_ pid: pid_t) -> Bool {
            NSRunningApplication(processIdentifier: pid)?.isActive == true
        }
        if let cached = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            isActive(cached)
        {
            return cached
        }
        var asked = Set<pid_t>()
        for pid in candidates where asked.insert(pid).inserted {
            if isActive(pid) { return pid }
        }
        return nil
    }

    /// The live half: a thread feeding a ``Monitor`` until ``stop()``.
    ///
    /// A thread rather than a task, because the capture path it watches blocks — the
    /// teardown sleeps between `kill` polls — and a sample that waits its turn on the
    /// cooperative pool is a sample taken late.
    ///
    /// Stopped explicitly on every path out of a shot (`Capture` holds it in a `defer`).
    /// A signal needs nothing extra: the interrupt handler ends the process, and the
    /// thread with it.
    public final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var monitor = Monitor()
        private var running = true
        private var verdict: Violation?

        /// Start sampling now, before the launch, so the app that holds the front is
        /// known by the time the launched one could take it.
        public static func start(interval: Double = ForegroundGuard.interval) -> Watch {
            let watch = Watch()
            let thread = Thread { watch.loop(interval: interval) }
            thread.name = "appshot.foreground-guard"
            thread.start()
            return watch
        }

        /// Which pid is ours, once `open` has produced it.
        public func track(_ pid: pid_t) {
            lock.withLock { monitor.track(pid) }
        }

        /// Stop and return the verdict. Idempotent, and does not wait for the thread:
        /// it exits at its next tick, and any sample it takes meanwhile is discarded, so
        /// the teardown that follows cannot be misread as the app's doing.
        @discardableResult
        public func stop() -> Violation? {
            lock.withLock {
                if running {
                    running = false
                    verdict = monitor.verdict
                }
                return verdict
            }
        }

        private func loop(interval: Double) {
            while true {
                let sample = ForegroundGuard.sample(launched: lock.withLock { monitor.launched })
                let keepGoing = lock.withLock {
                    guard running else { return false }
                    monitor.observe(sample)
                    return true
                }
                guard keepGoing else { return }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }
}
