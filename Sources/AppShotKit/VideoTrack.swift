import CoreGraphics
import Foundation

/// What actually happened during a take, as opposed to what the config planned.
///
/// Only the cues are frozen at record time: they are what the app did on screen. Every
/// other beat (a caption, a zoom, the end card) is read from the config as it is when
/// rendering, so copy and pacing change with a render, never a re-record.
public struct VideoTrack: Codable, Sendable, Equatable {
    /// One cue as it was sent, and when the app said its effect was on screen.
    public struct Cue: Codable, Sendable, Equatable {
        /// The cue's rank among the video's cue beats, as `Recorder.cueLines` numbers it.
        public var seq: Int
        public var cue: String
        public var args: [String: Config.CueValue]
        /// The beat's `at` when the take was recorded.
        public var at: Double
        /// Nil only for a cue that was never acknowledged; such a take normally fails.
        public var acked: Double?

        public var time: Double { acked ?? at }
    }

    /// An element the app reported in answer to a pointer cue.
    public struct Target: Codable, Sendable, Equatable {
        public var seq: Int
        public var name: String
        /// The scheduled time of the cue that reported it.
        public var at: Double
        /// Stage pixels, top-left origin: x, y, width, height.
        public var rect: [Double]
        public var click: Bool
    }

    public var video: String
    public var appearance: String
    public var duration: Double
    /// The crop applied to the master, in master pixels: x, y, width, height.
    public var stage: [Double]
    public var cues: [Cue]
    public var targets: [Target]
    public var frames: Int
    /// Longest gap between two recorded frames, in seconds. The proxy for dropped
    /// frames: SCStream sends nothing while the screen is still, so a count alone
    /// cannot tell a stall from a quiet screen.
    public var maxFrameGap: Double

    public var stageSize: CGSize { CGSize(width: stage[2], height: stage[3]) }

    /// The cues `video` sends, numbered as `record` numbers them, none acknowledged yet.
    public static func plannedCues(for video: Config.Video) -> [Cue] {
        Recorder.cueLines(for: video).map {
            Cue(seq: $0.seq, cue: $0.line.cue, args: $0.line.args, at: $0.line.t, acked: nil)
        }
    }

    /// When each of `video`'s beats happens: a cued beat when the app acknowledged its
    /// cue, matched by rank, and any other beat at its `at`.
    ///
    /// Throws when the config's cues are no longer the ones recorded, or when the video
    /// now runs past the end of the take. The master shows what the old cues did, for as
    /// long as it was recorded, and nothing a render can do would make it show the new
    /// cues or the missing seconds; past the end it would only hold the last frame.
    public func beatTimes(for video: Config.Video) throws -> [Double] {
        if video.duration > duration + 1e-6 {
            throw AppShotError.videoRenderFailed(
                video: video.id,
                reason: "the take is \(duration)s long and the video asks for \(video.duration)s; "
                    + "re-record with appshot record, or shorten duration")
        }
        let planned = Self.plannedCues(for: video)
        if let difference = Self.firstDifference(planned: planned, taken: cues) {
            throw AppShotError.videoRenderFailed(
                video: video.id,
                reason: "the cues changed since the take (\(difference)); re-record with appshot record")
        }
        var rank = 0
        return video.beats.map { beat in
            guard beat.cue != nil else { return beat.at }
            defer { rank += 1 }
            return cues[rank].time
        }
    }

    static func firstDifference(planned: [Cue], taken: [Cue]) -> String? {
        func describe(_ cue: Cue) -> String {
            let args = cue.args.sorted { $0.key < $1.key }.map { "\($0.key): \(describe($0.value))" }
            let shown = args.isEmpty ? "" : " {\(args.joined(separator: ", "))}"
            return "\(cue.cue)\(shown) at \(cue.at)s"
        }
        func describe(_ value: Config.CueValue) -> String {
            switch value {
            case .string(let s): "\"\(s)\""
            case .number(let n): "\(n)"
            case .bool(let b): "\(b)"
            }
        }
        for (now, then) in zip(planned, taken)
        where now.cue != then.cue || now.args != then.args || abs(now.at - then.at) > 1e-6 {
            return "cue #\(now.seq) is \(describe(now)) in the config, \(describe(then)) in the take"
        }
        if planned.count > taken.count {
            return "cue #\(taken.count) \(describe(planned[taken.count])) is new"
        }
        if taken.count > planned.count {
            return "cue #\(planned.count) \(describe(taken[planned.count])) is gone from the config"
        }
        return nil
    }

    /// The track a `--from-stills` render pretends was recorded: every cue on time,
    /// nothing reported, the whole canvas as the stage.
    public static func stills(
        video: Config.Video, appearance: String, stageSize: CGSize
    ) -> VideoTrack {
        VideoTrack(
            video: video.id, appearance: appearance, duration: video.duration,
            stage: [0, 0, stageSize.width, stageSize.height],
            cues: plannedCues(for: video).map {
                var cue = $0
                cue.acked = cue.at
                return cue
            },
            targets: [], frames: 0, maxFrameGap: 0)
    }

    public static func url(in dir: URL, video: String, appearance: String) -> URL {
        dir.appending(path: "\(video)~\(appearance).track.json")
    }

    /// Checks the shapes JSON cannot: a stage or a rect of the wrong length would
    /// otherwise trap mid-render instead of failing here, naming the file.
    public static func read(_ url: URL) throws -> VideoTrack {
        let track: VideoTrack
        do {
            track = try JSONDecoder().decode(VideoTrack.self, from: Data(contentsOf: url))
        } catch {
            throw AppShotError.invalidConfig(url, "unreadable track: \(error)")
        }
        guard track.stage.count == 4 else {
            throw AppShotError.invalidConfig(
                url, "the track's stage has \(track.stage.count) numbers, not [x, y, width, height]")
        }
        if let bad = track.targets.first(where: { $0.rect.count != 4 }) {
            throw AppShotError.invalidConfig(
                url,
                "target \"\(bad.name)\" (cue #\(bad.seq)) has \(bad.rect.count) numbers in its rect, "
                    + "not [x, y, width, height]")
        }
        return track
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
