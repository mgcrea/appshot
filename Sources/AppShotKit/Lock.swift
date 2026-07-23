import Foundation

/// The machine-wide capture lock.
///
/// A machine-wide lock, not a per-app one. Activation is global: two capture runs
/// overlapping — even of different apps — steal focus from each other and photograph
/// the wrong windows.
///
/// ## Why it says who holds it
///
/// The lock used to hold a bare pid, and a pid is the one thing a person driving this
/// from another project cannot act on: "another capture run is in progress (pid 10994)"
/// costs a `ps aux | grep` to learn it belongs to a different repository, and a
/// hand-written polling loop to wait it out. So the holder writes down who it is —
/// app, working directory, when it started — and `--wait` does the polling loop that
/// everyone was writing by hand.
///
/// ## Why a missing info file is not a dead lock
///
/// The directory is the lock: `mkdir` is atomic and fails if it exists, which is what
/// actually excludes two runs. The info file is written immediately *after*, and the
/// old code treated an unreadable holder as license to delete the lock and take it — so
/// a second process arriving inside that window destroyed a live lock and both runs
/// proceeded, which is precisely the failure the lock exists to prevent. An info-less
/// lock is now re-polled through a grace window first, and only debris that survives it
/// is cleared.
public struct CaptureLock {

    // MARK: - Holder

    /// Who holds the lock. Enough to answer "whose run is this?" without a `ps`.
    public struct Holder: Codable, Sendable {
        public let pid: pid_t
        /// The app being photographed — the name a reader recognises.
        public let app: String
        public let appPath: String
        public let cwd: String
        public let argv: [String]
        public let startedAt: Date
        /// Shots the run intends to take, so a waiter can size the wait.
        public let shots: Int
        public let appshotVersion: String

        public init(
            pid: pid_t,
            app: String,
            appPath: String,
            cwd: String,
            argv: [String],
            startedAt: Date,
            shots: Int,
            appshotVersion: String = AppShotVersion.current
        ) {
            self.pid = pid
            self.app = app
            self.appPath = appPath
            self.cwd = cwd
            self.argv = argv
            self.startedAt = startedAt
            self.shots = shots
            self.appshotVersion = appshotVersion
        }

        /// This process, photographing `app`.
        public static func current(app: String, appPath: String, shots: Int) -> Holder {
            Holder(
                pid: ProcessInfo.processInfo.processIdentifier,
                app: app,
                appPath: appPath,
                cwd: FileManager.default.currentDirectoryPath,
                argv: ProcessInfo.processInfo.arguments,
                startedAt: Date(),
                shots: shots,
                appshotVersion: AppShotVersion.current)
        }

        public var isAlive: Bool { kill(pid, 0) == 0 }

        /// One line naming the run, for an error a person has to act on.
        public var summary: String {
            let age = CaptureLock.duration(max(0, Date().timeIntervalSince(startedAt)))
            return "\(app) (pid \(pid)), started \(age) ago in \(abbreviate(cwd))"
        }
    }

    /// What could be learned about the current holder — which is not always its
    /// identity: a lock written by an older appshot has only a pid file, and one
    /// caught mid-write has neither.
    public struct Held: Sendable {
        public let holder: Holder?
        public let pid: pid_t?

        public init(holder: Holder?, pid: pid_t?) {
            self.holder = holder
            self.pid = pid
        }

        public var isAlive: Bool { pid.map { kill($0, 0) == 0 } ?? false }
    }

    // MARK: - Configuration

    public static let defaultRoot = URL(fileURLWithPath: "/tmp")
    /// Half an hour: long enough to sit behind a full run of a large project,
    /// short enough that a wedged holder does not hang an agent overnight.
    public static let defaultWaitTimeout = 1800.0

    static let directoryName = "appshot-capture.lock"
    static let infoName = "info.json"
    /// Written alongside `info.json` so an older appshot still sees a held lock.
    static let pidName = "pid"

    /// How long a lock may exist without its info file before it reads as debris.
    /// The holder writes that file microseconds after the mkdir, so this is margin.
    static let infoGrace = 1.0
    static let retryInterval = 2.0
    /// How often a wait reports that it is still waiting.
    static let announceInterval = 30.0

    let dir: URL

    // MARK: - Acquire

    /// Take the lock, optionally waiting for whoever has it.
    ///
    /// `onWait` is called once when the wait starts and every `announceInterval`
    /// after that, with the holder (when known) and the seconds waited so far. The
    /// library never prints; this is how a caller reports the wait.
    public static func acquire(
        _ holder: Holder,
        root: URL = defaultRoot,
        wait: Bool = false,
        timeout: Double = defaultWaitTimeout,
        onWait: (Held, Double) -> Void = { _, _ in }
    ) async throws -> CaptureLock {
        let dir = root.appending(path: directoryName)
        let clock = ContinuousClock()
        let start = clock.now
        var announced = false
        var lastAnnounce = start

        while true {
            if let lock = await take(dir: dir, holder: holder) { return lock }

            let held = read(dir: dir)
            let waited = seconds(since: start, clock)
            guard wait else { throw AppShotError.captureLockHeld(held, waited: nil) }

            if !announced || seconds(since: lastAnnounce, clock) >= announceInterval {
                onWait(held, waited)
                announced = true
                lastAnnounce = clock.now
            }
            guard waited < timeout else {
                throw AppShotError.captureLockHeld(held, waited: waited)
            }
            // Clamped to what is left, so a short timeout is honoured to the second
            // rather than overshot by a whole retry interval.
            try await Task.sleep(for: .seconds(min(retryInterval, max(0.05, timeout - waited))))
        }
    }

    /// The live holder, without acquiring anything. Nil when the lock is free — or
    /// held by a process that is gone, which is the same thing to a caller.
    public static func holder(root: URL = defaultRoot) -> Held? {
        let held = read(dir: root.appending(path: directoryName))
        guard held.holder != nil || held.pid != nil else { return nil }
        return held.isAlive ? held : nil
    }

    public func release() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Internals

    /// One attempt. Nil means someone else has it.
    private static func take(dir: URL, holder: Holder) async -> CaptureLock? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            guard await isDebris(dir) else { return nil }
            try? fm.removeItem(at: dir)
        }

        // `mkdir` is the atomic primitive and the only thing that excludes anyone —
        // the check above is for diagnostics and stale-clearing, and two processes
        // can both pass it. Losing this race is not an error, it is the answer.
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            return nil
        }

        let lock = CaptureLock(dir: dir)
        lock.write(holder)
        return lock
    }

    /// Left over from a process that is gone?
    ///
    /// Only a holder that can be *read* and is provably dead clears immediately. A
    /// lock with no readable holder is re-polled through the grace window, because
    /// the likeliest reason to see one is that it was created microseconds ago and
    /// its info file is not written yet. See the type doc.
    private static func isDebris(_ dir: URL) async -> Bool {
        for attempt in 0..<max(1, Int(infoGrace / 0.1)) {
            let held = read(dir: dir)
            if held.holder != nil || held.pid != nil { return !held.isAlive }
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return true
    }

    private func write(_ holder: Holder) {
        if let data = try? CaptureLock.encoder.encode(holder) {
            try? data.write(to: dir.appending(path: CaptureLock.infoName))
        }
        // Kept for an older appshot reading a newer lock: it looks for this file and
        // nothing else, and would otherwise call a live lock stale and take it.
        try? "\(holder.pid)".write(
            to: dir.appending(path: CaptureLock.pidName), atomically: true, encoding: .utf8)
    }

    private static func read(dir: URL) -> Held {
        let holder = (try? Data(contentsOf: dir.appending(path: infoName)))
            .flatMap { try? decoder.decode(Holder.self, from: $0) }
        let raw = try? String(contentsOf: dir.appending(path: pidName), encoding: .utf8)
        let pid = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap(pid_t.init)
        return Held(holder: holder, pid: holder?.pid ?? pid)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func seconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock)
        -> Double
    {
        let d = clock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// "45s", "2m14s", "1h20m" — a duration a person reads at a glance.
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 {
            let rest = total % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m\(rest)s"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }
}

/// `/Users/me/Projects/App` → `~/Projects/App`. A home-relative path is what the
/// reader recognises as "the other project".
func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
