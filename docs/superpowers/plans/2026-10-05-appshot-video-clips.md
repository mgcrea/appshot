# appshot video clips — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third video path. `appshot record --clips` films one short moving clip per screen, with no cue handler. `appshot compose video --from-clips` cuts between those clips, falling back to stills, the way `--from-stills` cuts between stills.

**Architecture:** Two pure pieces come first:

- `ClipPlan` says which clips a set of videos needs and how long each must be.
- `ClipInfo` is a clip's sidecar JSON.

`ClipsMaster` is a third `VideoMaster`. It resolves each `screen` beat to a clip or a still, plays each clip from its own start through a `RecordedMaster`, crossfades between segments, and centres everything on one canvas. `VideoCompose` gains a clips branch beside the stills and recorded ones.

On the recording side, the ScreenCaptureKit loop is lifted out of `Recorder.record` into `Recorder.film`. Both `Recorder` and the new `ClipRecorder` use it. `ClipRecorder` launches each stage the way `capture` does, waits for the ready file, and films until the clip's length.

**Tech Stack:** Swift 6, macOS 14 floor, ScreenCaptureKit, AVFoundation, CoreGraphics, Swift Testing, swift-argument-parser, swift-format.

**Spec:** `docs/superpowers/specs/2026-10-05-appshot-video-clips-design.md`. Read it first.

### Spec refinements made while planning

The spec was approved before the code was read line by line. These four points refine it. Each is small, and none changes what a user sees beyond the message text.

1. **`present` is refused in any `--from-clips` render,** on a still screen as well as on a clip screen. Supporting sheets on the still segments of a mixed video would mean copying `StillsMaster`'s present and swap logic into `ClipsMaster`, for a case no project has. The message says to use `--from-stills` for sheets.
2. **`--from-clips` together with an explicit `--source` is a command-line usage error** (ArgumentParser's `ValidationError`, exit 64), like every other flag conflict, not `invalid_video`. To tell an explicit `--source` from its default, `--source` becomes optional in the CLI.
3. **`ClipInfo.length` is the span recorded,** from t = 0 to the moment the stream stopped, not to the last frame. ScreenCaptureKit sends nothing while the screen is still, so the last frame can sit well before the end of a perfectly good clip. `RecordedMaster` already holds the last frame.
4. **A screen with neither a clip nor a still fails as `invalid_video`, naming both paths.** It is not `missing_captures`, whose message names a single directory.

## Global Constraints

- Swift 6 language mode, macOS 14 floor (`Package.swift`); no new dependencies.
- AppShotKit never prints and never exits; it returns values, calls progress callbacks, and throws `AppShotError`.
- Every new `AppShotError` case gets a `description` line and a `slug` line (`Sources/AppShotKit/AppShotError.swift`).
- Lint gate: run `swift format --in-place --recursive Sources Tests`, then `swift format lint --strict --recursive Sources Tests` must be clean (line length 110).
- Tests: `swift test` (Swift Testing, `@Test`, `#expect`). The whole suite must pass at the end of every task.
- Renders are deterministic: the same clips, stills and config give identical frames. No randomness and no wall clock in compose.
- The crossfade is `StillsMaster.crossfade` (0.5 s) and the recording margin is `ClipPlan.margin` (0.5 s). Name them; never write the literal.
- The app is told `-ScreenshotClip YES` (`ClipRecorder.Options.clipArg`), appended after the project's extra args, so appshot's value wins.
- Clips are silent; outputs keep `VideoWriter`'s silent stereo AAC track. No audio capture anywhere.
- iOS has no clips: `record --clips` and `compose video --from-clips` refuse an iOS config with `Recorder.iosReason`.
- Nothing drives the real Mac: no synthetic input, no clicks or keystrokes. Integration runs use `noActivate: true`.
- Demo data only in any capture or video.
- Work on branch `video-clips` in worktree `~/Projects/appshot-clips`. When done, merge to `main` fast-forward only, then delete the branch and the worktree.
- Never bump the version, tag, push or release appshot. The CHANGELOG entry goes under `## [Unreleased]`.

## Review Focus

1. **One appearance has a clip and the other does not.** Resolution is per appearance: dark plays the clip, light shows the still, and the report says so for each. *(Task 3 test `resolvesEachAppearanceOnItsOwn`.)*
2. **The first `screen` beat is not at 0.** A clips render must fail with the same message stills give, not open on a transparent canvas. *(Task 3 test `aFirstCutAfterZeroFailsLikeStills`.)*
3. **The capture extends past the window's top-left** because a popover or second window sits up and to the left. The recorded traffic-light origin must be the base window's corner inside the crop, not (0, 0), or every frame's recolor fails. *(Task 8 test `trafficLightsOriginIsTheBaseWindowInsideTheCrop`.)*
4. **`record --clips --screens` names a screen that no chosen video uses.** It must fail before the lock and before any launch, naming the screen. *(Task 8 test `aScreenNoVideoUsesFailsBeforeAnythingLaunches`.)*
5. **`--from-clips` against an empty or missing clips directory, with stills.** It must render exactly as a stills render does, with `frames` 0 and every beat `source: "still"`, rather than failing. *(Task 5 test `anEmptyClipsDirectoryRendersFromStills`.)*

---

## Task 0: Workspace

**Files:** none.

- [ ] **Step 1: Create the worktree**

```bash
cd ~/Projects/appshot
git status --short            # must be empty
git worktree add ../appshot-clips -b video-clips
cd ../appshot-clips
```

- [ ] **Step 2: Baseline**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: the build succeeds and every test passes. Write down the test count; every later task must keep it green.

---

## Task 1: `ClipPlan` and `ClipInfo`

The pure data the rest builds on: which screens a set of videos holds and for how long, and the sidecar a clip is recorded with.

**Files:**
- Create: `Sources/AppShotKit/ClipPlan.swift`
- Create: `Sources/AppShotKit/ClipInfo.swift`
- Test: `Tests/AppShotKitTests/ClipPlanTests.swift`
- Test: `Tests/AppShotKitTests/ClipInfoTests.swift`

**Interfaces:**
- Consumes: `Config.Video`, `StillsMaster.crossfade`, `AppShotError.invalidConfig(URL, String)`.
- Produces:
  - `ClipPlan.margin: Double` (0.5), `ClipPlan.Hold { beat: Int, screen: String, at: Double, seconds: Double, needed: Double }`
  - `ClipPlan.holds(in: Config.Video) -> [ClipPlan.Hold]`
  - `ClipPlan.lengths(for: [Config.Video]) -> [String: Double]`
  - `ClipInfo` (Codable) with `screen, stage, appearance: String`, `length: Double`, `crop: [Double]`, `trafficLights: ClipInfo.TrafficLights?` (`origin: [Double]`, `scale: Double`), `frames: Int`, `maxFrameGap: Double`, `appshotVersion: String`, `recordedAt: String`, plus the computed `size: CGSize`
  - `ClipInfo.name(screen:appearance:) -> String`, `ClipInfo.movieURL(in:screen:appearance:) -> URL`, `ClipInfo.url(in:screen:appearance:) -> URL`, `ClipInfo.read(_:) throws -> ClipInfo`, `ClipInfo.write(to:) throws`

- [ ] **Step 1: Write the failing tests**

`Tests/AppShotKitTests/ClipPlanTests.swift`:

```swift
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
```

`Tests/AppShotKitTests/ClipInfoTests.swift`:

```swift
import Foundation
import Testing

@testable import AppShotKit

struct ClipInfoTests {
    static func info(screen: String = "browser", length: Double = 5, frames: Int = 120) -> ClipInfo {
        ClipInfo(
            screen: screen, stage: screen, appearance: "dark", length: length, crop: [10, 20, 400, 250],
            trafficLights: .init(origin: [0, 0], scale: 2), frames: frames, maxFrameGap: 0.04,
            appshotVersion: "test", recordedAt: "2026-10-05T12:00:00Z")
    }

    @Test func roundTripsThroughItsFile() throws {
        let dir = try VideoMasterTests.dir()
        let url = ClipInfo.url(in: dir, screen: "browser", appearance: "dark")
        #expect(url.lastPathComponent == "browser~dark.clip.json")
        #expect(
            ClipInfo.movieURL(in: dir, screen: "browser", appearance: "dark").lastPathComponent
                == "browser~dark.mov")
        try Self.info().write(to: url)
        #expect(try ClipInfo.read(url) == Self.info())
        #expect(Self.info().size == CGSize(width: 400, height: 250))
    }

    @Test func aCropOfTheWrongShapeFailsNamingTheFile() throws {
        let dir = try VideoMasterTests.dir()
        let url = dir.appending(path: "browser~dark.clip.json")
        var info = Self.info()
        info.crop = [0, 0, 400]
        try info.write(to: url)
        #expect {
            _ = try ClipInfo.read(url)
        } throws: { error in
            guard case .invalidConfig(let at, let why)? = error as? AppShotError else { return false }
            return at == url && why.contains("crop")
        }
    }

    @Test func aTrafficLightOriginOfTheWrongShapeFails() throws {
        let dir = try VideoMasterTests.dir()
        let url = dir.appending(path: "browser~dark.clip.json")
        var info = Self.info()
        info.trafficLights = .init(origin: [1], scale: 2)
        try info.write(to: url)
        #expect(throws: AppShotError.self) { _ = try ClipInfo.read(url) }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "ClipPlanTests|ClipInfoTests" 2>&1 | tail -5`
Expected: compile errors, `cannot find 'ClipPlan' in scope` and `cannot find 'ClipInfo' in scope`.

- [ ] **Step 3: Implement `ClipPlan`**

`Sources/AppShotKit/ClipPlan.swift`:

```swift
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
```

- [ ] **Step 4: Implement `ClipInfo`**

`Sources/AppShotKit/ClipInfo.swift`:

```swift
import CoreGraphics
import Foundation

/// What `record --clips` wrote beside one clip: what was filmed, the crop that makes the
/// clip match its still, and how the take went.
public struct ClipInfo: Codable, Sendable, Equatable {
    /// Where the window's traffic lights are, so compose can recolor every frame as
    /// `capture --recolor-traffic-lights` recolors a still.
    public struct TrafficLights: Codable, Sendable, Equatable {
        /// The base window's top-left in crop pixels: x, y.
        public var origin: [Double]
        public var scale: Double
    }

    public var screen: String
    public var stage: String
    public var appearance: String
    /// Seconds recorded, from t = 0 to the moment the stream stopped. Not the last
    /// frame's time: ScreenCaptureKit sends nothing while the screen is still.
    public var length: Double
    /// The stage in master pixels, top-left origin: x, y, width, height.
    public var crop: [Double]
    /// Present only when the clip was recorded with `--recolor-traffic-lights` on a
    /// screen with chrome.
    public var trafficLights: TrafficLights?
    public var frames: Int
    public var maxFrameGap: Double
    public var appshotVersion: String
    public var recordedAt: String

    public var size: CGSize { CGSize(width: crop[2], height: crop[3]) }

    public static func name(screen: String, appearance: String) -> String { "\(screen)~\(appearance)" }

    public static func movieURL(in dir: URL, screen: String, appearance: String) -> URL {
        dir.appending(path: "\(name(screen: screen, appearance: appearance)).mov")
    }

    public static func url(in dir: URL, screen: String, appearance: String) -> URL {
        dir.appending(path: "\(name(screen: screen, appearance: appearance)).clip.json")
    }

    /// Checks the shapes JSON cannot, so a bad file fails here, named, rather than
    /// trapping mid-render.
    public static func read(_ url: URL) throws -> ClipInfo {
        let info: ClipInfo
        do {
            info = try JSONDecoder().decode(ClipInfo.self, from: Data(contentsOf: url))
        } catch {
            throw AppShotError.invalidConfig(url, "unreadable clip info: \(error)")
        }
        guard info.crop.count == 4, info.crop[2] > 0, info.crop[3] > 0 else {
            throw AppShotError.invalidConfig(url, "the clip's crop is not [x, y, width, height]: \(info.crop)")
        }
        if let lights = info.trafficLights, lights.origin.count != 2 {
            throw AppShotError.invalidConfig(url, "the traffic-light origin is not [x, y]: \(lights.origin)")
        }
        return info
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "ClipPlanTests|ClipInfoTests" 2>&1 | tail -5`
Expected: PASS, 6 tests.

- [ ] **Step 6: Format, lint, full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/ClipPlan.swift Sources/AppShotKit/ClipInfo.swift \
  Tests/AppShotKitTests/ClipPlanTests.swift Tests/AppShotKitTests/ClipInfoTests.swift
git commit -m "feat(video): plan clip lengths per screen and describe a clip in its sidecar"
```

---

## Task 2: Share the stills helpers, and give `RecordedMaster` a crop

A refactor with no behaviour change. `ClipsMaster` needs the same centring and crossfade as `StillsMaster`, and a `RecordedMaster` built from a crop rather than a whole take.

**Files:**
- Modify: `Sources/AppShotKit/VideoMaster.swift` (StillsMaster: `init` lines 24-61 and `crossfade` lines 112-123; RecordedMaster: `init` lines 175-196 and the `video` property)
- Test: `Tests/AppShotKitTests/VideoMasterTests.swift`

**Interfaces:**
- Produces:
  - `StillsMaster.centered(_ image: CGImage, on size: CGSize) -> CGImage?`
  - `StillsMaster.blend(_ from: CGImage, _ to: CGImage, q: Double, size: CGSize) -> CGImage`, where `q` is seconds since the cut
  - `RecordedMaster.init(url: URL, crop: [Double], label: String) throws`
  - `RecordedMaster.init(url: URL, track: VideoTrack) throws`, kept and delegating

- [ ] **Step 1: Write the failing tests**

Append to `struct VideoMasterTests` in `Tests/AppShotKitTests/VideoMasterTests.swift`:

```swift
    @Test func centeredPutsASmallerImageInTheMiddle() throws {
        let ctx = try #require(Image.context(width: 60, height: 30))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        let small = try #require(ctx.makeImage())
        let out = try #require(StillsMaster.centered(small, on: CGSize(width: 100, height: 50)))
        let px = try #require(Image.pixels(out))
        #expect(out.width == 100 && out.height == 50)
        #expect(px.at(2, 2, 3) == 0)
        #expect(px.at(50, 25, 3) == 255)
    }

    @Test func blendIsTheStillsCrossfade() throws {
        func solid(_ gray: Double) throws -> CGImage {
            let ctx = try #require(Image.context(width: 10, height: 10))
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            return try #require(ctx.makeImage())
        }
        let size = CGSize(width: 10, height: 10)
        let px = { (img: CGImage) in Image.pixels(img)!.at(5, 5) }
        #expect(px(StillsMaster.blend(try solid(0), try solid(1), q: 0, size: size)) == 0)
        let mid = px(StillsMaster.blend(try solid(0), try solid(1), q: StillsMaster.crossfade / 2, size: size))
        #expect(mid > 100 && mid < 160)
        #expect(px(StillsMaster.blend(try solid(0), try solid(1), q: 9, size: size)) == 255)
    }

    @Test func aRecordedMasterCropsToTheRectItIsGiven() async throws {
        let url = try Self.dir().appending(path: "m.mov")
        try await Self.writeAlphaMovie(url, width: 64, height: 64)
        // writeAlphaMovie paints x 16..<48, y 0..<24 (y-down) white on transparent.
        let master = try RecordedMaster(url: url, crop: [16, 0, 32, 24], label: "m")
        let frame = try master.frame(at: 0.1)
        #expect(frame.width == 32 && frame.height == 24)
        let px = try #require(Image.pixels(frame))
        #expect(px.at(16, 12, 3) >= 250)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter VideoMasterTests 2>&1 | tail -5`
Expected: compile errors, `type 'StillsMaster' has no member 'centered'` and `extra argument 'crop' in call`.

- [ ] **Step 3: Implement the two static helpers and use them**

In `StillsMaster` (`Sources/AppShotKit/VideoMaster.swift`), replace the body of the `keys = try zip(cuts, images).map { … }` closure with a call to `centered`, and add the helpers:

```swift
        keys = try zip(cuts, images).map { cut, image in
            guard let centered = Self.centered(image, on: CGSize(width: w, height: h)) else {
                throw AppShotError.videoRenderFailed(video: video.id, reason: "could not center \(cut.1)")
            }
            return (cut.0, centered, cut.2)
        }
```

```swift
    /// `image` drawn in the middle of a transparent canvas of `size`, never stretched.
    static func centered(_ image: CGImage, on size: CGSize) -> CGImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        if image.width == w, image.height == h { return image }
        guard let ctx = Image.context(width: w, height: h) else { return nil }
        let x: Int = (w - image.width) / 2
        let y: Int = (h - image.height) / 2
        ctx.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// The cut's crossfade, `q` seconds after it: `to` eased in over `from`.
    static func blend(_ from: CGImage, _ to: CGImage, q: Double, size: CGSize) -> CGImage {
        let p = q / crossfade
        guard p < 1, let ctx = Image.context(width: Int(size.width), height: Int(size.height)) else {
            return to
        }
        let full = CGRect(origin: .zero, size: size)
        ctx.draw(from, in: full)
        ctx.setAlpha(Ease.smooth(p))
        ctx.draw(to, in: full)
        return ctx.makeImage() ?? to
    }
```

Then make the private instance `crossfade(_:_:_:)` delegate:

```swift
    private func crossfade(_ from: CGImage, _ to: CGImage, _ q: Double) -> CGImage {
        Self.blend(from, to, q: q, size: stageSize)
    }
```

The early return in `centered` for a same-size image keeps the stills path byte-identical: the old code drew into a context even at the same size, which was a no-op redraw of the same pixels.

- [ ] **Step 4: Give `RecordedMaster` a crop init**

In `RecordedMaster`, rename the stored `video` to `label` and split the init:

```swift
    private let label: String

    /// `crop` is the stage in master pixels, top-left origin: x, y, width, height.
    /// `label` names the movie in errors: a video id for a take, `screen~appearance` for
    /// a clip.
    public init(url: URL, crop: [Double], label: String) throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw AppShotError.videoRenderFailed(
                video: label, reason: "\(url.lastPathComponent) has no video track")
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AppShotError.videoRenderFailed(video: label, reason: "cannot read \(url.lastPathComponent)")
        }
        self.label = label
        self.crop = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
        stageSize = self.crop.size
    }

    public convenience init(url: URL, track: VideoTrack) throws {
        try self.init(url: url, crop: track.stage, label: track.video)
    }
```

Replace `video:` with `label` in the two `AppShotError.videoRenderFailed(video: video, …)` calls inside `frame(at:)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "VideoMasterTests|VideoComposeTests" 2>&1 | tail -5`
Expected: PASS, including every pre-existing stills test (crossfade, centring, present, swap).

- [ ] **Step 6: Format, lint, full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoMaster.swift Tests/AppShotKitTests/VideoMasterTests.swift
git commit -m "refactor(video): share the stills centering and crossfade, and build a RecordedMaster from a crop"
```

---

## Task 3: `ClipsMaster`

The third `VideoMaster`. It resolves each cut to a clip or a still, plays each clip from its own start, crossfades between segments with at most two decoders open, and recolours traffic lights per frame.

**Files:**
- Create: `Sources/AppShotKit/ClipsMaster.swift`
- Test: `Tests/AppShotKitTests/ClipsMasterTests.swift`

**Interfaces:**
- Consumes: `ClipInfo`, `ClipPlan`, `StillsMaster.centered`, `StillsMaster.blend`, `StillsMaster.crossfade`, `RecordedMaster(url:crop:label:)`, `TrafficLights.recolor(_:windowOrigin:scale:screen:)`, `Image.load`.
- Produces:
  - `ClipsMaster.Segment { beat: Int, at: Double, screen: String, appearance: String, source: Source }`, where `Source` is `.clip(movie: URL, info: ClipInfo)` or `.still(URL)`, plus `isClip: Bool` and `name: String` (`screen~appearance`)
  - `ClipsMaster.segments(video: Config.Video, appearance: String, clipsDir: URL, stillsDir: URL?) throws -> [Segment]`
  - `ClipsMaster.init(segments: [Segment], video: String) throws`, with `stageSize: CGSize`, `mutating frame(at:) throws -> CGImage`, and the internal `openDecoders: Int` for tests
  - the test helper `ClipsMasterTests.writeClip(dir:screen:appearance:width:height:seconds:frames:trafficLights:gray:)`

- [ ] **Step 1: Write the failing tests**

`Tests/AppShotKitTests/ClipsMasterTests.swift`:

```swift
import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct ClipsMasterTests {
    /// A clip `seconds` long at 30 fps, opaque, each frame filled with `gray(t)`, and its
    /// sidecar. Shared with the compose tests.
    static func writeClip(
        dir: URL, screen: String, appearance: String = "dark", width: Int = 100, height: Int = 50,
        seconds: Double, frames: Int? = nil, trafficLights: ClipInfo.TrafficLights? = nil,
        gray: (Double) -> Double
    ) async throws {
        let url = ClipInfo.movieURL(in: dir, screen: screen, appearance: appearance)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let count = Int((seconds * 30).rounded())
        for i in 0..<count {
            let ctx = try #require(Image.context(width: width, height: height))
            ctx.setFillColor(CGColor(gray: gray(Double(i) / 30), alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(ctx.makeImage())
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pool = try #require(adaptor.pixelBufferPool)
            adaptor.append(
                try VideoWriter.pixelBuffer(image, pool: pool), withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try ClipInfo(
            screen: screen, stage: screen, appearance: appearance, length: seconds,
            crop: [0, 0, Double(width), Double(height)], trafficLights: trafficLights,
            frames: frames ?? count, maxFrameGap: 1.0 / 30, appshotVersion: "test",
            recordedAt: "2026-10-05T12:00:00Z"
        ).write(to: ClipInfo.url(in: dir, screen: screen, appearance: appearance))
    }

    static func video(duration: Double = 6, _ cuts: [(Double, String)]) throws -> Config.Video {
        try ClipPlanTests.video("v", duration: duration, cuts: cuts)
    }

    /// The clip time a ramp clip shows: gray = t / seconds.
    static func level(_ image: CGImage) -> Int { Int(Image.pixels(image)!.at(50, 25)) }

    @Test func playsEachClipFromItsOwnStart() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 4) { $0 / 4 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 4) { $0 / 4 }
        let video = try Self.video([(0, "browser"), (2, "paywall")])
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        var master = try ClipsMaster(segments: segments, video: "v")
        // 1 s into browser: a quarter up the ramp.
        #expect(abs(Self.level(try master.frame(at: 1)) - 64) <= 8)
        // 3 s into the video is 1 s into paywall, past the crossfade.
        #expect(abs(Self.level(try master.frame(at: 3)) - 64) <= 8)
    }

    @Test func aScreenNamedTwiceRestartsItsClip() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { $0 / 3 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 3) { _ in 0 }
        let video = try Self.video([(0, "browser"), (2, "paywall"), (4, "browser")])
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        var master = try ClipsMaster(segments: segments, video: "v")
        _ = try master.frame(at: 1.5)
        _ = try master.frame(at: 3)
        // 0.75 s into the second browser segment, not 4.75 s into the clip.
        #expect(abs(Self.level(try master.frame(at: 4.75)) - 64) <= 8)
    }

    @Test func crossfadesFromAClipIntoAStill() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { _ in 0 }
        try VideoMasterTests.solid(100, 50, gray: 1, to: stills.appending(path: "paywall~dark.png"))
        let video = try Self.video(duration: 4, [(0, "browser"), (2, "paywall")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        #expect(segments.map(\.isClip) == [true, false])
        var master = try ClipsMaster(segments: segments, video: "v")
        #expect(Self.level(try master.frame(at: 1)) <= 8)
        let mid = Self.level(try master.frame(at: 2.25))
        #expect(mid > 100 && mid < 160)
        #expect(Self.level(try master.frame(at: 3)) == 255)
    }

    @Test func clipsAndStillsOfDifferentSizesAreCenteredOnTheLargest() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", width: 100, height: 50, seconds: 3) { _ in 1 }
        try VideoMasterTests.solid(60, 30, gray: 1, to: stills.appending(path: "paywall~dark.png"))
        let video = try Self.video(duration: 4, [(0, "browser"), (2, "paywall")])
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: stills),
            video: "v")
        #expect(master.stageSize == CGSize(width: 100, height: 50))
        _ = try master.frame(at: 1)
        let px = try #require(Image.pixels(try master.frame(at: 3)))
        #expect(px.at(2, 2, 3) == 0)
        #expect(px.at(50, 25, 3) == 255)
    }

    @Test func neverHoldsMoreThanTwoDecoders() async throws {
        let dir = try VideoMasterTests.dir()
        for screen in ["browser", "paywall", "organize"] {
            try await Self.writeClip(dir: dir, screen: screen, seconds: 3) { _ in 0.5 }
        }
        let video = try Self.video([(0, "browser"), (2, "paywall"), (4, "organize")])
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil),
            video: "v")
        var most = 0
        for i in 0..<180 {
            _ = try master.frame(at: Double(i) / 30)
            most = max(most, master.openDecoders)
        }
        #expect(most == 2)
        #expect(master.openDecoders == 1)
    }

    @Test func rendersTheSameFramesTwice() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { $0 / 3 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 3) { 1 - $0 / 3 }
        let video = try Self.video(duration: 4, [(0, "browser"), (2, "paywall")])
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        var a = try ClipsMaster(segments: segments, video: "v")
        var b = try ClipsMaster(segments: segments, video: "v")
        for t in stride(from: 0.0, to: 4, by: 0.3) {
            #expect(Image.pixels(try a.frame(at: t))!.bytes == Image.pixels(try b.frame(at: t))!.bytes)
        }
    }

    @Test func aScreenWithNeitherClipNorStillNamesBothPaths() throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        let video = try Self.video([(0, "browser")])
        #expect {
            _ = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        } throws: { error in
            guard case .invalidVideo(let id, let reason)? = error as? AppShotError else { return false }
            return id == "v" && reason.contains("browser~dark.mov") && reason.contains("browser~dark.png")
        }
    }

    @Test func aFirstCutAfterZeroFailsLikeStills() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { _ in 0 }
        let video = try Self.video([(1, "browser")])
        #expect {
            _ = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("a beat at 0 that names a screen")
        }
    }

    @Test func resolvesEachAppearanceOnItsOwn() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", appearance: "dark", seconds: 7) { _ in 0 }
        try VideoMasterTests.solid(100, 50, gray: 1, to: stills.appending(path: "browser~light.png"))
        let video = try Self.video([(0, "browser")])
        let dark = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        let light = try ClipsMaster.segments(video: video, appearance: "light", clipsDir: dir, stillsDir: stills)
        #expect(dark.map(\.isClip) == [true])
        #expect(light.map(\.isClip) == [false])
        #expect(light.map(\.name) == ["browser~light"])
    }

    @Test func aClipWhoseTrafficLightsCannotBeFoundFailsNamingIt() async throws {
        let dir = try VideoMasterTests.dir()
        // A flat frame has no buttons to find.
        try await Self.writeClip(
            dir: dir, screen: "browser", seconds: 3, trafficLights: .init(origin: [0, 0], scale: 2)
        ) { _ in 0.5 }
        let video = try Self.video(duration: 2, [(0, "browser")])
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil),
            video: "v")
        #expect {
            _ = try master.frame(at: 0.5)
        } throws: { error in
            guard case .trafficLightsNotFound(let screen)? = error as? AppShotError else { return false }
            return screen == "browser~dark"
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ClipsMasterTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'ClipsMaster' in scope`.

- [ ] **Step 3: Implement `ClipsMaster`**

`Sources/AppShotKit/ClipsMaster.swift`:

```swift
import CoreGraphics
import Foundation

/// Moving footage without a take: each beat that names a `screen` plays that screen's
/// clip from its own start, or shows its still when no clip was recorded, with the
/// stills' crossfade between them.
///
/// Sequential, like `RecordedMaster`: `frame(at:)` must be asked for non-decreasing
/// times. A clip is decoded only while its segment, or its crossfade out, is on screen,
/// so at most two decoders are ever open.
public struct ClipsMaster: VideoMaster {
    public struct Segment: Sendable {
        public enum Source: Sendable {
            case clip(movie: URL, info: ClipInfo)
            case still(URL)
        }
        /// Index of the beat that cuts here.
        public let beat: Int
        public let at: Double
        public let screen: String
        public let appearance: String
        public let source: Source

        public var isClip: Bool { if case .clip = source { true } else { false } }
        public var name: String { ClipInfo.name(screen: screen, appearance: appearance) }
    }

    /// Each beat that names a screen, resolved to its clip if one was recorded for this
    /// appearance, else to its still.
    public static func segments(
        video: Config.Video, appearance: String, clipsDir: URL, stillsDir: URL?
    ) throws -> [Segment] {
        let holds = ClipPlan.holds(in: video)
        guard let first = holds.first, first.at == 0 else {
            throw AppShotError.invalidVideo(
                id: video.id, reason: "--from-clips needs a beat at 0 that names a screen")
        }
        return try holds.map { hold in
            let movie = ClipInfo.movieURL(in: clipsDir, screen: hold.screen, appearance: appearance)
            let info = ClipInfo.url(in: clipsDir, screen: hold.screen, appearance: appearance)
            let source: Segment.Source
            if FileManager.default.fileExists(atPath: movie.path),
                FileManager.default.fileExists(atPath: info.path)
            {
                source = .clip(movie: movie, info: try ClipInfo.read(info))
            } else if let stillsDir,
                case let still = stillsDir.appending(path: "\(hold.screen)~\(appearance).png"),
                FileManager.default.fileExists(atPath: still.path)
            {
                source = .still(still)
            } else {
                let fallback =
                    stillsDir.map {
                        " and no still at \($0.appending(path: "\(hold.screen)~\(appearance).png").path)"
                    } ?? "; pass --from-stills to fall back to the screenshot"
                throw AppShotError.invalidVideo(
                    id: video.id,
                    reason: "screen \(hold.screen) has no clip at \(movie.path)\(fallback)")
            }
            return Segment(
                beat: hold.beat, at: hold.at, screen: hold.screen, appearance: appearance, source: source)
        }
    }

    /// A clip being decoded, with the last frame it recoloured: ScreenCaptureKit sends
    /// nothing while the screen is still, so the decoder hands back the same image for
    /// many frames, and recolouring it again would only cost time.
    private final class Live {
        let reader: RecordedMaster
        var lastIn: CGImage?
        var lastOut: CGImage?
        init(_ reader: RecordedMaster) { self.reader = reader }
    }

    public let stageSize: CGSize
    private let segments: [Segment]
    private let video: String
    /// Stills, already centred, by segment index.
    private let stills: [Int: CGImage]
    private var live: [Int: Live] = [:]

    var openDecoders: Int { live.count }

    public init(segments: [Segment], video: String) throws {
        var sizes: [CGSize] = []
        var loaded: [Int: CGImage] = [:]
        for (i, segment) in segments.enumerated() {
            switch segment.source {
            case .clip(_, let info): sizes.append(info.size)
            case .still(let url):
                let image = try Image.load(url)
                loaded[i] = image
                sizes.append(CGSize(width: image.width, height: image.height))
            }
        }
        let size = CGSize(
            width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        stills = try loaded.mapValues { image in
            guard let centered = StillsMaster.centered(image, on: size) else {
                throw AppShotError.videoRenderFailed(video: video, reason: "could not center a still")
            }
            return centered
        }
        stageSize = size
        self.segments = segments
        self.video = video
    }

    public mutating func frame(at t: Double) throws -> CGImage {
        let index = segments.lastIndex { $0.at <= t } ?? 0
        let q = t - segments[index].at
        let fading = index > 0 && q < StillsMaster.crossfade
        // Release what can no longer be on screen before opening anything new.
        for open in live.keys where open < index - 1 || (open == index - 1 && !fading) {
            live[open] = nil
        }
        let current = try image(of: index, at: q)
        guard fading else { return current }
        let previous = try image(of: index - 1, at: t - segments[index - 1].at)
        return StillsMaster.blend(previous, current, q: q, size: stageSize)
    }

    private mutating func image(of index: Int, at clipTime: Double) throws -> CGImage {
        let segment = segments[index]
        guard case .clip(let movie, let info) = segment.source else {
            guard let still = stills[index] else {
                throw AppShotError.videoRenderFailed(video: video, reason: "no still for \(segment.name)")
            }
            return still
        }
        let clip: Live
        if let open = live[index] {
            clip = open
        } else {
            clip = Live(try RecordedMaster(url: movie, crop: info.crop, label: segment.name))
            live[index] = clip
        }
        let decoded = try clip.reader.frame(at: clipTime)
        if decoded === clip.lastIn, let out = clip.lastOut { return out }
        var image = decoded
        if let lights = info.trafficLights {
            image = try TrafficLights.recolor(
                image, windowOrigin: CGPoint(x: lights.origin[0], y: lights.origin[1]), scale: lights.scale,
                screen: segment.name
            ).image
        }
        guard let out = StillsMaster.centered(image, on: stageSize) else {
            throw AppShotError.videoRenderFailed(video: video, reason: "could not center \(segment.name)")
        }
        clip.lastIn = decoded
        clip.lastOut = out
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipsMasterTests 2>&1 | tail -5`
Expected: PASS, 10 tests.

If `neverHoldsMoreThanTwoDecoders` reports `most == 1`, the crossfade is not decoding the outgoing clip. Check that `fading` keeps `index - 1` open.

- [ ] **Step 5: Format, lint, full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/ClipsMaster.swift Tests/AppShotKitTests/ClipsMasterTests.swift
git commit -m "feat(video): ClipsMaster plays a clip per screen, falls back to stills, and crossfades between them"
```

---

## Task 4: Checks and warnings for a clips render

What must fail before anything is written, and what the report should warn about.

**Files:**
- Modify: `Sources/AppShotKit/AppShotError.swift` (a new case beside `captionTooShort`, line 101; its `description` beside line 183; its `slug` beside line 854)
- Modify: `Sources/AppShotKit/ClipsMaster.swift`
- Test: `Tests/AppShotKitTests/ClipsMasterTests.swift`

**Interfaces:**
- Consumes: `ClipPlan.holds(in:)`, `ClipsMaster.Segment`, `VideoTimeline.Warning(kind:at:message:)`.
- Produces:
  - `AppShotError.clipTooShort(video: String, clip: String, screen: String, length: Double, needed: Double)`, slug `clip_too_short`
  - `ClipsMaster.check(video: Config.Video, segments: [Segment]) throws`
  - `ClipsMaster.warnings(for: [Segment], stillsDir: URL?) -> [VideoTimeline.Warning]`, with kinds `clipNeverMoved` and `clipStillSizeMismatch`
  - `ClipsMaster.neverMovedFrames` (3) and `ClipsMaster.sizeTolerance` (2)

- [ ] **Step 1: Write the failing tests**

Append to `struct ClipsMasterTests`:

```swift
    @Test func aClipShorterThanItsHoldFailsNamingTheScreenAndTheFix() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 2) { _ in 0 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 5) { _ in 0 }
        // browser is held 3 s, so it needs 3.5 s with the crossfade, and has 2.
        let video = try Self.video([(0, "browser"), (3, "paywall")])
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect {
            try ClipsMaster.check(video: video, segments: segments)
        } throws: { error in
            guard let error = error as? AppShotError,
                case .clipTooShort("v", "browser~dark", "browser", 2, 3.5) = error
            else { return false }
            return error.slug == "clip_too_short"
                && error.description.contains("appshot record --clips --screens browser")
        }
    }

    @Test func presentIsRefusedInAClipsRender() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7) { _ in 0 }
        var video = try Self.video([(0, "browser")])
        video.beats[0].present = [0, 0, 10, 10]
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect {
            try ClipsMaster.check(video: video, segments: segments)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("beat 0") && reason.contains("--from-stills")
        }
    }

    @Test func aCueIsRefusedInAClipsRender() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7) { _ in 0 }
        var video = try Self.video([(0, "browser")])
        video.beats.append(.init(at: 1, cue: "pointer.click"))
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect {
            try ClipsMaster.check(video: video, segments: segments)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("beat 1 has a cue") && reason.contains("clips have no cue channel")
        }
    }

    @Test func warnsWhenAClipNeverMoved() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7, frames: 2) { _ in 0 }
        let video = try Self.video([(0, "browser")])
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        let warnings = ClipsMaster.warnings(for: segments, stillsDir: nil)
        #expect(warnings.map(\.kind) == ["clipNeverMoved"])
        #expect(warnings[0].message.contains("browser~dark has 2 frames in 7.0s"))
        #expect(warnings[0].message.contains("-ScreenshotClip"))
    }

    @Test func warnsWhenAClipAndItsStillDifferInSize() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", width: 100, height: 50, seconds: 7) { _ in 0 }
        try VideoMasterTests.solid(96, 50, gray: 1, to: stills.appending(path: "browser~dark.png"))
        let video = try Self.video([(0, "browser")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        #expect(ClipsMaster.warnings(for: segments, stillsDir: stills).map(\.kind) == ["clipStillSizeMismatch"])
        // Within 2 px is the same size.
        try VideoMasterTests.solid(98, 50, gray: 1, to: stills.appending(path: "browser~dark.png"))
        #expect(ClipsMaster.warnings(for: segments, stillsDir: stills).isEmpty)
    }

    @Test func aClipUsedTwiceWarnsOnce() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7, frames: 1) { _ in 0 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 7) { _ in 0 }
        let video = try Self.video([(0, "browser"), (2, "paywall"), (4, "browser")])
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect(ClipsMaster.warnings(for: segments, stillsDir: nil).count == 1)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ClipsMasterTests 2>&1 | tail -5`
Expected: compile errors, `type 'ClipsMaster' has no member 'check'` and `type 'AppShotError' has no member 'clipTooShort'`.

- [ ] **Step 3: Add the error case**

In `Sources/AppShotKit/AppShotError.swift`, after `case captionTooShort(…)`:

```swift
    /// A clip that ends before the video stops showing its screen. The render would hold
    /// the clip's last frame for the rest, and a frozen app under a caption claiming it
    /// moves is the lie a clip exists to avoid.
    case clipTooShort(video: String, clip: String, screen: String, length: Double, needed: Double)
```

In `description`, after the `.captionTooShort` case:

```swift
        case .clipTooShort(let video, let clip, let screen, let length, let needed):
            return """
                \(video): the clip \(clip) is \(String(format: "%.1f", length))s; \(video) holds \(screen) \
                for \(String(format: "%.1f", needed))s with the crossfade. Re-record it with \
                appshot record --clips --screens \(screen), or move the next cut earlier.
                """
```

In `slug`, after `.captionTooShort`:

```swift
        case .clipTooShort: return "clip_too_short"
```

- [ ] **Step 4: Implement `check` and `warnings`**

Add to `ClipsMaster`:

```swift
    /// A clip with no more frames than this over its whole length never moved.
    static let neverMovedFrames = 3
    /// Pixels a clip and its still may differ by before rects stop landing the same.
    static let sizeTolerance = 2.0

    /// What a clips render refuses before writing anything.
    public static func check(video: Config.Video, segments: [Segment]) throws {
        for (i, beat) in video.beats.enumerated() {
            if beat.cue != nil {
                throw AppShotError.invalidVideo(
                    id: video.id,
                    reason: "beat \(i) has a cue, which needs a recorded take: clips have no cue channel")
            }
            if beat.present != nil {
                throw AppShotError.invalidVideo(
                    id: video.id,
                    reason: "beat \(i) presents a sheet; present is for --from-stills renders. A clip "
                        + "shows the app's own sheet: stage it in the app")
            }
        }
        for (hold, segment) in zip(ClipPlan.holds(in: video), segments) {
            guard case .clip(_, let info) = segment.source, info.length + 1e-6 < hold.needed else { continue }
            throw AppShotError.clipTooShort(
                video: video.id, clip: segment.name, screen: segment.screen, length: info.length,
                needed: hold.needed)
        }
    }

    /// Clips that look wrong without being wrong enough to stop the render. Each clip is
    /// judged once, however many times the video cuts to it.
    public static func warnings(for segments: [Segment], stillsDir: URL?) -> [VideoTimeline.Warning] {
        var seen: Set<String> = []
        var out: [VideoTimeline.Warning] = []
        for segment in segments {
            guard case .clip(_, let info) = segment.source, seen.insert(segment.name).inserted else { continue }
            if info.frames <= neverMovedFrames {
                out.append(
                    .init(
                        kind: "clipNeverMoved", at: segment.at,
                        message: "\(segment.name) has \(info.frames) frames in "
                            + "\(String(format: "%.1f", info.length))s: does the app read -ScreenshotClip?"))
            }
            if let stillsDir,
                case let url = stillsDir.appending(path: "\(segment.name).png"),
                FileManager.default.fileExists(atPath: url.path),
                let still = try? Image.load(url),
                abs(Double(still.width) - info.size.width) > sizeTolerance
                    || abs(Double(still.height) - info.size.height) > sizeTolerance
            {
                out.append(
                    .init(
                        kind: "clipStillSizeMismatch", at: segment.at,
                        message: "\(segment.name) is \(Int(info.size.width))x\(Int(info.size.height)) as a "
                            + "clip and \(still.width)x\(still.height) as a still: rects written for one "
                            + "land off on the other"))
            }
        }
        return out
    }
```

`check` zips the holds with the segments. Both come from `ClipPlan.holds(in:)` in the same order: `segments(video:…)` maps the holds one to one.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ClipsMasterTests 2>&1 | tail -5`
Expected: PASS, 16 tests.

- [ ] **Step 6: Format, lint, full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/AppShotError.swift Sources/AppShotKit/ClipsMaster.swift \
  Tests/AppShotKitTests/ClipsMasterTests.swift
git commit -m "feat(video): refuse a clip too short for its screen, sheets and cues in a clips render, and warn on still or mis-sized clips"
```

---

## Task 5: Compose with `--from-clips`

Wire `ClipsMaster` into `VideoCompose` and the CLI: plan, check, report and contact sheet.

**Files:**
- Modify: `Sources/AppShotKit/VideoCompose.swift` (Options 11-44, Report 52-76, Job 79-94, run 96-176, scoped 180-187, render 211-220, render(job:makeMaster:) 328-344, renderTarget 369-371, reportBeats 386-400)
- Modify: `Sources/AppShotKit/VideoTrack.swift` (`stills(...)`, lines 113-125)
- Modify: `Sources/appshot/VideoCommands.swift` (`ComposeVideo`, lines 5-66)
- Create: `Tests/AppShotKitTests/VideoComposeClipsTests.swift`

**Interfaces:**
- Consumes: `ClipsMaster.segments/check/warnings/init`, `ClipsMaster.Segment`.
- Produces:
  - `VideoCompose.Options.fromClips: URL?`; the init gains `fromClips: URL? = nil` after `fromStills`
  - `VideoCompose.run(_:progress:)`, with `progress: (String) -> Void = { _ in }`
  - `VideoCompose.Report.Beat.source: String?` and `.clip: Report.ClipStats?` (`frames: Int`, `maxFrameGap: Double`, `length: Double`)
  - `VideoTrack.stills(video:appearance:stageSize:frames:maxFrameGap:)`, the last two defaulting to 0
  - the CLI `appshot compose video --from-clips <dir>`

- [ ] **Step 1: Write the failing tests**

`Tests/AppShotKitTests/VideoComposeClipsTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing

@testable import AppShotKit

struct VideoComposeClipsTests {
    /// The compose tests' stills (browser and paywall, 400×250) plus a clips directory.
    static func setup(beats: String, duration: Double = 3) throws -> (VideoCompose.Options, URL) {
        var (options, root) = try VideoComposeTests.setup(beats: beats, duration: duration)
        let clips = root.appending(path: "clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        options.fromClips = clips
        return (options, root)
    }

    static func report(_ root: URL) throws -> VideoCompose.Report {
        try JSONDecoder().decode(
            VideoCompose.Report.self,
            from: Data(contentsOf: root.appending(path: "videos/report/v~dark.report.json")))
    }

    @Test func mixesAClipAndAStill() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser", "caption": "One" },
                 { "at": 1.5, "screen": "paywall" }]
                """)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 3
        ) { $0 / 3 }
        var lines: [String] = []
        let outputs = try await VideoCompose.run(options) { lines.append($0) }
        let promo = root.appending(path: "videos/promo/v~dark~320x200.mp4")
        #expect(outputs.map(\.url).contains(promo))
        #expect(abs(try await AVURLAsset(url: promo).load(.duration).seconds - 3) < 0.05)
        #expect(lines.contains("v~dark: clips browser · stills paywall"))
        let report = try Self.report(root)
        #expect(report.beats.map(\.source) == ["clip", "still"])
        #expect(report.beats[0].clip?.frames == 90)
        #expect(report.beats[1].clip == nil)
        #expect(report.frames == 90)
    }

    @Test func aClipTooShortFailsBeforeAnyFileIsWritten() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser" }, { "at": 1.5, "screen": "paywall" }]
                """)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 1
        ) { _ in 0 }
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .clipTooShort? = error as? AppShotError else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func clipWarningsReachTheReport() async throws {
        let (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 4,
            frames: 1
        ) { _ in 0 }
        var lines: [String] = []
        _ = try await VideoCompose.run(options) { lines.append($0) }
        #expect(try Self.report(root).warnings.map(\.kind).contains("clipNeverMoved"))
        #expect(lines.contains { $0.hasPrefix("  warning: browser~dark has 1 frames") })
    }

    @Test func anEmptyClipsDirectoryRendersFromStills() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser" }, { "at": 1.5, "screen": "paywall" }]
                """)
        var lines: [String] = []
        _ = try await VideoCompose.run(options) { lines.append($0) }
        let report = try Self.report(root)
        #expect(report.beats.map(\.source) == ["still", "still"])
        #expect(report.frames == 0)
        #expect(lines.contains("v~dark: stills browser, paywall"))
    }

    @Test func aClipsRenderLabelsItsContactSheetCells() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser", "caption": "One" },
                 { "at": 1.5, "screen": "paywall", "caption": "Two" }]
                """)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 3
        ) { _ in 0.5 }
        let cells = try await VideoCompose.contactLabels(options)
        #expect(cells.contains { $0.hasPrefix("One · clip") })
        #expect(cells.contains { $0.hasPrefix("Two · still") })
        _ = root
    }

    @Test func clipsAreRefusedForAnIOSConfig() async throws {
        var (options, _) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        options.config.platform = .ios
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason == Recorder.iosReason
        }
    }
}
```

`VideoComposeTests.setup` returns `let` values, and `options` must be mutable at the call site. The destructuring above uses `var`, which is enough. If `config.platform` is not settable under that name, read `Config` for the stored property behind `resolvedPlatform` and set that instead. The test only needs `resolvedPlatform == .ios`.

`contactLabels` is a test seam. It plans the jobs exactly as `run` does and returns the labels the contact sheet would draw, so the test needs no OCR on the rendered sheet. It is defined in Step 3.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter VideoComposeClipsTests 2>&1 | tail -5`
Expected: compile errors, `value of type 'VideoCompose.Options' has no member 'fromClips'`.

- [ ] **Step 3: Implement it in `VideoCompose`**

Make these changes in `Sources/AppShotKit/VideoCompose.swift`.

**Options:** add the property and the init parameter.

```swift
        /// `record --clips`'s output: a clip per screen, played where the video cuts to it.
        /// Screens without one fall back to `fromStills`.
        public var fromClips: URL?
```

The init gains `fromClips: URL? = nil` right after `fromStills: URL?`, and sets `self.fromClips = fromClips`. `scoped(_:to:)` gains `scoped.fromClips = options.fromClips.map(device.directory(under:))`.

**Report:** add the stats struct and two optional fields to `Report.Beat`. Optional fields are omitted from the JSON when nil, so existing reports do not change.

```swift
        public struct ClipStats: Codable, Sendable {
            public var frames: Int
            public var maxFrameGap: Double
            public var length: Double
        }
        public struct Beat: Codable, Sendable {
            public var index: Int
            public var scheduled: Double
            public var actual: Double
            public var latency: Double?
            /// `"clip"` or `"still"`, on a beat that cuts to a screen in a clips render.
            public var source: String?
            public var clip: ClipStats?
        }
```

**Job:** add `let segments: [ClipsMaster.Segment]?` (nil outside a clips render) and the helper:

```swift
        /// " · clip" or " · still" for the segment on screen at `t`, in a clips render.
        func sourceSuffix(at t: Double) -> String {
            guard let segments, let on = segments.last(where: { $0.at <= t }) else { return "" }
            return on.isClip ? " · clip" : " · still"
        }
```

**run:** give the signature `public static func run(_ options: Options, progress: (String) -> Void = { _ in }) async throws -> [Output]`. Then:

1. Replace the two `options.fromStills == nil` tests (the iOS refusal and the pointer/present loop) with a `recorded` flag, so that the stills-only keys stay allowed in clips renders:

    ```swift
    let recorded = options.fromStills == nil && options.fromClips == nil
    if (recorded || options.fromClips != nil), config.resolvedPlatform == .ios {
        throw AppShotError.invalidVideo(id: video.id, reason: Recorder.iosReason)
    }
    if recorded { /* the existing pointer/present loop, unchanged */ }
    ```

2. Inside the appearance loop, branch on clips first. Collect the clip warnings with the job.

    ```swift
    let track: VideoTrack
    var segments: [ClipsMaster.Segment]?
    var clipWarnings: [VideoTimeline.Warning] = []
    if let clips = options.fromClips {
        let resolved = try ClipsMaster.segments(
            video: video, appearance: appearance, clipsDir: clips, stillsDir: options.fromStills)
        try ClipsMaster.check(video: video, segments: resolved)
        let master = try ClipsMaster(segments: resolved, video: video.id)
        var used: [String: ClipInfo] = [:]
        for segment in resolved {
            if case .clip(_, let info) = segment.source { used[segment.name] = info }
        }
        track = .stills(
            video: video, appearance: appearance, stageSize: master.stageSize,
            frames: used.values.map(\.frames).reduce(0, +),
            maxFrameGap: used.values.map(\.maxFrameGap).max() ?? 0)
        segments = resolved
        clipWarnings = ClipsMaster.warnings(for: resolved, stillsDir: options.fromStills)
        progress(Self.resolution(resolved, name: "\(video.id)~\(appearance)"))
        for warning in clipWarnings { progress("  warning: \(warning.message)") }
    } else if let stills = options.fromStills {
        // existing stills branch, unchanged
    } else {
        // existing recorded branch, unchanged
    }
    ```

3. Pass `segments: segments` into each `Job(...)`, and keep `clipWarnings` with it. Add `let clipWarnings: [VideoTimeline.Warning]` to `Job` and set it.

4. Add the resolution line:

    ```swift
    /// `intro~dark: clips hero, learning · stills challenge`, each screen once, in cut order.
    static func resolution(_ segments: [ClipsMaster.Segment], name: String) -> String {
        func unique(_ clip: Bool) -> [String] {
            var seen: Set<String> = []
            return segments.filter { $0.isClip == clip }.map(\.screen).filter { seen.insert($0).inserted }
        }
        let parts = [("clips", unique(true)), ("stills", unique(false))]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0) \($0.1.joined(separator: ", "))" }
        return "\(name): \(parts.joined(separator: " · "))"
    }
    ```

**render(_:options:):** choose `ClipsMaster` first.

```swift
            if let segments = job.segments {
                return try ClipsMaster(segments: segments, video: job.video.id)
            }
```

**render(_:options:makeMaster:):**

- `warnings:` becomes `job.timeline.warnings(for: job.preset) + job.clipWarnings`.
- `beats:` becomes `Self.reportBeats(video: video, track: job.track, timeline: job.timeline, segments: job.segments)`.

**renderTarget:** the cell label gains the suffix.

```swift
                    let caption = job.timeline.caption(at: next).map { KineticText.plain($0.text) } ?? ""
                    let label = caption + job.sourceSuffix(at: next)
```

**reportBeats:** take `segments: [ClipsMaster.Segment]? = nil` and fill the new fields for each beat that has a segment.

```swift
            var source: String?
            var clip: Report.ClipStats?
            if let segment = segments?.first(where: { $0.beat == index }) {
                source = segment.isClip ? "clip" : "still"
                if case .clip(_, let info) = segment.source {
                    clip = .init(frames: info.frames, maxFrameGap: info.maxFrameGap, length: info.length)
                }
            }
            return Report.Beat(
                index: index, scheduled: beat.at, actual: timeline.beatTimes[index], latency: latency,
                source: source, clip: clip)
```

**The test seam:** this plans exactly as `run` does and returns the labels, without rendering.

```swift
    /// The contact-sheet labels `run` would draw for each job, without rendering. A test
    /// seam: reading text back off the sheet would need OCR.
    static func contactLabels(_ options: Options) async throws -> [String] {
        try plan(options, progress: { _ in }).flatMap { job, _ in
            ContactSheet.times(for: job.timeline, beats: job.timeline.beatTimes).map { t in
                (job.timeline.caption(at: t).map { KineticText.plain($0.text) } ?? "")
                    + job.sourceSuffix(at: t)
            }
        }
    }
```

To share the planning, move everything in `run` from `try config.validate()` through the `Text.font` check into `static func plan(_ options: Options, progress: (String) -> Void) throws -> [(Job, Options)]`. `run` then calls `plan` and renders the jobs it returns. The body moves unchanged except for the edits above.

`VideoTrack.stills` gains `frames: Int = 0, maxFrameGap: Double = 0` and passes them through, in place of the literal `0`s.

- [ ] **Step 4: Wire the CLI**

In `Sources/appshot/VideoCommands.swift`, `ComposeVideo`:

```swift
    @Option(help: "Directory of masters and tracks written by `appshot record`. Default: \(Defaults.videoSource).")
    var source: String?

    @Option(
        help: """
            Build the video from the clips `appshot record --clips` wrote here: each beat \
            that names a `screen` plays that screen's clip from its start. A screen with \
            no clip falls back to its still from --from-stills.
            """)
    var fromClips: String?

    func validate() throws {
        if fromClips != nil, source != nil {
            throw ValidationError("--from-clips and --source are two different paths; pass one")
        }
    }
```

In `run()`, pass `sourceDir: URL(fileURLWithPath: source ?? Defaults.videoSource)` and `fromClips: fromClips.map { URL(fileURLWithPath: $0) }`, and print the progress lines:

```swift
        let outputs = try await VideoCompose.run(VideoCompose.Options(/* … as before, plus fromClips … */)) {
            print($0)
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "VideoComposeClipsTests|VideoComposeTests|VideoMasterTests" 2>&1 | tail -5`
Expected: PASS.

Then run the CLI conflict by hand:

```bash
swift run appshot compose video --from-clips /tmp/x --source /tmp/y 2>&1 | tail -2
```

Expected: `Error: --from-clips and --source are two different paths; pass one`, exit 64.

- [ ] **Step 6: Format, lint, full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoCompose.swift Sources/AppShotKit/VideoTrack.swift \
  Sources/appshot/VideoCommands.swift Tests/AppShotKitTests/VideoComposeClipsTests.swift
git commit -m "feat(video): compose video --from-clips, with stills fallback, clip sources in the report and the contact sheet"
```

---

## Task 6: Lift the filming loop out of `Recorder.record`

A refactor with no behaviour change. The ScreenCaptureKit setup, the window-filter refresh, and the stop-and-finish logic move into `Recorder.film`. A take and a clip then share one tested loop.

**Files:**
- Modify: `Sources/AppShotKit/Recorder.swift` (`record`, lines 290-441)
- Test: `Tests/AppShotKitTests/RecorderIntegrationTests.swift` (unchanged; it is the proof)

**Interfaces:**
- Produces:
  - `Recorder.Film { crop: [Double], frames: Int, maxGap: Double, scale: Double, display: CGRect, stopped: Double }`
  - `Recorder.film(pid: pid_t, base: Window.Info, partial: URL, label: String, tick: (_ now: () -> Double) async throws -> Bool) async throws -> Film`. `tick` is called every 5 ms with the take's clock; it returns `false` to stop.

- [ ] **Step 1: Extract `film`**

Add to `Recorder`:

```swift
    /// What filming left behind, for the caller to turn into a track or a clip.
    struct Film {
        /// The union of the windows seen, in master pixels: x, y, width, height.
        let crop: [Double]
        let frames: Int
        let maxGap: Double
        /// The display's backing scale, and its frame in global points.
        let scale: Double
        let display: CGRect
        /// Seconds from t = 0 to the stop.
        let stopped: Double
    }

    /// Film the app's windows into `partial`, from the first frame until `tick` answers
    /// false. `tick` gets the take's clock, where t = 0 is the first frame's own
    /// timestamp. Every way out stops the stream.
    static func film(
        pid: pid_t, base: Window.Info, partial: URL, label: String,
        tick: (_ now: () -> Double) async throws -> Bool
    ) async throws -> Film {
        // Moved verbatim from `record`: the shareable-content listing, the display choice,
        // `stageWindows`/`recordable`/`filter`, the SCStreamConfiguration, the
        // StreamRecorder and SCStream setup, the first-frame wait and the host-clock
        // guard. Replace each `video.id` with `label`.
        …
        do {
            // addStreamOutput, startCapture, the first frame, the host-clock guard:
            // moved verbatim.
            var lastWindowCheck = 0.0
            while true {
                try recorder.throwIfStopped(video: label)
                guard try await tick(now) else { break }
                let t = now()
                if t - lastWindowCheck >= 0.25 {
                    lastWindowCheck = t
                    // The window refresh, moved verbatim from the record loop.
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let stopped = now()
            try recorder.throwIfStopped(video: label)
            try await bounded(video: label, "stopping the stream") { try await stream.value.stopCapture() }
            try await recorder.finish()
            return Film(
                crop: stageCrop(windows: seen, display: display.frame, scale: scale), frames: recorder.frames,
                maxGap: recorder.maxGap, scale: scale, display: display.frame, stopped: stopped)
        } catch {
            _ = try? await bounded(video: label, "stopping the stream") { try await stream.value.stopCapture() }
            recorder.cancel()
            throw error
        }
    }
```

"Moved verbatim" means cut from `record` and pasted unchanged, apart from the `video.id` → `label` rename. The lines are `Recorder.swift` 290-359 for the setup and 393-413 for the window refresh. The only new code is the `while true` / `tick` / `stopped` / `Film` shape shown above.

- [ ] **Step 2: Rewrite `record`'s middle on top of `film`**

In `record`, after the ready-event wait, the stream code is replaced by:

```swift
        let lines = cueLines(for: video)
        var sent: [Int: Double] = [:]
        var acked: [Int: Double] = [:]
        var targets: [(seq: Int, name: String, rect: [Double])] = []
        var warnings: [String] = []
        var pending = lines[...]

        let film = try await film(pid: pid, base: base, partial: partial, label: video.id) { now in
            func pollEvents() throws {
                // The body of the old pollEvents, unchanged; it already reads `now()`.
            }
            let t = now()
            if t < video.duration {
                while let next = pending.first, next.line.t <= t {
                    try channel.send(next.line)
                    sent[next.seq] = t
                    pending = pending.dropFirst()
                }
                try pollEvents()
                warnings = try judge(sent: sent, acked: acked, now: now(), lines: lines, video: video.id)
                return true
            }
            // A cue sent just before the end still owes its ack, and the take is not
            // judged until it answers or times out. The stream keeps running so its
            // effect lands in the master.
            guard sent.keys.contains(where: { acked[$0] == nil }) else { return false }
            try pollEvents()
            warnings = try judge(sent: sent, acked: acked, now: now(), lines: lines, video: video.id)
            return true
        }
        let crop = film.crop
        let scale = film.scale
        let display = film.display
```

Everything after that (`clicks`, `cues`, `reported`, the `VideoTrack`, the move and the write) is unchanged, with two edits. `display` is now the display's frame, a `CGRect`, where it was an `SCDisplay`, so `display.frame.minX` and `display.frame.minY` become `display.minX` and `display.minY`. And `frames: recorder.frames, maxFrameGap: recorder.maxGap` become `frames: film.frames, maxFrameGap: film.maxGap`.

- [ ] **Step 3: Run the unit suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, the same count as before.

- [ ] **Step 4: Run the integration suite against the fixture**

This needs Screen Recording permission for the terminal running the tests. The fixture launches with `--no-activate` and is filmed in the background.

```bash
make fixture
APPSHOT_INTEGRATION=1 swift test --filter RecorderIntegrationTests 2>&1 | tail -8
```

Expected: PASS for every case: all cues acked, the mid-take window joins, an unknown cue fails cleanly, and `instant` never sends ready. If permission is missing, the suite fails at `screenRecordingDenied`. In that case stop and report it to the human rather than skip this step: the refactor is unproven until this passes.

- [ ] **Step 5: Format, lint, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/Recorder.swift
git commit -m "refactor(record): lift the ScreenCaptureKit filming loop into Recorder.film"
```

---

## Task 7: The fixture moves under `-ScreenshotClip`

The fixture app learns the clip contract, so the clip recorder has something to film in its integration test.

**Files:**
- Modify: `Sources/AppShotFixture/main.swift` (`Stage` enum lines 35-44; the animation start around lines 203-210; `Delegate.init`)
- Test: covered by Task 9's integration test (the fixture is not unit-tested)

**Interfaces:**
- Produces:
  - Under `-ScreenshotClip YES`, every fixture stage except `clip-deaf` starts its `restless` animation once ready is signalled.
  - `clip-deaf` is a stage that signals ready and ignores the flag.

- [ ] **Step 1: Add the stage and the behaviour**

In `enum Stage`, add `case clipDeaf = "clip-deaf"`.

`Delegate` reads the flag once, in `init`:

```swift
    let clip = UserDefaults.standard.bool(forKey: "ScreenshotClip")
```

Replace the `if stage.animates { … }` block with:

```swift
        // Under -ScreenshotClip the screen must move once it is ready, as a clip-mode
        // app does; clip-deaf is the app that never learned to.
        if stage.animates || (clip && stage != .clipDeaf) {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    view.phase += 1
                    view.needsDisplay = true
                }
            }
        }
```

The timer must start after the ready signal, which it does: the block comes after `signalReady()` in the method.

- [ ] **Step 2: Build it**

Run: `make fixture 2>&1 | tail -2`
Expected: `.build/fixture/AppShotFixture.app` is rebuilt with no errors.

- [ ] **Step 3: Format, lint, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotFixture/main.swift
git commit -m "test(fixture): move under -ScreenshotClip, and a clip-deaf stage that does not"
```

---

## Task 8: `ClipRecorder`

The library side of `record --clips`. It plans the clips, launches each stage with the ready file and the clip flag, films until the clip's length, and writes the clip and its sidecar.

**Files:**
- Create: `Sources/AppShotKit/ClipRecorder.swift`
- Test: `Tests/AppShotKitTests/ClipRecorderTests.swift`

**Interfaces:**
- Consumes:
  - `ClipPlan.lengths(for:)`, `ClipInfo`, `Recorder.film`, `Recorder.requireMac`, `Recorder.takeError`
  - `Capture.openArguments`, `Capture.readyFileURL`, `Capture.waitForReady`, `Capture.waitForNewPID`, `Capture.waitForWindow`, `Capture.pids`, `Capture.terminate`, `Capture.Screen.applyingChrome`, `Capture.hasScreenRecordingPermission`
  - `CaptureLock`, `GlobalBoolOverride`, `Interrupt`, `AppShotVersion.current`
- Produces:
  - `ClipRecorder.Options(capture: Capture.Options, config: Config, videos: [Config.Video], clipArg: String = "-ScreenshotClip")`
  - `ClipRecorder.Clip { screen, appearance: String, movie: URL, info: URL, frames: Int }`
  - `ClipRecorder.run(_:progress:) async throws -> [Clip]`
  - `ClipRecorder.plan(_ options: Options) throws -> [(screen: Capture.Screen, length: Double)]` (pure)
  - `ClipRecorder.arguments(screen:appearance:readyFile:display:options:) -> [String]` (pure)
  - `ClipRecorder.trafficLightsOrigin(base: CGRect, display: CGRect, scale: Double, crop: [Double]) -> [Double]` (pure)

- [ ] **Step 1: Write the failing tests**

`Tests/AppShotKitTests/ClipRecorderTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct ClipRecorderTests {
    static func options(screens: [Capture.Screen] = [], extraArgs: [String] = []) throws -> ClipRecorder.Options {
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
        let plan = try ClipRecorder.plan(Self.options(screens: [try Capture.Screen(spec: "paywall:paywall-play")]))
        #expect(plan.map(\.screen.name) == ["paywall"])
        #expect(plan.map(\.screen.stage) == ["paywall-play"])
    }

    @Test func aScreenNoVideoUsesFailsBeforeAnythingLaunches() throws {
        #expect {
            _ = try ClipRecorder.plan(Self.options(screens: [try Capture.Screen(spec: "organize")]))
        } throws: { error in
            guard case .invalidScreenSpec(let spec, let reason)? = error as? AppShotError else { return false }
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
```

`trafficLightsOriginIsTheBaseWindowInsideTheCrop` checks the arithmetic: (230 − 0) × 2 − 400 = 60 and (140 − 0) × 2 − 200 = 80.

As in Task 5, if `config.platform` is not settable under that name, set the stored property behind `resolvedPlatform`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ClipRecorderTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'ClipRecorder' in scope`.

- [ ] **Step 3: Implement `ClipRecorder`**

`Sources/AppShotKit/ClipRecorder.swift`:

```swift
import AppKit
import Foundation

/// `record --clips`: one moving clip per screen, with no cue handler.
///
/// Each stage is launched the way `capture` launches it, plus `-ScreenshotClip YES`. The
/// app stages, writes the ready file, and starts moving through its own code; appshot
/// films it until the clip's length. Nothing is clicked or typed.
public enum ClipRecorder {
    public struct Options: Sendable {
        /// The app, appearances, launch arguments, placement flags, `--screens`, the lock
        /// and `settleMax` (the ceiling on waiting for the ready file).
        public var capture: Capture.Options
        /// For `chrome: none` screens and the iOS refusal.
        public var config: Config
        /// Their `screen` beats decide which clips are recorded, and for how long.
        public var videos: [Config.Video]
        public var clipArg: String

        public init(
            capture: Capture.Options, config: Config, videos: [Config.Video], clipArg: String = "-ScreenshotClip"
        ) {
            self.capture = capture
            self.config = config
            self.videos = videos
            self.clipArg = clipArg
        }
    }

    public struct Clip: Sendable {
        public let screen: String
        public let appearance: String
        public let movie: URL
        public let info: URL
        public let frames: Int
    }

    /// Which screens to film, with their stage and length, in name order. `--screens`
    /// narrows the set and maps stages; without it, every screen the videos name.
    public static func plan(_ options: Options) throws -> [(screen: Capture.Screen, length: Double)] {
        let lengths = ClipPlan.lengths(for: options.videos)
        if lengths.isEmpty, let video = options.videos.first {
            throw AppShotError.invalidVideo(id: video.id, reason: "names no screen, so there is no clip to record")
        }
        let screens: [Capture.Screen]
        if options.capture.screens.isEmpty {
            screens = lengths.keys.sorted().map { Capture.Screen(name: $0, stage: $0) }
        } else {
            for screen in options.capture.screens where lengths[screen.name] == nil {
                throw AppShotError.invalidScreenSpec(
                    screen.name, reason: "no chosen video names screen \(screen.name), so it has no clip")
            }
            screens = options.capture.screens.sorted { $0.name < $1.name }
        }
        return Capture.Screen.applyingChrome(screens, from: options.config).map { ($0, lengths[$0.name] ?? 0) }
    }

    /// Everything `open` is given for one clip: capture's arguments, then the clip flag,
    /// last so appshot's value wins over a project's.
    static func arguments(
        screen: Capture.Screen, appearance: String, readyFile: URL, display: UInt32?, options: Options
    ) -> [String] {
        Capture.openArguments(
            screen: screen, appearance: appearance, readyFile: readyFile, display: display,
            options: options.capture) + [options.clipArg, "YES"]
    }

    /// The base window's top-left in crop pixels, where `TrafficLights` looks for the
    /// buttons. Not (0, 0): a popover or second window can push the crop past the corner.
    static func trafficLightsOrigin(base: CGRect, display: CGRect, scale: Double, crop: [Double]) -> [Double] {
        [((base.minX - display.minX) * scale - crop[0]).rounded(), ((base.minY - display.minY) * scale - crop[1]).rounded()]
    }

    public static func run(_ options: Options, progress: (Clip) -> Void = { _ in }) async throws -> [Clip] {
        try Recorder.requireMac(options.config)
        // Before the lock and any launch: a bad --screens found at its own clip would fail
        // after the earlier clips had held the screen for nothing.
        let plan = try plan(options)
        let app = options.capture.app
        guard FileManager.default.fileExists(atPath: app.path) else { throw AppShotError.appNotFound(app) }
        guard Capture.hasScreenRecordingPermission() else { throw AppShotError.screenRecordingDenied }
        try FileManager.default.createDirectory(at: options.capture.outDir, withIntermediateDirectories: true)

        let appName = app.deletingPathExtension().lastPathComponent
        let holder = CaptureLock.Holder.current(
            app: appName, appPath: app.path, shots: plan.count * options.capture.appearances.count)
        let lock = try await CaptureLock.acquire(
            holder, root: options.capture.lockRoot, wait: options.capture.wait,
            timeout: options.capture.waitTimeout)
        defer { lock.release() }

        // As capture does: give the person their setting back however we leave.
        try GlobalBoolOverride.recoverStale(
            key: GlobalBoolOverride.wallpaperTintKey, stateDir: options.capture.overrideStateDir)
        let tint =
            options.capture.noWallpaperTint
            ? try GlobalBoolOverride.acquire(
                key: GlobalBoolOverride.wallpaperTintKey, value: true, stateDir: options.capture.overrideStateDir)
            : nil
        defer { tint?.release() }
        let interrupted = Interrupt.onInterrupt { tint?.release() }
        defer { Interrupt.remove(interrupted) }

        var clips: [Clip] = []
        for appearance in options.capture.appearances {
            for (screen, length) in plan {
                let name = ClipInfo.name(screen: screen.name, appearance: appearance)
                let clip: Clip
                do {
                    clip = try await record(
                        screen: screen, length: length, appearance: appearance, appName: appName, options: options)
                } catch {
                    throw Recorder.takeError(error, video: name)
                }
                clips.append(clip)
                progress(clip)
            }
        }
        return clips
    }

    static func record(
        screen: Capture.Screen, length: Double, appearance: String, appName: String, options: Options
    ) async throws -> Clip {
        let name = ClipInfo.name(screen: screen.name, appearance: appearance)
        let out = options.capture.outDir
        let movie = ClipInfo.movieURL(in: out, screen: screen.name, appearance: appearance)
        let partial = movie.appendingPathExtension("partial")
        let readyFile = Capture.readyFileURL(for: options.capture.app)

        let before = Capture.pids(named: appName)
        let cleanup: @Sendable () -> Void = {
            for pid in Capture.pids(named: appName).subtracting(before) { Capture.terminate(pid) }
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: readyFile)
        }
        let interrupted = Interrupt.onInterrupt(cleanup)
        defer {
            Interrupt.remove(interrupted)
            cleanup()
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments(
            screen: screen, appearance: appearance, readyFile: readyFile,
            display: options.capture.captureDisplay.resolve(), options: options)
        try open.run()
        open.waitUntilExit()

        guard let pid = try await Capture.waitForNewPID(named: appName, excluding: before) else {
            throw AppShotError.appNeverStarted(screen: name)
        }
        guard let base = try await Capture.waitForWindow(pid: pid) else {
            throw AppShotError.windowNeverAppeared(screen: name)
        }
        // No stillness poll: the screen is supposed to move from here on.
        guard await Capture.waitForReady(readyFile, ceiling: options.capture.settleMax) else {
            throw AppShotError.appNeverSignalledReady(
                screen: name, file: readyFile, seconds: options.capture.settleMax)
        }

        let film = try await Recorder.film(pid: pid, base: base, partial: partial, label: name) { now in
            now() < length
        }

        let lights: ClipInfo.TrafficLights? =
            options.capture.recolorTrafficLights && !screen.chromeless
            ? .init(
                origin: trafficLightsOrigin(
                    base: base.bounds, display: film.display, scale: film.scale, crop: film.crop),
                scale: film.scale)
            : nil
        let info = ClipInfo(
            screen: screen.name, stage: screen.stage, appearance: appearance, length: film.stopped,
            crop: film.crop, trafficLights: lights, frames: film.frames, maxFrameGap: film.maxGap,
            appshotVersion: AppShotVersion.current,
            recordedAt: ISO8601DateFormatter().string(from: Date()))

        try? FileManager.default.removeItem(at: movie)
        try FileManager.default.moveItem(at: partial, to: movie)
        let infoURL = ClipInfo.url(in: out, screen: screen.name, appearance: appearance)
        try info.write(to: infoURL)
        return Clip(screen: screen.name, appearance: appearance, movie: movie, info: infoURL, frames: film.frames)
    }
}
```

If `Capture.hasScreenRecordingPermission`, `Capture.readyFileURL`, `Capture.waitForReady` or `Capture.waitForWindow` are `private`, widen them to internal (drop `private`). They are already used from `Recorder` in the same module, so most are internal now.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipRecorderTests 2>&1 | tail -5`
Expected: PASS, 7 tests.

- [ ] **Step 5: Format, lint, full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/ClipRecorder.swift Tests/AppShotKitTests/ClipRecorderTests.swift
git commit -m "feat(record): ClipRecorder films one moving clip per screen, after the app's ready file"
```

---

## Task 9: `record --clips` on the command line, proven on the fixture

**Files:**
- Modify: `Sources/appshot/VideoCommands.swift` (`Record`, lines 68-115)
- Create: `Scripts/fixture-clips.config.json`
- Create: `Tests/AppShotKitTests/ClipRecorderIntegrationTests.swift`

**Interfaces:**
- Consumes: `ClipRecorder.run`, `ClipsMaster.segments/warnings`, `RecordedMaster(url:crop:label:)`.
- Produces: the CLI `appshot record --clips [--screens …] [--capture-display …] [--no-wallpaper-tint] [--recolor-traffic-lights]`.

- [ ] **Step 1: Write the fixture config**

`Scripts/fixture-clips.config.json`:

```json
{
  "//": "Drives the clip integration test: a moving screen (the fixture under -ScreenshotClip) and one that ignores the flag.",
  "output": { "width": 2880, "height": 1800 },
  "appearances": ["dark"],
  "fontFamily": "Helvetica",
  "layout": {
    "margin": 180, "textTop": 150, "titleFontSize": 104, "titleWeight": 700, "titleLineHeight": 1.12,
    "subtitleFontSize": 46, "subtitleWeight": 500, "textGap": 30, "screenshotGap": 90, "cornerRadius": 26,
    "shadow": { "blur": 52, "opacity": 0.34, "dy": 26 }
  },
  "themes": {
    "dark": {
      "background": { "angle": 270, "stops": [{ "offset": 0, "color": "#7A2F1C" }, { "offset": 1, "color": "#0B0C0F" }] },
      "title": "#F4F2EF", "subtitle": "#9B9A96"
    }
  },
  "screens": [{ "id": "moving", "title": "Moving" }, { "id": "deaf", "title": "Deaf" }],
  "videos": [{
    "id": "clips", "duration": 4, "outputs": { "promo": [[1080, 1080]] },
    "beats": [{ "at": 0, "screen": "moving" }, { "at": 2, "screen": "deaf" }]
  }]
}
```

- [ ] **Step 2: Write the integration test**

`Tests/AppShotKitTests/ClipRecorderIntegrationTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Needs Screen Recording for the test runner and `make fixture` first. Never on CI.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["APPSHOT_INTEGRATION"] == "1"))
struct ClipRecorderIntegrationTests {
    @Test func recordsAMovingClipAndADeafOneThenComposesThem() async throws {
        let config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-clips.config.json"))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clips-\(UUID())")
        let options = ClipRecorder.Options(
            capture: Capture.Options(
                app: RecorderIntegrationTests.app, outDir: out,
                screens: [try Capture.Screen(spec: "moving:instant"), try Capture.Screen(spec: "deaf:clip-deaf")],
                appearances: ["dark"], noActivate: true),
            config: config, videos: config.videos ?? [])
        let clips = try await ClipRecorder.run(options)
        #expect(clips.map(\.screen) == ["deaf", "moving"])

        let moving = try ClipInfo.read(ClipInfo.url(in: out, screen: "moving", appearance: "dark"))
        // Held 2 s, plus the crossfade and the margin.
        #expect(moving.length >= 3 - 0.05)
        // The fixture animates every 0.1 s: a 3 s clip has far more than a handful of frames.
        #expect(moving.frames > 10)
        #expect(moving.stage == "instant")

        let video = try config.video("clips")
        let segments = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: out, stillsDir: nil)
        try ClipsMaster.check(video: video, segments: segments)
        #expect(ClipsMaster.warnings(for: segments, stillsDir: nil).map(\.message).contains {
            $0.hasPrefix("deaf~dark has")
        })
        #expect(!ClipsMaster.warnings(for: segments, stillsDir: nil).contains { $0.message.hasPrefix("moving") })

        var master = try ClipsMaster(segments: segments, video: "clips")
        let px = try #require(Image.pixels(try master.frame(at: 1)))
        #expect(px.bytes[3] <= 5)  // a window corner stays transparent

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter {
            $0.hasSuffix(".partial")
        }
        #expect(leftovers.isEmpty)
        #expect(Capture.pids(named: "AppShotFixture").isEmpty)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
make fixture
APPSHOT_INTEGRATION=1 swift test --filter ClipRecorderIntegrationTests 2>&1 | tail -5
```

Expected: it compiles, because ClipRecorder exists, and either passes or fails on a behaviour. If it passes already, Tasks 7 and 8 did their job, and this step and Step 4 confirm it. If it fails, fix the cause in ClipRecorder or the fixture before going on.

- [ ] **Step 4: Wire the CLI**

In `Record` (`Sources/appshot/VideoCommands.swift`), add:

```swift
    @Flag(
        help: """
            Record one moving clip per screen the videos name, instead of a scripted take. \
            Each stage launches as `capture` launches it, plus -ScreenshotClip YES: the app \
            stages, writes the ready file, then moves on its own. No cue handler needed. \
            Compose with `compose video --from-clips`.
            """)
    var clips = false

    @Option(
        parsing: .upToNextOption,
        help: "With --clips: only these screens, as name[:stage], the stage defaulting to the name.")
    var screens: [String] = []

    @Flag(help: "With --clips: repaint grey traffic lights in every frame at compose time, as capture does.")
    var recolorTrafficLights = false

    @Option(help: "With --clips: main, secondary, builtin or external, as for capture.")
    var captureDisplay: DisplayChoice = .main

    @Flag(help: "With --clips: turn off wallpaper tinting for the run, as capture does.")
    var noWallpaperTint = false

    func validate() throws {
        if !clips, !screens.isEmpty || recolorTrafficLights || captureDisplay != .main || noWallpaperTint {
            throw ValidationError(
                "--screens, --recolor-traffic-lights, --capture-display and --no-wallpaper-tint are for --clips")
        }
    }
```

In `run()`, branch before the take path:

```swift
        if clips {
            let capture = Capture.Options(
                app: URL(fileURLWithPath: app), outDir: URL(fileURLWithPath: out), partial: true,
                screens: try screens.map(Capture.Screen.init(spec:)),
                appearances: appearances.map(Pipeline.appearances(from:)) ?? config.appearances,
                extraArgs: LaunchArguments.split(extraArgs), settleMax: settleMax, wait: wait,
                noActivate: noActivate, recolorTrafficLights: recolorTrafficLights,
                captureDisplay: captureDisplay, noWallpaperTint: noWallpaperTint)
            let recorded = try await ClipRecorder.run(
                ClipRecorder.Options(capture: capture, config: config, videos: chosen)
            ) { clip in
                print("  \(clip.screen)~\(clip.appearance)  \(clip.movie.lastPathComponent)  \(clip.frames) frames")
            }
            print(
                "recorded \(recorded.count) clip(s) → \(out). Next: appshot compose video --from-clips \(out) "
                    + "--from-stills <captures>")
            return
        }
```

If `DisplayChoice` is not `Equatable`, compare with a `switch`, or make it `Equatable` in `Sources/AppShotKit/DisplayChoice.swift`; it is a plain enum.

- [ ] **Step 5: Verify the CLI end to end on the fixture**

```bash
swift build
rm -rf /tmp/appshot-clips-cli
.build/debug/appshot record --clips --app .build/fixture/AppShotFixture.app \
  --config Scripts/fixture-clips.config.json --out /tmp/appshot-clips-cli \
  --screens moving:instant deaf:clip-deaf --no-activate --wait
.build/debug/appshot compose video --config Scripts/fixture-clips.config.json \
  --from-clips /tmp/appshot-clips-cli --out /tmp/appshot-clips-cli/videos
```

Expected:

- `record` prints two clips.
- `compose` prints `clips~dark: clips moving, deaf` and `  warning: deaf~dark has … frames …`, then the promo path.
- Read `/tmp/appshot-clips-cli/videos/report/clips~dark.contact.png` with the Read tool: the moving square is in a different place in the two `moving` cells, and the labels end in `· clip`.

- [ ] **Step 6: Format, lint, full suite, integration, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
APPSHOT_INTEGRATION=1 swift test --filter "RecorderIntegrationTests|ClipRecorderIntegrationTests" 2>&1 | tail -5
git add Sources/appshot/VideoCommands.swift Scripts/fixture-clips.config.json \
  Tests/AppShotKitTests/ClipRecorderIntegrationTests.swift
git commit -m "feat(record): appshot record --clips, proven on the fixture"
```

---

## Task 10: Docs and skill

**Files:**
- Modify: `skills/appshot-video/SKILL.md`
- Modify: `skills/appshot-video/references/app-side.md`
- Modify: `README.md` (its video section)
- Modify: `CHANGELOG.md` (`## [Unreleased]`)

The skill is symlinked into `~/.claude/skills/appshot-video`, so these edits go live once they reach `main`.

- [ ] **Step 1: SKILL.md**

1. In the pipeline block at the top, add a line between the stills line and the recorded line:

    ```
    appshot record --clips    app moves on its own per screen → <dir>/<screen>~<app>.mov + .clip.json
    appshot compose video --from-clips <clips> --from-stills <captures>  → the same outputs, real motion, no cue handler
    ```

2. In "Pick the path first", make the table three columns, From stills | Clips | Recorded, with these Clips cells:
    - App code needed: "start moving after ready under `-ScreenshotClip YES` (`references/app-side.md`)"
    - Shows: "the app really moving per screen, notes falling, charts animating, crossfaded between screens; no clicks or app reactions"
    - Pointer: "yes, from `pointer` beats, drawn over the clip"
    - Time to first video: "an hour if the stages already exist"
    - Good for: "App Store previews for apps that move on their own; mixing with stills while a screen's motion is not built yet"

    Update the paragraph under the table: start from stills; move to clips when the app's screens can move by themselves; record a take only when the story needs the app reacting to input.

3. Add a section `## Path C — clips` between Path A and Path B:

    ````markdown
    ## Path C — clips

    1. **The app side.** Under `-ScreenshotClip YES`, each stage starts moving right
       after it writes the ready file: play, scroll, animate, through demo-mode code.
       Nothing else changes; see `references/app-side.md`.
    2. **Record**, in the background:

       ```bash
       appshot record --clips --app build/MyApp.app --config Screenshots/screenshots.config.json \
         --out Screenshots/videos/clips --videos intro --appearances dark \
         --no-activate --capture-display builtin --no-wallpaper-tint --recolor-traffic-lights --wait
       ```

       One clip per screen the videos name, as long as the longest hold plus 1 s.
       `--screens hero:hero-play` records a subset or maps a stage; screens left
       out keep their earlier clip.
    3. **Compose**, falling back to stills for any screen without a clip:

       ```bash
       appshot compose video --config Screenshots/screenshots.config.json \
         --from-clips Screenshots/videos/clips --from-stills Screenshots/source \
         --out Screenshots/videos --videos intro
       ```

       It prints which screens are clips and which are stills. Captions, framing
       and timing within each clip's length iterate with compose alone.

    Clips are silent, Mac only, and cannot take `cue` or `present` beats.
    ````

4. In "When it fails", add three rows:

    | Message | Meaning | Fix |
    |---|---|---|
    | `the clip hero~dark is 4.2s; intro holds hero for 7.0s with the crossfade` | The video stays on the screen longer than the clip runs. | `appshot record --clips --screens hero`, or move the next cut earlier. |
    | `clipNeverMoved` warning: `hero~dark has 2 frames in 7.0s` | The app staged but never moved. | Make the stage move under `-ScreenshotClip YES`. |
    | `clipStillSizeMismatch` warning | The clip and its still differ in size, so rects land off. | Record both on the same display (`--capture-display`), or re-capture the still. |

- [ ] **Step 2: references/app-side.md**

Append:

```markdown
## Clips: `-ScreenshotClip YES`

`appshot record --clips` launches each stage with the screenshot arguments plus
`-ScreenshotClip YES`, and films it. The app:

1. stages exactly as for a screenshot, with the same demo data and guards;
2. writes the ready file once that frame is drawn;
3. **starts moving immediately**, through its own demo code: play the song, run the
   animation, stream the list;
4. keeps moving, the same way every run, for at least the clip's length (the longest
   hold of that screen plus 1 s).

Without the flag nothing changes: a screenshot must still freeze. No cue file, no
event file, no acks. A screen that only moves when something is clicked needs a demo
code path that moves it, or the recorded path.
```

- [ ] **Step 3: README and CHANGELOG**

In `README.md`'s video section, name the three paths in one sentence each: stills, clips, recorded.

Under `## [Unreleased]` in `CHANGELOG.md`:

```markdown
### Added

- **Clips: moving video without a cue handler.** `appshot record --clips` films one
  short clip per screen the videos name: each stage launches as `capture` launches it,
  plus `-ScreenshotClip YES`, writes its ready file, and moves on its own. `compose video
  --from-clips` plays each screen's clip from its start and falls back to the still for a
  screen without one, so one video can mix both. The report says which screens are
  clips, and warns on a clip that never moved or does not match its still's size. A clip
  too short for its screen fails the render, naming the screen to re-record.
```

- [ ] **Step 4: Commit**

```bash
git add skills/appshot-video/SKILL.md skills/appshot-video/references/app-side.md README.md CHANGELOG.md
git commit -m "docs(video): the clips path in the skill, app-side contract, README and changelog"
```

---

## Task 11: Finish

- [ ] **Step 1: Full gate**

```bash
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
APPSHOT_INTEGRATION=1 swift test --filter "RecorderIntegrationTests|ClipRecorderIntegrationTests" 2>&1 | tail -5
```

Expected: the lint is clean, every unit test passes, and both integration suites pass.

- [ ] **Step 2: Merge fast-forward and clean up**

```bash
cd ~/Projects/appshot
git merge --ff-only video-clips
git worktree remove ../appshot-clips
git branch -d video-clips
git rev-list --count origin/main..main     # report this number; do not push
```

- [ ] **Step 3: Install locally, so Pupitre can use it**

```bash
make install
appshot record --help | grep -- --clips
```

Expected: `--clips` is listed. Do not tag, release or push. That is the human's call.
