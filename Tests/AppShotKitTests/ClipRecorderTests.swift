import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct ClipRecorderTests {
    static func options(screens: [Capture.Screen] = [], extraArgs: [String] = []) throws
        -> ClipRecorder.Options
    {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "a", "duration": 6, "outputs": { "promo": [[100, 100]] },
                   "beats": [{ "at": 0, "screen": "browser" }, { "at": 2, "screen": "paywall" }] },
                 { "id": "b", "duration": 9, "outputs": { "promo": [[100, 100]] },
                   "beats": [{ "at": 0, "screen": "paywall" }, { "at": 5, "screen": "browser" }] }]
                """)
        config.appearances = ["dark"]
        return ClipRecorder.Options(
            capture: Capture.Options(
                app: URL(fileURLWithPath: "/Applications/Nothing.app"),
                outDir: URL(fileURLWithPath: NSTemporaryDirectory()), screens: screens, appearances: ["dark"],
                extraArgs: extraArgs, noActivate: true),
            config: config, videos: config.videos ?? [])
    }

    @Test func plansEveryScreenTheVideosNameAtItsLongestNeed() throws {
        let plan = try ClipRecorder.plan(Self.options())
        #expect(plan.map(\.screen.name) == ["browser", "paywall"])
        #expect(plan.map(\.screen.stage) == ["browser", "paywall"])
        #expect(plan[0].length == 4 + StillsMaster.crossfade + ClipPlan.margin)
        #expect(plan[1].length == 5 + StillsMaster.crossfade + ClipPlan.margin)
    }

    @Test func screensNarrowThePlanAndMapStages() throws {
        let plan = try ClipRecorder.plan(
            Self.options(screens: [try Capture.Screen(spec: "paywall:paywall-play")]))
        #expect(plan.map(\.screen.name) == ["paywall"])
        #expect(plan.map(\.screen.stage) == ["paywall-play"])
    }

    @Test func aScreenNoVideoUsesFailsBeforeAnythingLaunches() throws {
        #expect {
            _ = try ClipRecorder.plan(Self.options(screens: [try Capture.Screen(spec: "organize")]))
        } throws: { error in
            guard case .invalidScreenSpec(let spec, let reason)? = error as? AppShotError else {
                return false
            }
            return spec == "organize" && reason.contains("no chosen video")
        }
    }

    @Test func aVideoThatNamesNoScreenHasNothingToRecord() throws {
        var options = try Self.options()
        options.videos = [
            try VideoConfigTests.config(
                videos: """
                    [{ "id": "c", "stage": "s", "duration": 4, "outputs": { "promo": [[100, 100]] },
                       "beats": [{ "at": 0, "caption": "Hi there" }] }]
                    """
            ).video("c")
        ]
        #expect {
            _ = try ClipRecorder.plan(options)
        } throws: { error in
            guard case .invalidVideo("c", let reason)? = error as? AppShotError else { return false }
            return reason.contains("names no screen")
        }
    }

    @Test func theClipFlagComesAfterTheProjectsArgsAndTheReadyFileIsPassed() throws {
        let options = try Self.options(extraArgs: ["-ScreenshotClip", "NO", "-ScreenshotMode", "YES"])
        let ready = URL(fileURLWithPath: "/tmp/ready")
        let args = ClipRecorder.arguments(
            screen: Capture.Screen(name: "browser", stage: "browser"), appearance: "dark", readyFile: ready,
            display: nil, options: options)
        #expect(args.suffix(2) == ["-ScreenshotClip", "YES"])
        let i = try #require(args.firstIndex(of: "-ScreenshotReadyFile"))
        #expect(args[i + 1] == "/tmp/ready")
        #expect(args.contains("-ScreenshotStage"))
    }

    @Test func trafficLightsOriginIsTheBaseWindowInsideTheCrop() {
        // A popover overhangs 40 points above and 30 to the left of the window, so the crop
        // starts there, and the window's corner sits inside it.
        let origin = ClipRecorder.trafficLightsOrigin(
            base: CGRect(x: 230, y: 140, width: 900, height: 600),
            display: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, crop: [400, 200, 1860, 1280])
        #expect(origin == [60, 80])
    }

    @Test func refusesAnIOSConfig() async throws {
        var options = try Self.options()
        options.config.platform = .ios
        await #expect(throws: AppShotError.self) { _ = try await ClipRecorder.run(options) }
    }
}
