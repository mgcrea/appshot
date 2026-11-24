import Foundation

/// Runs `body` on a serial queue of its own, one at a time, and hands back what it returns
/// or throws.
///
/// A test that compiles symbols waits seconds on `actool` (`Process.waitUntilExit` and a
/// semaphore in `SymbolCatalog.compile`). swift-testing runs a synchronous test on the
/// cooperative pool, so on a 3-core CI runner three such waits at once held every pool
/// thread and starved the async tests beside them: `LockTests`' release `Task` did not run
/// in 30 s, and the v0.35.0 release failed twice (2026-11-24). The library stays
/// synchronous; the tests that reach `actool` wait here instead, off the pool.
///
/// One at a time, too: off the pool alone was not enough. Seventeen `actool` runs at once,
/// each with its AssetCatalogAgent, saturated the runner's three cores, and two timing tests
/// stalled 83 to 89 s (v0.35.1's first CI run, 2026-11-24). The queue is serial, so only one
/// `actool` runs in this test process at a time (GCD's threads are not the cooperative
/// pool's).
///
/// Task-local values do not reach this thread, so a test that sets `SymbolCatalog.$xcrun`
/// or `$actoolTimeout` with `withValue` must not use it.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        actoolQueue.async { continuation.resume(with: Result { try body() }) }
    }
}

private let actoolQueue = DispatchQueue(label: "appshot.tests.actool")
