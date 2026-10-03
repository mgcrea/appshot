import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoTrackTests {
    static func video() throws -> Config.Video {
        try VideoConfigTests.config(videos: VideoConfigTests.valid).video("intro")
    }

    @Test func stillsTrackAcksEveryBeatOnTime() throws {
        let track = VideoTrack.stills(
            video: try Self.video(), appearance: "dark", stageSize: CGSize(width: 800, height: 500))
        #expect(track.beats.map(\.index) == [0, 1, 2, 3])
        #expect(track.beats.allSatisfy { $0.acked == $0.scheduled })
        #expect(track.stage == [0, 0, 800, 500])
        #expect(track.time(ofBeat: 2) == 4)
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

    @Test func ackedTimeWinsOverScheduled() {
        let track = VideoTrack(
            video: "v", appearance: "dark", duration: 5, stage: [0, 0, 10, 10],
            beats: [.init(index: 0, scheduled: 1, acked: 1.04)], targets: [], frames: 0, maxFrameGap: 0)
        #expect(track.time(ofBeat: 0) == 1.04)
    }
}
