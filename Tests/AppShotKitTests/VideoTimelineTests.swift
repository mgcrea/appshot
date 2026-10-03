import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoTimelineTests {
    static func video(_ beats: String, duration: Double = 20, card: Bool = true) throws
        -> Config.Video
    {
        let cardJSON = card ? #", "card": { "title": "T" }"# : ""
        return try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": \(duration), "outputs": { "promo": [[100, 100]] }\(cardJSON),
                   "beats": \(beats) }]
                """
        ).video("v")
    }

    static func timeline(
        _ video: Config.Video, targets: [VideoTrack.Target] = []
    ) throws -> VideoTimeline {
        var track = VideoTrack.stills(
            video: video, appearance: "dark", stageSize: CGSize(width: 1000, height: 600))
        track.targets = targets
        return try VideoTimeline(video: video, track: track)
    }

    @Test func captionRunsToTheNextCaption() throws {
        let t = try Self.timeline(
            Self.video(#"[{"at":0,"caption":"one two"},{"at":5,"caption":"three"}]"#))
        #expect(t.captions.map(\.end) == [5, 20])
        #expect(t.caption(at: 2.5)?.text == "one two")
        #expect(t.caption(at: 5.1)?.text == "three")
    }

    @Test func captionStopsAtTheEndCard() throws {
        let t = try Self.timeline(
            Self.video(#"[{"at":0,"caption":"a"},{"at":8,"endCard":true}]"#))
        #expect(t.captions[0].end == 8)
    }

    @Test func captionFadesInAndOut() throws {
        let t = try Self.timeline(Self.video(#"[{"at":1,"caption":"a","until":3}]"#))
        #expect(t.caption(at: 0.9) == nil)
        #expect(abs((t.caption(at: 1.125)?.opacity ?? 0) - 0.5) < 0.001)
        #expect(t.caption(at: 2)?.opacity == 1)
        #expect(t.caption(at: 3.01) == nil)
    }

    @Test func readingCheckFlagsShortCaptions() throws {
        // 4 words need 1 + 1.2 = 2.2s; shown 2s.
        let t = try Self.timeline(
            Self.video(#"[{"at":0,"caption":"one two three four"},{"at":2,"caption":"b"}]"#))
        #expect(t.readingProblems().map(\.text) == ["one two three four"])
    }

    @Test func cameraEasesToTheTarget() throws {
        let target = VideoTrack.Target(
            seq: 0, name: "row", at: 1, rect: [100, 100, 200, 100], click: false)
        let t = try Self.timeline(
            Self.video(
                #"[{"at":1,"cue":"pointer.move","args":{"target":"row"}},{"at":2,"zoom":{"target":"row","scale":2}}]"#
            ),
            targets: [target])
        #expect(t.camera(at: 1.9, stage: CGSize(width: 1000, height: 600)).scale == 1)
        let done = t.camera(at: 3, stage: CGSize(width: 1000, height: 600))
        #expect(done.scale == 2)
        #expect(done.center == CGPoint(x: 200, y: 150))
    }

    @Test func zoomOnUnreportedTargetThrows() throws {
        let video = try Self.video(#"[{"at":2,"zoom":{"target":"ghost","scale":2}}]"#)
        #expect(throws: AppShotError.self) { try Self.timeline(video) }
    }

    @Test func cursorTravelsThenRipples() throws {
        let a = VideoTrack.Target(seq: 0, name: "a", at: 1, rect: [0, 0, 100, 100], click: false)
        let b = VideoTrack.Target(
            seq: 1, name: "b", at: 3, rect: [400, 0, 100, 100], click: true)
        let t = try Self.timeline(Self.video("[]"), targets: [a, b])
        #expect(t.cursor(at: 0) == nil)
        #expect(t.cursor(at: 2)?.point == CGPoint(x: 50, y: 50))
        let mid = try #require(t.cursor(at: 2.75))
        #expect(mid.point.x > 50 && mid.point.x < 450)
        #expect(t.cursor(at: 3.2)?.point == CGPoint(x: 450, y: 50))
        #expect(abs((t.cursor(at: 3.2)?.ripple ?? 0) - 0.5) < 0.001)
    }
}
