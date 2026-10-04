import CoreGraphics
import Foundation

/// Where the window sits on the canvas at time t.
///
/// The whole window moves, chrome, corners and shadow included, and the frame's edge
/// does the cropping. The first renderer cropped inside a fixed box instead, which reads
/// as the content panning rather than the camera moving in.
public struct VideoCamera: Sendable {
    /// A move toward a region in stage pixels, or with no rect back to the whole window.
    public struct Key: Sendable, Equatable {
        public var time: Double
        public var rect: CGRect?
        public var fill: Double?

        public init(time: Double, rect: CGRect?, fill: Double?) {
            self.time = time
            self.rect = rect
            self.fill = fill
        }
    }

    public struct Placement: Sendable, Equatable {
        /// The whole window, y-down canvas pixels; it may run past the canvas.
        public var rect: CGRect
        public var alpha: Double
        public var zoom: Double
        /// Canvas pixels per stage pixel.
        public var scale: Double

        public func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
        }

        public func map(_ r: CGRect) -> CGRect {
            CGRect(
                x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale, width: r.width * scale,
                height: r.height * scale)
        }
    }

    public let preset: MotionPreset
    public let stage: CGSize
    public let canvas: CGSize
    /// Where the window rests at zoom 1, y-down canvas pixels.
    public let box: CGRect
    public let keys: [Key]
    /// When an entering window starts to come in.
    public let entryAt: Double
    /// When the window starts leaving for the end card; nil without one.
    public let exitAt: Double?

    public init(
        preset: MotionPreset, stage: CGSize, canvas: CGSize, box: CGRect, keys: [Key], entryAt: Double,
        exitAt: Double?
    ) {
        self.preset = preset
        self.stage = stage
        self.canvas = canvas
        self.box = box
        self.keys = keys
        self.entryAt = entryAt
        self.exitAt = exitAt
    }

    var fit: Double { min(box.width / stage.width, box.height / stage.height) }
    var anchor: CGPoint { CGPoint(x: box.midX, y: box.midY) }

    /// The zoom and stage-pixel center a key asks for. The zoom is computed, never
    /// configured: the region fills `fill` of the box on whichever axis binds.
    public func target(_ key: Key) -> (zoom: Double, center: CGPoint) {
        guard let r = key.rect else { return (1, CGPoint(x: stage.width / 2, y: stage.height / 2)) }
        let fill = key.fill ?? preset.fill
        let zoom = fill * min(box.width / (r.width * fit), box.height / (r.height * fit))
        return (min(max(zoom, 1), preset.zoomCap), CGPoint(x: r.midX, y: r.midY))
    }

    /// Zoom and center after the springs, the drift and the clamp.
    ///
    /// Each key pulls the state toward its target from wherever the earlier keys left
    /// it; zoom is sprung in log space so zooming in and out feel alike.
    public func state(at t: Double) -> (zoom: Double, center: CGPoint) {
        var logZoom = 0.0
        var center = CGPoint(x: stage.width / 2, y: stage.height / 2)
        for key in keys where key.time <= t {
            let p = preset.camera.value(t - key.time)
            let to = target(key)
            logZoom += (log(to.zoom) - logZoom) * p
            center.x += (to.center.x - center.x) * p
            center.y += (to.center.y - center.y) * p
        }
        logZoom += log(1 + preset.drift * (0.5 - 0.5 * cos(2 * .pi * t / preset.driftPeriod)))
        let zoom = exp(logZoom)
        // One rule for both cases: a window larger than the canvas keeps covering it, a
        // smaller one stays inside it.
        let k = fit * zoom
        center.x = Self.clamp(center.x, anchor.x / k, stage.width - (canvas.width - anchor.x) / k)
        center.y = Self.clamp(center.y, anchor.y / k, stage.height - (canvas.height - anchor.y) / k)
        return (zoom, center)
    }

    static func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double {
        min(max(v, min(a, b)), max(a, b))
    }

    static func scaled(_ r: CGRect, by s: Double, about p: CGPoint) -> CGRect {
        CGRect(
            x: p.x + (r.minX - p.x) * s, y: p.y + (r.minY - p.y) * s, width: r.width * s, height: r.height * s
        )
    }

    public func placement(at t: Double) -> Placement {
        let s = state(at: t)
        let k = fit * s.zoom
        var rect = CGRect(
            x: anchor.x - s.center.x * k, y: anchor.y - s.center.y * k, width: stage.width * k,
            height: stage.height * k)
        var alpha = 1.0
        switch preset.entry {
        case .riseAfterHook:
            let up = Spring(response: 0.6, damping: 0.75).value(t - entryAt)
            // From wherever the camera holds it, so a zoomed window stays hidden under the hook.
            rect.origin.y += (1 - up) * (canvas.height - rect.minY + min(canvas.width, canvas.height) * 0.1)
        case .fadeIn:
            let p = Ease.out((t - entryAt) / 0.8)
            rect = Self.scaled(rect, by: 0.94 + 0.06 * p, about: CGPoint(x: rect.midX, y: rect.midY))
            alpha = p
        }
        if let exitAt, t > exitAt {
            let q = t - exitAt
            switch preset.exit {
            case .fall:
                // From wherever the camera left it: a fixed offset left a zoomed window on
                // screen under the card.
                let e = Ease.clamp01(q / 0.45)
                rect.origin.y += e * e * (canvas.height - rect.minY + min(canvas.width, canvas.height) * 0.1)
            case .shrinkFade:
                let e = Ease.smooth(q / 0.7)
                rect = Self.scaled(
                    rect, by: 1 - 0.12 * e, about: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
                alpha *= 1 - e
            }
        }
        return Placement(rect: rect, alpha: alpha, zoom: s.zoom, scale: rect.width / stage.width)
    }
}
