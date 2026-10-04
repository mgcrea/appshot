import Foundation

/// A spring's step response, from 0 toward 1.
///
/// Closed form rather than simulated: a frame is a function of its time alone, so any
/// frame (a motion-blur sub-frame, a contact-sheet cell) can be drawn without replaying
/// the ones before it, and two renders of one frame are identical.
public struct Spring: Sendable, Equatable {
    /// Seconds per cycle of the undamped spring; the move is about 98% done after one.
    public var response: Double
    /// 1 settles without overshoot; below 1 overshoots and rings.
    public var damping: Double

    public init(response: Double, damping: Double) {
        self.response = response
        self.damping = damping
    }

    public func value(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t.isFinite else { return 1 }
        let w = 2 * Double.pi / response
        if damping >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
        let wd = w * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }
}

public enum Ease {
    public static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Slow in, slow out.
    public static func smooth(_ x: Double) -> Double {
        let c = clamp01(x)
        return c * c * (3 - 2 * c)
    }

    /// Fast in, slow out.
    public static func out(_ x: Double) -> Double {
        let c = clamp01(x)
        return 1 - pow(1 - c, 3)
    }
}

/// How a video moves. A preset only chooses among the drawing styles the renderer
/// knows, so a new preset made of existing styles is data, not code.
public struct MotionPreset: Sendable, Equatable {
    public enum Captions: Sendable, Equatable { case band, pill }
    public enum Pop: Sendable, Equatable {
        case lift(scale: Double)
        case outline
    }
    public enum Entry: Sendable, Equatable { case riseAfterHook, fadeIn }
    public enum Exit: Sendable, Equatable { case fall, shrinkFade }
    public enum Card: Sendable, Equatable { case spring, fade }

    public var name: String
    public var camera: Spring
    public var sheet: Spring
    /// How much of the window's box a focused region fills on its binding axis.
    public var fill: Double
    public var zoomCap: Double
    /// A slow push-in and back, as a fraction of the zoom, so no frame is ever still.
    public var drift: Double
    public var driftPeriod: Double
    public var captions: Captions
    public var captionWeight: Int
    /// Caption font size as a fraction of the output's short side.
    public var captionSize: Double
    /// Delay between caption words; 0 brings a caption in whole.
    public var wordStagger: Double
    public var wordSpring: Spring
    public var hookCard: Bool
    public var hookSize: Double
    public var hookStagger: Double
    public var spotlightDim: Double
    public var spotlightOutline: Bool
    public var pop: Pop
    public var popSpring: Spring
    /// An accent-coloured glow drifting behind the window.
    public var glow: Bool
    /// Degrees the background gradient swings either way over 20 s.
    public var swing: Double
    public var entry: Entry
    public var exit: Exit
    public var card: Card
    public var blurSamples: Int
    /// Motion-blur shutter as a fraction of a frame: 0.25 is a 90° shutter.
    public var shutter: Double
    /// Pixels the window must move in 1/60 s before a frame is blurred.
    public var blurThreshold: Double

    /// The hook holds the first 1.5 s whatever the preset, so one config stays valid
    /// under every preset `--motion` may name.
    public static let hookDuration = 1.5
    public static let defaultName = "kinetic"

    public static let kinetic = MotionPreset(
        name: "kinetic", camera: Spring(response: 0.7, damping: 0.78),
        sheet: Spring(response: 0.45, damping: 0.7), fill: 0.92, zoomCap: 2.6, drift: 0.04,
        driftPeriod: 10, captions: .band, captionWeight: 800, captionSize: 0.062, wordStagger: 0.06,
        wordSpring: Spring(response: 0.5, damping: 0.7), hookCard: true, hookSize: 0.11,
        hookStagger: 0.08, spotlightDim: 0.62, spotlightOutline: false, pop: .lift(scale: 1.32),
        popSpring: Spring(response: 0.5, damping: 0.62), glow: true, swing: 12, entry: .riseAfterHook,
        exit: .fall, card: .spring, blurSamples: 6, shutter: 0.25, blurThreshold: 3)

    public static let studio = MotionPreset(
        name: "studio", camera: Spring(response: 1.0, damping: 1.0),
        sheet: Spring(response: 0.55, damping: 0.9), fill: 0.9, zoomCap: 2.6, drift: 0.025,
        driftPeriod: 10, captions: .pill, captionWeight: 600, captionSize: 0.04, wordStagger: 0,
        wordSpring: Spring(response: 0.5, damping: 1), hookCard: false, hookSize: 0.11, hookStagger: 0.08,
        spotlightDim: 0.5, spotlightOutline: true, pop: .outline,
        popSpring: Spring(response: 0.6, damping: 1), glow: false, swing: 12, entry: .fadeIn,
        exit: .shrinkFade, card: .fade, blurSamples: 6, shutter: 0.25, blurThreshold: 3)

    public static let all: [MotionPreset] = [.kinetic, .studio]

    public static func named(_ name: String) -> MotionPreset? {
        all.first { $0.name == name }
    }
}
