import Foundation

/// Runs `body` on a thread of its own and hands back what it returns or throws.
///
/// A test that compiles symbols waits seconds on `actool` (`Process.waitUntilExit` and a
/// semaphore in `SymbolCatalog.compile`). swift-testing runs a synchronous test on the
/// cooperative pool, so on a 3-core CI runner three such waits at once held every pool
/// thread and starved the async tests beside them: `LockTests`' release `Task` did not run
/// in 30 s, and the v0.35.0 release failed twice (2026-11-24). The library stays
/// synchronous; the tests that reach `actool` wait here instead, off the pool.
///
/// Task-local values do not reach this thread, so a test that sets `SymbolCatalog.$xcrun`
/// or `$actoolTimeout` with `withValue` must not use it.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread {
            continuation.resume(with: Result { try body() })
        }.start()
    }
}
