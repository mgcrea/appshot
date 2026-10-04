import CoreGraphics
import Foundation

/// Every time-dependent decision a frame needs, as pure functions of `t`.
///
/// A cued beat happens when the app acknowledged it, so its caption follows what the
/// app actually did; every other beat happens at its `at` in the config as it is now.
public struct VideoTimeline: Sendable {
    public struct CaptionSpan: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        public let words: Int
        /// The video's `hook`, shown as its first caption.
        public var isHook = false

        /// The text as read, accent marks dropped: for messages and the report.
        public var plain: String { KineticText.plain(text) }

        public var shown: Double { end - start }
        /// 1s to notice the text, 0.3s per word to read it.
        public var needed: Double { 1 + 0.3 * Double(words) }
    }

    public static let fade = 0.25
    public static let zoomTransition = 0.6
    public static let pointerTravel = 0.5
    public static let ripple = 0.4
    public static let cardFade = 0.4

    public struct Span: Sendable, Equatable {
        public let from: Double
        public let to: Double
        public let rect: CGRect
    }

    public struct PointerKey: Sendable, Equatable {
        public let time: Double
        public let point: CGPoint
        public let click: Bool
    }

    /// Something a render can make but a viewer will notice. Listed in the report; never
    /// fails the render.
    public struct Warning: Codable, Sendable, Equatable {
        public var kind: String
        public var at: Double
        public var message: String
    }

    public static let pointerGlide = 0.7
    public static let pointerLinger = 2.0

    public let hook: String?
    public let focusKeys: [VideoCamera.Key]
    /// Every spotlight, including the one each pop implies.
    public let spotlights: [Span]
    public let pops: [Span]
    public let pointerKeys: [PointerKey]
    public let duration: Double
    /// When each of the video's beats happens, by index into `beats`.
    public let beatTimes: [Double]
    public let captions: [CaptionSpan]
    public let cardStart: Double?
    private let zooms: [(time: Double, scale: Double, center: CGPoint?)]
    private let pointers: [(time: Double, point: CGPoint, click: Bool)]

    /// How many frames a render writes, and when the last one is. Anything timed after
    /// the last frame (a contact-sheet cell, the poster) must be pulled back to it, or
    /// it is never drawn.
    public var frameCount: Int { Int((duration * Double(VideoWriter.fps)).rounded()) }
    public var lastFrameTime: Double { Double(max(frameCount - 1, 0)) / Double(VideoWriter.fps) }

    public init(video: Config.Video, track: VideoTrack) throws {
        duration = video.duration
        let times = try track.beatTimes(for: video)
        beatTimes = times
        let card = video.beats.indices.first { video.beats[$0].endCard == true }.map { times[$0] }
        cardStart = card

        let captioned = video.beats.indices.filter { video.beats[$0].caption != nil }
        var spans = captioned.enumerated().map { position, index in
            let beat = video.beats[index]
            let start = times[index]
            let next = position + 1 < captioned.count ? times[captioned[position + 1]] : video.duration
            // `until` moves with its beat: a cue acked 40ms late keeps its caption on
            // screen for the span the config asked for.
            let until = beat.until.map { $0 + (start - beat.at) }
            let end = min(until ?? next, card ?? video.duration, video.duration)
            let text = beat.caption ?? ""
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return CaptionSpan(text: text, start: start, end: end, words: words)
        }
        if let hook = video.hook {
            let next = spans.first?.start ?? video.duration
            let words = KineticText.plain(hook).split(whereSeparator: { $0.isWhitespace }).count
            spans.insert(
                CaptionSpan(
                    text: hook, start: 0, end: min(next, card ?? video.duration, video.duration),
                    words: words,
                    isHook: true), at: 0)
        }
        captions = spans
        hook = video.hook

        func region(_ target: String?, _ rect: [Double]?, at time: Double, _ what: String) throws -> CGRect {
            if let rect { return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
            let name = target ?? ""
            // The latest report at or before the beat; an element that moved is wherever
            // the app last said it was.
            guard let found = track.targets.last(where: { $0.name == name && $0.at <= time + 0.001 }) else {
                throw AppShotError.videoRenderFailed(
                    video: video.id,
                    reason:
                        "\(what) at \(time)s targets \"\(name)\", which no pointer cue at or before it reported"
                )
            }
            return CGRect(x: found.rect[0], y: found.rect[1], width: found.rect[2], height: found.rect[3])
        }

        focusKeys = try video.beats.indices.compactMap { i in
            switch video.beats[i].focus {
            case nil: return nil
            case .home: return VideoCamera.Key(time: times[i], rect: nil, fill: nil)
            case .region(let r, let fill)?:
                return VideoCamera.Key(
                    time: times[i], rect: try region(r.target, r.rect, at: times[i], "focus"), fill: fill)
            }
        }.sorted { $0.time < $1.time }

        // `until` moves with its beat, like a caption's: a cue acked late keeps the span
        // the config asked for.
        func emphases(_ key: KeyPath<Config.Beat, Config.Emphasis?>, _ what: String) throws -> [Span] {
            try video.beats.indices.compactMap { i in
                guard let e = video.beats[i][keyPath: key] else { return nil }
                let start = times[i]
                return Span(
                    from: start, to: e.until + (start - video.beats[i].at),
                    rect: try region(e.target, e.rect, at: start, what))
            }
        }
        let popSpans = try emphases(\.pop, "pop")
        pops = popSpans.sorted { $0.from < $1.from }
        spotlights = (try emphases(\.spotlight, "spotlight") + popSpans).sorted { $0.from < $1.from }

        let drawnUnsorted = video.beats.indices.compactMap { i -> PointerKey? in
            guard let move = video.beats[i].pointer else { return nil }
            let point =
                if let p = move.point {
                    CGPoint(x: p[0], y: p[1])
                } else if let r = move.rect {
                    CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
                } else {
                    CGPoint.zero
                }
            return PointerKey(time: times[i], point: point, click: move.click ?? false)
        }
        let drawn = drawnUnsorted.sorted { $0.time < $1.time }
        pointerKeys =
            !drawn.isEmpty
            ? drawn
            : track.targets.sorted { $0.at < $1.at }.map {
                PointerKey(
                    time: $0.at,
                    point: CGPoint(x: $0.rect[0] + $0.rect[2] / 2, y: $0.rect[1] + $0.rect[3] / 2),
                    click: $0.click)
            }

        zooms = try video.beats.indices.compactMap { index in
            guard let zoom = video.beats[index].zoom else { return nil }
            let time = times[index]
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

    /// The drawn pointer at `t`: where it is, how visible, and how long ago it clicked.
    ///
    /// It appears on its first key 0.25 s before that key's time and glides into each
    /// later key over `pointerGlide` along a slight arc, so it *arrives* on time. It
    /// fades out `pointerLinger` after its last key, or as the end card starts.
    public func pointer(at t: Double) -> (point: CGPoint, alpha: Double, clickAge: Double?)? {
        guard let first = pointerKeys.first, t >= first.time - 0.25 else { return nil }
        let gone = min(pointerKeys[pointerKeys.count - 1].time + Self.pointerLinger, cardStart ?? duration)
        guard t < gone + 0.3 else { return nil }
        var point = first.point
        var clickAge: Double?
        for (i, key) in pointerKeys.enumerated() {
            if t >= key.time {
                point = key.point
                clickAge = key.click ? t - key.time : nil
                continue
            }
            guard i > 0 else { break }
            // Never starts before the previous key: two keys closer than the glide would jump.
            let start = max(key.time - Self.pointerGlide, pointerKeys[i - 1].time)
            guard t >= start, key.time > start else { break }
            let e = Ease.smooth((t - start) / (key.time - start))
            let from = pointerKeys[i - 1].point
            let dx = key.point.x - from.x
            let dy = key.point.y - from.y
            let arc = sin(e * .pi) * 0.12
            point = CGPoint(x: from.x + dx * e - dy * arc, y: from.y + dy * e + dx * arc)
            break
        }
        let alpha = min(Ease.clamp01((t - first.time + 0.25) / 0.25), Ease.clamp01((gone + 0.3 - t) / 0.3))
        return (point, alpha, clickAge.flatMap { $0 < 0.5 ? $0 : nil })
    }

    public func warnings(for preset: MotionPreset) -> [Warning] {
        func s(_ x: Double) -> String { String(format: "%.2f", x) }
        var out: [Warning] = []
        for (a, b) in zip(focusKeys, focusKeys.dropFirst()) where b.time - a.time < preset.camera.response {
            out.append(
                Warning(
                    kind: "cameraNeverSettles", at: b.time,
                    message: "focus at \(s(b.time))s comes \(s(b.time - a.time))s after the one before; "
                        + "\(preset.name)'s camera needs \(s(preset.camera.response))s to settle, so the "
                        + "move reads as a whiplash"))
        }
        if pops.count > 3 {
            out.append(
                Warning(
                    kind: "popOverload", at: pops[3].from,
                    message: "\(pops.count) pops: past three, none of them stands out"))
        }
        return out
    }

    public func cardOpacity(at t: Double) -> Double {
        cardStart.map { Self.ease((t - $0) / Self.cardFade) } ?? 0
    }
}
