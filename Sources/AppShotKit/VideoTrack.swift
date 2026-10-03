import CoreGraphics
import Foundation

/// What actually happened during a take, as opposed to what the config planned.
///
/// Rendering reads this and never the plan, so a cue that reached the app 40ms late
/// moves its caption with it and the text cannot drift from the screen.
public struct VideoTrack: Codable, Sendable, Equatable {
    public struct Beat: Codable, Sendable, Equatable {
        /// Index into the video's `beats`.
        public var index: Int
        public var scheduled: Double
        /// When the app said the cue's effect was on screen. Nil for a beat with no cue,
        /// which happens exactly when scheduled.
        public var acked: Double?
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
    public var beats: [Beat]
    public var targets: [Target]
    public var frames: Int
    /// Longest gap between two recorded frames, in seconds. The proxy for dropped
    /// frames: SCStream sends nothing while the screen is still, so a count alone
    /// cannot tell a stall from a quiet screen.
    public var maxFrameGap: Double

    public var stageSize: CGSize { CGSize(width: stage[2], height: stage[3]) }

    public func time(ofBeat index: Int) -> Double {
        guard let beat = beats.first(where: { $0.index == index }) else { return 0 }
        return beat.acked ?? beat.scheduled
    }

    /// The track a `--from-stills` render pretends was recorded: every beat on time,
    /// nothing reported, the whole canvas as the stage.
    public static func stills(
        video: Config.Video, appearance: String, stageSize: CGSize
    ) -> VideoTrack {
        VideoTrack(
            video: video.id, appearance: appearance, duration: video.duration,
            stage: [0, 0, stageSize.width, stageSize.height],
            beats: video.beats.enumerated().map {
                .init(index: $0.offset, scheduled: $0.element.at, acked: $0.element.at)
            },
            targets: [], frames: 0, maxFrameGap: 0)
    }

    public static func url(in dir: URL, video: String, appearance: String) -> URL {
        dir.appending(path: "\(video)~\(appearance).track.json")
    }

    public static func read(_ url: URL) throws -> VideoTrack {
        do {
            return try JSONDecoder().decode(VideoTrack.self, from: Data(contentsOf: url))
        } catch {
            throw AppShotError.invalidConfig(url, "unreadable track: \(error)")
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
