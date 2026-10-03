import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoTrackTests {
    static func video() throws -> Config.Video {
        try VideoConfigTests.config(videos: VideoConfigTests.valid).video("intro")
    }

    @Test func stillsTrackAcksEveryCueOnTime() throws {
        let video = try Self.video()
        let track = VideoTrack.stills(
            video: video, appearance: "dark", stageSize: CGSize(width: 800, height: 500))
        #expect(track.cues.map(\.seq) == [0])
        #expect(track.cues.map(\.cue) == ["pointer.click"])
        #expect(track.cues[0].args["target"] == .string("row-2"))
        #expect(track.cues.allSatisfy { $0.acked == $0.at })
        #expect(track.stage == [0, 0, 800, 500])
        #expect(try track.beatTimes(for: video) == [0, 1.5, 4, 16])
    }

    @Test func roundTripsThroughAFile() throws {
        var track = VideoTrack.stills(
            video: try Self.video(), appearance: "dark", stageSize: CGSize(width: 800, height: 500))
        track.targets = [.init(seq: 1, name: "row-2", at: 1.5, rect: [10, 20, 300, 40], click: true)]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "track-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = VideoTrack.url(in: dir, video: "intro", appearance: "dark")
        #expect(url.lastPathComponent == "intro~dark.track.json")
        try track.write(to: url)
        #expect(try VideoTrack.read(url) == track)
    }

    static func cued(_ acked: Double?) throws -> (Config.Video, VideoTrack) {
        let video = try VideoTimelineTests.video(#"[{"at":0,"caption":"a"},{"at":1,"cue":"x"}]"#)
        var track = VideoTrack.stills(
            video: video, appearance: "dark", stageSize: CGSize(width: 10, height: 10))
        track.cues[0].acked = acked
        return (video, track)
    }

    @Test func ackedTimeWinsOverScheduled() throws {
        let (video, track) = try Self.cued(1.04)
        #expect(try track.beatTimes(for: video) == [0, 1.04])
    }

    @Test func anUnackedCueFallsBackToItsAt() throws {
        let (video, track) = try Self.cued(nil)
        #expect(try track.beatTimes(for: video) == [0, 1])
    }

    @Test(arguments: [
        (#""stage": [0, 0, 10]"#, "stage"),
        (#""targets": [{"seq": 0, "name": "row", "at": 1, "rect": [1, 2, 3], "click": false}]"#, "row"),
    ])
    func readRejectsMisshapenArrays(field: String, named: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "track-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = VideoTrack.url(in: dir, video: "v", appearance: "dark")
        var fields = [
            "stage": #""stage": [0, 0, 10, 10]"#, "targets": #""targets": []"#,
        ]
        fields[field.hasPrefix(#""stage""#) ? "stage" : "targets"] = field
        let json = """
            { "video": "v", "appearance": "dark", "duration": 5, "cues": [], "frames": 0, "maxFrameGap": 0,
              \(fields["stage"]!), \(fields["targets"]!) }
            """
        try Data(json.utf8).write(to: url)
        #expect {
            _ = try VideoTrack.read(url)
        } throws: { error in
            guard case .invalidConfig(_, let why) = error as? AppShotError else { return false }
            return why.contains(named) && why.contains("[x, y, width, height]")
        }
    }
}
