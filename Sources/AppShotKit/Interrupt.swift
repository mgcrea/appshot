import Dispatch
import Foundation

/// Cleanup that must run when a run is interrupted, not only when it returns or throws.
///
/// A `defer` covers every exit Swift controls, and Ctrl-C is not one of them: SIGINT's
/// default action ends the process on the spot. Measured before this existed: an
/// interrupted capture left the app it had launched running in screenshot mode, and it
/// would equally have left a global preference overridden. So the handful of things that
/// must be undone register here, and SIGINT, SIGTERM and SIGHUP run them before exiting.
///
/// `kill -9` still runs nothing, which no handler can change; the state that matters is
/// recorded on disk before it is changed so the next run can repair it (see
/// ``GlobalBoolOverride/recoverStale(key:stateDir:store:isAlive:)``).
public enum Interrupt {
    public struct Token: Hashable, Sendable {
        let id: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [Int: @Sendable () -> Void] = [:]
    nonisolated(unsafe) private static var nextID = 0
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    private static let queue = DispatchQueue(label: "appshot.interrupt")

    /// Run `cleanup` if the process is interrupted before ``remove(_:)`` is called.
    public static func onInterrupt(_ cleanup: @escaping @Sendable () -> Void) -> Token {
        lock.withLock {
            installIfNeeded()
            nextID += 1
            handlers[nextID] = cleanup
            return Token(id: nextID)
        }
    }

    public static func remove(_ token: Token) {
        lock.withLock { _ = handlers.removeValue(forKey: token.id) }
    }

    /// The registered cleanups, newest first, as a `defer` stack would run them. Removes
    /// them, so a second signal during cleanup does not run them twice.
    static func drain() -> [@Sendable () -> Void] {
        lock.withLock {
            let ordered = handlers.sorted { $0.key > $1.key }.map(\.value)
            handlers.removeAll()
            return ordered
        }
    }

    /// Must be called with `lock` held.
    private static func installIfNeeded() {
        guard sources.isEmpty else { return }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            // The dispatch source only sees a signal whose default action is off.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                for cleanup in drain() { cleanup() }
                // The shell's convention for death by signal, so `make` reports it as
                // an interrupt rather than an ordinary failure.
                exit(128 + sig)
            }
            source.resume()
            sources.append(source)
        }
    }
}
