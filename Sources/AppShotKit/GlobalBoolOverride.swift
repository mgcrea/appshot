import CoreFoundation
import Darwin
import Foundation

/// A boolean in the global preferences domain, overridden for the length of a capture run
/// and put back exactly as it was afterwards.
///
/// Some ambient state reaches every screen and no launch argument reaches it. The case
/// that made this exist is wallpaper tinting: a dark window takes the colour of the
/// wallpaper behind it, up to 22 levels against the gate's floor of 8, and the app reads
/// the setting from the global domain, not its argument domain, so `-Key YES` does
/// nothing. Writing the global default does work, for apps launched after the write, and
/// it posts no notification, so apps already running never notice.
///
/// But that is the person's own preference, and the pipeline's needs do not make it the
/// pipeline's to keep. So the prior value, "absent" kept distinct from false, is written
/// to a state file *before* the preference is touched, and restored when the last run
/// holding the override lets go. The state file is what makes that safe:
///
///   concurrent runs  the capture lock covers only the shutter, so two projects' runs
///                    overlap. The second would read the first's override as "the prior
///                    value" and restore *that*, leaving the setting off for good. It
///                    joins the holders instead, and only the last one out restores.
///   a crashed run    a `kill -9` runs no cleanup. Its holder pid is dead, so the next
///                    capture, with or without the flag, finds the file and restores
///                    the recorded prior value.
public struct GlobalBoolOverride: Sendable {
    /// Where a preference is read and written. The system one is the global domain; tests
    /// pass their own, since writing the real one from a test would change the machine.
    public protocol Store: Sendable {
        func read(_ key: String) -> Bool?
        /// `nil` deletes the key: restoring "absent" must not leave an explicit false.
        func write(_ key: String, _ value: Bool?)
    }

    /// `NSGlobalDomain` for the current user, through CFPreferences, which is what
    /// `defaults write -g` does.
    public struct SystemStore: Store {
        public init() {}

        public func read(_ key: String) -> Bool? {
            guard
                let value = CFPreferencesCopyValue(
                    key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                    kCFPreferencesAnyHost)
            else { return nil }
            return (value as? NSNumber)?.boolValue
        }

        public func write(_ key: String, _ value: Bool?) {
            CFPreferencesSetValue(
                key as CFString, value.map { ($0 ? kCFBooleanTrue : kCFBooleanFalse) as CFPropertyList },
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(
                kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    /// The state file's contents.
    public struct State: Codable, Equatable, Sendable {
        public let key: String
        /// The value before any run overrode it. `nil` means the key was absent.
        public let prior: Bool?
        /// The runs currently holding the override.
        public var holders: [pid_t]
    }

    public let key: String
    let pid: pid_t
    let stateDir: URL
    let store: any Store
    let isAlive: @Sendable (pid_t) -> Bool

    /// Wallpaper tinting of window backgrounds. `true` turns tinting off.
    public static let wallpaperTintKey = "AppleReduceDesktopTinting"

    /// Per user rather than `/tmp`: the preference outlives a reboot, so the record of
    /// what to put back has to as well.
    public static var defaultStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/appshot/overrides")
    }

    public static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Set `key` to `value` for this process, recording what to restore first.
    public static func acquire(
        key: String,
        value: Bool,
        stateDir: URL = defaultStateDir,
        store: any Store = SystemStore(),
        pid: pid_t = getpid(),
        isAlive: @escaping @Sendable (pid_t) -> Bool = processIsAlive
    ) throws -> GlobalBoolOverride {
        let lease = GlobalBoolOverride(
            key: key, pid: pid, stateDir: stateDir, store: store, isAlive: isAlive)
        try lease.locked {
            let existing = try lease.readState()
            // While a state file exists, its prior is the truth: the live value is some
            // run's override, whether that run is still going or crashed.
            let prior = existing.map(\.prior) ?? store.read(key)
            let holders = (existing?.holders ?? []).filter(isAlive) + [pid]
            try lease.writeState(State(key: key, prior: prior, holders: holders))
            store.write(key, value)
        }
        return lease
    }

    /// Let go of the override; the last holder restores the prior value.
    public func release() {
        try? locked {
            guard var state = try readState() else { return }
            state.holders.removeAll { $0 == pid || !isAlive($0) }
            if state.holders.isEmpty {
                store.write(key, state.prior)
                try? FileManager.default.removeItem(at: stateURL)
            } else {
                try writeState(state)
            }
        }
    }

    /// Restore a preference a crashed run left overridden: a state file whose holders are
    /// all dead. Called at the start of every capture, so a `kill -9` is repaired by the
    /// next run whether or not it asks for the override. Returns the value restored, or
    /// nil when there was nothing to do.
    @discardableResult
    public static func recoverStale(
        key: String,
        stateDir: URL = defaultStateDir,
        store: any Store = SystemStore(),
        isAlive: @escaping @Sendable (pid_t) -> Bool = processIsAlive
    ) throws -> State? {
        let probe = GlobalBoolOverride(
            key: key, pid: 0, stateDir: stateDir, store: store, isAlive: isAlive)
        var restored: State?
        try probe.locked {
            guard let state = try probe.readState(), !state.holders.contains(where: isAlive)
            else { return }
            store.write(key, state.prior)
            try FileManager.default.removeItem(at: probe.stateURL)
            restored = state
        }
        return restored
    }

    // MARK: - State file

    var stateURL: URL { stateDir.appending(path: "\(key).json") }

    func readState() throws -> State? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
    }

    func writeState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Runs `body` holding an exclusive `flock` on the key's lock file, so two runs
    /// acquiring at once cannot both read "no state file" and both record the other's
    /// override as the prior value.
    func locked(_ body: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let path = stateDir.appending(path: "\(key).lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        try body()
    }
}
