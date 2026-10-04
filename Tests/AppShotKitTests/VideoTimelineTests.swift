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

struct VideoMotionTimelineTests {
    static func timeline(_ json: String, hook: String? = nil, targets: [VideoTrack.Target] = []) throws
        -> VideoTimeline
    {
        var video = try VideoTimelineTests.video(json)
        video.hook = hook
        var track = VideoTrack.stills(
            video: video, appearance: "dark", stageSize: CGSize(width: 1000, height: 600))
        track.targets = targets
        return try VideoTimeline(video: video, track: track)
    }

    @Test func focusKeysResolveRectsTargetsAndHome() throws {
        let row = VideoTrack.Target(seq: 0, name: "row", at: 1, rect: [100, 100, 200, 50], click: false)
        let t = try Self.timeline(
            #"""
            [{"at":1,"cue":"pointer.move","args":{"target":"row"}},
             {"at":2,"focus":{"target":"row","fill":0.5}},
             {"at":4,"focus":{"rect":[0,0,10,20]}},
             {"at":6,"focus":"home"}]
            """#, targets: [row])
        #expect(t.focusKeys.map(\.time) == [2, 4, 6])
        #expect(t.focusKeys[0].rect == CGRect(x: 100, y: 100, width: 200, height: 50))
        #expect(t.focusKeys[0].fill == 0.5)
        #expect(t.focusKeys[1].rect == CGRect(x: 0, y: 0, width: 10, height: 20))
        #expect(t.focusKeys[2].rect == nil)
    }

    @Test func aFocusOnAnUnreportedTargetThrows() throws {
        #expect {
            _ = try Self.timeline(#"[{"at":2,"focus":{"target":"ghost"}}]"#)
        } throws: { error in
            guard case .videoRenderFailed(_, let why) = error as? AppShotError else { return false }
            return why.contains("ghost") && why.contains("no pointer cue")
        }
    }

    @Test func aPopAlsoSpotlightsItsRegion() throws {
        let t = try Self.timeline(
            #"[{"at":1,"spotlight":{"rect":[0,0,10,10],"until":3}},{"at":4,"pop":{"rect":[5,5,20,20],"until":6}}]"#
        )
        #expect(t.pops == [.init(from: 4, to: 6, rect: CGRect(x: 5, y: 5, width: 20, height: 20))])
        #expect(t.spotlights.map(\.from) == [1, 4])
    }

    @Test func thePointerGlidesIntoEachKeyAndClicks() throws {
        let t = try Self.timeline(
            #"[{"at":1,"pointer":{"point":[100,100]}},{"at":3,"pointer":{"rect":[480,180,40,40],"click":true}}]"#
        )
        #expect(t.pointer(at: 0.5) == nil)
        #expect(t.pointer(at: 1)?.point == CGPoint(x: 100, y: 100))
        let mid = try #require(t.pointer(at: 2.65))
        #expect(mid.point.x > 100 && mid.point.x < 500)
        let landed = try #require(t.pointer(at: 3.1))
        #expect(landed.point == CGPoint(x: 500, y: 200))
        #expect(abs((landed.clickAge ?? -1) - 0.1) < 1e-9)
        #expect(t.pointer(at: 3.6)?.clickAge == nil)
        // Gone pointerLinger after the last key.
        #expect(t.pointer(at: 5.5) == nil)
    }

    @Test func theHookIsTheFirstCaptionUntilTheNextOne() throws {
        let t = try Self.timeline(#"[{"at":5,"caption":"next"}]"#, hook: "Your folder is a *mess*.")
        #expect(t.hook == "Your folder is a *mess*.")
        let first = try #require(t.captions.first)
        #expect(first.isHook && first.start == 0 && first.end == 5)
        #expect(first.plain == "Your folder is a mess.")
        #expect(first.words == 5)
    }

    @Test func aHookTooLongForItsSpanIsAReadingProblem() throws {
        let t = try Self.timeline(
            #"[{"at":2,"caption":"next"}]"#, hook: "one two three four five six seven eight")
        #expect(t.readingProblems().first?.isHook == true)
    }

    @Test func focusMovesTooCloseTogetherWarn() throws {
        let t = try Self.timeline(#"[{"at":1,"focus":{"rect":[0,0,10,10]}},{"at":1.4,"focus":"home"}]"#)
        #expect(t.warnings(for: .kinetic).map(\.kind) == ["cameraNeverSettles"])
        #expect(t.warnings(for: .studio).map(\.kind) == ["cameraNeverSettles"])
        let calm = try Self.timeline(#"[{"at":1,"focus":{"rect":[0,0,10,10]}},{"at":3,"focus":"home"}]"#)
        #expect(calm.warnings(for: .studio).isEmpty)
    }

    @Test func morePopsThanThreeWarn() throws {
        let pops = (0..<4).map { #"{"at":\#($0 * 2 + 1),"pop":{"rect":[0,0,10,10],"until":\#($0 * 2 + 2)}}"# }
        let t = try Self.timeline("[\(pops.joined(separator: ","))]")
        #expect(t.warnings(for: .kinetic).map(\.kind) == ["popOverload"])
    }

    @Test func keysCloserThanTheGlideDoNotJump() throws {
        let t = try Self.timeline(
            #"[{"at":1,"pointer":{"point":[100,100],"click":true}},{"at":1.3,"pointer":{"point":[500,300]}}]"#
        )
        let before = try #require(t.pointer(at: 0.999)).point
        let after = try #require(t.pointer(at: 1.001))
        #expect(hypot(after.point.x - before.x, after.point.y - before.y) < 1)
        // The click pulse survives the glide that follows it.
        #expect(try #require(t.pointer(at: 1.1)).clickAge != nil)
        #expect(t.pointer(at: 1.3)?.point == CGPoint(x: 500, y: 300))
    }

    @Test func aTakeThatReordersBeatsKeepsKeysInTimeOrder() throws {
        let video = try VideoTimelineTests.video(
            #"[{"at":2,"cue":"pointer.move","args":{"target":"row"},"focus":{"rect":[0,0,10,10]}},{"at":3,"focus":"home"}]"#
        )
        var track = VideoTrack.stills(
            video: video, appearance: "dark", stageSize: CGSize(width: 1000, height: 600))
        track.targets = [VideoTrack.Target(seq: 0, name: "row", at: 2, rect: [0, 0, 10, 10], click: false)]
        track.cues[0].acked = 5
        let t = try VideoTimeline(video: video, track: track)
        #expect(t.focusKeys.map(\.time) == [3, 5])
    }
}
