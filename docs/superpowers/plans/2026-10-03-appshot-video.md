# appshot video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `appshot record` (macOS) and `appshot compose video` (including `--from-stills`) so any fleet app can turn a `videos[]` config entry into App Store previews and promo videos.

**Architecture:** appshot owns the timeline: it writes cues into a file in the app's sandbox container and reads the app's events back from a second file. `record` captures the app's windows with an `SCStream` into an HEVC-with-alpha master plus a `track.json` of what actually happened. `compose video` is a pure function of master + track + config. It renders every frame with CoreGraphics (reusing `Compose`'s gradient, shadow and CoreText code) and encodes H.264 + silent AAC with `AVAssetWriter`. `--from-stills` synthesizes the master and track from existing PNG captures, so the renderer has two sources and one code path.

**Tech Stack:** Swift 6 (strict concurrency, swift-tools 6.0), ScreenCaptureKit, AVFoundation, CoreImage, CoreGraphics/CoreText, swift-argument-parser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-03-appshot-video-design.md`. Read it before starting any task.

**Scope of this plan:** spec phases 0 (spike), 1 (core) and 1b (from stills). Not in this plan: Armada's cue handler (phase 2, planned separately in the armada repo), video `check` and the skill's `video.md` (phase 3), iOS recording (phase 4).

## Global Constraints

- Platform floor stays **macOS 14** (`Package.swift` `platforms: [.macOS(.v14)]`). Every API used must exist on 14.
- **AppShotKit never prints and never exits.** It returns values and throws `AppShotError`. Only `Sources/appshot` prints.
- Every new `AppShotError` case gets a `description` **and** a `slug` (the `slug` switch in `AppShotError.swift` is exhaustive; `check --json` callers branch on it).
- Formatting: `swift format lint --strict --recursive Sources Tests` must pass (`.swift-format`: 4 spaces, line length 110). CI runs it.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), like the rest of `Tests/`.
- Comment density matches the codebase: doc comments explain *why* (the failure a choice prevents), not what.
- Coordinates: every rect a fixture or app reports is in **global screen points, top-left origin** (the `CGWindowList` convention `Window.Info.bounds` uses). `track.json` stores rects in **stage pixels, top-left origin**.
- Video constants (copied verbatim from the spec): App Store preview 15-30 s, 30 fps, H.264 High 4.0 ~10 Mbps, stereo AAC 48 kHz; macOS preview size 1920x1080; caption fade 0.25 s; reading check `1 s + 0.3 s per word`; cue latency warn > 50 ms, fail > 250 ms; ack timeout 1 s.
- Masters, previews and promos are written as `<name>.partial` and renamed on success, so an interrupted run never leaves a file that looks finished.
- Tests that need a hardware HEVC encoder are `.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, …)`. Tests that need Screen Recording and a window server are `.enabled(if: ProcessInfo.processInfo.environment["APPSHOT_INTEGRATION"] == "1")`.
- Never commit, tag or push a release without asking Olivier. Commits to `main` per task are fine (the repo works on `main`).

## Review Focus

1. **A config with no `videos` key**: every existing config and command must behave exactly as before. Pinned in Task 1 (`existingConfigsStillValidate`).
2. **A caption cut short by the next caption or the end card**: the reading check must fail *before* any output file is written, naming the caption. Pinned in Task 8 (`shortCaptionFailsBeforeWriting`).
3. **Captures of different sizes in `--from-stills`**: they must be centered on one canvas, never stretched. Pinned in Task 5 (`differentSizedStillsAreCenteredNotStretched`).
4. **An app that never sends `ready`, or acks a cue late or not at all**: the run must fail naming the cue, terminate the launched app and leave no master behind. Pinned in Task 10 (unit, against a fake event file) and Task 11 (integration).
5. **A zoom whose target the app never reported**: the render must fail naming the target, not zoom on the stage center. Pinned in Task 3 (`zoomOnUnreportedTargetThrows`).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AppShotKit/VideoConfig.swift` (new) | `Config.Video` and its parts; `Config.validateVideos()` |
| `Sources/AppShotKit/Config.swift` (modify) | add `videos` property; call `validateVideos()` from `validate()` |
| `Sources/AppShotKit/AppShotError.swift` (modify) | six new cases |
| `Sources/AppShotKit/VideoTrack.swift` (new) | what happened during a take; file IO; stills synthesis |
| `Sources/AppShotKit/VideoTimeline.swift` (new) | pure time functions: captions, reading check, camera, cursor, card |
| `Sources/AppShotKit/VideoFrame.swift` (new) | one rendered frame: layout, backdrop, stage, overlays |
| `Sources/AppShotKit/Compose.swift` (modify) | `drawShadow` private → internal |
| `Sources/AppShotKit/VideoWriter.swift` (new) | H.264 + silent AAC encoder |
| `Sources/AppShotKit/VideoMaster.swift` (new) | `StillsMaster`, `RecordedMaster` |
| `Sources/AppShotKit/ContactSheet.swift` (new) | labeled grid of frames |
| `Sources/AppShotKit/VideoCompose.swift` (new) | orchestration, report |
| `Sources/AppShotKit/CueChannel.swift` (new) | cue and event JSON-lines files |
| `Sources/AppShotKit/Capture.swift` (modify) | extract `handshakeDirectory(for:)`; widen helpers to internal |
| `Sources/AppShotKit/StreamRecorder.swift` (new) | `SCStreamOutput` → HEVC-with-alpha `.mov` |
| `Sources/AppShotKit/Recorder.swift` (new) | one take: launch, cue loop, track |
| `Sources/AppShotFixture/VideoFixture.swift` (new), `main.swift` (modify) | fixture app's `video` stage |
| `Sources/appshot/VideoCommands.swift` (new) | `record`, `compose video` |
| `Sources/appshot/AppShot.swift`, `ComposeCommands.swift` (modify) | register commands; defaults |
| `Scripts/fixture-video.config.json` (new), `Makefile` (modify) | `make bench-record` |
| `Tests/AppShotKitTests/Video*Tests.swift`, `CueChannelTests.swift`, `ContactSheetTests.swift`, `RecorderIntegrationTests.swift` (new) | tests |
| `README.md`, `CHANGELOG.md` (modify) | docs |

---

### Task 0: Spike (throwaway)

Answers the spec's three open questions before anything is built on them. **Nothing from this task is committed except the results appended to the spec.**

**Files:**
- Create (not committed): `.build/spike/record.swift`, `.build/spike/readback.swift`
- Modify: `docs/superpowers/specs/2026-10-03-appshot-video-design.md` (append "Spike results")

- [ ] **Step 1: Build the fixture app**

Run: `make fixture`
Expected: `.build/fixture/AppShotFixture.app` exists.

- [ ] **Step 2: Write the recording probe**

`.build/spike/record.swift`: launches the fixture's `instant` stage in the background, records its windows for 4 s with `SCStream` into HEVC with alpha, and prints the frame count.

```swift
import AVFoundation
import AppKit
import ScreenCaptureKit

final class Out: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var frames = 0
    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
            let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = a.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        if !started { writer.startSession(atSourceTime: sb.presentationTimeStamp); started = true }
        if input.isReadyForMoreMediaData, input.append(sb) { frames += 1 }
    }
}

let app = URL(fileURLWithPath: ".build/fixture/AppShotFixture.app")
let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = ["-gn", app.path, "--args", "-ScreenshotStage", "instant", "-ScreenshotActivation", "none"]
try open.run()
open.waitUntilExit()
try await Task.sleep(for: .seconds(2))

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let windows = content.windows.filter { $0.owningApplication?.applicationName == "AppShotFixture" }
guard let display = content.displays.first else { fatalError("no display") }
let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
let config = SCStreamConfiguration()
config.width = Int(display.frame.width) * scale
config.height = Int(display.frame.height) * scale
config.pixelFormat = kCVPixelFormatType_32BGRA
let clear = CGColor(gray: 0, alpha: 0)
config.backgroundColor = clear
config.showsCursor = false
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
let out = try Out(url: URL(fileURLWithPath: ".build/spike/master.mov"), width: config.width, height: config.height)
let stream = SCStream(filter: SCContentFilter(display: display, including: windows), configuration: config, delegate: nil)
try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "spike"))
try await stream.startCapture()
print("recording 4s — during it, drag another app's window over the fixture")
try await Task.sleep(for: .seconds(4))
try await stream.stopCapture()
out.input.markAsFinished()
await out.writer.finishWriting()
print("status \(out.writer.status.rawValue) frames \(out.frames)")
```

- [ ] **Step 3: Run it, covering the fixture with another window halfway through**

Run: `swift .build/spike/record.swift` (grant Screen Recording to the terminal if asked). While it records, drag any other app's window over the fixture window.
Expected: `status 2 frames <n>` with `n` > 0 (status 2 = completed).

- [ ] **Step 4: Write the readback probe**

`.build/spike/readback.swift`: decodes the master as BGRA and prints alpha at a display corner (outside the window: expect 0) and at the window's center (expect 255).

```swift
import AVFoundation
import AppKit

let asset = AVURLAsset(url: URL(fileURLWithPath: ".build/spike/master.mov"))
let track = try await asset.loadTracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(
    track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(output)
reader.startReading()
var n = 0
while let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
    n += 1
    guard n == 60 else { continue }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pb)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    func alpha(_ x: Int, _ y: Int) -> UInt8 { base[y * row + x * 4 + 3] }
    print("size \(w)x\(h) corner alpha \(alpha(2, 2)) center alpha \(alpha(w / 2, h / 2))")
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
}
print("frames read \(n)")
```

Before running, move the fixture window so it covers the display's center, or edit the probed point to the window's center.

- [ ] **Step 5: Run it**

Run: `swift .build/spike/readback.swift`
Expected: `corner alpha 0` and `center alpha 255`. Then quit the fixture: `pkill -x AppShotFixture`.

- [ ] **Step 6: Probe simulator recording latency (informational, iOS is phase 4)**

Run, with any booted simulator:
```bash
UDID=$(xcrun simctl list devices booted -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v))")
( xcrun simctl io "$UDID" recordVideo --codec=h264 --force .build/spike/sim.mp4 & echo $! > .build/spike/sim.pid ); \
start=$(date +%s.%N); while [ ! -s .build/spike/sim.mp4 ]; do sleep 0.02; done; echo "first bytes after $(echo "$(date +%s.%N) - $start" | bc)s"; \
sleep 2; kill -INT "$(cat .build/spike/sim.pid)"
```
Expected: prints the delay before the file starts growing. Record it; don't act on it in this plan.

- [ ] **Step 7: Record results in the spec and commit**

Append to the spec:

```markdown
## Spike results (2026-10-0X)

1. SCStream filtered to the app's windows, HEVC with alpha: <frames written, status>. Occlusion by another app's window: <survived / did not>.
2. AVFoundation readback: corner alpha <v>, center alpha <v>.
3. simctl recordVideo first bytes after <s>.

Verdict: <go / no-go> on section 2. <If no-go: what changes.>
```

If probe 1 or 2 fails, stop and report to Olivier before Task 10. Tasks 1-9 don't depend on recording.

```bash
git add docs/superpowers/specs/2026-10-03-appshot-video-design.md
git commit -m "docs(spec): record the video spike results"
```

---

### Task 1: `videos[]` config model and validation

**Files:**
- Create: `Sources/AppShotKit/VideoConfig.swift`
- Modify: `Sources/AppShotKit/Config.swift` (add property after `locales`; extend `validate()`)
- Modify: `Sources/AppShotKit/AppShotError.swift`
- Test: `Tests/AppShotKitTests/VideoConfigTests.swift`

**Interfaces:**
- Produces: `Config.videos: [Config.Video]?`; `Config.Video { id, stage, duration, poster, outputs, card, beats }`; `Config.VideoOutputs { preview, promo, website; wantsPreview, wantsWebsite, promoSizes }`; `Config.Card { title, subtitle, icon }`; `Config.Zoom { target, rect, scale }`; `Config.CueValue` (`.string/.number/.bool`); `Config.Beat { at, cue, args, caption, until, zoom, endCard, screen }`; `Config.previewSize(for:) -> Size?`; `Config.previewDuration`; `Config.video(_ id:) throws -> Video`.
- Produces errors: `AppShotError.invalidVideo(id:reason:)`, `.unknownVideo(_:known:)`, `.captionTooShort(video:caption:shown:needed:)`, `.videoRenderFailed(video:reason:)`, `.cueFailed(video:seq:cue:reason:)`, `.recordFailed(video:reason:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/AppShotKitTests/VideoConfigTests.swift`:

```swift
import Foundation
import Testing

@testable import AppShotKit

struct VideoConfigTests {
    /// ConfigTests' fixture with a `videos` array spliced in before `screens`.
    static func config(videos: String) throws -> Config {
        let json = ConfigTests.json.replacingOccurrences(
            of: "\"screens\": [", with: "\"videos\": \(videos),\n\"screens\": [")
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    static let valid = """
        [{ "id": "intro", "stage": "browser", "duration": 20, "poster": 5,
           "outputs": { "preview": true, "promo": [[1920, 1080], [1080, 1080]], "website": true },
           "card": { "title": "D1", "subtitle": "d1.example" },
           "beats": [
             { "at": 0, "caption": "Your databases", "screen": "browser" },
             { "at": 1.5, "cue": "pointer.click", "args": { "target": "row-2", "n": 2, "on": true } },
             { "at": 4, "zoom": { "target": "row-2", "scale": 1.6 } },
             { "at": 16, "endCard": true }
           ] }]
        """

    @Test func existingConfigsStillValidate() throws {
        let config = try ConfigTests.decode()
        #expect(config.videos == nil)
        try config.validate()
    }

    @Test func decodesAVideo() throws {
        let config = try Self.config(videos: Self.valid)
        try config.validate()
        let video = try config.video("intro")
        #expect(video.beats.count == 4)
        #expect(video.outputs.promoSizes == [Config.Size(width: 1920, height: 1080), Config.Size(width: 1080, height: 1080)])
        #expect(video.beats[1].args?["n"] == .number(2))
        #expect(video.beats[1].args?["on"] == .bool(true))
        #expect(video.beats[1].args?["target"] == .string("row-2"))
    }

    @Test(arguments: [
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[1079,1080]]},"beats":[]}]"#, "odd side"),
        (#"[{"id":"x","duration":10,"outputs":{"preview":true},"beats":[]}]"#, "15-30s"),
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":5},{"at":2}]}]"#, "time order"),
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":20}]}]"#, "outside"),
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"endCard":true}]}]"#, "no card"),
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"zoom":{"scale":2}}]}]"#, "exactly one of target or rect"),
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"screen":"nope"}]}]"#, "does not capture"),
        (#"[{"id":"X Y","duration":20,"outputs":{"promo":[[100,100]]},"beats":[]}]"#, "filename"),
        (#"[{"id":"x","duration":20,"outputs":{},"beats":[]}]"#, "asks for nothing"),
        (#"[{"id":"x","duration":20,"outputs":{"website":true},"beats":[]}]"#, "website video"),
    ])
    func rejects(json: String, reason: String) throws {
        let config = try Self.config(videos: json)
        #expect {
            try config.validate()
        } throws: { error in
            guard case .invalidVideo(_, let why) = error as? AppShotError else { return false }
            return why.contains(reason)
        }
    }

    @Test func unknownVideoNamesTheKnownOnes() throws {
        let config = try Self.config(videos: Self.valid)
        #expect(throws: AppShotError.self) { try config.video("outro") }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter VideoConfigTests`
Expected: compile failure, "value of type 'Config' has no member 'videos'".

- [ ] **Step 3: Add the error cases**

In `Sources/AppShotKit/AppShotError.swift`, add to the enum:

```swift
    case invalidVideo(id: String, reason: String)
    case unknownVideo(String, known: [String])
    /// A caption on screen for less than `1s + 0.3s per word`. Apple asks that preview
    /// text stay up long enough to read, and it is the mistake an agent writing copy
    /// makes most.
    case captionTooShort(video: String, caption: String, shown: Double, needed: Double)
    case videoRenderFailed(video: String, reason: String)
    case cueFailed(video: String, seq: Int, cue: String, reason: String)
    case recordFailed(video: String, reason: String)
```

To `description`:

```swift
        case .invalidVideo(let id, let reason):
            return "videos[\"\(id)\"]: \(reason)"
        case .unknownVideo(let id, let known):
            return "no video \"\(id)\" in videos[]; known: \(known.joined(separator: ", "))"
        case .captionTooShort(let video, let caption, let shown, let needed):
            return """
                \(video): the caption "\(caption)" is on screen for \(String(format: "%.1f", shown))s \
                but needs \(String(format: "%.1f", needed))s to read (1s + 0.3s per word). Move the \
                next caption later, give this one an `until`, or cut words.
                """
        case .videoRenderFailed(let video, let reason):
            return "\(video): render failed: \(reason)"
        case .cueFailed(let video, let seq, let cue, let reason):
            return "\(video): cue #\(seq) \"\(cue)\" failed: \(reason)"
        case .recordFailed(let video, let reason):
            return "\(video): recording failed: \(reason)"
```

To `slug`:

```swift
        case .invalidVideo: return "invalid_video"
        case .unknownVideo: return "unknown_video"
        case .captionTooShort: return "caption_too_short"
        case .videoRenderFailed: return "video_render_failed"
        case .cueFailed: return "cue_failed"
        case .recordFailed: return "record_failed"
```

- [ ] **Step 4: Add the model**

`Sources/AppShotKit/VideoConfig.swift`:

```swift
import Foundation

extension Config {
    /// One entry of `videos[]`: a scripted take of the app plus the copy laid over it.
    ///
    /// Lives in the same file as the screenshots for the same reason captions do: copy
    /// and pacing change without touching code or re-recording.
    public struct Video: Codable, Sendable {
        public var id: String
        /// The `-ScreenshotStage` the app launches into. Only `record` needs it;
        /// `compose video --from-stills` names a screen per beat instead.
        public var stage: String?
        public var duration: Double
        /// Seconds into the video for the poster frame. App Store Connect defaults to 5.
        public var poster: Double?
        public var outputs: VideoOutputs
        public var card: Card?
        public var beats: [Beat]
    }

    public struct VideoOutputs: Codable, Sendable {
        public var preview: Bool?
        /// `[[width, height], …]`, the shape the spec's examples use.
        public var promo: [[Int]]?
        /// A muted loop for the marketing site, rendered at the first promo size.
        public var website: Bool?

        public var wantsPreview: Bool { preview ?? false }
        public var wantsWebsite: Bool { website ?? false }
        public var promoSizes: [Size] {
            (promo ?? []).compactMap { $0.count == 2 ? Size(width: $0[0], height: $0[1]) : nil }
        }
    }

    /// The promo's closing card. Previews never show it: Apple allows only the app's
    /// own footage there.
    public struct Card: Codable, Sendable {
        public var title: String
        public var subtitle: String?
        /// A PNG, relative to the config file's directory.
        public var icon: String?
    }

    /// Ease the camera toward a reported element (`target`) or a fixed rect in stage
    /// pixels (`rect`, `[x, y, width, height]`, for `--from-stills` where no app reports
    /// anything). `scale: 1` returns to the whole stage and needs neither.
    public struct Zoom: Codable, Sendable, Equatable {
        public var target: String?
        public var rect: [Double]?
        public var scale: Double
    }

    public enum CueValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        /// String first, then number, then bool: JSONDecoder will not read `1` as a Bool,
        /// but trying Bool first would be the order that depends on that.
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else {
                self = .bool(try c.decode(Bool.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            }
        }
    }

    public struct Beat: Codable, Sendable {
        public var at: Double
        public var cue: String?
        public var args: [String: CueValue]?
        public var caption: String?
        /// When the caption leaves. Absent ⇒ the next caption, the end card, or the end.
        public var until: Double?
        public var zoom: Zoom?
        public var endCard: Bool?
        /// `--from-stills` only: the `screens[]` capture to show from this beat on.
        public var screen: String?
    }

    public static let previewDuration: ClosedRange<Double> = 15...30

    /// The App Store preview canvas for a platform. iOS returns nil until iOS
    /// recording exists (spec phase 4), and validation says so.
    public static func previewSize(for platform: Platform) -> Size? {
        switch platform {
        case .mac: return Size(width: 1920, height: 1080)
        case .ios: return nil
        }
    }

    public func video(_ id: String) throws -> Video {
        guard let video = videos?.first(where: { $0.id == id }) else {
            throw AppShotError.unknownVideo(id, known: (videos ?? []).map(\.id))
        }
        return video
    }

    func validateVideos() throws {
        var seen = Set<String>()
        for video in videos ?? [] {
            func fail(_ why: String) -> AppShotError { .invalidVideo(id: video.id, reason: why) }

            guard video.id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
            else { throw fail("the id becomes a filename: use lowercase letters, digits and -") }
            guard seen.insert(video.id).inserted else { throw fail("the id is used twice") }
            guard video.duration > 0 else { throw fail("duration must be positive") }
            if let poster = video.poster, !(0..<video.duration).contains(poster) {
                throw fail("poster \(poster)s is outside 0..<\(video.duration)s")
            }

            var last = 0.0
            for (i, beat) in video.beats.enumerated() {
                guard (0..<video.duration).contains(beat.at) else {
                    throw fail("beat \(i) at \(beat.at)s is outside 0..<\(video.duration)s")
                }
                guard beat.at >= last else {
                    throw fail("beat \(i) at \(beat.at)s comes before the one above it; keep beats in time order")
                }
                last = beat.at
                if let until = beat.until {
                    guard beat.caption != nil else { throw fail("beat \(i) has `until` but no caption") }
                    guard until > beat.at, until <= video.duration else {
                        throw fail("beat \(i) until \(until)s must be after its `at` and within the duration")
                    }
                }
                if let zoom = beat.zoom {
                    guard (1...4).contains(zoom.scale) else {
                        throw fail("beat \(i) zoom scale \(zoom.scale) is outside 1...4")
                    }
                    guard zoom.scale == 1 || (zoom.target == nil) != (zoom.rect == nil) else {
                        throw fail("beat \(i) zoom needs exactly one of target or rect")
                    }
                    if let rect = zoom.rect, rect.count != 4 || rect[2] <= 0 || rect[3] <= 0 {
                        throw fail("beat \(i) zoom rect must be [x, y, width, height] with a positive size")
                    }
                }
                if let screen = beat.screen, !capturedScreenIDs.contains(screen) {
                    throw fail("beat \(i) names screen \"\(screen)\", which screens[] does not capture")
                }
            }

            let cards = video.beats.filter { $0.endCard == true }.count
            guard cards <= 1 else { throw fail("only one beat may show the end card") }
            if cards == 1, video.card == nil { throw fail("a beat shows the end card but the video has no card") }

            for raw in video.outputs.promo ?? [] {
                guard raw.count == 2, raw[0] > 0, raw[1] > 0 else {
                    throw fail("promo sizes are [width, height] pairs of positive integers")
                }
                guard raw[0] % 2 == 0, raw[1] % 2 == 0 else {
                    throw fail("promo size \(raw[0])x\(raw[1]) has an odd side; H.264 needs even dimensions")
                }
            }
            if video.outputs.wantsPreview {
                guard Config.previewSize(for: resolvedPlatform) != nil else {
                    throw fail("App Store previews for iOS arrive with iOS recording; set preview to false for now")
                }
                guard Config.previewDuration.contains(video.duration) else {
                    throw fail("an App Store preview must last 15-30s, this one is \(video.duration)s")
                }
            }
            if video.outputs.wantsWebsite, video.outputs.promoSizes.isEmpty {
                throw fail("the website video is rendered at the first promo size; add one to promo")
            }
            guard video.outputs.wantsPreview || !video.outputs.promoSizes.isEmpty else {
                throw fail("outputs asks for nothing: set preview, promo or both")
            }
        }
    }
}
```

In `Sources/AppShotKit/Config.swift`, after `public var locales: [String]?`:

```swift
    /// Scripted videos, rendered by `appshot record` + `appshot compose video`.
    /// Absent ⇒ none, and every other command behaves exactly as before.
    public var videos: [Video]?
```

At the end of `public func validate() throws` (after its last check):

```swift
        try validateVideos()
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter VideoConfigTests && swift test --filter ConfigTests`
Expected: PASS, both suites.

- [ ] **Step 6: Lint and commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoConfig.swift Sources/AppShotKit/Config.swift Sources/AppShotKit/AppShotError.swift Tests/AppShotKitTests/VideoConfigTests.swift
git commit -m "feat(video): add the videos[] config and its validation"
```

---

### Task 2: The track: what happened during a take

**Files:**
- Create: `Sources/AppShotKit/VideoTrack.swift`
- Test: `Tests/AppShotKitTests/VideoTrackTests.swift`

**Interfaces:**
- Consumes: `Config.Video`, `Config.Beat` (Task 1).
- Produces:
  - `struct VideoTrack: Codable, Sendable, Equatable { video: String; appearance: String; duration: Double; stage: [Double]; beats: [Beat]; targets: [Target]; frames: Int; maxFrameGap: Double }`
  - `VideoTrack.Beat { index: Int; scheduled: Double; acked: Double? }`
  - `VideoTrack.Target { seq: Int; name: String; at: Double; rect: [Double]; click: Bool }`
  - `func time(ofBeat index: Int) -> Double` (acked ?? scheduled)
  - `var stageSize: CGSize`
  - `static func stills(video: Config.Video, appearance: String, stageSize: CGSize) -> VideoTrack`
  - `static func url(in dir: URL, video: String, appearance: String) -> URL`
  - `static func read(_ url: URL) throws -> VideoTrack`, `func write(to url: URL) throws`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter VideoTrackTests`
Expected: compile failure, "cannot find 'VideoTrack' in scope".

- [ ] **Step 3: Implement**

`Sources/AppShotKit/VideoTrack.swift`:

```swift
import CoreGraphics
import Foundation

/// What actually happened during a take, as opposed to what the config planned.
///
/// Rendering reads this and never the plan, so a cue that reached the app 40ms late
/// moves its caption with it and the text cannot drift from the screen.
public struct VideoTrack: Codable, Sendable, Equatable {
    public struct Beat: Codable, Sendable, Equatable {
        /// Index into the video's `beats`.
        public var index: Int
        public var scheduled: Double
        /// When the app said the cue's effect was on screen. Nil for a beat with no cue,
        /// which happens exactly when scheduled.
        public var acked: Double?
    }

    /// An element the app reported in answer to a pointer cue.
    public struct Target: Codable, Sendable, Equatable {
        public var seq: Int
        public var name: String
        /// The scheduled time of the cue that reported it.
        public var at: Double
        /// Stage pixels, top-left origin: x, y, width, height.
        public var rect: [Double]
        public var click: Bool
    }

    public var video: String
    public var appearance: String
    public var duration: Double
    /// The crop applied to the master, in master pixels: x, y, width, height.
    public var stage: [Double]
    public var beats: [Beat]
    public var targets: [Target]
    public var frames: Int
    /// Longest gap between two recorded frames, in seconds. The proxy for dropped
    /// frames: SCStream sends nothing while the screen is still, so a count alone
    /// cannot tell a stall from a quiet screen.
    public var maxFrameGap: Double

    public var stageSize: CGSize { CGSize(width: stage[2], height: stage[3]) }

    public func time(ofBeat index: Int) -> Double {
        guard let beat = beats.first(where: { $0.index == index }) else { return 0 }
        return beat.acked ?? beat.scheduled
    }

    /// The track a `--from-stills` render pretends was recorded: every beat on time,
    /// nothing reported, the whole canvas as the stage.
    public static func stills(video: Config.Video, appearance: String, stageSize: CGSize) -> VideoTrack {
        VideoTrack(
            video: video.id, appearance: appearance, duration: video.duration,
            stage: [0, 0, stageSize.width, stageSize.height],
            beats: video.beats.enumerated().map { .init(index: $0.offset, scheduled: $0.element.at, acked: $0.element.at) },
            targets: [], frames: 0, maxFrameGap: 0)
    }

    public static func url(in dir: URL, video: String, appearance: String) -> URL {
        dir.appending(path: "\(video)~\(appearance).track.json")
    }

    public static func read(_ url: URL) throws -> VideoTrack {
        do {
            return try JSONDecoder().decode(VideoTrack.self, from: Data(contentsOf: url))
        } catch {
            throw AppShotError.invalidConfig(url, "unreadable track: \(error)")
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter VideoTrackTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoTrack.swift Tests/AppShotKitTests/VideoTrackTests.swift
git commit -m "feat(video): record what happened during a take as a track"
```

---

### Task 3: The timeline: captions, reading check, camera, cursor, card

**Files:**
- Create: `Sources/AppShotKit/VideoTimeline.swift`
- Test: `Tests/AppShotKitTests/VideoTimelineTests.swift`

**Interfaces:**
- Consumes: `Config.Video`, `VideoTrack` (Tasks 1-2).
- Produces:
  - `struct VideoTimeline: Sendable` with `init(video: Config.Video, track: VideoTrack) throws`
  - `struct CaptionSpan: Equatable, Sendable { text: String; start: Double; end: Double; words: Int; shown: Double; needed: Double }`
  - `let captions: [CaptionSpan]`, `let duration: Double`, `let cardStart: Double?`
  - `func caption(at t: Double) -> (text: String, opacity: Double)?`
  - `func readingProblems() -> [CaptionSpan]`
  - `func camera(at t: Double, stage: CGSize) -> (scale: Double, center: CGPoint)`
  - `func cursor(at t: Double) -> (point: CGPoint, ripple: Double?)?`
  - `func cardOpacity(at t: Double) -> Double`
  - `static func ease(_ x: Double) -> Double`
  - constants `fade = 0.25`, `zoomTransition = 0.6`, `pointerTravel = 0.5`, `ripple = 0.4`, `cardFade = 0.4`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoTimelineTests {
    static func video(_ beats: String, duration: Double = 20, card: Bool = true) throws -> Config.Video {
        let cardJSON = card ? #", "card": { "title": "T" }"# : ""
        return try VideoConfigTests.config(videos: """
            [{ "id": "v", "duration": \(duration), "outputs": { "promo": [[100, 100]] }\(cardJSON),
               "beats": \(beats) }]
            """).video("v")
    }

    static func timeline(_ video: Config.Video, targets: [VideoTrack.Target] = []) throws -> VideoTimeline {
        var track = VideoTrack.stills(video: video, appearance: "dark", stageSize: CGSize(width: 1000, height: 600))
        track.targets = targets
        return try VideoTimeline(video: video, track: track)
    }

    @Test func captionRunsToTheNextCaption() throws {
        let t = try Self.timeline(Self.video(#"[{"at":0,"caption":"one two"},{"at":5,"caption":"three"}]"#))
        #expect(t.captions.map(\.end) == [5, 20])
        #expect(t.caption(at: 2.5)?.text == "one two")
        #expect(t.caption(at: 5.1)?.text == "three")
    }

    @Test func captionStopsAtTheEndCard() throws {
        let t = try Self.timeline(Self.video(#"[{"at":0,"caption":"a"},{"at":8,"endCard":true}]"#))
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
        let t = try Self.timeline(Self.video(#"[{"at":0,"caption":"one two three four"},{"at":2,"caption":"b"}]"#))
        #expect(t.readingProblems().map(\.text) == ["one two three four"])
    }

    @Test func cameraEasesToTheTarget() throws {
        let target = VideoTrack.Target(seq: 0, name: "row", at: 1, rect: [100, 100, 200, 100], click: false)
        let t = try Self.timeline(
            Self.video(#"[{"at":1,"cue":"pointer.move","args":{"target":"row"}},{"at":2,"zoom":{"target":"row","scale":2}}]"#),
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
        let b = VideoTrack.Target(seq: 1, name: "b", at: 3, rect: [400, 0, 100, 100], click: true)
        let t = try Self.timeline(Self.video("[]"), targets: [a, b])
        #expect(t.cursor(at: 0) == nil)
        #expect(t.cursor(at: 2)?.point == CGPoint(x: 50, y: 50))
        let mid = try #require(t.cursor(at: 2.75))
        #expect(mid.point.x > 50 && mid.point.x < 450)
        #expect(t.cursor(at: 3.2)?.point == CGPoint(x: 450, y: 50))
        #expect(abs((t.cursor(at: 3.2)?.ripple ?? 0) - 0.5) < 0.001)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter VideoTimelineTests`
Expected: compile failure, "cannot find 'VideoTimeline' in scope".

- [ ] **Step 3: Implement**

`Sources/AppShotKit/VideoTimeline.swift`:

```swift
import CoreGraphics
import Foundation

/// Every time-dependent decision a frame needs, as pure functions of `t`.
///
/// Built from the track's times rather than the config's, so everything here follows
/// what the app actually did.
public struct VideoTimeline: Sendable {
    public struct CaptionSpan: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        public let words: Int

        public var shown: Double { end - start }
        /// 1s to notice the text, 0.3s per word to read it.
        public var needed: Double { 1 + 0.3 * Double(words) }
    }

    public static let fade = 0.25
    public static let zoomTransition = 0.6
    public static let pointerTravel = 0.5
    public static let ripple = 0.4
    public static let cardFade = 0.4

    public let duration: Double
    public let captions: [CaptionSpan]
    public let cardStart: Double?
    private let zooms: [(time: Double, scale: Double, center: CGPoint?)]
    private let pointers: [(time: Double, point: CGPoint, click: Bool)]

    public init(video: Config.Video, track: VideoTrack) throws {
        duration = video.duration
        let card = video.beats.indices.first { video.beats[$0].endCard == true }.map { track.time(ofBeat: $0) }
        cardStart = card

        let captioned = video.beats.indices.filter { video.beats[$0].caption != nil }
        captions = captioned.enumerated().map { position, index in
            let beat = video.beats[index]
            let start = track.time(ofBeat: index)
            let next = position + 1 < captioned.count ? track.time(ofBeat: captioned[position + 1]) : video.duration
            let end = min(beat.until ?? next, card ?? video.duration, video.duration)
            let text = beat.caption ?? ""
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return CaptionSpan(text: text, start: start, end: end, words: words)
        }

        zooms = try video.beats.indices.compactMap { index in
            guard let zoom = video.beats[index].zoom else { return nil }
            let time = track.time(ofBeat: index)
            if zoom.scale == 1 { return (time, 1, nil) }
            if let rect = zoom.rect {
                return (time, zoom.scale, CGPoint(x: rect[0] + rect[2] / 2, y: rect[1] + rect[3] / 2))
            }
            let name = zoom.target ?? ""
            // The latest report at or before the zoom; an element that moved is wherever
            // the app last said it was.
            guard let target = track.targets.last(where: { $0.name == name && $0.at <= time + 0.001 }) else {
                throw AppShotError.videoRenderFailed(
                    video: video.id,
                    reason: "zoom at \(time)s targets \"\(name)\", which no pointer cue at or before it reported")
            }
            let r = target.rect
            return (time, zoom.scale, CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2))
        }

        pointers = track.targets.sorted { $0.at < $1.at }.map {
            ($0.at, CGPoint(x: $0.rect[0] + $0.rect[2] / 2, y: $0.rect[1] + $0.rect[3] / 2), $0.click)
        }
    }

    public static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    public func caption(at t: Double) -> (text: String, opacity: Double)? {
        guard let span = captions.last(where: { $0.start <= t && t <= $0.end }) else { return nil }
        let opacity = min(1, (t - span.start) / Self.fade, (span.end - t) / Self.fade)
        return opacity > 0 ? (span.text, opacity) : nil
    }

    public func readingProblems() -> [CaptionSpan] {
        captions.filter { $0.shown < $0.needed }
    }

    public func camera(at t: Double, stage: CGSize) -> (scale: Double, center: CGPoint) {
        let home = CGPoint(x: stage.width / 2, y: stage.height / 2)
        var scale = 1.0
        var center = home
        for zoom in zooms where zoom.time <= t {
            let p = Self.ease((t - zoom.time) / Self.zoomTransition)
            let to = zoom.center ?? home
            scale += (zoom.scale - scale) * p
            center = CGPoint(x: center.x + (to.x - center.x) * p, y: center.y + (to.y - center.y) * p)
        }
        return (scale, center)
    }

    /// The drawn pointer: hidden until the first report is due, then travelling into
    /// each target over `pointerTravel` so it *arrives* when the cue fires, with a
    /// ripple after a click.
    public func cursor(at t: Double) -> (point: CGPoint, ripple: Double?)? {
        guard let first = pointers.first, t >= first.time - Self.pointerTravel else { return nil }
        let arrivedIndex = pointers.lastIndex { $0.time <= t }
        let arrived = arrivedIndex.map { pointers[$0] }
        let nextIndex = arrivedIndex.map { $0 + 1 } ?? 0
        if nextIndex < pointers.count, t >= pointers[nextIndex].time - Self.pointerTravel {
            let next = pointers[nextIndex]
            let from = arrived?.point ?? next.point
            let p = Self.ease((t - (next.time - Self.pointerTravel)) / Self.pointerTravel)
            return (CGPoint(x: from.x + (next.point.x - from.x) * p, y: from.y + (next.point.y - from.y) * p), nil)
        }
        guard let arrived else { return nil }
        let age = t - arrived.time
        return (arrived.point, arrived.click && age < Self.ripple ? age / Self.ripple : nil)
    }

    public func cardOpacity(at t: Double) -> Double {
        cardStart.map { Self.ease((t - $0) / Self.cardFade) } ?? 0
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter VideoTimelineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoTimeline.swift Tests/AppShotKitTests/VideoTimelineTests.swift
git commit -m "feat(video): compute captions, camera, cursor and card over time"
```

---

### Task 4: Rendering one frame

**Files:**
- Create: `Sources/AppShotKit/VideoFrame.swift`
- Modify: `Sources/AppShotKit/Compose.swift:430` (`private static func drawShadow` → `static func drawShadow`)
- Test: `Tests/AppShotKitTests/VideoFrameTests.swift`

**Interfaces:**
- Consumes: `VideoTimeline` (Task 3); `Compose.drawGradient`, `Compose.drawShadow`, `Compose.flip`, `Compose.draw(_:ctx:baselineYDown:width:height:)`, `Text.font`, `Text.wrap`, `Image.context`, `Image.color`, `Image.load` (existing).
- Produces:
  - `enum VideoFrame { enum Kind { case promo, preview } }`
  - `struct VideoFrame.Style: @unchecked Sendable { kind; size: Config.Size; stageRect: CGRect; backdrop: CGImage; … }`
  - `static func style(kind:size:config:appearance:video:stage:icon:) throws -> Style`
  - `static func render(stage: CGImage, t: Double, timeline: VideoTimeline, style: Style) throws -> CGImage`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoFrameTests {
    /// A stage that is solid white, so anything drawn on top is easy to find.
    static func stage(_ w: Int = 800, _ h: Int = 500) throws -> CGImage {
        let ctx = try #require(Image.context(width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try #require(ctx.makeImage())
    }

    static func config() throws -> Config {
        var config = try VideoConfigTests.config(videos: """
            [{ "id": "v", "duration": 20, "outputs": { "preview": true, "promo": [[1080, 1080]] },
               "card": { "title": "Armada", "subtitle": "armada.mgcrea.io" },
               "beats": [{ "at": 0, "caption": "Hello there" }, { "at": 18, "endCard": true }] }]
            """)
        config.fontFamily = "Helvetica"
        return config
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let px = try #require(Image.pixels(image))
        let i = (y * px.width + x) * 4
        return Array(px.bytes[i..<i + 4])
    }

    @Test func previewIsFullBleedOnTheDarkestStop() throws {
        let config = try Self.config()
        let video = try config.video("v")
        let style = try VideoFrame.style(
            kind: .preview, size: .init(width: 1920, height: 1080), config: config,
            appearance: "dark", video: video, stage: CGSize(width: 800, height: 500), icon: nil)
        let timeline = try VideoTimeline(
            video: video, track: .stills(video: video, appearance: "dark", stageSize: CGSize(width: 800, height: 500)))
        let frame = try VideoFrame.render(stage: Self.stage(), t: 19, timeline: timeline, style: style)
        #expect(frame.width == 1920 && frame.height == 1080)
        // Corner: the darkest stop #0D0E11, no gradient and no end card in a preview.
        #expect(try Self.pixel(frame, 2, 2).prefix(3) == [0x0D, 0x0E, 0x11])
        // The stage covers the middle.
        #expect(try Self.pixel(frame, 960, 480).prefix(3) == [255, 255, 255])
    }

    @Test func promoReservesRoomForTheCaption() throws {
        let config = try Self.config()
        let video = try config.video("v")
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 1080, height: 1080), config: config,
            appearance: "dark", video: video, stage: CGSize(width: 800, height: 500), icon: nil)
        #expect(style.stageRect.minY > 100)
        #expect(style.stageRect.maxY <= 1080)
    }

    @Test func endCardCoversThePromo() throws {
        let config = try Self.config()
        let video = try config.video("v")
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 1080, height: 1080), config: config,
            appearance: "dark", video: video, stage: CGSize(width: 800, height: 500), icon: nil)
        let timeline = try VideoTimeline(
            video: video, track: .stills(video: video, appearance: "dark", stageSize: CGSize(width: 800, height: 500)))
        let frame = try VideoFrame.render(stage: Self.stage(), t: 19.9, timeline: timeline, style: style)
        // Where the white stage was, the card's gradient now is.
        let center = try Self.pixel(frame, Int(style.stageRect.midX), Int(style.stageRect.maxY) - 10)
        #expect(center[0] < 200)
    }
}
```

`Image.pixels` returns `Image.Pixels` (`Image.swift:122`): `width`, `height` and RGBA `bytes`.

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter VideoFrameTests`
Expected: compile failure, "cannot find 'VideoFrame' in scope".

- [ ] **Step 3: Widen `drawShadow`**

In `Sources/AppShotKit/Compose.swift`, change `private static func drawShadow(` to `static func drawShadow(`.

- [ ] **Step 4: Implement**

`Sources/AppShotKit/VideoFrame.swift`:

```swift
import CoreGraphics
import CoreText
import Foundation

/// One rendered video frame.
///
/// Everything that does not move — gradient, shadow, the stage's place on the canvas —
/// is rendered once into `Style.backdrop`. The shadow alone is a Gaussian blur over the
/// whole canvas, and doing it 720 times per output is most of a render.
public enum VideoFrame {
    public enum Kind: Sendable { case promo, preview }

    public struct Style: @unchecked Sendable {
        public let kind: Kind
        public let size: Config.Size
        /// Where the stage lands, y-down.
        public let stageRect: CGRect
        public let backdrop: CGImage
        let layout: Config.Layout
        let fontFamily: String
        let theme: Config.Theme
        let captionBaseline: Double
        let captionFontSize: Double
        let card: Config.Card?
        let icon: CGImage?
    }

    /// The config's layout is tuned for its own `output` canvas; scale it to this one.
    static func scaled(_ layout: Config.Layout, by s: Double) -> Config.Layout {
        var l = layout
        l.margin *= s
        l.textTop *= s
        l.titleFontSize *= s
        l.subtitleFontSize *= s
        l.textGap *= s
        l.screenshotGap *= s
        l.cornerRadius *= s
        l.shadow.blur *= s
        l.shadow.dy *= s
        return l
    }

    /// The darkest stop by luma: the preview's surround, which must read as the app's
    /// own backdrop rather than as marketing.
    static func darkest(_ background: Config.Background) -> String {
        func luma(_ hex: String) -> Double {
            guard let c = Image.color(hex: hex)?.components, c.count >= 3 else { return 1 }
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        return background.stops.min { luma($0.color) < luma($1.color) }?.color ?? "#000000"
    }

    public static func style(
        kind: Kind, size: Config.Size, config: Config, appearance: String,
        video: Config.Video, stage: CGSize, icon: CGImage?
    ) throws -> Style {
        guard let theme = config.themes[appearance] else { throw AppShotError.missingTheme(appearance) }
        let W = Double(size.width)
        let H = Double(size.height)
        let reference = config.output ?? Config.Size(width: 2880, height: 1800)
        let s = min(W / Double(reference.width), H / Double(reference.height))
        let layout = scaled(config.layout, by: s)

        let box: CGRect
        let captionBaseline: Double
        let captionFontSize: Double
        switch kind {
        case .promo:
            // Room for the longest caption, so the window never moves between captions.
            let font = try Text.font(stack: config.fontFamily, weight: layout.titleWeight, size: layout.titleFontSize)
            let white = CGColor(gray: 1, alpha: 1)
            let lines = video.beats.compactMap(\.caption).map {
                Text.wrap($0, font: font, color: white, kern: Config.Layout.titleLetterSpacing,
                          maxWidth: W - layout.margin * 2).count
            }.max() ?? 0
            let step = layout.titleFontSize * layout.titleLineHeight
            let block = lines == 0 ? 0 : layout.titleFontSize + Double(lines - 1) * step
            let top = layout.textTop + block + (lines == 0 ? 0 : layout.screenshotGap)
            box = CGRect(x: layout.margin, y: top, width: W - layout.margin * 2, height: H - top - layout.margin)
            captionBaseline = layout.textTop + layout.titleFontSize
            captionFontSize = layout.titleFontSize
        case .preview:
            let strip = (H * 0.11).rounded()
            let inset = (layout.margin * 0.5).rounded()
            box = CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset - strip)
            captionFontSize = (strip * 0.42).rounded()
            captionBaseline = H - strip / 2 + captionFontSize * 0.35
        }
        guard box.width > 0, box.height > 0 else {
            throw AppShotError.videoRenderFailed(
                video: video.id, reason: "\(size.description) leaves no room for the app under the caption")
        }
        let fit = min(box.width / stage.width, box.height / stage.height)
        let w = (stage.width * fit).rounded()
        let h = (stage.height * fit).rounded()
        let stageRect = CGRect(x: ((W - w) / 2).rounded(), y: (box.minY + (box.height - h) / 2).rounded(), width: w, height: h)

        guard let ctx = Image.context(width: size.width, height: size.height) else {
            throw AppShotError.videoRenderFailed(video: video.id, reason: "no bitmap context")
        }
        switch kind {
        case .promo:
            Compose.drawGradient(ctx, theme.background, width: W, height: H)
        case .preview:
            ctx.setFillColor(Image.color(hex: darkest(theme.background)) ?? CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        Compose.drawShadow(ctx, rect: stageRect, radius: layout.cornerRadius, shadow: layout.shadow, width: W, height: H)
        guard let backdrop = ctx.makeImage() else {
            throw AppShotError.videoRenderFailed(video: video.id, reason: "backdrop did not render")
        }

        return Style(
            kind: kind, size: size, stageRect: stageRect, backdrop: backdrop, layout: layout,
            fontFamily: config.fontFamily, theme: theme, captionBaseline: captionBaseline,
            captionFontSize: captionFontSize, card: kind == .promo ? video.card : nil, icon: icon)
    }

    public static func render(stage: CGImage, t: Double, timeline: VideoTimeline, style: Style) throws -> CGImage {
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        guard let ctx = Image.context(width: style.size.width, height: style.size.height) else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no bitmap context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(style.backdrop, in: CGRect(x: 0, y: 0, width: W, height: H))

        // Camera: crop the stage around the eased center, clamped inside it.
        let stageSize = CGSize(width: stage.width, height: stage.height)
        let camera = timeline.camera(at: t, stage: stageSize)
        let cw = stageSize.width / camera.scale
        let ch = stageSize.height / camera.scale
        let crop = CGRect(
            x: min(max(camera.center.x - cw / 2, 0), stageSize.width - cw),
            y: min(max(camera.center.y - ch / 2, 0), stageSize.height - ch),
            width: cw, height: ch
        ).integral
        let dest = Compose.flip(style.stageRect, in: H)
        if camera.scale > 1.001, let cropped = stage.cropping(to: crop) {
            // A zoomed crop has lost the window's own rounded corners; put them back.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: dest, cornerWidth: style.layout.cornerRadius,
                               cornerHeight: style.layout.cornerRadius, transform: nil))
            ctx.clip()
            ctx.draw(cropped, in: dest)
            ctx.restoreGState()
        } else {
            ctx.draw(stage, in: dest)
        }

        // Pointer, mapped from stage pixels through the same crop.
        let k = style.stageRect.width / crop.width
        if let cursor = timeline.cursor(at: t) {
            let x = style.stageRect.minX + (cursor.point.x - crop.minX) * k
            let y = style.stageRect.minY + (cursor.point.y - crop.minY) * k
            drawPointer(ctx, at: CGPoint(x: x, y: H - y), size: min(W, H) * 0.035, ripple: cursor.ripple)
        }

        if let caption = timeline.caption(at: t) {
            ctx.saveGState()
            ctx.setAlpha(caption.opacity)
            let font = try Text.font(stack: style.fontFamily, weight: style.layout.titleWeight, size: style.captionFontSize)
            let color = Image.color(hex: style.theme.title) ?? CGColor(gray: 1, alpha: 1)
            let lines = Text.wrap(caption.text, font: font, color: color, kern: Config.Layout.titleLetterSpacing,
                                  maxWidth: W - style.layout.margin * 2)
            let step = style.captionFontSize * style.layout.titleLineHeight
            for (i, line) in lines.enumerated() {
                Compose.draw(line, ctx: ctx, baselineYDown: style.captionBaseline + Double(i) * step, width: W, height: H)
            }
            ctx.restoreGState()
        }

        let card = timeline.cardOpacity(at: t)
        if style.kind == .promo, card > 0, let content = style.card {
            ctx.saveGState()
            ctx.setAlpha(card)
            Compose.drawGradient(ctx, style.theme.background, width: W, height: H)
            let side = min(W, H) * 0.22
            if let icon = style.icon {
                ctx.draw(icon, in: Compose.flip(CGRect(x: (W - side) / 2, y: H * 0.38 - side / 2, width: side, height: side), in: H))
            }
            let titleFont = try Text.font(stack: style.fontFamily, weight: style.layout.titleWeight, size: style.captionFontSize)
            let subFont = try Text.font(stack: style.fontFamily, weight: style.layout.subtitleWeight, size: style.captionFontSize * 0.5)
            let titleColor = Image.color(hex: style.theme.title) ?? CGColor(gray: 1, alpha: 1)
            let subColor = Image.color(hex: style.theme.subtitle) ?? titleColor
            var baseline = H * 0.38 + side / 2 + style.captionFontSize * 1.4
            for line in Text.wrap(content.title, font: titleFont, color: titleColor, kern: 0, maxWidth: W) {
                Compose.draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
            }
            if let subtitle = content.subtitle {
                baseline += style.captionFontSize * 0.9
                for line in Text.wrap(subtitle, font: subFont, color: subColor, kern: 0, maxWidth: W) {
                    Compose.draw(line, ctx: ctx, baselineYDown: baseline, width: W, height: H)
                }
            }
            ctx.restoreGState()
        }

        guard let image = ctx.makeImage() else {
            throw AppShotError.videoRenderFailed(video: "", reason: "frame did not render")
        }
        return image
    }

    /// A plain arrow, drawn rather than borrowed: Apple's cursor artwork is not ours to
    /// ship. `origin` is the tip, in CoreGraphics' y-up space.
    static func drawPointer(_ ctx: CGContext, at origin: CGPoint, size: Double, ripple: Double?) {
        if let ripple {
            ctx.saveGState()
            let r = size * (0.6 + ripple)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6 * (1 - ripple)))
            ctx.setLineWidth(size * 0.12)
            ctx.strokeEllipse(in: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
        let path = CGMutablePath()
        let points: [(Double, Double)] = [(0, 0), (0, -1), (0.28, -0.74), (0.46, -1.1), (0.6, -1.04), (0.43, -0.68), (0.78, -0.68)]
        path.addLines(between: points.map { CGPoint(x: origin.x + $0.0 * size, y: origin.y + $0.1 * size) })
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.04), blur: size * 0.15, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(size * 0.06)
        ctx.strokePath()
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter VideoFrameTests`
Expected: PASS. If `previewIsFullBleedOnTheDarkestStop` reads a slightly different corner value, check `Image.context`'s color space before loosening the test: the backdrop must be exactly the stop's sRGB value.

- [ ] **Step 6: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoFrame.swift Sources/AppShotKit/Compose.swift Tests/AppShotKitTests/VideoFrameTests.swift
git commit -m "feat(video): render a promo or preview frame with captions, camera and pointer"
```

---

### Task 5: Masters: stills and recorded

**Files:**
- Create: `Sources/AppShotKit/VideoMaster.swift`
- Test: `Tests/AppShotKitTests/VideoMasterTests.swift`

**Interfaces:**
- Consumes: `VideoTrack` (Task 2); `Image.load`, `Image.context` (existing).
- Produces:
  - `protocol VideoMaster { var stageSize: CGSize { get }; mutating func frame(at t: Double) throws -> CGImage }`
  - `struct StillsMaster: VideoMaster { init(video: Config.Video, sourceDir: URL, appearance: String) throws; static let crossfade = 0.5 }`
  - `final class RecordedMaster: VideoMaster { init(url: URL, track: VideoTrack) throws }`

- [ ] **Step 1: Write the failing tests**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoMasterTests {
    static func solid(_ w: Int, _ h: Int, gray: Double, to url: URL) throws {
        let ctx = try #require(Image.context(width: w, height: h))
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        try Image.write(try #require(ctx.makeImage()), to: url)
    }

    static func dir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "master-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func video() throws -> Config.Video {
        try VideoConfigTests.config(videos: """
            [{ "id": "v", "duration": 4, "outputs": { "promo": [[100, 100]] },
               "beats": [{ "at": 0, "screen": "browser" }, { "at": 2, "screen": "paywall" }] }]
            """).video("v")
    }

    @Test func crossfadesBetweenStills() throws {
        let dir = try Self.dir()
        try Self.solid(100, 50, gray: 0, to: dir.appending(path: "browser~dark.png"))
        try Self.solid(100, 50, gray: 1, to: dir.appending(path: "paywall~dark.png"))
        var master = try StillsMaster(video: Self.video(), sourceDir: dir, appearance: "dark")
        #expect(master.stageSize == CGSize(width: 100, height: 50))
        let px = { (img: CGImage) in Image.pixels(img)!.bytes[(25 * 100 + 50) * 4] }
        #expect(px(try master.frame(at: 1)) == 0)
        let mid = px(try master.frame(at: 2.25))
        #expect(mid > 100 && mid < 160)
        #expect(px(try master.frame(at: 3)) == 255)
    }

    @Test func differentSizedStillsAreCenteredNotStretched() throws {
        let dir = try Self.dir()
        try Self.solid(100, 50, gray: 1, to: dir.appending(path: "browser~dark.png"))
        try Self.solid(60, 30, gray: 1, to: dir.appending(path: "paywall~dark.png"))
        var master = try StillsMaster(video: Self.video(), sourceDir: dir, appearance: "dark")
        let frame = try master.frame(at: 3)
        let px = Image.pixels(frame)!
        // Outside the centered 60x30 the canvas is transparent.
        #expect(px.bytes[(2 * 100 + 2) * 4 + 3] == 0)
        #expect(px.bytes[(25 * 100 + 50) * 4 + 3] == 255)
    }

    @Test func missingStillNamesTheFile() throws {
        let dir = try Self.dir()
        #expect {
            _ = try StillsMaster(video: Self.video(), sourceDir: dir, appearance: "dark")
        } throws: { error in
            guard case .missingCaptures(let names, _) = error as? AppShotError else { return false }
            return names.contains("browser~dark.png")
        }
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "no hardware HEVC encoder on CI runners"))
    func recordedMasterKeepsAlphaAndCrops() async throws {
        let url = try Self.dir().appending(path: "m.mov")
        try await Self.writeAlphaMovie(url, width: 64, height: 64)
        let track = VideoTrack(
            video: "v", appearance: "dark", duration: 1, stage: [16, 16, 32, 32],
            beats: [], targets: [], frames: 30, maxFrameGap: 0)
        var master = try RecordedMaster(url: url, track: track)
        let frame = try master.frame(at: 0.5)
        #expect(frame.width == 32 && frame.height == 32)
        #expect(Image.pixels(frame)!.bytes[(16 * 32 + 16) * 4 + 3] == 255)
    }

    /// A 1s HEVC-with-alpha movie: transparent, with an opaque 32x32 square in the middle.
    static func writeAlphaMovie(_ url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let ctx = try #require(Image.context(width: width, height: height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        let image = try #require(ctx.makeImage())
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pb = try VideoWriter.pixelBuffer(image, pool: try #require(adaptor.pixelBufferPool))
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
```

The last test uses `VideoWriter.pixelBuffer(_:pool:)`, which Task 6 creates. **Order:** write this test file now but leave `recordedMasterKeepsAlphaAndCrops` and `writeAlphaMovie` commented out until Task 6 lands, then uncomment them in Task 6 Step 5. (They're in this task because they test this task's code.)

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter VideoMasterTests`
Expected: compile failure, "cannot find 'StillsMaster' in scope".

- [ ] **Step 3: Implement**

`Sources/AppShotKit/VideoMaster.swift`:

```swift
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// A source of stage frames, in stage pixels. The renderer never knows which kind it has.
public protocol VideoMaster {
    var stageSize: CGSize { get }
    mutating func frame(at t: Double) throws -> CGImage
}

/// A stand-in recording built from existing captures: each beat that names a `screen`
/// cuts to it with a crossfade.
///
/// Captures of different sizes are centered on one canvas the size of the largest,
/// never stretched: a stretched window is a lie about the app, and it is the kind a
/// reviewer only notices after it ships.
public struct StillsMaster: VideoMaster {
    public static let crossfade = 0.5

    public let stageSize: CGSize
    private let keys: [(time: Double, image: CGImage)]

    public init(video: Config.Video, sourceDir: URL, appearance: String) throws {
        let cuts = video.beats.compactMap { beat in beat.screen.map { (beat.at, $0) } }
        guard let first = cuts.first, first.0 == 0 else {
            throw AppShotError.invalidVideo(
                id: video.id, reason: "--from-stills needs a beat at 0 that names a screen")
        }
        let names = cuts.map { "\($0.1)~\(appearance).png" }
        let missing = Set(names).filter { !FileManager.default.fileExists(atPath: sourceDir.appending(path: $0).path) }
        guard missing.isEmpty else { throw AppShotError.missingCaptures(missing.sorted(), dir: sourceDir) }

        let images = try names.map { try Image.load(sourceDir.appending(path: $0)) }
        let w = images.map(\.width).max() ?? 0
        let h = images.map(\.height).max() ?? 0
        stageSize = CGSize(width: w, height: h)
        keys = try zip(cuts, images).map { cut, image in
            guard let ctx = Image.context(width: w, height: h) else {
                throw AppShotError.videoRenderFailed(video: video.id, reason: "no bitmap context")
            }
            ctx.draw(image, in: CGRect(x: (w - image.width) / 2, y: (h - image.height) / 2,
                                       width: image.width, height: image.height))
            guard let centered = ctx.makeImage() else {
                throw AppShotError.videoRenderFailed(video: video.id, reason: "could not center \(cut.1)")
            }
            return (cut.0, centered)
        }
    }

    public mutating func frame(at t: Double) throws -> CGImage {
        let index = keys.lastIndex { $0.time <= t } ?? 0
        let p = (t - keys[index].time) / Self.crossfade
        guard index > 0, p < 1 else { return keys[index].image }
        guard let ctx = Image.context(width: Int(stageSize.width), height: Int(stageSize.height)) else {
            return keys[index].image
        }
        let full = CGRect(origin: .zero, size: stageSize)
        ctx.draw(keys[index - 1].image, in: full)
        ctx.setAlpha(VideoTimeline.ease(p))
        ctx.draw(keys[index].image, in: full)
        return ctx.makeImage() ?? keys[index].image
    }
}

/// The recording, decoded in order and cropped to the track's stage.
///
/// Sequential only: `frame(at:)` must be asked for non-decreasing times, which is how
/// the renderer walks a video. Seeking an HEVC stream per frame would cost a decode
/// from the last keyframe every time.
public final class RecordedMaster: VideoMaster {
    public let stageSize: CGSize
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let crop: CGRect
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var origin: CMTime?
    private var current: CGImage?
    private var pending: CMSampleBuffer?

    public init(url: URL, track: VideoTrack) throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw AppShotError.videoRenderFailed(video: track.video, reason: "\(url.lastPathComponent) has no video track")
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AppShotError.videoRenderFailed(video: track.video, reason: "cannot read \(url.lastPathComponent)")
        }
        crop = CGRect(x: track.stage[0], y: track.stage[1], width: track.stage[2], height: track.stage[3])
        stageSize = crop.size
    }

    public func frame(at t: Double) throws -> CGImage {
        while true {
            guard let sample = pending ?? output.copyNextSampleBuffer() else { break }
            pending = nil
            let pts = sample.presentationTimeStamp
            if origin == nil { origin = pts }
            guard (pts - (origin ?? pts)).seconds <= t + 0.0005 else {
                pending = sample
                break
            }
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                let ci = CIImage(cvPixelBuffer: pb)
                // CIImage is y-up; the crop is y-down.
                let rect = CGRect(x: crop.minX, y: ci.extent.height - crop.maxY, width: crop.width, height: crop.height)
                current = context.createCGImage(ci, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
        guard let current else {
            throw AppShotError.videoRenderFailed(video: "", reason: "the master has no frame at \(t)s")
        }
        return current
    }
}
```

`asset.tracks(withMediaType:)` is deprecated in favor of the async `loadTracks`, but `RecordedMaster.init` is synchronous on purpose (the render loop is synchronous). If the deprecation warning fails the build, make `init` `async` and use `try await asset.loadTracks(withMediaType: .video)`, then adjust Task 8's caller.

- [ ] **Step 4: Run tests**

Run: `swift test --filter VideoMasterTests`
Expected: the three stills tests PASS (the recorded one is still commented out).

- [ ] **Step 5: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoMaster.swift Tests/AppShotKitTests/VideoMasterTests.swift
git commit -m "feat(video): read stage frames from stills or a recorded master"
```

---

### Task 6: Encoding H.264 with a silent stereo track

**Files:**
- Create: `Sources/AppShotKit/VideoWriter.swift`
- Modify: `Tests/AppShotKitTests/VideoMasterTests.swift` (uncomment the recorded test)
- Test: `Tests/AppShotKitTests/VideoWriterTests.swift`

**Interfaces:**
- Produces:
  - `final class VideoWriter { static let fps: Int32 = 30; init(url: URL, size: Config.Size, bitRate: Int = 10_000_000) throws; func append(_ image: CGImage) throws; func finish() async throws -> URL }`
  - `static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer`
  - Writes to `url.appendingPathExtension("partial")` and renames to `url` in `finish()`.

- [ ] **Step 1: Write the failing test**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoWriterTests {
    @Test func writesH264WithASilentStereoTrack() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "w-\(UUID()).mp4")
        let writer = try VideoWriter(url: url, size: .init(width: 64, height: 48))
        let ctx = try #require(Image.context(width: 64, height: 48))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(ctx.makeImage())
        for _ in 0..<30 { try writer.append(image) }
        let done = try await writer.finish()
        #expect(done == url)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".partial"))

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.05)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 64, height: 48))
        #expect(abs(try await video.load(.nominalFrameRate) - 30) < 0.5)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mSampleRate == 48_000)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter VideoWriterTests`
Expected: compile failure, "cannot find 'VideoWriter' in scope".

- [ ] **Step 3: Implement**

`Sources/AppShotKit/VideoWriter.swift`:

```swift
import AVFoundation
import CoreGraphics
import Foundation

/// H.264 at 30 fps plus a silent stereo AAC track.
///
/// The silent track is there because Apple's preview spec lists stereo audio and says
/// every track must be enabled; carrying one costs nothing and takes the question off
/// the table. Promos get it too, so the two outputs differ only in what they show.
///
/// Audio is appended alongside video rather than all at the end: AVAssetWriter
/// interleaves its inputs, and an input that falls far behind makes the other one stop
/// accepting data — a stall, not an error.
public final class VideoWriter {
    public static let fps: Int32 = 30
    static let sampleRate = 48_000

    private let url: URL
    private let partial: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let format: CMAudioFormatDescription
    private var frame: Int64 = 0
    private var audioFrames: Int64 = 0

    public init(url: URL, size: Config.Size, bitRate: Int = 10_000_000) throws {
        self.url = url
        partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High40,
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.fps),
            ],
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(video)
        writer.add(audio)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard let description, writer.startWriting() else {
            throw AppShotError.videoRenderFailed(video: url.lastPathComponent, reason: "\(writer.error.map { "\($0)" } ?? "writer did not start")")
        }
        format = description
        writer.startSession(atSourceTime: .zero)
    }

    public func append(_ image: CGImage) throws {
        try waitFor(video)
        guard let pool = adaptor.pixelBufferPool else { throw failure("no pixel buffer pool") }
        let buffer = try Self.pixelBuffer(image, pool: pool)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: Self.fps)) else {
            throw failure("frame \(frame) was refused")
        }
        frame += 1
        try appendSilence(upTo: Double(frame) / Double(Self.fps))
    }

    public func finish() async throws -> URL {
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure("finish: \(writer.error.map { "\($0)" } ?? "unknown")") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    public static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { throw AppShotError.videoRenderFailed(video: "", reason: "no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw AppShotError.videoRenderFailed(video: "", reason: "no pixel buffer context") }
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return buffer
    }

    private func appendSilence(upTo seconds: Double) throws {
        let target = Int64(seconds * Double(Self.sampleRate))
        while audioFrames < target {
            let count = Int(min(1024, target - audioFrames))
            try waitFor(audio)
            let bytes = count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw failure("no audio block") }
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: audioFrames, timescale: CMTimeScale(Self.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, audio.append(sample) else { throw failure("silence was refused") }
            audioFrames += Int64(count)
        }
    }

    /// The inputs are not real-time, so readiness comes back quickly; ten seconds
    /// without it is a stuck writer, and a hang is worse than an error.
    private func waitFor(_ input: AVAssetWriterInput) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else { throw failure("encoder stalled") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func failure(_ why: String) -> AppShotError {
        .videoRenderFailed(video: url.lastPathComponent, reason: why)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter VideoWriterTests`
Expected: PASS.

- [ ] **Step 5: Uncomment the recorded-master test from Task 5 and run it**

Run: `swift test --filter VideoMasterTests`
Expected: all four PASS (on this Mac; skipped on CI).

- [ ] **Step 6: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoWriter.swift Tests/AppShotKitTests/VideoWriterTests.swift Tests/AppShotKitTests/VideoMasterTests.swift
git commit -m "feat(video): encode H.264 at 30 fps with a silent stereo track"
```

---

### Task 7: Contact sheet

**Files:**
- Create: `Sources/AppShotKit/ContactSheet.swift`
- Test: `Tests/AppShotKitTests/ContactSheetTests.swift`

**Interfaces:**
- Produces:
  - `enum ContactSheet { struct Cell { time: Double; label: String; image: CGImage }; static func render(_ cells: [Cell], columns: Int = 3, cellWidth: Int = 640) throws -> CGImage; static func times(for timeline: VideoTimeline, beats: [Double]) -> [Double] }`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct ContactSheetTests {
    @Test func laysCellsOutInAGrid() throws {
        let ctx = try #require(Image.context(width: 320, height: 200))
        let image = try #require(ctx.makeImage())
        let cells = (0..<4).map { ContactSheet.Cell(time: Double($0), label: "beat \($0)", image: image) }
        let sheet = try ContactSheet.render(cells, columns: 3, cellWidth: 160)
        #expect(sheet.width == 480)
        // Two rows of a 100px thumbnail plus a 40px label band.
        #expect(sheet.height == 2 * (100 + 40))
    }

    @Test func picksASettledFrameAfterEachBeatAndMidCaption() throws {
        let video = try VideoTimelineTests.video(#"[{"at":0,"caption":"a","until":4},{"at":6,"cue":"x"}]"#)
        let timeline = try VideoTimelineTests.timeline(video)
        #expect(ContactSheet.times(for: timeline, beats: [0, 6]) == [0.8, 2, 6.8])
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter ContactSheetTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

`Sources/AppShotKit/ContactSheet.swift`:

```swift
import CoreGraphics
import Foundation

/// The whole video as one image, so an agent that cannot watch a video can still look
/// at it: one settled frame per beat, one in the middle of each caption, each labeled.
public enum ContactSheet {
    public struct Cell {
        public let time: Double
        public let label: String
        public let image: CGImage

        public init(time: Double, label: String, image: CGImage) {
            self.time = time
            self.label = label
            self.image = image
        }
    }

    /// After a beat, the UI may still be animating; 0.8s is past every transition this
    /// pipeline draws itself (the longest is the 0.6s zoom).
    static let settle = 0.8

    public static func times(for timeline: VideoTimeline, beats: [Double]) -> [Double] {
        let raw = beats.map { min($0 + settle, timeline.duration - 0.01) }
            + timeline.captions.map { ($0.start + $0.end) / 2 }
        var out: [Double] = []
        for t in raw.sorted() where out.last.map({ t - $0 >= 0.1 }) ?? true {
            out.append((t * 100).rounded() / 100)
        }
        return out
    }

    public static func render(_ cells: [Cell], columns: Int = 3, cellWidth: Int = 640) throws -> CGImage {
        guard let first = cells.first else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no frames for the contact sheet")
        }
        let thumb = Int((Double(cellWidth) * Double(first.image.height) / Double(first.image.width)).rounded())
        let band = max(40, cellWidth / 16)
        let rows = (cells.count + columns - 1) / columns
        let W = columns * cellWidth
        let H = rows * (thumb + band)
        guard let ctx = Image.context(width: W, height: H) else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no bitmap context")
        }
        ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Helvetica ships with every macOS; the sheet is a working image, not a store one.
        let font = try Text.font(stack: "Helvetica", weight: 500, size: Double(band) * 0.5)
        let white = CGColor(gray: 0.92, alpha: 1)
        ctx.interpolationQuality = .high
        for (i, cell) in cells.enumerated() {
            let x = Double((i % columns) * cellWidth)
            let top = Double((i / columns) * (thumb + band))
            ctx.draw(cell.image, in: Compose.flip(CGRect(x: x, y: top, width: Double(cellWidth), height: Double(thumb)), in: Double(H)))
            let label = String(format: "%.1fs  ", cell.time) + cell.label
            if let line = Text.wrap(label, font: font, color: white, kern: 0, maxWidth: Double(cellWidth) - 24).first {
                ctx.textPosition = CGPoint(x: x + 12, y: Double(H) - (top + Double(thumb) + Double(band) * 0.68))
                CTLineDraw(line.ctLine, ctx)
            }
        }
        guard let image = ctx.makeImage() else {
            throw AppShotError.videoRenderFailed(video: "", reason: "contact sheet did not render")
        }
        return image
    }
}
```

Add `import CoreText` at the top for `CTLineDraw`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ContactSheetTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/ContactSheet.swift Tests/AppShotKitTests/ContactSheetTests.swift
git commit -m "feat(video): render a labeled contact sheet of a video"
```

---

### Task 8: `compose video`: orchestration, report, CLI

**Files:**
- Create: `Sources/AppShotKit/VideoCompose.swift`
- Create: `Sources/appshot/VideoCommands.swift` (the `ComposeVideo` command; `Record` comes in Task 11)
- Modify: `Sources/appshot/ComposeCommands.swift` (`Compose_.configuration.subcommands` gains `ComposeVideo.self`)
- Modify: `Sources/appshot/AppShot.swift` (`Defaults` gains `videoSource = "videos/source"`, `videoOut = "videos"`)
- Test: `Tests/AppShotKitTests/VideoComposeTests.swift`

**Interfaces:**
- Consumes: Tasks 1-7.
- Produces:
  - `enum VideoCompose { struct Options; struct Output { url: URL; kind: String; size: Config.Size }; struct Report: Codable; static func run(_ options: Options) async throws -> [Output] }`
  - `Options { config: Config; configDir: URL; sourceDir: URL; outDir: URL; fromStills: URL?; videos: [String]?; appearances: [String]?; websiteOut: URL? }`
  - Files: `<out>/preview/<id>~<app>.mp4`, `<out>/promo/<id>~<app>~<w>x<h>.mp4`, `<out>/promo/<id>~<app>.poster.png`, `<out>/report/<id>~<app>.report.json`, `<out>/report/<id>~<app>.contact.png`, `<websiteOut>/<id>.mp4` (single appearance) or `<id>~<app>.mp4`.

- [ ] **Step 1: Write the failing tests**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoComposeTests {
    static func setup(beats: String, duration: Double = 3) throws -> (VideoCompose.Options, URL) {
        var config = try VideoConfigTests.config(videos: """
            [{ "id": "v", "duration": \(duration), "outputs": { "promo": [[320, 200]], "website": true },
               "card": { "title": "T" }, "beats": \(beats) }]
            """)
        config.fontFamily = "Helvetica"
        config.appearances = ["dark"]
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "vc-\(UUID())")
        let stills = root.appending(path: "shots")
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        try VideoMasterTests.solid(400, 250, gray: 0.9, to: stills.appending(path: "browser~dark.png"))
        try VideoMasterTests.solid(400, 250, gray: 0.2, to: stills.appending(path: "paywall~dark.png"))
        let options = VideoCompose.Options(
            config: config, configDir: root, sourceDir: root.appending(path: "source"),
            outDir: root.appending(path: "videos"), fromStills: stills, videos: nil, appearances: nil,
            websiteOut: root.appending(path: "site"))
        return (options, root)
    }

    @Test func composesAPromoFromStills() async throws {
        let (options, root) = try Self.setup(beats: """
            [{ "at": 0, "screen": "browser", "caption": "One" },
             { "at": 1.5, "screen": "paywall" }]
            """)
        let outputs = try await VideoCompose.run(options)
        let promo = root.appending(path: "videos/promo/v~dark~320x200.mp4")
        #expect(outputs.map(\.url).contains(promo))
        let asset = AVURLAsset(url: promo)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.05)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "videos/promo/v~dark.poster.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "videos/report/v~dark.report.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "videos/report/v~dark.contact.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "site/v.mp4").path))
    }

    @Test func shortCaptionFailsBeforeWriting() async throws {
        let (options, root) = try Self.setup(beats: """
            [{ "at": 0, "screen": "browser", "caption": "far too many words to read here" },
             { "at": 1, "caption": "next" }]
            """)
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .captionTooShort(_, let caption, _, _) = error as? AppShotError else { return false }
            return caption.hasPrefix("far too many")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func reportCarriesCaptionMargins() async throws {
        let (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser", "caption": "One" }]"#)
        _ = try await VideoCompose.run(options)
        let data = try Data(contentsOf: root.appending(path: "videos/report/v~dark.report.json"))
        let report = try JSONDecoder().decode(VideoCompose.Report.self, from: data)
        // "One": 1 word needs 1.3s, shown for the whole 3s.
        #expect(abs((report.captions.first?.margin ?? 0) - 1.7) < 0.01)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter VideoComposeTests`
Expected: compile failure, "cannot find 'VideoCompose' in scope".

- [ ] **Step 3: Implement the orchestration**

`Sources/AppShotKit/VideoCompose.swift`:

```swift
import CoreGraphics
import Foundation

/// master + track + config → previews, promos, a website loop, a report and a contact
/// sheet.
///
/// Everything that can fail on its inputs — a missing track, a caption too short to
/// read, a font that does not resolve — fails before the first file is written.
public enum VideoCompose {
    public struct Options: Sendable {
        public var config: Config
        /// Where `card.icon` paths resolve from.
        public var configDir: URL
        /// `record`'s output: masters and tracks.
        public var sourceDir: URL
        public var outDir: URL
        /// Screenshot captures to build a stand-in master from, instead of `sourceDir`.
        public var fromStills: URL?
        public var videos: [String]?
        public var appearances: [String]?
        public var websiteOut: URL?

        public init(
            config: Config, configDir: URL, sourceDir: URL, outDir: URL, fromStills: URL?,
            videos: [String]?, appearances: [String]?, websiteOut: URL?
        ) {
            self.config = config
            self.configDir = configDir
            self.sourceDir = sourceDir
            self.outDir = outDir
            self.fromStills = fromStills
            self.videos = videos
            self.appearances = appearances
            self.websiteOut = websiteOut
        }
    }

    public struct Output: Sendable {
        public let url: URL
        public let kind: String
        public let size: Config.Size
    }

    public struct Report: Codable, Sendable {
        public struct Beat: Codable, Sendable {
            public var index: Int
            public var scheduled: Double
            public var actual: Double
            public var latency: Double?
        }
        public struct Caption: Codable, Sendable {
            public var text: String
            public var start: Double
            public var shown: Double
            public var needed: Double
            public var margin: Double
        }
        public var video: String
        public var appearance: String
        public var duration: Double
        public var beats: [Beat]
        public var captions: [Caption]
        public var outputs: [String]
        public var frames: Int
        public var maxFrameGap: Double
    }

    struct Job {
        let video: Config.Video
        let appearance: String
        let track: VideoTrack
        let timeline: VideoTimeline
    }

    public static func run(_ options: Options) async throws -> [Output] {
        let config = options.config
        try config.validate()
        let videos = try (options.videos ?? (config.videos ?? []).map(\.id)).map { try config.video($0) }
        let appearances = options.appearances ?? config.appearances

        // Plan every job and run every check before writing anything.
        var jobs: [Job] = []
        for video in videos {
            for appearance in appearances {
                let track: VideoTrack
                if let stills = options.fromStills {
                    let master = try StillsMaster(video: video, sourceDir: stills, appearance: appearance)
                    track = .stills(video: video, appearance: appearance, stageSize: master.stageSize)
                } else {
                    let url = VideoTrack.url(in: options.sourceDir, video: video.id, appearance: appearance)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw AppShotError.missingCaptures([url.lastPathComponent], dir: options.sourceDir)
                    }
                    track = try VideoTrack.read(url)
                }
                let timeline = try VideoTimeline(video: video, track: track)
                if let short = timeline.readingProblems().first {
                    throw AppShotError.captionTooShort(
                        video: video.id, caption: short.text, shown: short.shown, needed: short.needed)
                }
                jobs.append(Job(video: video, appearance: appearance, track: track, timeline: timeline))
            }
        }
        _ = try Text.font(stack: config.fontFamily, weight: config.layout.titleWeight, size: config.layout.titleFontSize)

        var outputs: [Output] = []
        for job in jobs {
            outputs += try await render(job, options: options)
        }
        return outputs
    }

    static func render(_ job: Job, options: Options) async throws -> [Output] {
        let config = options.config
        let video = job.video
        let name = "\(video.id)~\(job.appearance)"
        var master: any VideoMaster =
            if let stills = options.fromStills {
                try StillsMaster(video: video, sourceDir: stills, appearance: job.appearance)
            } else {
                try RecordedMaster(
                    url: options.sourceDir.appending(path: "\(name).mov"), track: job.track)
            }
        let icon = try video.card?.icon.map { try Image.load(options.configDir.appending(path: $0)) }

        var targets: [(style: VideoFrame.Style, writer: VideoWriter, kind: String)] = []
        if video.outputs.wantsPreview, let size = Config.previewSize(for: config.resolvedPlatform) {
            let style = try VideoFrame.style(
                kind: .preview, size: size, config: config, appearance: job.appearance,
                video: video, stage: master.stageSize, icon: nil)
            let url = options.outDir.appending(path: "preview/\(name).mp4")
            targets.append((style, try VideoWriter(url: url, size: size), "preview"))
        }
        for size in video.outputs.promoSizes {
            let style = try VideoFrame.style(
                kind: .promo, size: size, config: config, appearance: job.appearance,
                video: video, stage: master.stageSize, icon: icon)
            let url = options.outDir.appending(path: "promo/\(name)~\(size.description).mp4")
            targets.append((style, try VideoWriter(url: url, size: size), "promo"))
        }

        let poster = video.poster ?? min(5, video.duration / 2)
        let sheetTimes = ContactSheet.times(
            for: job.timeline, beats: video.beats.indices.map { job.track.time(ofBeat: $0) })
        var sheet: [ContactSheet.Cell] = []
        var posterImage: CGImage?
        let count = Int((video.duration * Double(VideoWriter.fps)).rounded())
        for i in 0..<count {
            let t = Double(i) / Double(VideoWriter.fps)
            let stage = try master.frame(at: t)
            for (n, target) in targets.enumerated() {
                let frame = try VideoFrame.render(stage: stage, t: t, timeline: job.timeline, style: target.style)
                try target.writer.append(frame)
                guard n == targets.count - 1 else { continue }
                // The last target is a promo when there is one: the poster and the sheet
                // show the framed version, which is what a reviewer is judging.
                if posterImage == nil, t >= poster { posterImage = frame }
                if let next = sheetTimes.dropFirst(sheet.count).first, t >= next {
                    let caption = job.timeline.caption(at: next)?.text ?? ""
                    sheet.append(ContactSheet.Cell(time: next, label: caption, image: frame))
                }
            }
        }

        var outputs: [Output] = []
        for target in targets {
            let url = try await target.writer.finish()
            outputs.append(Output(url: url, kind: target.kind, size: target.style.size))
        }

        if let posterImage, video.outputs.wantsPreview || !video.outputs.promoSizes.isEmpty {
            let url = options.outDir.appending(path: "promo/\(name).poster.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Image.write(posterImage, to: url)
        }

        if video.outputs.wantsWebsite, let site = options.websiteOut,
            let first = outputs.first(where: { $0.kind == "promo" })
        {
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            let single = (options.appearances ?? config.appearances).count == 1
            let url = site.appending(path: single ? "\(video.id).mp4" : "\(name).mp4")
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: first.url, to: url)
            outputs.append(Output(url: url, kind: "website", size: first.size))
        }

        let reportDir = options.outDir.appending(path: "report")
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        if !sheet.isEmpty {
            try Image.write(try ContactSheet.render(sheet), to: reportDir.appending(path: "\(name).contact.png"))
        }
        let report = Report(
            video: video.id, appearance: job.appearance, duration: video.duration,
            beats: job.track.beats.map {
                .init(index: $0.index, scheduled: $0.scheduled, actual: $0.acked ?? $0.scheduled,
                      latency: $0.acked.map { a in a - $0.scheduled })
            },
            captions: job.timeline.captions.map {
                .init(text: $0.text, start: $0.start, shown: $0.shown, needed: $0.needed, margin: $0.shown - $0.needed)
            },
            outputs: outputs.map(\.url.lastPathComponent),
            frames: job.track.frames, maxFrameGap: job.track.maxFrameGap)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportDir.appending(path: "\(name).report.json"), options: .atomic)
        return outputs
    }
}
```

`Options` holds `Config`, which is already `Sendable`, so `Options: Sendable` compiles.

- [ ] **Step 4: Run tests**

Run: `swift test --filter VideoComposeTests`
Expected: PASS.

- [ ] **Step 5: Add the CLI command**

`Sources/appshot/VideoCommands.swift`:

```swift
import AppShotKit
import ArgumentParser
import Foundation

struct ComposeVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Render App Store previews and promos from a recording, or from stills.")

    @OptionGroup var cfg: ConfigOption

    @Option(help: "Directory of masters and tracks written by `appshot record`.")
    var source: String = Defaults.videoSource

    @Option(help: "Where to write preview/, promo/ and report/.")
    var out: String = Defaults.videoOut

    @Option(
        help: """
            Build the video from these screenshot captures instead of a recording. Each \
            beat that names a `screen` cuts to it.
            """)
    var fromStills: String?

    @Option(parsing: .upToNextOption, help: "Only these videos[] ids. Omitted ⇒ all.")
    var videos: [String] = []

    @Option(help: "Comma-separated appearances. Omitted ⇒ the config's.")
    var appearances: String?

    @Option(help: "Where the website loop goes, for videos with outputs.website.")
    var websiteOut: String?

    func run() async throws {
        let config = try cfg.load()
        let outputs = try await VideoCompose.run(
            VideoCompose.Options(
                config: config,
                configDir: cfg.configURL.deletingLastPathComponent(),
                sourceDir: URL(fileURLWithPath: source),
                outDir: URL(fileURLWithPath: out),
                fromStills: fromStills.map { URL(fileURLWithPath: $0) },
                videos: videos.isEmpty ? nil : videos,
                appearances: appearances.map(Pipeline.appearances(from:)),
                websiteOut: websiteOut.map { URL(fileURLWithPath: $0) }))
        for output in outputs {
            print("  \(output.kind.padding(toLength: 8, withPad: " ", startingAt: 0)) \(output.size.description)  \(output.url.path)")
        }
        print("review: \(out)/report/*.contact.png and *.report.json")
    }
}
```

In `Sources/appshot/AppShot.swift` `enum Defaults`, add:

```swift
    static let videoSource = "videos/source"
    static let videoOut = "videos"
```

In `Sources/appshot/ComposeCommands.swift`, change `Compose_`'s `subcommands: [AppStore.self, Website.self, Both.self, Family.self]` to `[AppStore.self, Website.self, Both.self, Family.self, ComposeVideo.self]`.

`Compose_` is a `ParsableCommand` with an async child. If ArgumentParser refuses that combination at build time, change `Compose_` to `AsyncParsableCommand` (the root `AppShot` already is).

- [ ] **Step 6: Smoke-test the CLI end to end**

Run: `swift build && swift test`
Expected: the full suite passes.

- [ ] **Step 7: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/VideoCompose.swift Sources/appshot/VideoCommands.swift Sources/appshot/ComposeCommands.swift Sources/appshot/AppShot.swift Tests/AppShotKitTests/VideoComposeTests.swift
git commit -m "feat(video): add compose video, including --from-stills"
```

**Milestone:** at this point `appshot compose video --from-stills screenshots/source` works for any fleet app with captures. The Armada promo can be made now, before recording exists.

---

### Task 9: Cue and event files

**Files:**
- Create: `Sources/AppShotKit/CueChannel.swift`
- Modify: `Sources/AppShotKit/Capture.swift:678-689` (extract `handshakeDirectory(for:)`; `readyFileURL` uses it)
- Test: `Tests/AppShotKitTests/CueChannelTests.swift`

**Interfaces:**
- Consumes: `Config.CueValue` (Task 1).
- Produces:
  - `struct CueLine: Codable, Sendable, Equatable { seq: Int; t: Double; cue: String; args: [String: Config.CueValue] }`
  - `struct AppEvent: Codable, Sendable, Equatable { kind: String; seq: Int?; name: String?; rect: [Double]?; cue: String? }`
  - `final class CueChannel { let cueFile: URL; let eventFile: URL; init(directory: URL) throws; func send(_ line: CueLine) throws; func poll() throws -> [AppEvent]; func remove() }`
  - `enum CuePolicy { static let warnLatency = 0.05; static let failLatency = 0.25; static let ackTimeout = 1.0 }`
  - `Capture.handshakeDirectory(for app: URL) -> URL`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import AppShotKit

struct CueChannelTests {
    static func channel() throws -> CueChannel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try CueChannel(directory: dir)
    }

    @Test func sendAppendsOneJSONLinePerCue() throws {
        let channel = try Self.channel()
        try channel.send(CueLine(seq: 0, t: 1.5, cue: "pointer.click", args: ["target": .string("row-2")]))
        try channel.send(CueLine(seq: 1, t: 3, cue: "stage", args: ["to": .string("codex")]))
        let lines = try String(contentsOf: channel.cueFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let first = try JSONDecoder().decode(CueLine.self, from: Data(lines[0].utf8))
        #expect(first.cue == "pointer.click")
    }

    @Test func pollReturnsOnlyCompleteNewLines() throws {
        let channel = try Self.channel()
        let handle = try FileHandle(forWritingTo: channel.eventFile)
        handle.write(Data(#"{"kind":"ready"}"#.utf8) + Data("\n".utf8) + Data(#"{"kind":"ack","se"#.utf8))
        #expect(try channel.poll() == [AppEvent(kind: "ready", seq: nil, name: nil, rect: nil, cue: nil)])
        #expect(try channel.poll().isEmpty)
        handle.write(Data(#"q":3}"#.utf8) + Data("\n".utf8))
        #expect(try channel.poll().map(\.seq) == [3])
        try handle.close()
    }

    @Test func garbageLineIsAnError() throws {
        let channel = try Self.channel()
        try Data("not json\n".utf8).write(to: channel.eventFile)
        #expect(throws: AppShotError.self) { try channel.poll() }
    }

    @Test func handshakeDirectoryFallsBackToTmpForUnsandboxedApps() {
        let dir = Capture.handshakeDirectory(for: URL(fileURLWithPath: "/nonexistent/Nope.app"))
        #expect(dir.path == URL(fileURLWithPath: NSTemporaryDirectory()).path)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter CueChannelTests`
Expected: compile failure.

- [ ] **Step 3: Extract the container lookup in `Capture.swift`**

Replace `readyFileURL(for:)` with:

```swift
    /// Where appshot and the app exchange files: inside the app's sandbox container
    /// when it has one, because a sandboxed app — which is every App Store app, the
    /// exact audience for this tool — cannot write to `/tmp`. It *can* use its own
    /// container by absolute path, and appshot is not sandboxed, so it can read and
    /// write there from outside. An unsandboxed app gets the ordinary temporary
    /// directory. The ready file, the cue file and the event file all live here.
    static func handshakeDirectory(for app: URL) -> URL {
        guard
            let bundleID = Bundle(url: app)?.bundleIdentifier,
            case let container = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers/\(bundleID)/Data/tmp"),
            FileManager.default.fileExists(atPath: container.path)
        else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return container
    }

    /// Where the app should write its ready marker.
    static func readyFileURL(for app: URL) -> URL {
        handshakeDirectory(for: app).appending(path: "appshot-ready-\(UUID().uuidString)")
    }
```

- [ ] **Step 4: Implement the channel**

`Sources/AppShotKit/CueChannel.swift`:

```swift
import Foundation

/// One cue, as appshot appends it to the cue file at its scheduled time.
public struct CueLine: Codable, Sendable, Equatable {
    public var seq: Int
    public var t: Double
    public var cue: String
    public var args: [String: Config.CueValue]

    public init(seq: Int, t: Double, cue: String, args: [String: Config.CueValue]) {
        self.seq = seq
        self.t = t
        self.cue = cue
        self.args = args
    }
}

/// One line the app appends to the event file.
///
/// `kind` stays a string: an app on a newer contract may send kinds this appshot does
/// not know, and the recorder decides what an unknown kind means, not the decoder.
public struct AppEvent: Codable, Sendable, Equatable {
    /// `ready`, `ack`, `target` or `unknown`.
    public var kind: String
    public var seq: Int?
    public var name: String?
    /// Global screen points, top-left origin.
    public var rect: [Double]?
    public var cue: String?
}

public enum CuePolicy {
    public static let warnLatency = 0.05
    public static let failLatency = 0.25
    public static let ackTimeout = 1.0
}

/// The two JSON-lines files appshot and the app talk through.
///
/// Files, not a socket or a notification: the ready file already proved that this is
/// the one channel that crosses the Mac sandbox and the simulator alike.
public final class CueChannel {
    public let cueFile: URL
    public let eventFile: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(directory: URL) throws {
        let id = UUID().uuidString
        cueFile = directory.appending(path: "appshot-cues-\(id).jsonl")
        eventFile = directory.appending(path: "appshot-events-\(id).jsonl")
        // Both exist before launch: the app opens the cue file to watch it, and a
        // sandboxed app can append to an existing file in its container.
        guard FileManager.default.createFile(atPath: cueFile.path, contents: nil),
            FileManager.default.createFile(atPath: eventFile.path, contents: nil)
        else { throw AppShotError.recordFailed(video: "", reason: "cannot create the cue files in \(directory.path)") }
    }

    public func send(_ line: CueLine) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let handle = try FileHandle(forWritingTo: cueFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try encoder.encode(line) + Data("\n".utf8))
    }

    /// New complete lines since the last poll. A line still being written stays
    /// buffered until its newline arrives.
    public func poll() throws -> [AppEvent] {
        let handle = try FileHandle(forReadingFrom: eventFile)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        offset += UInt64(data.count)
        partial += data

        var events: [AppEvent] = []
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial = Data(partial[partial.index(after: newline)...])
            guard !line.isEmpty else { continue }
            do {
                events.append(try JSONDecoder().decode(AppEvent.self, from: Data(line)))
            } catch {
                throw AppShotError.recordFailed(
                    video: "", reason: "the app wrote a line that is not an event: \(String(decoding: line, as: UTF8.self))")
            }
        }
        return events
    }

    public func remove() {
        try? FileManager.default.removeItem(at: cueFile)
        try? FileManager.default.removeItem(at: eventFile)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter CueChannelTests && swift test --filter CaptureTests`
Expected: PASS. CaptureTests still passes, which shows the ready file is unchanged.

- [ ] **Step 6: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/CueChannel.swift Sources/AppShotKit/Capture.swift Tests/AppShotKitTests/CueChannelTests.swift
git commit -m "feat(video): exchange cues and events with the app through container files"
```

---

### Task 10: The fixture app learns cues

**Files:**
- Create: `Sources/AppShotFixture/VideoFixture.swift`
- Modify: `Sources/AppShotFixture/main.swift:212` (branch to the video fixture before parsing `Stage`)

**Interfaces:**
- Consumes: the cue and event line formats (Task 9). The fixture deliberately doesn't import AppShotKit: it speaks the file contract the way a real app would.
- Produces: stage `video`. One window, 900x600 points at a fixed origin, six rows named `row-0`…`row-5`. Cues: `pointer.move` and `pointer.click` (`target`: a row name), `stage` (`to: "alt"` relabels the rows), `fixture.flash` (toggles the header color). Anything else gets an `unknown` event.

- [ ] **Step 1: Write the fixture**

`Sources/AppShotFixture/VideoFixture.swift`:

```swift
import AppKit

/// The `video` stage: an app that speaks the cue contract the way a real app's demo
/// seed would, so `appshot record` can be exercised without borrowing a product.
///
/// Every effect is acknowledged one runloop turn *after* it is drawn, as the contract
/// asks: an ack written before the frame commits is an ack that lies.
@MainActor
final class VideoFixture: NSObject, NSApplicationDelegate {
    final class RowsView: NSView {
        var highlighted: Int?
        var flashed = false
        var alt = false
        override var isFlipped: Bool { true }

        func rowRect(_ i: Int) -> NSRect { NSRect(x: 32, y: 104 + Double(i) * 64, width: bounds.width - 64, height: 48) }

        override func draw(_ dirty: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            (flashed ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 72).fill()
            for i in 0..<6 {
                (highlighted == i ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(roundedRect: rowRect(i), xRadius: 8, yRadius: 8).fill()
                let label = (alt ? "Alt row \(i)" : "Row \(i)") as NSString
                label.draw(at: NSPoint(x: rowRect(i).minX + 16, y: rowRect(i).minY + 14),
                           withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor])
            }
        }
    }

    let cueFile: String?
    let eventFile: String?
    var window: NSWindow?
    let view = RowsView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    var offset: UInt64 = 0
    var buffer = Data()

    init(cueFile: String?, eventFile: String?) {
        self.cueFile = cueFile
        self.eventFile = eventFile
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "appshot fixture — video"
        window.contentView = view
        // A fixed place, as a demo seed pins its windows, so takes are comparable.
        window.setFrameTopLeftPoint(NSPoint(x: 200, y: (NSScreen.main?.frame.maxY ?? 1000) - 160))
        window.orderFrontRegardless()
        self.window = window
        if UserDefaults.standard.string(forKey: "ScreenshotActivation") != "none" {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { self.emit(["kind": "ready"]) }
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { self.readCues() }
        }
    }

    func readCues() {
        guard let cueFile, let handle = FileHandle(forReadingAtPath: cueFile) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        buffer += data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let cue = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let seq = cue["seq"] as? Int, let name = cue["cue"] as? String
            else { continue }
            handle(seq: seq, cue: name, args: cue["args"] as? [String: Any] ?? [:])
        }
    }

    func handle(seq: Int, cue: String, args: [String: Any]) {
        switch cue {
        case "pointer.move", "pointer.click":
            guard let target = args["target"] as? String, target.hasPrefix("row-"),
                let i = Int(target.dropFirst(4)), (0..<6).contains(i), let window
            else { return emit(["kind": "unknown", "seq": seq, "cue": cue]) }
            // Global screen points, top-left origin: the CGWindowList convention appshot uses.
            let inWindow = view.convert(view.rowRect(i), to: nil)
            let onScreen = window.convertToScreen(inWindow)
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - onScreen.maxY
            emit(["kind": "target", "seq": seq, "name": target,
                  "rect": [onScreen.minX, top, onScreen.width, onScreen.height]])
            if cue == "pointer.click" { view.highlighted = i }
        case "stage":
            view.alt = (args["to"] as? String) == "alt"
        case "fixture.flash":
            view.flashed.toggle()
        default:
            return emit(["kind": "unknown", "seq": seq, "cue": cue])
        }
        view.needsDisplay = true
        view.displayIfNeeded()
        DispatchQueue.main.async { self.emit(["kind": "ack", "seq": seq]) }
    }

    func emit(_ event: [String: Any]) {
        guard let eventFile, let handle = FileHandle(forWritingAtPath: eventFile),
            let data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
```

- [ ] **Step 2: Branch to it in `main.swift`**

In `Sources/AppShotFixture/main.swift`, insert before `let stage = Stage(rawValue: …)`:

```swift
if UserDefaults.standard.string(forKey: "ScreenshotStage") == "video" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.appearance = NSAppearance(
        named: UserDefaults.standard.string(forKey: "ScreenshotAppearance") == "light" ? .aqua : .darkAqua)
    let fixture = MainActor.assumeIsolated {
        VideoFixture(
            cueFile: UserDefaults.standard.string(forKey: "ScreenshotCueFile"),
            eventFile: UserDefaults.standard.string(forKey: "ScreenshotEventFile"))
    }
    app.delegate = fixture
    app.run()
    exit(0)
}
```

Update the doc comment at the top of `main.swift` to list the `video` stage.

- [ ] **Step 3: Check it by hand**

```bash
make fixture
D=$(mktemp -d); : > "$D/cues"; : > "$D/events"
open -gn .build/fixture/AppShotFixture.app --args -ScreenshotStage video -ScreenshotActivation none \
  -ScreenshotCueFile "$D/cues" -ScreenshotEventFile "$D/events"
sleep 2
printf '%s\n' '{"seq":0,"t":0,"cue":"pointer.click","args":{"target":"row-2"}}' '{"seq":1,"t":0,"cue":"nope","args":{}}' >> "$D/cues"
sleep 1; cat "$D/events"; pkill -x AppShotFixture
```

Expected: `{"kind":"ready"}`, then a `target` for `row-2` with a rect, `{"kind":"ack","seq":0}`, and `{"kind":"unknown","seq":1,"cue":"nope"}`.

- [ ] **Step 4: Commit**

```bash
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotFixture/VideoFixture.swift Sources/AppShotFixture/main.swift
git commit -m "feat(fixture): add a video stage that speaks the cue contract"
```

---

### Task 11: `appshot record` on macOS

**Files:**
- Create: `Sources/AppShotKit/StreamRecorder.swift`
- Create: `Sources/AppShotKit/Recorder.swift`
- Modify: `Sources/AppShotKit/Capture.swift`: change `private` to internal on `pids(named:)`, `waitForNewPID(named:excluding:)`, `waitForWindow(pid:)`, `terminate(_:)`, `clearColor`, `backingScale`
- Modify: `Sources/appshot/VideoCommands.swift` (add `Record`), `Sources/appshot/AppShot.swift` (register `Record.self` in `subcommands`)
- Create: `Scripts/fixture-video.config.json`
- Modify: `Makefile` (add `bench-record`)
- Test: `Tests/AppShotKitTests/RecorderTests.swift` (unit), `Tests/AppShotKitTests/RecorderIntegrationTests.swift` (gated)

**Interfaces:**
- Consumes: `CueChannel`, `CueLine`, `AppEvent`, `CuePolicy`, `Capture.handshakeDirectory` (Task 9); `VideoTrack` (Task 2); `Capture.openArguments`, `Capture.Options`, `Capture.Screen`, `CaptureLock`, `Interrupt`, `Window.windows(pid:)`, `Window.base(pid:)` (existing).
- Produces:
  - `enum Recorder { struct Options; struct Take { video: String; appearance: String; master: URL; track: URL; warnings: [String] }; static func run(_ options: Options, progress: (Take) -> Void) async throws -> [Take] }`
  - `static func cueLines(for video: Config.Video) -> [(seq: Int, beat: Int, line: CueLine)]` (pure)
  - `static func judge(sent: [Int: Double], acked: [Int: Double], now: Double, lines: [(seq: Int, beat: Int, line: CueLine)], video: String) throws -> [String]` (pure: throws on timeout or failing latency, returns warnings)
  - `static func stageCrop(windows: [CGRect], display: CGRect, scale: Double) -> [Double]` (pure)

- [ ] **Step 1: Write the failing unit tests (pure parts)**

`Tests/AppShotKitTests/RecorderTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct RecorderTests {
    static func video() throws -> Config.Video {
        try VideoConfigTests.config(videos: """
            [{ "id": "v", "stage": "video", "duration": 4, "outputs": { "promo": [[100, 100]] },
               "beats": [{ "at": 0, "caption": "a" }, { "at": 1, "cue": "pointer.click", "args": { "target": "row-2" } },
                         { "at": 2, "cue": "fixture.flash" }] }]
            """).video("v")
    }

    @Test func onlyBeatsWithACueBecomeLines() throws {
        let lines = Recorder.cueLines(for: try Self.video())
        #expect(lines.map(\.seq) == [0, 1])
        #expect(lines.map(\.beat) == [1, 2])
        #expect(lines[0].line.args["target"] == .string("row-2"))
    }

    @Test func lateAckWarnsThenFails() throws {
        let lines = Recorder.cueLines(for: try Self.video())
        let warnings = try Recorder.judge(sent: [0: 1], acked: [0: 1.1], now: 1.2, lines: lines, video: "v")
        #expect(warnings.count == 1)
        #expect(throws: AppShotError.self) {
            try Recorder.judge(sent: [0: 1], acked: [0: 1.3], now: 1.4, lines: lines, video: "v")
        }
    }

    @Test func missingAckFailsAfterTheTimeout() throws {
        let lines = Recorder.cueLines(for: try Self.video())
        _ = try Recorder.judge(sent: [0: 1], acked: [:], now: 1.9, lines: lines, video: "v")
        #expect {
            try Recorder.judge(sent: [0: 1], acked: [:], now: 2.01, lines: lines, video: "v")
        } throws: { error in
            guard case .cueFailed(_, let seq, let cue, _) = error as? AppShotError else { return false }
            return seq == 0 && cue == "pointer.click"
        }
    }

    @Test func stageCropIsTheWindowUnionInDisplayPixels() {
        let crop = Recorder.stageCrop(
            windows: [CGRect(x: 110, y: 60, width: 100, height: 50), CGRect(x: 150, y: 80, width: 100, height: 50)],
            display: CGRect(x: 100, y: 50, width: 1000, height: 800), scale: 2)
        #expect(crop == [20, 20, 280, 140])
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter RecorderTests`
Expected: compile failure, "cannot find 'Recorder' in scope".

- [ ] **Step 3: Widen the capture helpers**

In `Sources/AppShotKit/Capture.swift`, remove `private` from: `static func pids(named:)`, `static func waitForNewPID(named:excluding:)`, `static func waitForWindow(pid:)`, `static func terminate(_:)`, `static let clearColor`, `static var backingScale`. No behavior change.

- [ ] **Step 4: Implement the stream recorder**

`Sources/AppShotKit/StreamRecorder.swift`:

```swift
import AVFoundation
import ScreenCaptureKit

/// SCStream frames → an HEVC-with-alpha `.mov`, kept as the master.
///
/// HEVC with alpha rather than ProRes 4444: the same transparency at roughly a
/// hundredth of the size, hardware-encoded. A 24s Retina take in ProRes 4444 runs to
/// several gigabytes.
final class StreamRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var firstFrame: CheckedContinuation<Void, Never>?
    private(set) var frames = 0
    private(set) var maxGap = 0.0

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw AppShotError.recordFailed(video: "", reason: "\(writer.error.map { "\($0)" } ?? "writer did not start")")
        }
    }

    /// Resumes once the first complete frame is written: that instant is t = 0.
    func waitForFirstFrame() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if firstPTS != nil {
                lock.unlock()
                continuation.resume()
            } else {
                firstFrame = continuation
                lock.unlock()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, Self.isComplete(sample) else { return }
        let pts = sample.presentationTimeStamp
        lock.lock()
        var resume: CheckedContinuation<Void, Never>?
        if firstPTS == nil {
            firstPTS = pts
            writer.startSession(atSourceTime: pts)
            resume = firstFrame
            firstFrame = nil
        }
        if let last = lastPTS { maxGap = max(maxGap, (pts - last).seconds) }
        lastPTS = pts
        if input.isReadyForMoreMediaData, input.append(sample) { frames += 1 }
        lock.unlock()
        resume?.resume()
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AppShotError.recordFailed(video: "", reason: "master: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
    }

    /// SCStream also delivers idle and blank frames; only complete ones are pictures.
    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
```

- [ ] **Step 5: Implement the recorder**

`Sources/AppShotKit/Recorder.swift`:

```swift
import AppKit
import ScreenCaptureKit

/// One take per video × appearance: launch the app staged, record its windows, play the
/// cues on appshot's clock, and write the master and the track.
///
/// Nothing is clicked or typed. The pointer is drawn later from what the app reports,
/// so a take never touches the input of whoever is using the Mac.
public enum Recorder {
    public struct Options: Sendable {
        /// Reused for the app, appearances, launch arguments, `--no-activate`, the lock and
        /// `settleMax` (the ceiling on waiting for `ready`).
        public var capture: Capture.Options
        public var videos: [Config.Video]
        public var cueArg: String
        public var eventArg: String

        public init(
            capture: Capture.Options, videos: [Config.Video],
            cueArg: String = "-ScreenshotCueFile", eventArg: String = "-ScreenshotEventFile"
        ) {
            self.capture = capture
            self.videos = videos
            self.cueArg = cueArg
            self.eventArg = eventArg
        }
    }

    public struct Take: Sendable {
        public let video: String
        public let appearance: String
        public let master: URL
        public let track: URL
        public let warnings: [String]
    }

    public static func cueLines(for video: Config.Video) -> [(seq: Int, beat: Int, line: CueLine)] {
        video.beats.enumerated()
            .compactMap { index, beat in beat.cue.map { (index, beat, $0) } }
            .enumerated()
            .map { seq, item in
                (seq, item.0, CueLine(seq: seq, t: item.1.at, cue: item.2, args: item.1.args ?? [:]))
            }
    }

    /// Throws on a cue never acknowledged within `ackTimeout`, or acknowledged later than
    /// `failLatency`; returns a warning per ack later than `warnLatency`.
    public static func judge(
        sent: [Int: Double], acked: [Int: Double], now: Double,
        lines: [(seq: Int, beat: Int, line: CueLine)], video: String
    ) throws -> [String] {
        var warnings: [String] = []
        for item in lines {
            guard let s = sent[item.seq] else { continue }
            guard let a = acked[item.seq] else {
                if now - s > CuePolicy.ackTimeout {
                    throw AppShotError.cueFailed(
                        video: video, seq: item.seq, cue: item.line.cue,
                        reason: "no ack within \(CuePolicy.ackTimeout)s. The app received it and did nothing, or does not watch the cue file")
                }
                continue
            }
            let latency = a - item.line.t
            if latency > CuePolicy.failLatency {
                throw AppShotError.cueFailed(
                    video: video, seq: item.seq, cue: item.line.cue,
                    reason: "acked \(Int(latency * 1000))ms after its time; the limit is \(Int(CuePolicy.failLatency * 1000))ms")
            }
            if latency > CuePolicy.warnLatency {
                warnings.append("cue #\(item.seq) \(item.line.cue) acked \(Int(latency * 1000))ms late")
            }
        }
        return warnings
    }

    /// The union of every window the app showed, in master pixels relative to the display.
    public static func stageCrop(windows: [CGRect], display: CGRect, scale: Double) -> [Double] {
        guard let first = windows.first else { return [0, 0, display.width * scale, display.height * scale] }
        let union = windows.dropFirst().reduce(first) { $0.union($1) }
        return [
            ((union.minX - display.minX) * scale).rounded(), ((union.minY - display.minY) * scale).rounded(),
            (union.width * scale).rounded(), (union.height * scale).rounded(),
        ]
    }

    public static func run(_ options: Options, progress: (Take) -> Void = { _ in }) async throws -> [Take] {
        let app = options.capture.app
        guard FileManager.default.fileExists(atPath: app.path) else { throw AppShotError.appNotFound(app) }
        guard Capture.hasScreenRecordingPermission() else { throw AppShotError.screenRecordingDenied }
        try FileManager.default.createDirectory(at: options.capture.outDir, withIntermediateDirectories: true)

        let appName = app.deletingPathExtension().lastPathComponent
        let holder = CaptureLock.Holder.current(
            app: appName, appPath: app.path, shots: options.videos.count * options.capture.appearances.count)
        let lock = try await CaptureLock.acquire(
            holder, root: options.capture.lockRoot, wait: options.capture.wait, timeout: options.capture.waitTimeout)
        defer { lock.release() }

        var takes: [Take] = []
        for video in options.videos {
            for appearance in options.capture.appearances {
                let take = try await record(video: video, appearance: appearance, appName: appName, options: options)
                takes.append(take)
                progress(take)
            }
        }
        return takes
    }

    static func record(
        video: Config.Video, appearance: String, appName: String, options: Options
    ) async throws -> Take {
        guard let stage = video.stage else {
            throw AppShotError.invalidVideo(id: video.id, reason: "record needs `stage`, the -ScreenshotStage to launch")
        }
        let name = "\(video.id)~\(appearance)"
        let masterURL = options.capture.outDir.appending(path: "\(name).mov")
        let partial = masterURL.appendingPathExtension("partial")
        let channel = try CueChannel(directory: Capture.handshakeDirectory(for: options.capture.app))

        // Kill what we launched and drop the half-written master however we leave,
        // Ctrl-C included.
        let before = Capture.pids(named: appName)
        let cleanup: @Sendable () -> Void = {
            for pid in Capture.pids(named: appName).subtracting(before) { Capture.terminate(pid) }
            try? FileManager.default.removeItem(at: partial)
            channel.remove()
        }
        let interrupted = Interrupt.onInterrupt(cleanup)
        defer {
            Interrupt.remove(interrupted)
            cleanup()
        }

        var args = Capture.openArguments(
            screen: Capture.Screen(name: video.id, stage: stage), appearance: appearance, readyFile: nil,
            display: options.capture.captureDisplay.resolve(), options: options.capture)
        args += [options.cueArg, channel.cueFile.path, options.eventArg, channel.eventFile.path]
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = args
        try open.run()
        open.waitUntilExit()

        guard let pid = try await Capture.waitForNewPID(named: appName, excluding: before) else {
            throw AppShotError.appNeverStarted(screen: name)
        }
        guard let base = try await Capture.waitForWindow(pid: pid) else {
            throw AppShotError.recordFailed(video: video.id, reason: "the app showed no window")
        }

        // `ready` before anything is recorded: t = 0 must be a finished first screen.
        let readyDeadline = Date().addingTimeInterval(options.capture.settleMax)
        var ready = false
        while !ready {
            ready = try channel.poll().contains { $0.kind == "ready" }
            if ready { break }
            guard Date() < readyDeadline else {
                throw AppShotError.recordFailed(
                    video: video.id, reason: "no ready event within \(options.capture.settleMax)s; does the app read \(options.eventArg)?")
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(base.bounds) }) ?? content.displays.first
        else { throw AppShotError.recordFailed(video: video.id, reason: "no display") }
        let scale = Capture.backingScale
        let config = SCStreamConfiguration()
        config.width = Int((display.frame.width * scale).rounded())
        config.height = Int((display.frame.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.backgroundColor = Capture.clearColor
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6

        func appWindows() -> [Window.Info] { Window.windows(pid: pid).filter { $0.bounds.width > 1 && $0.bounds.height > 1 } }
        var ids = Set(appWindows().map(\.id))
        var seen = appWindows().map(\.bounds)
        func filter(_ content: SCShareableContent) -> SCContentFilter {
            SCContentFilter(display: display, including: content.windows.filter { ids.contains($0.windowID) })
        }

        let recorder = try StreamRecorder(url: partial, width: config.width, height: config.height)
        let stream = SCStream(filter: filter(content), configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "appshot.record"))
        try await stream.startCapture()
        await recorder.waitForFirstFrame()

        let clock = ContinuousClock()
        let t0 = clock.now
        func now() -> Double {
            let d = clock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        let lines = cueLines(for: video)
        var pending = lines[...]
        var sent: [Int: Double] = [:]
        var acked: [Int: Double] = [:]
        var targets: [(seq: Int, name: String, rect: [Double])] = []
        var warnings: [String] = []
        var lastWindowCheck = 0.0

        while now() < video.duration {
            let t = now()
            while let next = pending.first, next.line.t <= t {
                try channel.send(next.line)
                sent[next.seq] = t
                pending = pending.dropFirst()
            }
            for event in try channel.poll() {
                switch event.kind {
                case "ack": if let seq = event.seq { acked[seq] = now() }
                case "target":
                    if let seq = event.seq, let name = event.name, let rect = event.rect, rect.count == 4 {
                        targets.append((seq, name, rect))
                    }
                case "unknown":
                    throw AppShotError.cueFailed(
                        video: video.id, seq: event.seq ?? -1, cue: event.cue ?? "?",
                        reason: "the app does not implement it")
                default: continue
                }
            }
            warnings = try judge(sent: sent, acked: acked, now: now(), lines: lines, video: video.id)
            if t - lastWindowCheck >= 0.25 {
                lastWindowCheck = t
                let current = appWindows()
                seen += current.map(\.bounds)
                let currentIDs = Set(current.map(\.id))
                if currentIDs != ids {
                    ids = currentIDs
                    let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    try await stream.updateContentFilter(filter(refreshed))
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        try await stream.stopCapture()
        try await recorder.finish()

        let crop = stageCrop(windows: seen, display: display.frame, scale: scale)
        let clicks = Set(lines.filter { $0.line.cue == "pointer.click" }.map(\.seq))
        let track = VideoTrack(
            video: video.id, appearance: appearance, duration: video.duration, stage: crop,
            beats: video.beats.indices.map { index in
                let line = lines.first { $0.beat == index }
                return .init(index: index, scheduled: video.beats[index].at, acked: line.flatMap { acked[$0.seq] })
            },
            targets: targets.compactMap { target in
                guard let line = lines.first(where: { $0.seq == target.seq }) else { return nil }
                // Global points → master pixels → stage pixels.
                let x = (target.rect[0] - display.frame.minX) * scale - crop[0]
                let y = (target.rect[1] - display.frame.minY) * scale - crop[1]
                return .init(seq: target.seq, name: target.name, at: line.line.t,
                             rect: [x, y, target.rect[2] * scale, target.rect[3] * scale],
                             click: clicks.contains(target.seq))
            },
            frames: recorder.frames, maxFrameGap: recorder.maxGap)

        try? FileManager.default.removeItem(at: masterURL)
        try FileManager.default.moveItem(at: partial, to: masterURL)
        let trackURL = VideoTrack.url(in: options.capture.outDir, video: video.id, appearance: appearance)
        try track.write(to: trackURL)
        return Take(video: video.id, appearance: appearance, master: masterURL, track: trackURL, warnings: warnings)
    }
}
```

Notes for the implementer:
- `CaptureLock.acquire(_:root:wait:timeout:onWait:)` is at `Lock.swift:129`; `onWait` defaults to a no-op.
- `Capture.Screen(name:stage:)` is the public init at `Capture.swift:48`.
- `options.capture.captureDisplay.resolve()` is what `launch` uses; keep it.
- The capture lock covers the whole take, because a take needs the screen for its full duration.

- [ ] **Step 6: Run the unit tests**

Run: `swift test --filter RecorderTests`
Expected: PASS.

- [ ] **Step 7: Add the CLI command**

Append to `Sources/appshot/VideoCommands.swift`:

```swift
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record scripted videos of the app (macOS). Nothing is clicked or typed.")

    @OptionGroup var cfg: ConfigOption

    @Option(help: "The .app to record.")
    var app: String

    @Option(help: "Where masters and tracks go.")
    var out: String = Defaults.videoSource

    @Option(parsing: .upToNextOption, help: "Only these videos[] ids. Omitted ⇒ all.")
    var videos: [String] = []

    @Option(help: "Comma-separated appearances. Omitted ⇒ the config's.")
    var appearances: String?

    @Option(help: "Extra launch arguments, as one string: --extra-args=\"-ScreenshotMode YES\".")
    var extraArgs: String = ""

    @Flag(help: "Launch and keep the app in the background; you can keep working during a take.")
    var noActivate = false

    @Flag(help: "Wait for another project's capture to finish instead of failing.")
    var wait = false

    @Option(help: "Seconds to wait for the app's ready event.")
    var settleMax: Double = Defaults.settleMax

    func run() async throws {
        let config = try cfg.load()
        let chosen = try (videos.isEmpty ? (config.videos ?? []).map(\.id) : videos).map { try config.video($0) }
        let capture = Capture.Options(
            app: URL(fileURLWithPath: app), outDir: URL(fileURLWithPath: out), partial: true,
            screens: [], appearances: appearances.map(Pipeline.appearances(from:)) ?? config.appearances,
            extraArgs: LaunchArguments.split(extraArgs), settleMax: settleMax, wait: wait, noActivate: noActivate)
        let takes = try await Recorder.run(Recorder.Options(capture: capture, videos: chosen)) { take in
            print("  \(take.video)~\(take.appearance)  \(take.master.lastPathComponent)")
            for warning in take.warnings { print("    warning: \(warning)") }
        }
        print("recorded \(takes.count) take(s) → \(out). Next: appshot compose video --source \(out)")
    }
}
```

Register it in `AppShot.configuration.subcommands`, after `CaptureCommand.self`: `Record.self,`.

- [ ] **Step 8: Add the bench config and target**

`Scripts/fixture-video.config.json`:

```json
{
  "//": "Drives `make bench-record`: a 6s take of the fixture's video stage, composed into a promo.",
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
  "screens": [{ "id": "video", "title": "Fixture" }],
  "videos": [{
    "id": "fixture", "stage": "video", "duration": 6,
    "outputs": { "promo": [[1080, 1080]] },
    "card": { "title": "appshot", "subtitle": "fixture" },
    "beats": [
      { "at": 0, "caption": "Six rows" },
      { "at": 0.8, "cue": "pointer.move", "args": { "target": "row-1" } },
      { "at": 1.6, "cue": "pointer.click", "args": { "target": "row-3" }, "caption": "Click one" },
      { "at": 2.0, "zoom": { "target": "row-3", "scale": 1.8 } },
      { "at": 3.6, "cue": "fixture.flash" },
      { "at": 4.0, "zoom": { "scale": 1 } },
      { "at": 4.2, "cue": "stage", "args": { "to": "alt" } },
      { "at": 5.0, "endCard": true }
    ]
  }]
}
```

In `Makefile`, add `bench-record` to `.PHONY` and:

```make
# Not CI, for the same reasons as bench: Screen Recording and a window server. Records
# the fixture's video stage and composes it, so the whole video path runs on one command.
bench-record: fixture ## Record the fixture app and compose the promo
	@swift build -c release --product appshot >&2
	.build/release/appshot record --app .build/fixture/AppShotFixture.app \
	  --config Scripts/fixture-video.config.json --out .build/fixture/videos/source --no-activate
	.build/release/appshot compose video --config Scripts/fixture-video.config.json \
	  --source .build/fixture/videos/source --out .build/fixture/videos
```

- [ ] **Step 9: Write the gated integration test**

`Tests/AppShotKitTests/RecorderIntegrationTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Needs Screen Recording for the test runner and `make fixture` first. Never on CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["APPSHOT_INTEGRATION"] == "1"))
struct RecorderIntegrationTests {
    static let app = URL(fileURLWithPath: ".build/fixture/AppShotFixture.app")

    @Test func recordsTheFixtureWithEveryCueAcked() async throws {
        let config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-video.config.json"))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(app: Self.app, outDir: out, screens: [], appearances: ["dark"], noActivate: true),
            videos: [try config.video("fixture")])
        let takes = try await Recorder.run(options)
        let track = try VideoTrack.read(try #require(takes.first).track)
        let cued = track.beats.filter { config.videos![0].beats[$0.index].cue != nil }
        #expect(cued.allSatisfy { $0.acked != nil })
        #expect(cued.allSatisfy { ($0.acked ?? 9) - $0.scheduled < CuePolicy.failLatency })
        #expect(track.targets.contains { $0.name == "row-3" && $0.click })
        var master = try RecordedMaster(url: try #require(takes.first).master, track: track)
        let frame = try master.frame(at: 0.2)
        let px = try #require(Image.pixels(frame))
        // A window corner is transparent; the window's middle is not.
        #expect(px.bytes[3] == 0)
        #expect(px.bytes[((frame.height / 2) * frame.width + frame.width / 2) * 4 + 3] == 255)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov.partial").path))
    }

    @Test func unknownCueFailsAndLeavesNothingRunning() async throws {
        var config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-video.config.json"))
        config.videos![0].beats.insert(.init(at: 0.5, cue: "no.such.cue"), at: 1)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(app: Self.app, outDir: out, screens: [], appearances: ["dark"], noActivate: true),
            videos: [config.videos![0]])
        await #expect {
            _ = try await Recorder.run(options)
        } throws: { error in
            guard case .cueFailed(_, _, let cue, _) = error as? AppShotError else { return false }
            return cue == "no.such.cue"
        }
        #expect(Capture.pids(named: "AppShotFixture").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov").path))
    }
}
```

`Config.Beat` needs a memberwise init with defaults for `.init(at:cue:)` to compile. Add to `Config.Beat` in `VideoConfig.swift`:

```swift
        public init(
            at: Double, cue: String? = nil, args: [String: CueValue]? = nil, caption: String? = nil,
            until: Double? = nil, zoom: Zoom? = nil, endCard: Bool? = nil, screen: String? = nil
        ) {
            self.at = at
            self.cue = cue
            self.args = args
            self.caption = caption
            self.until = until
            self.zoom = zoom
            self.endCard = endCard
            self.screen = screen
        }
```

- [ ] **Step 10: Run the integration tests and the bench**

```bash
make fixture
APPSHOT_INTEGRATION=1 swift test --filter RecorderIntegrationTests
make bench-record
```

Expected: both integration tests PASS. `make bench-record` prints one take and then the promo path. Open `.build/fixture/videos/report/fixture~dark.contact.png` and check that the green highlighted row, the zoom and the end card are all there.

- [ ] **Step 11: Run the whole suite and lint, then commit**

```bash
swift test
swift format lint --strict --recursive Sources Tests
git add Sources/AppShotKit/StreamRecorder.swift Sources/AppShotKit/Recorder.swift Sources/AppShotKit/Capture.swift Sources/AppShotKit/VideoConfig.swift Sources/appshot/VideoCommands.swift Sources/appshot/AppShot.swift Scripts/fixture-video.config.json Makefile Tests/AppShotKitTests/RecorderTests.swift Tests/AppShotKitTests/RecorderIntegrationTests.swift
git commit -m "feat(video): add appshot record for macOS"
```

---

### Task 12: Documentation

**Files:**
- Modify: `README.md` (new "Videos" section after "The pipeline")
- Modify: `CHANGELOG.md` (`## [Unreleased]` → `### Added`)

- [ ] **Step 1: README section**

Add after "## The pipeline":

````markdown
## Videos

`appshot record` films the app running a script, and `appshot compose video` turns the
take into App Store previews and promos. Nothing is clicked or typed: appshot writes
named **cues** to a file in the app's container, the app's demo mode performs them and
reports back, and the pointer is drawn afterwards from what the app reported.

```sh
appshot record --app build/MyApp.app --config screenshots/screenshots.config.json \
  --appearances dark --no-activate
appshot compose video --config screenshots/screenshots.config.json \
  --website-out ../site/src/assets/videos

# No cue code yet? Build the same video from the screenshot captures:
appshot compose video --config screenshots/screenshots.config.json \
  --from-stills screenshots/source
```

Each run writes `videos/report/<id>~<appearance>.contact.png`, one labeled frame per
beat, and a `.report.json` with cue latency and every caption's reading margin. Read
those instead of watching the video.

The app's side of the contract: launched with `-ScreenshotCueFile <path>` and
`-ScreenshotEventFile <path>`, it appends `{"kind":"ready"}` once staged, watches the
cue file for `{"seq","t","cue","args"}` lines, and answers each with
`{"kind":"ack","seq":n}` one runloop turn after the effect is drawn. Pointer cues
also get `{"kind":"target","seq":n,"name":…,"rect":[x,y,w,h]}` in global screen points
(top-left origin), and unimplemented cues get `{"kind":"unknown","seq":n,"cue":…}`.
Shared cue names: `stage`, `pointer.move`, `pointer.click`, `scroll`.
`Sources/AppShotFixture/VideoFixture.swift` is a complete, small implementation.

The design and Apple's preview limits are in
`docs/superpowers/specs/2026-10-03-appshot-video-design.md`.
````

- [ ] **Step 2: CHANGELOG entries**

Under `## [Unreleased]` → `### Added`:

```markdown
- **`appshot record`** films a macOS app running a scripted `videos[]` entry, with no
  synthetic input: cues go to the app through a file in its container, and the app
  reports back through another. Output is an HEVC-with-alpha master and a track of
  what actually happened.
- **`appshot compose video`** renders App Store previews (1920x1080, 15-30 s, H.264 with
  a silent stereo track) and framed promos at any even size, with captions, a drawn
  pointer, zoom and an end card. A caption too short to read fails the render before
  anything is written.
- **`compose video --from-stills`** builds the same video from screenshot captures, so
  any app can have a promo before it implements a single cue.
- Every video run writes a contact sheet and a JSON report, so an agent can review a
  video it cannot watch.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document record and compose video"
```

- [ ] **Step 4: Stop and ask before releasing**

Don't bump `AppShotVersion.current`, tag or push. Report to Olivier: tasks done, test results, the `make bench-record` contact sheet path. Ask whether to cut 0.20.0.
