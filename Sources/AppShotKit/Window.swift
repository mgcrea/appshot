import AppKit
import CoreGraphics
import Foundation

/// Window discovery, activation and cursor parking.
///
/// This is `windowid.swift` folded in. As a standalone script the driver invoked it
/// 50-110 times per run — via `swift windowid.swift`, which **recompiled the file
/// every single time**. Inlining it is most of the runtime back for free.
public enum Window {
    public struct Info: Sendable {
        public let id: CGWindowID
        public let bounds: CGRect
        public let layer: Int
    }

    /// The app's on-screen windows, front-to-back.
    ///
    /// Scoped strictly to `pid`, never to a bundle id or app name. Matching by name
    /// happily returns the *developer's own running copy* of the app, with their
    /// real data in it — the single most common way a private repository or bucket
    /// name ends up in a store screenshot.
    public static func windows(pid: pid_t) -> [Info] {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        return list.compactMap { entry in
            guard
                (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let dict = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return nil }
            return Info(id: id, bounds: bounds, layer: layer)
        }
    }

    /// The frontmost *normal* window: layer 0, and big enough not to be a panel or
    /// HUD. An app also owns menu-bar strips on higher layers, which would otherwise
    /// match first. The list is front-to-back, so the first match is the frontmost —
    /// which is what lets a stage photograph a secondary window it deliberately put
    /// in front.
    public static func base(pid: pid_t) -> Info? {
        windows(pid: pid).first {
            $0.layer == 0 && $0.bounds.width > 300 && $0.bounds.height > 200
        }
    }

    /// Park the pointer somewhere inert.
    ///
    /// The capture bakes in whatever hover state is on screen: a table-row highlight
    /// or a `.help` tooltip under the cursor lands in the image.
    public static func parkCursor() {
        CGWarpMouseCursorPosition(CGPoint(x: 8, y: 8))
    }

    /// Bring `pid` to the front and confirm it took.
    ///
    /// Re-activates on every attempt rather than merely observing: passively waiting
    /// for frontmost-ness just burns the timeout whenever something else holds focus.
    ///
    /// An inactive macOS window renders grey traffic lights, a flat sidebar and
    /// dimmed toolbar icons. The shot still looks plausible on its own — you only
    /// notice next to an active one. So a failure here is fatal, not a warning.
    @discardableResult
    public static func activate(pid: pid_t, attempts: Int = 30) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        for _ in 0..<attempts {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            app.activate(options: [.activateAllWindows])
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
}
