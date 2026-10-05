import CoreGraphics
import Foundation

/// Moving footage without a take: each beat that names a `screen` plays that screen's
/// clip from its own start, or shows its still when no clip was recorded, with the
/// stills' crossfade between them.
///
/// Sequential, like `RecordedMaster`: `frame(at:)` must be asked for non-decreasing
/// times. A clip is decoded only while its segment, or its crossfade out, is on screen,
/// so at most two decoders are ever open.
public struct ClipsMaster: VideoMaster {
    public struct Segment: Sendable {
        public enum Source: Sendable {
            case clip(movie: URL, info: ClipInfo)
            case still(URL)
        }
        /// Index of the beat that cuts here.
        public let beat: Int
        public let at: Double
        public let screen: String
        public let appearance: String
        public let source: Source

        public var isClip: Bool { if case .clip = source { true } else { false } }
        public var name: String { ClipInfo.name(screen: screen, appearance: appearance) }
    }

    /// Each beat that names a screen, resolved to its clip if one was recorded for this
    /// appearance, else to its still.
    public static func segments(
        video: Config.Video, appearance: String, clipsDir: URL, stillsDir: URL?
    ) throws -> [Segment] {
        let holds = ClipPlan.holds(in: video)
        guard let first = holds.first, first.at == 0 else {
            throw AppShotError.invalidVideo(
                id: video.id, reason: "--from-clips needs a beat at 0 that names a screen")
        }
        return try holds.map { hold in
            let movie = ClipInfo.movieURL(in: clipsDir, screen: hold.screen, appearance: appearance)
            let info = ClipInfo.url(in: clipsDir, screen: hold.screen, appearance: appearance)
            let source: Segment.Source
            if FileManager.default.fileExists(atPath: movie.path),
                FileManager.default.fileExists(atPath: info.path)
            {
                source = .clip(movie: movie, info: try ClipInfo.read(info))
            } else if let stillsDir,
                case let still = stillsDir.appending(path: "\(hold.screen)~\(appearance).png"),
                FileManager.default.fileExists(atPath: still.path)
            {
                source = .still(still)
            } else {
                let fallback =
                    stillsDir.map {
                        " and no still at \($0.appending(path: "\(hold.screen)~\(appearance).png").path)"
                    } ?? "; pass --from-stills to fall back to the screenshot"
                throw AppShotError.invalidVideo(
                    id: video.id,
                    reason: "screen \(hold.screen) has no clip at \(movie.path)\(fallback)")
            }
            return Segment(
                beat: hold.beat, at: hold.at, screen: hold.screen, appearance: appearance, source: source)
        }
    }

    /// A clip with no more frames than this over its whole length never moved.
    static let neverMovedFrames = 3
    /// Pixels a clip and its still may differ by before rects stop landing the same.
    static let sizeTolerance = 2.0

    /// What a clips render refuses before writing anything.
    public static func check(video: Config.Video, segments: [Segment]) throws {
        for (i, beat) in video.beats.enumerated() {
            if beat.cue != nil {
                throw AppShotError.invalidVideo(
                    id: video.id,
                    reason: "beat \(i) has a cue, which needs a recorded take: clips have no cue channel")
            }
            if beat.present != nil {
                throw AppShotError.invalidVideo(
                    id: video.id,
                    reason: "beat \(i) presents a sheet; present is for --from-stills renders. A clip "
                        + "shows the app's own sheet: stage it in the app")
            }
        }
        for (hold, segment) in zip(ClipPlan.holds(in: video), segments) {
            guard case .clip(_, let info) = segment.source, info.length + 1e-6 < hold.needed else { continue }
            throw AppShotError.clipTooShort(
                video: video.id, clip: segment.name, screen: segment.screen, length: info.length,
                needed: hold.needed)
        }
    }

    /// Clips that look wrong without being wrong enough to stop the render. Each clip is
    /// judged once, however many times the video cuts to it.
    public static func warnings(for segments: [Segment], stillsDir: URL?) -> [VideoTimeline.Warning] {
        var seen: Set<String> = []
        var out: [VideoTimeline.Warning] = []
        for segment in segments {
            guard case .clip(_, let info) = segment.source, seen.insert(segment.name).inserted else {
                continue
            }
            if info.frames <= neverMovedFrames {
                out.append(
                    .init(
                        kind: "clipNeverMoved", at: segment.at,
                        message: "\(segment.name) has \(info.frames) frames in "
                            + "\(String(format: "%.1f", info.length))s: does the app read -ScreenshotClip?"))
            }
            if let stillsDir,
                case let url = stillsDir.appending(path: "\(segment.name).png"),
                FileManager.default.fileExists(atPath: url.path),
                let still = try? Image.load(url),
                abs(Double(still.width) - info.size.width) > sizeTolerance
                    || abs(Double(still.height) - info.size.height) > sizeTolerance
            {
                out.append(
                    .init(
                        kind: "clipStillSizeMismatch", at: segment.at,
                        message: "\(segment.name) is \(Int(info.size.width))x\(Int(info.size.height)) as a "
                            + "clip and \(still.width)x\(still.height) as a still: rects written for one "
                            + "land off on the other"))
            }
        }
        return out
    }

    /// A clip being decoded, with the last frame it recoloured. The master holds a frame
    /// only where ScreenCaptureKit sent one, so between two of them the decoder hands back
    /// the same image, and recolouring it again would only cost time. ScreenCaptureKit
    /// sends one whenever anything on the display changes, though, identical or not, so
    /// on a Mac in use the frames come at the stream's rate and this saves work mainly
    /// on a quiet display.
    private final class Live {
        let reader: RecordedMaster
        var lastIn: CGImage?
        var lastOut: CGImage?
        init(_ reader: RecordedMaster) { self.reader = reader }
    }

    public let stageSize: CGSize
    private let segments: [Segment]
    private let video: String
    /// Stills, already centred, by segment index.
    private let stills: [Int: CGImage]
    private var live: [Int: Live] = [:]

    var openDecoders: Int { live.count }

    public init(segments: [Segment], video: String) throws {
        var sizes: [CGSize] = []
        var loaded: [Int: CGImage] = [:]
        for (i, segment) in segments.enumerated() {
            switch segment.source {
            case .clip(_, let info): sizes.append(info.size)
            case .still(let url):
                let image = try Image.load(url)
                loaded[i] = image
                sizes.append(CGSize(width: image.width, height: image.height))
            }
        }
        let size = CGSize(
            width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        stills = try loaded.mapValues { image in
            guard let centered = StillsMaster.centered(image, on: size) else {
                throw AppShotError.videoRenderFailed(video: video, reason: "could not center a still")
            }
            return centered
        }
        stageSize = size
        self.segments = segments
        self.video = video
    }

    public mutating func frame(at t: Double) throws -> CGImage {
        let index = segments.lastIndex { $0.at <= t } ?? 0
        let q = t - segments[index].at
        let fading = index > 0 && q < StillsMaster.crossfade
        // Release what can no longer be on screen before opening anything new.
        for open in live.keys where open < index - 1 || (open == index - 1 && !fading) {
            live[open] = nil
        }
        let current = try image(of: index, at: q)
        guard fading else { return current }
        let previous = try image(of: index - 1, at: t - segments[index - 1].at)
        return StillsMaster.blend(previous, current, q: q, size: stageSize)
    }

    private mutating func image(of index: Int, at clipTime: Double) throws -> CGImage {
        let segment = segments[index]
        guard case .clip(let movie, let info) = segment.source else {
            guard let still = stills[index] else {
                throw AppShotError.videoRenderFailed(video: video, reason: "no still for \(segment.name)")
            }
            return still
        }
        let clip: Live
        if let open = live[index] {
            clip = open
        } else {
            clip = Live(try RecordedMaster(url: movie, crop: info.crop, label: segment.name))
            live[index] = clip
        }
        let decoded = try clip.reader.frame(at: clipTime)
        if decoded === clip.lastIn, let out = clip.lastOut { return out }
        var image = decoded
        if let lights = info.trafficLights {
            image = try TrafficLights.recolor(
                image, windowOrigin: CGPoint(x: lights.origin[0], y: lights.origin[1]), scale: lights.scale,
                screen: segment.name
            ).image
        }
        guard let out = StillsMaster.centered(image, on: stageSize) else {
            throw AppShotError.videoRenderFailed(video: video, reason: "could not center \(segment.name)")
        }
        clip.lastIn = decoded
        clip.lastOut = out
        return out
    }
}
