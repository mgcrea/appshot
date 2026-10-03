import CoreGraphics
import Foundation

/// Every time-dependent decision a frame needs, as pure functions of `t`.
///
/// Built from the track's times rather than the config's, so everything here follows
/// what the app actually did.
public struct VideoTimeline: Sendable {
    public struct CaptionSpan: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        public let words: Int

        public var shown: Double { end - start }
        /// 1s to notice the text, 0.3s per word to read it.
        public var needed: Double { 1 + 0.3 * Double(words) }
    }

    public static let fade = 0.25
    public static let zoomTransition = 0.6
    public static let pointerTravel = 0.5
    public static let ripple = 0.4
    public static let cardFade = 0.4

    public let duration: Double
    public let captions: [CaptionSpan]
    public let cardStart: Double?
    private let zooms: [(time: Double, scale: Double, center: CGPoint?)]
    private let pointers: [(time: Double, point: CGPoint, click: Bool)]

    public init(video: Config.Video, track: VideoTrack) throws {
        duration = video.duration
        let card = video.beats.indices.first { video.beats[$0].endCard == true }.map {
            track.time(ofBeat: $0)
        }
        cardStart = card

        let captioned = video.beats.indices.filter { video.beats[$0].caption != nil }
        captions = captioned.enumerated().map { position, index in
            let beat = video.beats[index]
            let start = track.time(ofBeat: index)
            let next =
                position + 1 < captioned.count
                ? track.time(ofBeat: captioned[position + 1])
                : video.duration
            let end = min(beat.until ?? next, card ?? video.duration, video.duration)
            let text = beat.caption ?? ""
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return CaptionSpan(text: text, start: start, end: end, words: words)
        }

        zooms = try video.beats.indices.compactMap { index in
            guard let zoom = video.beats[index].zoom else { return nil }
            let time = track.time(ofBeat: index)
            if zoom.scale == 1 { return (time, 1, nil) }
            if let rect = zoom.rect {
                return (
                    time, zoom.scale,
                    CGPoint(
                        x: rect[0] + rect[2] / 2, y: rect[1] + rect[3] / 2)
                )
            }
            let name = zoom.target ?? ""
            // The latest report at or before the zoom; an element that moved is wherever
            // the app last said it was.
            guard
                let target = track.targets.last(
                    where: { $0.name == name && $0.at <= time + 0.001 })
            else {
                throw AppShotError.videoRenderFailed(
                    video: video.id,
                    reason:
                        "zoom at \(time)s targets \"\(name)\", which no pointer cue at or before it reported"
                )
            }
            let r = target.rect
            return (time, zoom.scale, CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2))
        }

        pointers = track.targets.sorted { $0.at < $1.at }.map {
            (
                $0.at, CGPoint(x: $0.rect[0] + $0.rect[2] / 2, y: $0.rect[1] + $0.rect[3] / 2),
                $0.click
            )
        }
    }

    public static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    public func caption(at t: Double) -> (text: String, opacity: Double)? {
        guard let span = captions.last(where: { $0.start <= t && t <= $0.end }) else {
            return nil
        }
        let opacity = min(1, (t - span.start) / Self.fade, (span.end - t) / Self.fade)
        return opacity > 0 ? (span.text, opacity) : nil
    }

    public func readingProblems() -> [CaptionSpan] {
        captions.filter { $0.shown < $0.needed }
    }

    public func camera(at t: Double, stage: CGSize) -> (scale: Double, center: CGPoint) {
        let home = CGPoint(x: stage.width / 2, y: stage.height / 2)
        var scale = 1.0
        var center = home
        for zoom in zooms where zoom.time <= t {
            let p = Self.ease((t - zoom.time) / Self.zoomTransition)
            let to = zoom.center ?? home
            scale += (zoom.scale - scale) * p
            center = CGPoint(
                x: center.x + (to.x - center.x) * p, y: center.y + (to.y - center.y) * p)
        }
        return (scale, center)
    }

    /// The drawn pointer: hidden until the first report is due, then travelling into
    /// each target over `pointerTravel` so it *arrives* when the cue fires, with a
    /// ripple after a click.
    public func cursor(at t: Double) -> (point: CGPoint, ripple: Double?)? {
        guard let first = pointers.first, t >= first.time - Self.pointerTravel else {
            return nil
        }
        let arrivedIndex = pointers.lastIndex { $0.time <= t }
        let arrived = arrivedIndex.map { pointers[$0] }
        let nextIndex = arrivedIndex.map { $0 + 1 } ?? 0
        if nextIndex < pointers.count, t >= pointers[nextIndex].time - Self.pointerTravel {
            let next = pointers[nextIndex]
            let from = arrived?.point ?? next.point
            let p = Self.ease((t - (next.time - Self.pointerTravel)) / Self.pointerTravel)
            return (
                CGPoint(
                    x: from.x + (next.point.x - from.x) * p,
                    y: from.y + (next.point.y - from.y) * p), nil
            )
        }
        guard let arrived else { return nil }
        let age = t - arrived.time
        return (
            arrived.point,
            arrived.click && age < Self.ripple ? age / Self.ripple : nil
        )
    }

    public func cardOpacity(at t: Double) -> Double {
        cardStart.map { Self.ease((t - $0) / Self.cardFade) } ?? 0
    }
}
