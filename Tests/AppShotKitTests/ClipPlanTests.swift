import Foundation
import Testing

@testable import AppShotKit

struct ClipPlanTests {
    static func video(_ id: String, duration: Double, cuts: [(Double, String)]) throws -> Config.Video {
        let beats = cuts.map { #"{ "at": \#($0.0), "screen": "\#($0.1)" }"# }.joined(separator: ", ")
        return try VideoConfigTests.config(
            videos: """
                [{ "id": "\(id)", "duration": \(duration), "outputs": { "promo": [[100, 100]] },
                   "beats": [\(beats)] }]
                """
        ).video(id)
    }

    @Test func eachCutHoldsUntilTheNextCutOrTheEnd() throws {
        let v = try Self.video("v", duration: 10, cuts: [(0, "browser"), (4, "paywall"), (7, "browser")])
        let holds = ClipPlan.holds(in: v)
        #expect(holds.map(\.screen) == ["browser", "paywall", "browser"])
        #expect(holds.map(\.at) == [0, 4, 7])
        #expect(holds.map(\.seconds) == [4, 3, 3])
        #expect(holds.map(\.beat) == [0, 1, 2])
        // The outgoing clip keeps playing under the crossfade into the next screen.
        #expect(holds[0].needed == 4 + StillsMaster.crossfade)
    }

    @Test func aScreenSharedByTwoVideosGetsTheLongestNeedPlusTheMargin() throws {
        let a = try Self.video("a", duration: 6, cuts: [(0, "browser"), (2, "paywall")])
        let b = try Self.video("b", duration: 9, cuts: [(0, "paywall"), (5, "browser")])
        let lengths = ClipPlan.lengths(for: [a, b])
        // browser: a holds it 2 s, b holds it 4 s (5 → 9).
        #expect(lengths["browser"] == 4 + StillsMaster.crossfade + ClipPlan.margin)
        // paywall: a holds it 4 s (2 → 6), b holds it 5 s.
        #expect(lengths["paywall"] == 5 + StillsMaster.crossfade + ClipPlan.margin)
        #expect(lengths.count == 2)
    }

    @Test func aVideoWithNoScreenNeedsNoClip() throws {
        let v = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "stage": "s", "duration": 4, "outputs": { "promo": [[100, 100]] },
                   "beats": [{ "at": 0, "caption": "Hi there" }] }]
                """
        ).video("v")
        #expect(ClipPlan.holds(in: v).isEmpty)
        #expect(ClipPlan.lengths(for: [v]).isEmpty)
    }
}
