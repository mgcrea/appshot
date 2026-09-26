import Foundation
import Testing

@testable import AppShotKit

/// Overriding a global preference for a run and putting it back.
///
/// The failure these guard against is quiet and lands on the person, not the pipeline:
/// a setting of theirs left changed after the run. So every test ends by asking what the
/// preference is now, against an in-memory store — writing the real global domain from a
/// test would change the machine running it.
struct GlobalBoolOverrideTests {
    final class MemoryStore: GlobalBoolOverride.Store, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]
        private(set) var writes = 0

        init(_ initial: [String: Bool] = [:]) { values = initial }

        func read(_ key: String) -> Bool? { lock.withLock { values[key] } }
        func write(_ key: String, _ value: Bool?) {
            lock.withLock {
                values[key] = value
                writes += 1
            }
        }
        func has(_ key: String) -> Bool { lock.withLock { values.keys.contains(key) } }
    }

    final class Alive: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<pid_t>
        init(_ pids: Set<pid_t>) { self.pids = pids }
        func kill(_ pid: pid_t) { _ = lock.withLock { pids.remove(pid) } }
        func check(_ pid: pid_t) -> Bool { lock.withLock { pids.contains(pid) } }
    }

    let key = "AppleReduceDesktopTinting"
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "appshot-override-\(UUID().uuidString)")

    func acquire(_ store: MemoryStore, pid: pid_t, alive: Alive) throws -> GlobalBoolOverride {
        try GlobalBoolOverride.acquire(
            key: key, value: true, stateDir: dir, store: store, pid: pid,
            isAlive: { alive.check($0) })
    }

    @Test("an absent key is deleted on release, not left as an explicit false")
    func absentStaysAbsent() throws {
        let store = MemoryStore()
        let alive = Alive([1])
        let lease = try acquire(store, pid: 1, alive: alive)
        #expect(store.read(key) == true)
        lease.release()
        #expect(!store.has(key))
    }

    @Test("an explicit value comes back as that value", arguments: [false, true])
    func explicitValueRestored(_ prior: Bool) throws {
        let store = MemoryStore([key: prior])
        let lease = try acquire(store, pid: 1, alive: Alive([1]))
        #expect(store.read(key) == true)
        lease.release()
        #expect(store.read(key) == prior)
    }

    @Test("the prior value is on disk before the preference changes")
    func recordedFirst() throws {
        let store = MemoryStore([key: false])
        let lease = try acquire(store, pid: 1, alive: Alive([1]))
        let state = try #require(try lease.readState())
        #expect(state.prior == false)
        #expect(state.holders == [1])
        lease.release()
        #expect(try lease.readState() == nil)
    }

    /// The capture lock covers only the shutter, so two projects' runs overlap. The
    /// second must not mistake the first's override for the person's setting.
    @Test("overlapping runs restore the person's value, and only the last one out does")
    func overlappingRuns() throws {
        let store = MemoryStore()
        let alive = Alive([1, 2])
        let first = try acquire(store, pid: 1, alive: alive)
        let second = try acquire(store, pid: 2, alive: alive)
        first.release()
        #expect(store.read(key) == true, "the second run is still capturing")
        second.release()
        #expect(!store.has(key))
    }

    @Test("a run killed with -9 is repaired by the next capture, flag or not")
    func staleRecovered() throws {
        let store = MemoryStore([key: false])
        let alive = Alive([1])
        _ = try acquire(store, pid: 1, alive: alive)
        alive.kill(1)

        let restored = try GlobalBoolOverride.recoverStale(
            key: key, stateDir: dir, store: store, isAlive: { alive.check($0) })
        #expect(restored?.prior == false)
        #expect(store.read(key) == false)
    }

    @Test("a live holder's override is not undone by another run's recovery")
    func liveHolderLeftAlone() throws {
        let store = MemoryStore()
        let alive = Alive([1])
        let lease = try acquire(store, pid: 1, alive: alive)
        let restored = try GlobalBoolOverride.recoverStale(
            key: key, stateDir: dir, store: store, isAlive: { alive.check($0) })
        #expect(restored == nil)
        #expect(store.read(key) == true)
        lease.release()
        #expect(!store.has(key))
    }

    /// A crashed run left the override in place. A new run that wants it too must record
    /// the crashed run's prior, not the live value, which is the leftover override.
    @Test("joining after a crash keeps the recorded prior, not the leftover override")
    func joinAfterCrash() throws {
        let store = MemoryStore([key: false])
        let alive = Alive([1, 2])
        _ = try acquire(store, pid: 1, alive: alive)
        alive.kill(1)
        let second = try acquire(store, pid: 2, alive: alive)
        #expect(try second.readState()?.holders == [2])
        second.release()
        #expect(store.read(key) == false)
    }

    @Test("with no state file, recovery touches nothing")
    func nothingToRecover() throws {
        let store = MemoryStore([key: true])
        #expect(try GlobalBoolOverride.recoverStale(key: key, stateDir: dir, store: store) == nil)
        #expect(store.writes == 0)
    }
}

struct InterruptTests {
    /// Newest first, as a `defer` stack runs, and each cleanup once.
    @Test("cleanups drain newest first, and only once")
    func drainOrder() {
        _ = Interrupt.drain()
        let a = Interrupt.onInterrupt {}
        let b = Interrupt.onInterrupt {}
        let c = Interrupt.onInterrupt {}
        Interrupt.remove(b)
        #expect(Interrupt.drain().count == 2)
        #expect(Interrupt.drain().isEmpty)
        Interrupt.remove(a)
        Interrupt.remove(c)
    }
}
