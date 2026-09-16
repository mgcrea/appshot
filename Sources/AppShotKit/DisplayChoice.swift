import AppKit
import CoreGraphics

/// Which display a capture window should be parked on.
///
/// Exists because `--no-activate` only solves half the disruption. A run that no longer
/// takes the keyboard still *draws* a window, over whatever the person at the machine is
/// reading. On a laptop with an external display that is nearly always solvable for free:
/// the work is happening on one of them and the other is sitting idle.
///
/// Resolution is deliberately conservative — every case falls back to "say nothing and let
/// the app decide" rather than guessing, because a wrong guess parks the window on a display
/// with a different backing scale and silently changes every captured dimension.
public enum DisplayChoice: String, CaseIterable, Sendable {

    /// Wherever the app would have put it. The default, and no argument is passed.
    case main

    /// Any display other than the one holding the key window, preferring a match on backing
    /// scale. This is the one to pair with `--no-activate`.
    case secondary

    /// The laptop's own panel. Usually the free one: someone working at a desk is looking at
    /// the external display, and on a MacBook alone it is the only display, so this
    /// degrades to `main` rather than failing.
    case builtin

    /// The external display, for the inverse setup — a laptop panel being used as the
    /// working screen with a spare monitor beside it.
    case external

    /// One display, reduced to the four facts the choice turns on.
    ///
    /// A value type rather than `NSScreen` so the rule below can be tested: `NSScreen` has
    /// no public initialiser, so a decision written directly against it is a decision that
    /// can only be checked by plugging in a monitor.
    public struct Display: Equatable, Sendable {
        public let id: CGDirectDisplayID
        public let isBuiltin: Bool
        public let scale: CGFloat
        public let isMain: Bool

        public init(id: CGDirectDisplayID, isBuiltin: Bool, scale: CGFloat, isMain: Bool) {
            self.id = id
            self.isBuiltin = isBuiltin
            self.scale = scale
            self.isMain = isMain
        }
    }

    /// The chosen display's `CGDirectDisplayID`, or `nil` to pass nothing at all.
    ///
    /// `nil` for `.main`, and `nil` whenever the named display does not exist or would
    /// change the backing scale. The scale guard is the important half: the capture is
    /// rendered at its screen's scale, so parking a window on a 1x display beside a 2x one
    /// halves every dimension — failing the gate on every screen at once, for a reason
    /// nothing in the output would explain.
    public func resolve(among displays: [Display]) -> CGDirectDisplayID? {
        guard self != .main, displays.count > 1, let main = displays.first(where: \.isMain)
        else { return nil }
        // Main is excluded BEFORE the choice is applied, not checked after. Searching the
        // whole list and then rejecting a main-display hit looks equivalent and is not: with
        // a laptop and two monitors, `.external` finds the monitor being worked on, rejects
        // it, and gives up — while the other monitor sits idle, which is the display the
        // caller asked for.
        let others = displays.filter { !$0.isMain }
        let candidate: Display? =
            switch self {
            case .main: nil
            case .secondary: others.first
            case .builtin: others.first { $0.isBuiltin }
            case .external: others.first { !$0.isBuiltin }
            }
        guard let candidate, candidate.scale == main.scale else { return nil }
        return candidate.id
    }

    /// The live window server's answer, in the shape `resolve(among:)` wants.
    public func resolve() -> CGDirectDisplayID? {
        let main = NSScreen.main
        return resolve(
            among: NSScreen.screens.compactMap { screen in
                guard let id = Self.displayID(of: screen) else { return nil }
                return Display(
                    id: id, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                    scale: screen.backingScaleFactor, isMain: screen == main)
            })
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }
}
