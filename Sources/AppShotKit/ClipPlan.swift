import Foundation

/// Which clips a set of videos needs, and how long each must run.
///
/// A clip plays from its own start every time a `screen` beat cuts to it, and keeps
/// playing under the crossfade into the next screen. So it must last as long as the
/// longest such hold, plus the crossfade, plus a margin that keeps a frame time rounded
/// up from ever landing past the end.
public enum ClipPlan {
    /// Seconds recorded past the longest need.
    public static let margin = 0.5

    public struct Hold: Sendable, Equatable {
        /// Index of the beat that cuts to the screen.
        public let beat: Int
        public let screen: String
        public let at: Double
        /// Until the next cut, or the video's end.
        public let seconds: Double

        /// How long the clip must run for this hold.
        public var needed: Double { seconds + StillsMaster.crossfade }
    }

    /// Every beat of `video` that names a screen, with how long the video stays on it.
    public static func holds(in video: Config.Video) -> [Hold] {
        let cuts = video.beats.enumerated().compactMap { index, beat in
            beat.screen.map { (index, beat.at, $0) }
        }
        return cuts.enumerated().map { i, cut in
            let end = i + 1 < cuts.count ? cuts[i + 1].1 : video.duration
            return Hold(beat: cut.0, screen: cut.2, at: cut.1, seconds: end - cut.1)
        }
    }

    /// The length to record for each screen the videos name: its longest need, plus the
    /// margin.
    public static func lengths(for videos: [Config.Video]) -> [String: Double] {
        var out: [String: Double] = [:]
        for video in videos {
            for hold in holds(in: video) {
                out[hold.screen] = max(out[hold.screen] ?? 0, hold.needed + margin)
            }
        }
        return out
    }
}
