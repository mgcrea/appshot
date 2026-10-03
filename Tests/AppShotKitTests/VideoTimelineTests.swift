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

/// A take is recorded once and rendered many times: everything but the cues may change
/// in the config between the two, and the render must follow the config as it is now.
struct VideoRerenderTests {
    /// What `record` would have written for `taken`, each cue acked at `acks[n]`.
    static func recorded(_ taken: Config.Video, acks: [Double]) -> VideoTrack {
        var track = VideoTrack.stills(
            video: taken, appearance: "dark", stageSize: CGSize(width: 1000, height: 600))
        for i in track.cues.indices { track.cues[i].acked = acks[i] }
        return track
    }

    @Test func movingACaptionAfterTheTakeMovesIt() throws {
        // 4 words need 2.2s; the take showed them for 2s, and the error says to move the
        // next caption later. Doing so must fix it without a re-record.
        let taken = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"one two three four"},{"at":1.5,"cue":"x"},{"at":2,"caption":"b"}]"#)
        let track = Self.recorded(taken, acks: [1.54])
        let edited = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"one two three four"},{"at":1.5,"cue":"x"},{"at":3,"caption":"b"}]"#)
        let timeline = try VideoTimeline(video: edited, track: track)
        #expect(timeline.captions.map(\.start) == [0, 3])
        #expect(timeline.captions[0].end == 3)
        #expect(timeline.readingProblems().isEmpty)
    }

    /// The take only lasts as long as it was recorded; past its end the master has no
    /// frames, and a render would silently hold the last one.
    @Test func aVideoLongerThanTheTakeAsksForARerecord() throws {
        let taken = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"}]"#, duration: 12)
        let track = Self.recorded(taken, acks: [2.04])
        let longer = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"}]"#, duration: 16)
        #expect {
            try VideoTimeline(video: longer, track: track)
        } throws: { error in
            guard case .videoRenderFailed(_, let reason) = error as? AppShotError else { return false }
            return reason.contains("12") && reason.contains("16") && reason.contains("re-record")
        }
    }

    @Test func aVideoShorterThanTheTakeRenders() throws {
        let taken = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"}]"#, duration: 16)
        let track = Self.recorded(taken, acks: [2.04])
        let shorter = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"}]"#, duration: 12)
        #expect(try VideoTimeline(video: shorter, track: track).duration == 12)
    }

    /// `until` can only end a caption earlier, so suggesting it for one that is too short
    /// sends the reader to a fix that cannot work.
    @Test func theTooShortMessageOffersOnlyFixesThatWork() {
        let message = AppShotError.captionTooShort(video: "v", caption: "a b c", shown: 1, needed: 1.9)
            .description
        #expect(!message.contains("until"))
        #expect(message.contains("cut words"))
        #expect(message.contains("later"))
    }

    @Test func anEndCardAddedAfterTheTakeStartsAtItsAt() throws {
        let taken = try VideoTimelineTests.video(#"[{"at":0,"caption":"a"},{"at":2,"cue":"x"}]"#)
        let track = Self.recorded(taken, acks: [2.05])
        let edited = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"},{"at":9,"endCard":true}]"#)
        let timeline = try VideoTimeline(video: edited, track: track)
        #expect(timeline.cardStart == 9)
        #expect(timeline.captions.map(\.end) == [9])
        #expect(timeline.captions.allSatisfy { $0.shown > 0 })
    }

    @Test func aBeatInsertedAfterTheTakeLeavesLaterCuesOnTheirAcks() throws {
        let taken = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"},{"at":6,"cue":"y","caption":"b"}]"#)
        let track = Self.recorded(taken, acks: [2.08, 6.03])
        let edited = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"},{"at":4,"caption":"c"},{"at":6,"cue":"y","caption":"b"}]"#
        )
        let timeline = try VideoTimeline(video: edited, track: track)
        #expect(timeline.captions.map(\.text) == ["a", "c", "b"])
        #expect(timeline.captions.map(\.start) == [0, 4, 6.03])
        #expect(timeline.captions.map(\.end) == [4, 6.03, 20])
    }

    @Test(arguments: [
        // Another target.
        #"[{"at":0,"caption":"a"},{"at":2,"cue":"pointer.click","args":{"target":"row-3"}}]"#,
        // Another time.
        #"[{"at":0,"caption":"a"},{"at":2.5,"cue":"pointer.click","args":{"target":"row-2"}}]"#,
        // Another cue.
        #"[{"at":0,"caption":"a"},{"at":2,"cue":"pointer.move","args":{"target":"row-2"}}]"#,
        // One more cue.
        #"[{"at":0,"caption":"a"},{"at":2,"cue":"pointer.click","args":{"target":"row-2"}},{"at":3,"cue":"x"}]"#,
        // One cue fewer.
        #"[{"at":0,"caption":"a"}]"#,
    ])
    func changedCuesNeedARerecord(edited: String) throws {
        let taken = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"pointer.click","args":{"target":"row-2"}}]"#)
        let track = Self.recorded(taken, acks: [2.04])
        let video = try VideoTimelineTests.video(edited)
        #expect {
            _ = try VideoTimeline(video: video, track: track)
        } throws: { error in
            guard case .videoRenderFailed(let id, let reason) = error as? AppShotError else { return false }
            return id == "v" && reason.contains("cues changed") && reason.contains("re-record")
        }
    }

    @Test func untilMovesWithALateAck() throws {
        let taken = try VideoTimelineTests.video(#"[{"at":2,"cue":"x","caption":"hello","until":5}]"#)
        let track = Self.recorded(taken, acks: [2.1])
        let timeline = try VideoTimeline(video: taken, track: track)
        let span = try #require(timeline.captions.first)
        #expect(span.start == 2.1)
        #expect(abs(span.end - 5.1) < 1e-9)
        #expect(abs(span.shown - 3) < 1e-9)
    }

    @Test func aZoomFindsItsTargetWithTheNewTimes() throws {
        let target = VideoTrack.Target(seq: 0, name: "row", at: 1, rect: [100, 100, 200, 100], click: false)
        let stage = CGSize(width: 1000, height: 600)
        // A zoom on the cue's own beat happens at the late ack, after the report.
        let own = try VideoTimelineTests.video(
            #"[{"at":1,"cue":"pointer.move","args":{"target":"row"},"zoom":{"target":"row","scale":2}}]"#)
        var track = Self.recorded(own, acks: [1.05])
        track.targets = [target]
        #expect(try VideoTimeline(video: own, track: track).camera(at: 2, stage: stage).scale == 2)

        // A zoom beat moved later after the take still finds the earlier report.
        let taken = try VideoTimelineTests.video(
            #"[{"at":1,"cue":"pointer.move","args":{"target":"row"}},{"at":2,"zoom":{"target":"row","scale":2}}]"#
        )
        track = Self.recorded(taken, acks: [1.04])
        track.targets = [target]
        let moved = try VideoTimelineTests.video(
            #"[{"at":1,"cue":"pointer.move","args":{"target":"row"}},{"at":3,"zoom":{"target":"row","scale":2}}]"#
        )
        let timeline = try VideoTimeline(video: moved, track: track)
        #expect(timeline.camera(at: 2.9, stage: stage).scale == 1)
        let done = timeline.camera(at: 3.7, stage: stage)
        #expect(done.scale == 2 && done.center == CGPoint(x: 200, y: 150))
    }
}
