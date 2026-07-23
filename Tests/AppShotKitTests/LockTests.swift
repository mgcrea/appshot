import Foundation
import Testing

@testable import AppShotKit

/// The lock is the one piece of appshot that two *processes* have to agree about, and
/// the failure it prevents — two runs fighting over the pointer, each photographing
/// the other's windows — is invisible in the output: the captures look plausible and
/// are wrong.
///
/// Every case here injects a lock root, so a test can never wedge or steal the real
/// `/tmp/appshot-capture.lock` from a capture happening on the same machine.
struct LockTests {
    static func root() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-lock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func holder(pid: pid_t? = nil, app: String = "D1Explorer") -> CaptureLock.Holder {
        CaptureLock.Holder(
            pid: pid ?? ProcessInfo.processInfo.processIdentifier,
            app: app,
            appPath: "/Applications/\(app).app",
            cwd: "\(FileManager.default.homeDirectoryForCurrentUser.path)/Projects/\(app)",
            argv: ["appshot", "capture"],
            startedAt: Date(),
            shots: 16)
    }

    @Test("an uncontended lock is taken and released")
    func acquireAndRelease() async throws {
        let root = try Self.root()
        let lock = try await CaptureLock.acquire(Self.holder(), root: root)
        #expect(CaptureLock.holder(root: root) != nil)

        lock.release()
        #expect(CaptureLock.holder(root: root) == nil)
    }

    /// The message that cost a `ps aux | grep appshot` to decode. It has to carry the
    /// app and the directory, or the reader still cannot tell whose run this is.
    @Test("a held lock is refused, naming who has it")
    func heldLockNamesItsHolder() async throws {
        let root = try Self.root()
        _ = try await CaptureLock.acquire(Self.holder(), root: root)

        await #expect(throws: AppShotError.self) {
            _ = try await CaptureLock.acquire(Self.holder(app: "Silhouette"), root: root)
        }

        let held = try #require(CaptureLock.holder(root: root))
        let message = "\(AppShotError.captureLockHeld(held, waited: nil))"
        #expect(message.contains("D1Explorer"))
        #expect(message.contains("~/Projects/D1Explorer"))
        #expect(message.contains("--wait"))
    }

    /// pid 1 is launchd: alive, and never us. Anything else would make this test
    /// depend on a pid that might get reused between the two lines.
    @Test("a lock whose holder is gone is debris, and is cleared")
    func deadHolderIsCleared() async throws {
        let root = try Self.root()
        // A pid that cannot be alive: kernel pids stop well below this and the value
        // is above the default pid_max, so `kill(pid, 0)` is guaranteed to fail.
        _ = try await CaptureLock.acquire(Self.holder(pid: 999_999), root: root)
        #expect(CaptureLock.holder(root: root) == nil, "a dead holder is not a holder")

        let lock = try await CaptureLock.acquire(Self.holder(), root: root)
        #expect(CaptureLock.holder(root: root)?.pid == ProcessInfo.processInfo.processIdentifier)
        lock.release()
    }

    /// The race the old lock lost. `mkdir` is what excludes anyone, and the info file
    /// lands microseconds later — a reader arriving in that window used to conclude
    /// "no readable holder, therefore stale", delete a *live* lock and take it. Both
    /// runs then fought over the pointer, which is the whole failure the lock exists
    /// to prevent.
    @Test("a lock with no info file yet is not stolen")
    func infoLessLockIsNotStolen() async throws {
        let root = try Self.root()
        let dir = root.appending(path: CaptureLock.directoryName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        // Write the info only after a delay longer than one poll but shorter than the
        // grace window: the acquirer must still be looking when it appears.
        let holder = Self.holder()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let data = try? JSONEncoder.iso8601.encode(holder)
            try? data?.write(to: dir.appending(path: CaptureLock.infoName))
        }

        await #expect(throws: AppShotError.self) {
            _ = try await CaptureLock.acquire(Self.holder(app: "Silhouette"), root: root)
        }
    }

    /// Debris from a process that died between the mkdir and the write would otherwise
    /// wedge every future run on the machine, with no holder to name and nothing to
    /// wait for.
    @Test("a lock with no info file at all is cleared once the grace window passes")
    func abandonedLockIsEventuallyCleared() async throws {
        let root = try Self.root()
        let dir = root.appending(path: CaptureLock.directoryName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        let lock = try await CaptureLock.acquire(Self.holder(), root: root)
        #expect(CaptureLock.holder(root: root)?.holder?.app == "D1Explorer")
        lock.release()
    }

    @Test("--wait blocks until the holder releases, then takes the lock")
    func waitAcquiresAfterRelease() async throws {
        let root = try Self.root()
        let held = try await CaptureLock.acquire(Self.holder(), root: root)

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            held.release()
        }

        var announced: [String] = []
        let lock = try await CaptureLock.acquire(
            Self.holder(app: "Silhouette"), root: root, wait: true, timeout: 30
        ) { held, _ in
            announced.append(held.holder?.app ?? "unknown")
        }
        lock.release()

        // The wait is reported once when it starts — a silent block is indistinguishable
        // from a hang to whoever is watching the terminal.
        #expect(announced.first == "D1Explorer")
    }

    @Test("--wait gives up at its timeout, still naming the holder")
    func waitTimesOut() async throws {
        let root = try Self.root()
        _ = try await CaptureLock.acquire(Self.holder(), root: root)

        do {
            _ = try await CaptureLock.acquire(
                Self.holder(app: "Silhouette"), root: root, wait: true, timeout: 0.1)
            Issue.record("the wait should have timed out")
        } catch let error as AppShotError {
            let message = "\(error)"
            #expect(message.contains("D1Explorer"))
            #expect(message.contains("--wait-timeout"))
        }
    }

    @Test("durations read as durations")
    func durationFormatting() {
        #expect(CaptureLock.duration(45) == "45s")
        #expect(CaptureLock.duration(134) == "2m14s")
        #expect(CaptureLock.duration(120) == "2m")
        #expect(CaptureLock.duration(4800) == "1h20m")
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
