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

    /// The fixture's plain titled window at 2x: 12 pt discs on a 20 pt pitch. While a stream
    /// runs, macOS 27 draws its capsule over (20, 8)-(128, 48) there; the patch must cover it.
    static let discs = [32.0, 72, 112].map { TrafficLights.Disc(x: $0, y: 28, diameter: 24) }

    @Test func theLightsPatchCoversTheButtonsAndTheSharingCapsule() {
        let rect = ClipRecorder.lightsRect(Self.discs, within: CGRect(x: 0, y: 0, width: 1600, height: 1096))
        #expect(rect == CGRect(x: 8, y: 4, width: 128, height: 48))
        #expect(rect.contains(CGRect(x: 20, y: 8, width: 108, height: 40)))
    }

    @Test func theLightsPatchStaysInsideTheWindow() {
        // The window starts 10 px into the screenshot (a popover overhangs it), and its
        // buttons sit closer to its corner than the margin.
        let discs = Self.discs.map { TrafficLights.Disc(x: $0.x, y: $0.y - 10, diameter: $0.diameter) }
        let rect = ClipRecorder.lightsRect(discs, within: CGRect(x: 10, y: 0, width: 1600, height: 1096))
        #expect(rect == CGRect(x: 10, y: 0, width: 126, height: 42))
    }

    /// Edges between pixels round outwards on both sides, so the patch never comes up short.
    @Test func theLightsPatchRoundsOutToWholePixels() {
        let discs = [32.4, 72.4, 112.4].map { TrafficLights.Disc(x: $0, y: 28.4, diameter: 24) }
        let rect = ClipRecorder.lightsRect(discs, within: CGRect(x: 0, y: 0, width: 1600, height: 1096))
        // 8.4 → 8 and 136.4 → 137; 4.4 → 4 and 52.4 → 53.
        #expect(rect == CGRect(x: 8, y: 4, width: 129, height: 49))
    }

    static let window = CGRect(x: 0, y: 0, width: 300, height: 120)

    @Test func noButtonsAndNoFlagRecordsNoPatch() throws {
        let shot = TrafficLightsTests.titleBar(discs: TrafficLightsTests.greyRow(count: 2))
        #expect(
            try ClipRecorder.lightsPatch(
                of: shot, window: Self.window, scale: 2, label: "s~dark", recolor: false)
                == nil)
    }

    @Test func noButtonsUnderTheFlagFailsAsAStillDoes() {
        let shot = TrafficLightsTests.titleBar(discs: TrafficLightsTests.greyRow(count: 2))
        #expect {
            _ = try ClipRecorder.lightsPatch(
                of: shot, window: Self.window, scale: 2, label: "s~dark", recolor: true)
        } throws: { error in
            guard case .trafficLightsNotFound(let screen)? = error as? AppShotError else { return false }
            return screen == "s~dark"
        }
    }

    /// The most saturated pixel in an image: grey buttons stay near 0, painted ones do not.
    static func chroma(_ image: CGImage) throws -> Int {
        let px = try #require(Image.pixels(image))
        return (0..<px.count).map { i in
            let p = px[i]
            return Int(max(p.r, p.g, p.b)) - Int(min(p.r, p.g, p.b))
        }.max() ?? 0
    }

    /// Repainted before it is cut, so the patch holds the coloured buttons; without the
    /// flag, the grey ones as captured.
    @Test(arguments: [false, true]) func thePatchIsCutAfterTheRepaint(recolor: Bool) throws {
        let shot = TrafficLightsTests.titleBar(discs: TrafficLightsTests.greyRow())
        let patch = try #require(
            try ClipRecorder.lightsPatch(
                of: shot, window: Self.window, scale: 2, label: "s", recolor: recolor))
        #expect(patch.rect == CGRect(x: 8, y: 4, width: 128, height: 48))
        #expect(patch.image.width == 128 && patch.image.height == 48)
        if recolor {
            #expect(try Self.chroma(patch.image) > Int(TrafficLights.colourChroma))
        } else {
            let cut = try #require(shot.cropping(to: patch.rect))
            #expect(Image.pixels(patch.image)?.bytes == Image.pixels(cut)?.bytes)
        }
    }

    /// Buttons found outside the window leave nothing to cut, which is a capture failure,
    /// not a silent clip without its patch.
    @Test func aPatchOutsideTheWindowFailsTheClip() {
        let shot = TrafficLightsTests.titleBar(discs: TrafficLightsTests.greyRow())
        #expect {
            _ = try ClipRecorder.lightsPatch(
                of: shot, window: CGRect(x: 0, y: 0, width: 4, height: 2), scale: 2, label: "s",
                recolor: false)
        } throws: { error in
            guard case .captureFailed(let screen, let reason)? = error as? AppShotError else { return false }
            return screen == "s" && reason.contains("window buttons")
        }
    }

    @Test func aChromeClipWithoutAPatchWarnsNamingItself() {
        let warnings = ClipRecorder.warnings(name: "browser~dark", chromeless: false, patched: false)
        #expect(warnings.count == 1)
        #expect(warnings[0].hasPrefix("browser~dark:"))
        #expect(warnings[0].contains("chrome: none") && warnings[0].contains("capsule"))
        #expect(ClipRecorder.warnings(name: "browser~dark", chromeless: false, patched: true).isEmpty)
        #expect(ClipRecorder.warnings(name: "browser~dark", chromeless: true, patched: false).isEmpty)
    }

    @Test func theLightsPatchLandsWhereTheWindowCornerSitsInTheCrop() {
        // Screenshot at 2x with the window 20 px in; filmed at 2x with the corner at (60, 80).
        #expect(
            ClipRecorder.lightsPatchRect(
                CGRect(x: 28, y: 4, width: 128, height: 48), shotOrigin: CGPoint(x: 20, y: 0), shotScale: 2,
                cropOrigin: [60, 80], filmScale: 2) == [68, 84, 128, 48])
        // A screenshot taken at another scale than the film is brought to the film's.
        #expect(
            ClipRecorder.lightsPatchRect(
                CGRect(x: 8, y: 4, width: 128, height: 48), shotOrigin: .zero, shotScale: 2,
                cropOrigin: [0, 0], filmScale: 1) == [4, 2, 64, 24])
    }

    @Test func refusesAnIOSConfig() async throws {
        var options = try Self.options()
        options.config.platform = .ios
        // The app path does not exist either: only the iOS refusal answers with this reason.
        await #expect {
            _ = try await ClipRecorder.run(options)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason == Recorder.iosReason
        }
    }

    @Test func noChosenVideoHasNothingToRecord() throws {
        var options = try Self.options()
        options.videos = []
        #expect {
            _ = try ClipRecorder.plan(options)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("no video is chosen")
        }
    }

    @Test func theForegroundIsGuardedUnderNoActivateAsCaptureGuardsIt() throws {
        let app = URL(fileURLWithPath: "/Applications/Nothing.app")
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
        let background = Capture.Options(app: app, outDir: out, screens: [], noActivate: true)
        let foreground = Capture.Options(
            app: app, outDir: out, screens: [], foregroundLaunch: true, noActivate: true)
        let activating = Capture.Options(app: app, outDir: out, screens: [])
        #expect(ClipRecorder.guardsForeground(background))
        #expect(!ClipRecorder.guardsForeground(foreground))
        #expect(!ClipRecorder.guardsForeground(activating))
    }
}
