# appshot video motion presets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `appshot compose video` a preset-driven motion layer. `kinetic` is the default and `studio` the calm alternative. Beats say what matters (`focus`, `spotlight`, `pop`, `pointer`, `present`, `hook`), and the preset decides how it moves.

**Architecture:** The pure, time-based logic grows into four files:

- `MotionPreset`: closed-form springs and the preset values.
- `KineticText`: accent marks, word layout and word entrances.
- `VideoCamera`: where the whole window sits on the canvas at time t.
- `VideoTimeline`: focus keys, spans, the pointer path and the hook.

`VideoFrame` draws the layers from those answers into a y-down `VideoCanvas`, and averages sub-frames during fast moves. `StillsMaster` gains the sheet present and swap transitions. `VideoCompose` gains `--motion`, renders each output on its own task, and reports the preset and its warnings.

**Tech Stack:** Swift 6, macOS 14 floor, CoreGraphics, CoreText, AVFoundation, Swift Testing, swift-format.

**Spec:** `docs/superpowers/specs/2026-10-04-appshot-video-motion-design.md`, read it first. A throwaway spike, since deleted, built these looks; every number in this plan comes from it.

## Global Constraints

- Swift 6 language mode, macOS 14 floor (`Package.swift`); no new dependencies.
- AppShotKit never prints and never exits; it returns values and throws `AppShotError`.
- Every new `AppShotError` case gets a `description` line and a `slug` line (`Sources/AppShotKit/AppShotError.swift`).
- Lint gate: `swift format lint --strict --recursive Sources Tests` must be clean (line length 110). Run `swift format --in-place --recursive Sources Tests` before linting.
- Tests: `swift test` (Swift Testing, `@Test`, `#expect`). The whole suite must pass at the end of every task.
- Renders are deterministic: no randomness, no wall clock, no frame-to-frame state. Every value is a function of `t`.
- `videos[]` has never been released. `zoom` is removed outright, with no alias.
- The hook holds the first 1.5 s whatever the preset (`MotionPreset.hookDuration`).
- Nothing drives the real Mac: no synthetic input, no clicks or keystrokes. `make bench-motion` launches with `--no-activate`.
- Never bump the version, tag, push or release appshot; count `git rev-list --count origin/main..main` before anything outward.
- Work on branch `video-motion` in worktree `~/Projects/appshot-motion`. When done, merge to `main` fast-forward only and delete the branch and worktree.
- Demo data only in any capture or video.

## Review Focus

1. **Light themes.** The band scrim must take the gradient stop that contrasts most with the caption color. A hard-coded dark scrim makes dark caption text unreadable on a light theme. *(Task 6 test `theScrimContrastsWithTheCaption`.)*
2. **A hook too long for the canvas.** A 40-word hook on a small promo must fail with "leaves no room for the app", not render a zero-height window or crash. *(Task 6 test `aHookTooLongForTheCanvasFailsClearly`.)*
3. **A pop region that runs past the stage edge.** It must draw the part inside the stage at the right place, never stretch a clipped crop over the full rect, and never throw. *(Task 7 test `aPopPastTheStageEdgeDrawsOnlyWhatExists`.)*
4. **`--motion` with several appearances.** Every output, report and contact sheet must get its own name, with nothing overwritten. *(Task 9 test `motionsAndAppearancesNeverCollide`.)*
5. **`present` on captures of different sizes.** The rect is in stage pixels, on the centered canvas, so the sheet lands on the smaller capture where it really is. *(Task 8 test `presentIsInStagePixelsOnTheCenteredCanvas`.)*

---

## Task 0: Workspace

**Files:** none.

- [ ] **Step 1: Remove the spike.** It is throwaway, and the spec keeps its lessons.

```bash
cd ~/Projects/appshot
git worktree remove --force ../appshot-spike
git branch -D spike/motion-presets
```

- [ ] **Step 2: Create the feature worktree**

```bash
cd ~/Projects/appshot
git status --short            # must be empty; stop and ask if not
git worktree add -b video-motion ../appshot-motion main
cd ../appshot-motion && swift build --build-tests 2>&1 | tail -1
```

Expected: `Build complete!`. All later paths are relative to `~/Projects/appshot-motion`.

---

## Task 1: Springs, easing and the presets

**Files:**
- Create: `Sources/AppShotKit/MotionPreset.swift`
- Test: `Tests/AppShotKitTests/MotionPresetTests.swift`

**Interfaces:**
- Produces:
  - `public struct Spring: Sendable, Equatable { response: Double; damping: Double; func value(_ t: Double) -> Double }`
  - `public enum Ease { static func clamp01(_:), smooth(_:), out(_:) -> Double }`
  - `public struct MotionPreset: Sendable, Equatable`, with the fields below plus `static let kinetic`, `static let studio`, `static let all`, `static let defaultName = "kinetic"`, `static let hookDuration = 1.5` and `static func named(_ name: String) -> MotionPreset?`.
  - Nested enums: `Captions { band, pill }`, `Pop { lift(scale: Double), outline }`, `Entry { riseAfterHook, fadeIn }`, `Exit { fall, shrinkFade }`, `Card { spring, fade }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing

@testable import AppShotKit

struct MotionPresetTests {
    @Test(arguments: [MotionPreset.kinetic.camera, MotionPreset.studio.camera, MotionPreset.kinetic.sheet])
    func aSpringStartsAtZeroAndSettlesAtOne(spring: Spring) {
        #expect(spring.value(-1) == 0)
        #expect(spring.value(0) == 0)
        #expect(abs(spring.value(spring.response * 5) - 1) < 0.001)
        #expect(spring.value(.infinity) == 1)
    }

    @Test func aCriticallyDampedSpringNeverOvershoots() {
        let spring = MotionPreset.studio.camera
        #expect(stride(from: 0.0, through: 5, by: 0.005).allSatisfy { spring.value($0) <= 1 })
    }

    @Test func kineticsCameraOvershoots() {
        let spring = MotionPreset.kinetic.camera
        #expect(stride(from: 0.0, through: 5, by: 0.005).contains { spring.value($0) > 1.001 })
    }

    @Test func easingIsClampedToItsRange() {
        #expect(Ease.smooth(-1) == 0 && Ease.smooth(2) == 1 && Ease.smooth(0.5) == 0.5)
        #expect(Ease.out(-1) == 0 && Ease.out(2) == 1 && Ease.out(0.5) > 0.5)
    }

    @Test func presetsAreFoundByName() {
        #expect(MotionPreset.named("kinetic") == .kinetic)
        #expect(MotionPreset.named("studio") == .studio)
        #expect(MotionPreset.named("keynote") == nil)
        #expect(MotionPreset.all.map(\.name) == ["kinetic", "studio"])
        #expect(MotionPreset.named(MotionPreset.defaultName) == .kinetic)
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter MotionPresetTests`
Expected: compile failure, `cannot find 'MotionPreset' in scope`.

- [ ] **Step 3: Implement `Sources/AppShotKit/MotionPreset.swift`**

```swift
import Foundation

/// A spring's step response, from 0 toward 1.
///
/// Closed form rather than simulated: a frame is a function of its time alone, so any
/// frame (a motion-blur sub-frame, a contact-sheet cell) can be drawn without replaying
/// the ones before it, and two renders of one frame are identical.
public struct Spring: Sendable, Equatable {
    /// Seconds per cycle of the undamped spring; the move is about 98% done after one.
    public var response: Double
    /// 1 settles without overshoot; below 1 overshoots and rings.
    public var damping: Double

    public init(response: Double, damping: Double) {
        self.response = response
        self.damping = damping
    }

    public func value(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t.isFinite else { return 1 }
        let w = 2 * Double.pi / response
        if damping >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
        let wd = w * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }
}

public enum Ease {
    public static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Slow in, slow out.
    public static func smooth(_ x: Double) -> Double {
        let c = clamp01(x)
        return c * c * (3 - 2 * c)
    }

    /// Fast in, slow out.
    public static func out(_ x: Double) -> Double {
        let c = clamp01(x)
        return 1 - pow(1 - c, 3)
    }
}

/// How a video moves. A preset only chooses among the drawing styles the renderer
/// knows, so a new preset made of existing styles is data, not code.
public struct MotionPreset: Sendable, Equatable {
    public enum Captions: Sendable, Equatable { case band, pill }
    public enum Pop: Sendable, Equatable {
        case lift(scale: Double)
        case outline
    }
    public enum Entry: Sendable, Equatable { case riseAfterHook, fadeIn }
    public enum Exit: Sendable, Equatable { case fall, shrinkFade }
    public enum Card: Sendable, Equatable { case spring, fade }

    public var name: String
    public var camera: Spring
    public var sheet: Spring
    /// How much of the window's box a focused region fills on its binding axis.
    public var fill: Double
    public var zoomCap: Double
    /// A slow push-in and back, as a fraction of the zoom, so no frame is ever still.
    public var drift: Double
    public var driftPeriod: Double
    public var captions: Captions
    public var captionWeight: Int
    /// Caption font size as a fraction of the output's short side.
    public var captionSize: Double
    /// Delay between caption words; 0 brings a caption in whole.
    public var wordStagger: Double
    public var wordSpring: Spring
    public var hookCard: Bool
    public var hookSize: Double
    public var hookStagger: Double
    public var spotlightDim: Double
    public var spotlightOutline: Bool
    public var pop: Pop
    public var popSpring: Spring
    /// An accent-coloured glow drifting behind the window.
    public var glow: Bool
    /// Degrees the background gradient swings either way over 20 s.
    public var swing: Double
    public var entry: Entry
    public var exit: Exit
    public var card: Card
    public var blurSamples: Int
    /// Motion-blur shutter as a fraction of a frame: 0.25 is a 90° shutter.
    public var shutter: Double
    /// Pixels the window must move in 1/60 s before a frame is blurred.
    public var blurThreshold: Double

    /// The hook holds the first 1.5 s whatever the preset, so one config stays valid
    /// under every preset `--motion` may name.
    public static let hookDuration = 1.5
    public static let defaultName = "kinetic"

    public static let kinetic = MotionPreset(
        name: "kinetic", camera: Spring(response: 0.7, damping: 0.78),
        sheet: Spring(response: 0.45, damping: 0.7), fill: 0.92, zoomCap: 2.6, drift: 0.04,
        driftPeriod: 10, captions: .band, captionWeight: 800, captionSize: 0.062, wordStagger: 0.06,
        wordSpring: Spring(response: 0.5, damping: 0.7), hookCard: true, hookSize: 0.11,
        hookStagger: 0.08, spotlightDim: 0.62, spotlightOutline: false, pop: .lift(scale: 1.32),
        popSpring: Spring(response: 0.5, damping: 0.62), glow: true, swing: 12, entry: .riseAfterHook,
        exit: .fall, card: .spring, blurSamples: 6, shutter: 0.25, blurThreshold: 3)

    public static let studio = MotionPreset(
        name: "studio", camera: Spring(response: 1.0, damping: 1.0),
        sheet: Spring(response: 0.55, damping: 0.9), fill: 0.9, zoomCap: 2.6, drift: 0.025,
        driftPeriod: 10, captions: .pill, captionWeight: 600, captionSize: 0.04, wordStagger: 0,
        wordSpring: Spring(response: 0.5, damping: 1), hookCard: false, hookSize: 0.11, hookStagger: 0.08,
        spotlightDim: 0.5, spotlightOutline: true, pop: .outline,
        popSpring: Spring(response: 0.6, damping: 1), glow: false, swing: 12, entry: .fadeIn,
        exit: .shrinkFade, card: .fade, blurSamples: 6, shutter: 0.25, blurThreshold: 3)

    public static let all: [MotionPreset] = [.kinetic, .studio]

    public static func named(_ name: String) -> MotionPreset? {
        all.first { $0.name == name }
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter MotionPresetTests`
Expected: all pass.

- [ ] **Step 5: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/MotionPreset.swift Tests/AppShotKitTests/MotionPresetTests.swift
git commit -m "feat(video): closed-form springs and the kinetic and studio motion presets"
```

---

## Task 2: Kinetic text

**Files:**
- Create: `Sources/AppShotKit/KineticText.swift`
- Test: `Tests/AppShotKitTests/KineticTextTests.swift`

**Interfaces:**
- Consumes: `Spring`, `Ease` (Task 1).
- Produces:
  - `KineticText.Token { text: String; accent: Bool }`
  - `static func tokens(_ text: String) -> [Token]?`: nil when a `*` is left open.
  - `static func plain(_ text: String) -> String`
  - `struct Placed { line: CTLine; width: Double; x: Double; row: Int }`
  - `struct Layout { words: [Placed]; rowWidths: [Double]; rows: Int }`
  - `static func layout(_ tokens: [Token], font: CTFont, color: CGColor, accent: CGColor, maxWidth: Double) -> Layout`
  - `static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine`
  - `static func entrance(age: Double, index: Int, stagger: Double, spring: Spring) -> (alpha: Double, drop: Double)`. `drop` is a fraction of the font size.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import CoreText
import Testing

@testable import AppShotKit

struct KineticTextTests {
    @Test func anAccentCoversTheMarkedWordsOnly() throws {
        let tokens = try #require(KineticText.tokens("Your music folder is a *mess*."))
        #expect(tokens.map(\.text) == ["Your", "music", "folder", "is", "a", "mess."])
        #expect(tokens.map(\.accent) == [false, false, false, false, false, true])
    }

    @Test func anAccentCanSpanSeveralWords() throws {
        let tokens = try #require(KineticText.tokens("Then file it all by *artist and album*."))
        #expect(tokens.filter(\.accent).map(\.text) == ["artist", "and", "album."])
    }

    @Test func anOpenMarkIsRejected() {
        #expect(KineticText.tokens("a *b c") == nil)
        #expect(KineticText.tokens("no marks") != nil)
    }

    @Test func plainDropsTheMarks() {
        #expect(KineticText.plain("Rename every file in *one go*.") == "Rename every file in one go.")
    }

    @Test func layoutWrapsInsideTheWidth() throws {
        let font = try Text.font(stack: "Helvetica", weight: 700, size: 40)
        let white = CGColor(gray: 1, alpha: 1)
        let tokens = try #require(KineticText.tokens("Then file it all by *artist and album* every time"))
        let layout = KineticText.layout(tokens, font: font, color: white, accent: white, maxWidth: 300)
        #expect(layout.rows > 1)
        #expect(layout.rowWidths.allSatisfy { $0 <= 300 })
        #expect(layout.words.count == tokens.count)
        #expect(layout.words.allSatisfy { $0.x + $0.width <= 300 + 0.5 })
    }

    @Test func wordsEnterInOrderAndSettle() {
        let spring = MotionPreset.kinetic.wordSpring
        #expect(KineticText.entrance(age: -0.1, index: 0, stagger: 0.06, spring: spring).alpha == 0)
        let first = KineticText.entrance(age: 0.1, index: 0, stagger: 0.06, spring: spring)
        let third = KineticText.entrance(age: 0.1, index: 2, stagger: 0.06, spring: spring)
        #expect(first.alpha > third.alpha)
        let settled = KineticText.entrance(age: 5, index: 3, stagger: 0.06, spring: spring)
        #expect(settled.alpha == 1 && abs(settled.drop) < 0.001)
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter KineticTextTests`
Expected: compile failure, `cannot find 'KineticText' in scope`.

- [ ] **Step 3: Implement `Sources/AppShotKit/KineticText.swift`**

```swift
import CoreGraphics
import CoreText
import Foundation

/// Captions set word by word, with `*accent*` marks.
public enum KineticText {
    public struct Token: Equatable, Sendable {
        public var text: String
        public var accent: Bool
    }

    /// The words of `text`, each flagged when an accent mark covers it.
    ///
    /// Every `*` toggles the accent, and a word takes the state at its first letter, so
    /// `*mess*.` is one accent word and `*artist and album*.` three. Nil when a mark is
    /// left open: an unclosed `*` would otherwise colour the rest of the caption.
    public static func tokens(_ text: String) -> [Token]? {
        var on = false
        var out: [Token] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            var word = ""
            var accent: Bool?
            for character in raw {
                if character == "*" {
                    on.toggle()
                    continue
                }
                if accent == nil { accent = on }
                word.append(character)
            }
            if !word.isEmpty { out.append(Token(text: word, accent: accent ?? false)) }
        }
        return on ? nil : out
    }

    /// The text as read: marks dropped.
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "")
    }

    public struct Placed {
        public let line: CTLine
        public let width: Double
        /// From the row's left edge.
        public let x: Double
        public let row: Int
    }

    public struct Layout {
        public let words: [Placed]
        public let rowWidths: [Double]
        public var rows: Int { rowWidths.count }
    }

    /// Greedy wrap at `maxWidth`, one `CTLine` per word so each can move on its own. A
    /// word wider than the line gets a row of its own rather than being cut.
    public static func layout(
        _ tokens: [Token], font: CTFont, color: CGColor, accent: CGColor, maxWidth: Double
    ) -> Layout {
        let space = CTLineGetTypographicBounds(line(" ", font: font, color: color), nil, nil, nil)
        var words: [Placed] = []
        var widths: [Double] = []
        var x = 0.0
        var row = 0
        for token in tokens {
            let ct = line(token.text, font: font, color: token.accent ? accent : color)
            let width = CTLineGetTypographicBounds(ct, nil, nil, nil)
            if x > 0, x + width > maxWidth {
                widths.append(x - space)
                row += 1
                x = 0
            }
            words.append(Placed(line: ct, width: width, x: x, row: row))
            x += width + space
        }
        if !words.isEmpty { widths.append(x - space) }
        return Layout(words: words, rowWidths: widths)
    }

    public static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .init(kCTFontAttributeName as String): font,
                    .init(kCTForegroundColorAttributeName as String): color,
                    .init(kCTKernAttributeName as String): Config.Layout.titleLetterSpacing,
                ]))
    }

    /// One word's entrance, `age` seconds after its caption appeared: its opacity, and
    /// how far below its resting baseline it still is, as a fraction of the font size.
    public static func entrance(
        age: Double, index: Int, stagger: Double, spring: Spring
    ) -> (alpha: Double, drop: Double) {
        let local = age - stagger * Double(index)
        return (Ease.clamp01(local / 0.15), (1 - spring.value(local)) * 0.6)
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter KineticTextTests`
Expected: all pass.

- [ ] **Step 5: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/KineticText.swift Tests/AppShotKitTests/KineticTextTests.swift
git commit -m "feat(video): word-by-word caption layout with accent marks"
```

---

## Task 3: The config keys

**Files:**
- Modify: `Sources/AppShotKit/VideoConfig.swift`. Add the `Video.motion` and `Video.hook` fields, `Card.cta`, the `Region`, `Focus`, `Emphasis` and `PointerMove` types, and the new `Beat` fields; extend `validateVideos()`.
- Modify: `Sources/AppShotKit/Config.swift:115-119`: `Theme.accent`.
- Modify: `Sources/AppShotKit/AppShotError.swift`: the `unknownMotion` case, its description and its slug.
- Test: `Tests/AppShotKitTests/VideoConfigTests.swift`

`zoom` stays for now; Task 6 removes it once nothing reads it.

**Interfaces:**
- Consumes: `MotionPreset.named`, `.all`, `.hookDuration` (Task 1); `KineticText.tokens` (Task 2).
- Produces:
  - `Config.Video.motion: String?`, `Config.Video.hook: String?`, `Config.Card.cta: String?`, `Config.Theme.accent: String?`
  - `Config.Region { target: String?; rect: [Double]? }`
  - `Config.Focus { case home; case region(Region, fill: Double?) }`, decoding `"home"` or `{ "target"|"rect", "fill"? }`
  - `Config.Emphasis { target: String?; rect: [Double]?; until: Double }`
  - `Config.PointerMove { point: [Double]?; rect: [Double]?; click: Bool? }`
  - Beat fields: `focus: Focus?`, `spotlight: Emphasis?`, `pop: Emphasis?`, `pointer: PointerMove?`, `present: [Double]?`
  - `AppShotError.unknownMotion(video: String, name: String, known: [String])`, slug `unknown_motion`

- [ ] **Step 1: Write the failing tests.** Append to `VideoConfigTests`:

```swift
    static let motion = """
        [{ "id": "promo", "duration": 20, "motion": "studio", "hook": "Your folder is a *mess*.",
           "outputs": { "promo": [[1200, 1200]] },
           "card": { "title": "Pochette", "subtitle": "Your music, as files.", "cta": "On the Mac App Store" },
           "beats": [
             { "at": 0, "screen": "browser" },
             { "at": 0.9, "focus": { "rect": [20, 426, 580, 516], "fill": 0.8 } },
             { "at": 1.6, "spotlight": { "rect": [20, 426, 580, 516], "until": 3.9 } },
             { "at": 3.4, "pointer": { "point": [1250, 760] } },
             { "at": 4.0, "focus": "home" },
             { "at": 4.8, "pointer": { "rect": [1460, 30, 44, 44], "click": true } },
             { "at": 5.0, "screen": "paywall", "present": [600, 275, 1358, 1047],
               "caption": "Rename every file in *one go*." },
             { "at": 7.6, "pop": { "rect": [640, 1040, 640, 78], "until": 10.2 } },
             { "at": 15.8, "endCard": true }
           ] }]
        """

    @Test func decodesTheMotionKeys() throws {
        let config = try Self.config(videos: Self.motion)
        try config.validate()
        let video = try config.video("promo")
        #expect(video.motion == "studio")
        #expect(video.hook == "Your folder is a *mess*.")
        #expect(video.card?.cta == "On the Mac App Store")
        #expect(video.beats[1].focus == .region(.init(target: nil, rect: [20, 426, 580, 516]), fill: 0.8))
        #expect(video.beats[4].focus == .home)
        #expect(video.beats[2].spotlight?.until == 3.9)
        #expect(video.beats[5].pointer?.click == true)
        #expect(video.beats[6].present == [600, 275, 1358, 1047])
        #expect(video.beats[7].pop?.rect == [640, 1040, 640, 78])
    }

    @Test func anUnknownMotionNamesTheKnownOnes() throws {
        let config = try Self.config(
            videos: #"[{"id":"x","duration":20,"motion":"keynote","outputs":{"promo":[[100,100]]},"beats":[]}]"#)
        #expect {
            try config.validate()
        } throws: { error in
            guard case .unknownMotion(let video, let name, let known) = error as? AppShotError else { return false }
            return video == "x" && name == "keynote" && known == ["kinetic", "studio"]
        }
    }

    @Test(arguments: [
        (#"{"at":1,"caption":"a *b"}"#, "unclosed"),
        (#"{"at":1,"caption":"under the hook"}"#, "starts under the hook"),
        (#"{"at":2,"focus":{"rect":[0,0,10,10],"target":"t"}}"#, "exactly one of target or rect"),
        (#"{"at":2,"focus":{"rect":[0,0,10]}}"#, "focus rect must be"),
        (#"{"at":2,"focus":{"rect":[0,0,10,10],"fill":0.2}}"#, "outside 0.3...1"),
        (#"{"at":2,"spotlight":{"rect":[0,0,10,10],"until":2}}"#, "spotlight until"),
        (#"{"at":2,"pop":{"target":"t","until":30}}"#, "pop until"),
        (#"{"at":2,"pop":{"until":3}}"#, "exactly one of target or rect"),
        (#"{"at":2,"pointer":{"point":[1,2],"rect":[0,0,1,1]}}"#, "exactly one of point or rect"),
        (#"{"at":2,"pointer":{"point":[1]}}"#, "point must be [x, y]"),
        (#"{"at":2,"present":[0,0,10,10]}"#, "but no screen"),
        (#"{"at":2,"screen":"browser","present":[0,0,0,10]}"#, "present rect must be"),
    ])
    func rejectsABadMotionBeat(beat: String, reason: String) throws {
        let config = try Self.config(
            videos: """
                [{"id":"x","duration":20,"hook":"Hello there","outputs":{"promo":[[100,100]]},
                  "beats":[{"at":0,"screen":"browser"},\(beat)]}]
                """)
        #expect {
            try config.validate()
        } throws: { error in
            guard case .invalidVideo(_, let why) = error as? AppShotError else { return false }
            return why.contains(reason)
        }
    }

    @Test func anUnclosedMarkInTheHookOrCardIsRejected() throws {
        for (hook, title) in [("a *b", "T"), ("ok", "*T")] {
            let config = try Self.config(
                videos: """
                    [{"id":"x","duration":20,"hook":"\(hook)","card":{"title":"\(title)"},
                      "outputs":{"promo":[[100,100]]},"beats":[]}]
                    """)
            #expect(throws: AppShotError.self) { try config.validate() }
        }
    }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoConfigTests`
Expected: compile failure on `cta`, `focus` and `unknownMotion`.

- [ ] **Step 3: Add the types and fields.** In `Sources/AppShotKit/VideoConfig.swift`:

Add to `Video`, after `public var card: Card?`:

```swift
        /// The motion preset; `kinetic` when absent. `compose video --motion` overrides it.
        public var motion: String?
        /// The opening line. Full-frame in a preset with a hook card, then the first
        /// caption until the next caption beat; just that caption in other presets.
        public var hook: String?
```

Add to `Card`, after `icon`:

```swift
        /// A call to action under the subtitle, drawn as a pill.
        public var cta: String?
```

Add these types after `Zoom`:

```swift
    /// A part of the stage: an element the app reported (`target`) or stage pixels
    /// (`rect`, `[x, y, width, height]`, for `--from-stills`, where nothing reports).
    public struct Region: Codable, Sendable, Equatable {
        public var target: String?
        public var rect: [Double]?

        public init(target: String?, rect: [Double]?) {
            self.target = target
            self.rect = rect
        }
    }

    /// Frame a region, or the whole window with `"home"`. The zoom is computed from the
    /// region; `fill` (0.3...1) loosens or tightens the preset's framing.
    public enum Focus: Codable, Sendable, Equatable {
        case home
        case region(Region, fill: Double?)

        private enum Keys: String, CodingKey { case target, rect, fill }

        public init(from decoder: Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self) {
                guard word == "home" else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: decoder.codingPath,
                            debugDescription: "focus is \"home\" or { \"rect\" | \"target\" }, not \"\(word)\""))
                }
                self = .home
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            self = .region(
                Region(
                    target: try c.decodeIfPresent(String.self, forKey: .target),
                    rect: try c.decodeIfPresent([Double].self, forKey: .rect)),
                fill: try c.decodeIfPresent(Double.self, forKey: .fill))
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .home:
                var c = encoder.singleValueContainer()
                try c.encode("home")
            case .region(let region, let fill):
                var c = encoder.container(keyedBy: Keys.self)
                try c.encodeIfPresent(region.target, forKey: .target)
                try c.encodeIfPresent(region.rect, forKey: .rect)
                try c.encodeIfPresent(fill, forKey: .fill)
            }
        }
    }

    /// A region that matters until `until`, in seconds from the start of the video.
    public struct Emphasis: Codable, Sendable, Equatable {
        public var target: String?
        public var rect: [Double]?
        public var until: Double
    }

    /// `--from-stills` only: where the drawn pointer goes, arriving at the beat's time.
    public struct PointerMove: Codable, Sendable, Equatable {
        public var point: [Double]?
        public var rect: [Double]?
        public var click: Bool?
    }
```

Add to `Beat`, after `screen`:

```swift
        public var focus: Focus?
        public var spotlight: Emphasis?
        public var pop: Emphasis?
        public var pointer: PointerMove?
        /// `--from-stills` only, on a `screen` beat: this region of the new capture is a
        /// sheet, and springs up over the window instead of crossfading.
        public var present: [Double]?
```

Then extend `Beat.init`. Add the parameters `focus: Focus? = nil, spotlight: Emphasis? = nil, pop: Emphasis? = nil, pointer: PointerMove? = nil, present: [Double]? = nil` after `screen`, and assign each one.

In `Sources/AppShotKit/Config.swift`, `Theme` gains:

```swift
        /// Accent words (`*…*`) in kinetic captions. Defaults to `title`.
        public var accent: String?
```

- [ ] **Step 4: Add the error.** In `AppShotError.swift`, add the case next to `invalidVideo`:

```swift
    case unknownMotion(video: String, name: String, known: [String])
```

Its description, next to `.invalidVideo`'s:

```swift
        case .unknownMotion(let video, let name, let known):
            return "videos[\"\(video)\"]: no motion preset \"\(name)\"; known: \(known.joined(separator: ", "))"
```

Its slug, next to `.invalidVideo: return "invalid_video"`:

```swift
        case .unknownMotion: return "unknown_motion"
```

- [ ] **Step 5: Validate.** In `validateVideos()`, after the `poster` check, add:

```swift
            if let motion = video.motion, MotionPreset.named(motion) == nil {
                throw AppShotError.unknownMotion(
                    video: video.id, name: motion, known: MotionPreset.all.map(\.name))
            }
            if let hook = video.hook, KineticText.tokens(hook) == nil {
                throw fail("the hook has an unclosed *")
            }
            if let title = video.card?.title, KineticText.tokens(title) == nil {
                throw fail("the card title has an unclosed *")
            }
            func checkRect(_ rect: [Double], _ what: String) throws {
                guard rect.count == 4, rect[2] > 0, rect[3] > 0 else {
                    throw fail("\(what) rect must be [x, y, width, height] with a positive size")
                }
            }
            func checkRegion(_ target: String?, _ rect: [Double]?, _ what: String) throws {
                guard (target == nil) != (rect == nil) else {
                    throw fail("\(what) needs exactly one of target or rect")
                }
                if let rect { try checkRect(rect, what) }
            }
```

Inside the beat loop, after the `until` block, add:

```swift
                if let caption = beat.caption {
                    guard KineticText.tokens(caption) != nil else {
                        throw fail("beat \(i) caption has an unclosed *")
                    }
                    if video.hook != nil, beat.at < MotionPreset.hookDuration {
                        throw fail(
                            "beat \(i) caption at \(beat.at)s starts under the hook, which holds "
                                + "the first \(MotionPreset.hookDuration)s")
                    }
                }
                if case .region(let region, let fill)? = beat.focus {
                    try checkRegion(region.target, region.rect, "beat \(i) focus")
                    if let fill, !(0.3...1).contains(fill) {
                        throw fail("beat \(i) focus fill \(fill) is outside 0.3...1")
                    }
                }
                for (key, emphasis) in [("spotlight", beat.spotlight), ("pop", beat.pop)] {
                    guard let emphasis else { continue }
                    try checkRegion(emphasis.target, emphasis.rect, "beat \(i) \(key)")
                    guard emphasis.until > beat.at, emphasis.until <= video.duration else {
                        throw fail(
                            "beat \(i) \(key) until \(emphasis.until)s must be after its `at` "
                                + "and within the duration")
                    }
                }
                if let pointer = beat.pointer {
                    guard (pointer.point == nil) != (pointer.rect == nil) else {
                        throw fail("beat \(i) pointer needs exactly one of point or rect")
                    }
                    if let point = pointer.point, point.count != 2 {
                        throw fail("beat \(i) pointer point must be [x, y]")
                    }
                    if let rect = pointer.rect { try checkRect(rect, "beat \(i) pointer") }
                }
                if let present = beat.present {
                    guard beat.screen != nil else {
                        throw fail(
                            "beat \(i) has `present` but no screen: only a cut to a capture "
                                + "can present a sheet")
                    }
                    try checkRect(present, "beat \(i) present")
                }
```

- [ ] **Step 6: Run the tests and see them pass**

Run: `swift test --filter VideoConfigTests`
Expected: all pass, the old cases included.

- [ ] **Step 7: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoConfig.swift Sources/AppShotKit/Config.swift \
  Sources/AppShotKit/AppShotError.swift Tests/AppShotKitTests/VideoConfigTests.swift
git commit -m "feat(video): motion, hook, focus, spotlight, pop, pointer and present config keys"
```

---

## Task 4: The camera

**Files:**
- Create: `Sources/AppShotKit/VideoCamera.swift`
- Test: `Tests/AppShotKitTests/VideoCameraTests.swift`

**Interfaces:**
- Consumes: `MotionPreset`, `Spring`, `Ease` (Task 1).
- Produces:
  - `VideoCamera.Key { time: Double; rect: CGRect?; fill: Double? }`
  - `VideoCamera(preset:stage:canvas:box:keys:entryAt:exitAt:)`
  - `func target(_ key: Key) -> (zoom: Double, center: CGPoint)`
  - `func state(at t: Double) -> (zoom: Double, center: CGPoint)`
  - `func placement(at t: Double) -> Placement`
  - `Placement { rect: CGRect; alpha: Double; zoom: Double; scale: Double; func map(_ p: CGPoint) -> CGPoint; func map(_ r: CGRect) -> CGRect }`. All coordinates are y-down canvas pixels; `scale` is canvas pixels per stage pixel.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Testing

@testable import AppShotKit

struct VideoCameraTests {
    static let stage = CGSize(width: 1000, height: 600)
    static let canvas = CGSize(width: 1920, height: 1080)
    static let box = CGRect(x: 54, y: 190, width: 1812, height: 836)

    static func still(_ preset: MotionPreset = .studio) -> MotionPreset {
        var p = preset
        p.drift = 0
        return p
    }

    static func camera(
        _ keys: [VideoCamera.Key], preset: MotionPreset = still(), entryAt: Double = -100,
        exitAt: Double? = nil
    ) -> VideoCamera {
        VideoCamera(
            preset: preset, stage: stage, canvas: canvas, box: box, keys: keys, entryAt: entryAt,
            exitAt: exitAt)
    }

    @Test func aFocusedRegionFillsTheBoxOnItsBindingAxis() {
        let region = CGRect(x: 100, y: 100, width: 600, height: 300)
        let cam = Self.camera([.init(time: 0, rect: region, fill: nil)])
        let placed = cam.placement(at: 10)
        let shown = placed.map(region)
        // fit = min(1812/1000, 836/600); height binds: 0.9 of the box's height.
        #expect(abs(shown.height - 0.9 * 836) < 0.5)
    }

    @Test func zoomStaysBetweenOneAndTheCap() {
        let tiny = Self.camera([.init(time: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), fill: nil)])
        #expect(abs(tiny.state(at: 10).zoom - 2.6) < 1e-6)
        let huge = Self.camera([.init(time: 0, rect: CGRect(x: 0, y: 0, width: 5000, height: 5000), fill: nil)])
        #expect(abs(huge.state(at: 10).zoom - 1) < 1e-6)
    }

    @Test func aZoomedWindowCoversTheCanvas() {
        let cam = Self.camera([.init(time: 0, rect: CGRect(x: 0, y: 0, width: 300, height: 200), fill: nil)])
        let rect = cam.placement(at: 10).rect
        #expect(rect.minX <= 0 && rect.minY <= 0)
        #expect(rect.maxX >= Self.canvas.width && rect.maxY >= Self.canvas.height)
    }

    @Test func aWindowAtRestStaysInsideTheCanvas() {
        let cam = Self.camera([.init(time: 0, rect: nil, fill: nil)])
        let rect = cam.placement(at: 10).rect
        #expect(rect.minX >= 0 && rect.minY >= 0)
        #expect(rect.maxX <= Self.canvas.width && rect.maxY <= Self.canvas.height)
    }

    @Test func theWindowNeverJumpsBetweenFrames() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 600, y: 350, width: 300, height: 200)
        let cam = Self.camera(
            [
                .init(time: 1, rect: a, fill: nil), .init(time: 3, rect: nil, fill: nil),
                .init(time: 5, rect: b, fill: nil),
            ], preset: .kinetic, entryAt: -100)
        var last = cam.placement(at: 0).rect
        for i in 1...(30 * 8) {
            let rect = cam.placement(at: Double(i) / 30).rect
            let moved = abs(rect.minX - last.minX) + abs(rect.minY - last.minY) + abs(rect.width - last.width)
            #expect(moved < Self.canvas.width * 0.5, "frame \(i) moved \(moved)px")
            last = rect
        }
    }

    @Test func driftIsContinuous() {
        let cam = Self.camera([], preset: .kinetic, entryAt: -100)
        for i in 0..<(30 * 12) {
            let a = cam.placement(at: Double(i) / 30).rect
            let b = cam.placement(at: Double(i + 1) / 30).rect
            #expect(abs(a.width - b.width) < 2)
        }
    }

    @Test func kineticRisesInAfterTheHookAndFallsOutForTheCard() {
        let cam = Self.camera([], preset: Self.still(.kinetic), entryAt: 1.25, exitAt: 10)
        #expect(cam.placement(at: 0.5).rect.minY >= Self.canvas.height)
        let settled = cam.placement(at: 5).rect
        #expect(abs(settled.midY - Self.box.midY) < 1)
        #expect(cam.placement(at: 10.5).rect.minY >= Self.canvas.height)
    }

    @Test func studioFadesInAndShrinksAway() {
        let cam = Self.camera([], preset: Self.still(), entryAt: 0, exitAt: 10)
        #expect(cam.placement(at: 0).alpha == 0)
        #expect(cam.placement(at: 2).alpha == 1)
        #expect(cam.placement(at: 10.8).alpha == 0)
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoCameraTests`
Expected: compile failure, `cannot find 'VideoCamera' in scope`.

- [ ] **Step 3: Implement `Sources/AppShotKit/VideoCamera.swift`**

```swift
import CoreGraphics
import Foundation

/// Where the window sits on the canvas at time t.
///
/// The whole window moves, chrome, corners and shadow included, and the frame's edge
/// does the cropping. The first renderer cropped inside a fixed box instead, which reads
/// as the content panning rather than the camera moving in.
public struct VideoCamera: Sendable {
    /// A move toward a region in stage pixels, or with no rect back to the whole window.
    public struct Key: Sendable, Equatable {
        public var time: Double
        public var rect: CGRect?
        public var fill: Double?

        public init(time: Double, rect: CGRect?, fill: Double?) {
            self.time = time
            self.rect = rect
            self.fill = fill
        }
    }

    public struct Placement: Sendable, Equatable {
        /// The whole window, y-down canvas pixels; it may run past the canvas.
        public var rect: CGRect
        public var alpha: Double
        public var zoom: Double
        /// Canvas pixels per stage pixel.
        public var scale: Double

        public func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
        }

        public func map(_ r: CGRect) -> CGRect {
            CGRect(
                x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale, width: r.width * scale,
                height: r.height * scale)
        }
    }

    public let preset: MotionPreset
    public let stage: CGSize
    public let canvas: CGSize
    /// Where the window rests at zoom 1, y-down canvas pixels.
    public let box: CGRect
    public let keys: [Key]
    /// When an entering window starts to come in.
    public let entryAt: Double
    /// When the window starts leaving for the end card; nil without one.
    public let exitAt: Double?

    public init(
        preset: MotionPreset, stage: CGSize, canvas: CGSize, box: CGRect, keys: [Key], entryAt: Double,
        exitAt: Double?
    ) {
        self.preset = preset
        self.stage = stage
        self.canvas = canvas
        self.box = box
        self.keys = keys
        self.entryAt = entryAt
        self.exitAt = exitAt
    }

    var fit: Double { min(box.width / stage.width, box.height / stage.height) }
    var anchor: CGPoint { CGPoint(x: box.midX, y: box.midY) }

    /// The zoom and stage-pixel center a key asks for. The zoom is computed, never
    /// configured: the region fills `fill` of the box on whichever axis binds.
    public func target(_ key: Key) -> (zoom: Double, center: CGPoint) {
        guard let r = key.rect else { return (1, CGPoint(x: stage.width / 2, y: stage.height / 2)) }
        let fill = key.fill ?? preset.fill
        let zoom = fill * min(box.width / (r.width * fit), box.height / (r.height * fit))
        return (min(max(zoom, 1), preset.zoomCap), CGPoint(x: r.midX, y: r.midY))
    }

    /// Zoom and center after the springs, the drift and the clamp.
    ///
    /// Each key pulls the state toward its target from wherever the earlier keys left
    /// it; zoom is sprung in log space so zooming in and out feel alike.
    public func state(at t: Double) -> (zoom: Double, center: CGPoint) {
        var logZoom = 0.0
        var center = CGPoint(x: stage.width / 2, y: stage.height / 2)
        for key in keys where key.time <= t {
            let p = preset.camera.value(t - key.time)
            let to = target(key)
            logZoom += (log(to.zoom) - logZoom) * p
            center.x += (to.center.x - center.x) * p
            center.y += (to.center.y - center.y) * p
        }
        logZoom += log(1 + preset.drift * (0.5 - 0.5 * cos(2 * .pi * t / preset.driftPeriod)))
        let zoom = exp(logZoom)
        // One rule for both cases: a window larger than the canvas keeps covering it, a
        // smaller one stays inside it.
        let k = fit * zoom
        center.x = Self.clamp(center.x, anchor.x / k, stage.width - (canvas.width - anchor.x) / k)
        center.y = Self.clamp(center.y, anchor.y / k, stage.height - (canvas.height - anchor.y) / k)
        return (zoom, center)
    }

    static func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double {
        min(max(v, min(a, b)), max(a, b))
    }

    static func scaled(_ r: CGRect, by s: Double, about p: CGPoint) -> CGRect {
        CGRect(
            x: p.x + (r.minX - p.x) * s, y: p.y + (r.minY - p.y) * s, width: r.width * s, height: r.height * s)
    }

    public func placement(at t: Double) -> Placement {
        let s = state(at: t)
        let k = fit * s.zoom
        var rect = CGRect(
            x: anchor.x - s.center.x * k, y: anchor.y - s.center.y * k, width: stage.width * k,
            height: stage.height * k)
        var alpha = 1.0
        switch preset.entry {
        case .riseAfterHook:
            let up = Spring(response: 0.6, damping: 0.75).value(t - entryAt)
            rect.origin.y += (1 - up) * canvas.height
        case .fadeIn:
            let p = Ease.out((t - entryAt) / 0.8)
            rect = Self.scaled(rect, by: 0.94 + 0.06 * p, about: CGPoint(x: rect.midX, y: rect.midY))
            alpha = p
        }
        if let exitAt, t > exitAt {
            let q = t - exitAt
            switch preset.exit {
            case .fall:
                // From wherever the camera left it: a fixed offset left a zoomed window on
                // screen under the card.
                let e = Ease.clamp01(q / 0.45)
                rect.origin.y += e * e * (canvas.height - rect.minY + min(canvas.width, canvas.height) * 0.1)
            case .shrinkFade:
                let e = Ease.smooth(q / 0.7)
                rect = Self.scaled(
                    rect, by: 1 - 0.12 * e, about: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
                alpha *= 1 - e
            }
        }
        return Placement(rect: rect, alpha: alpha, zoom: s.zoom, scale: rect.width / stage.width)
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter VideoCameraTests`
Expected: all pass. If `theWindowNeverJumpsBetweenFrames` fails, print the frame and the move size; do not widen the bound past 50% of the canvas width (a teleport moves the whole window, several canvas widths).

- [ ] **Step 5: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoCamera.swift Tests/AppShotKitTests/VideoCameraTests.swift
git commit -m "feat(video): a camera that places the whole window, with computed framing"
```

---

## Task 5: The timeline's motion events

**Files:**
- Modify: `Sources/AppShotKit/VideoTimeline.swift`. Add the hook caption, the focus keys, the spans, the pointer and the warnings. The old `zooms`, `camera(at:)` and `cursor(at:)` stay until Task 6.
- Test: `Tests/AppShotKitTests/VideoTimelineTests.swift`, a new `struct VideoMotionTimelineTests`.

**Interfaces:**
- Consumes: `Config.Focus`, `Config.Emphasis`, `Config.PointerMove`, `Video.hook` (Task 3); `VideoCamera.Key` (Task 4); `KineticText.plain` (Task 2); `MotionPreset` (Task 1).
- Produces, on `VideoTimeline`:
  - `CaptionSpan.isHook: Bool` (default false) and `CaptionSpan.plain: String`
  - `struct Span { from: Double; to: Double; rect: CGRect }`
  - `struct PointerKey { time: Double; point: CGPoint; click: Bool }`
  - `struct Warning: Codable { kind: String; at: Double; message: String }`
  - `let hook: String?`, `let focusKeys: [VideoCamera.Key]`, `let spotlights: [Span]` (a pop's span included), `let pops: [Span]`, `let pointerKeys: [PointerKey]`
  - `func pointer(at t: Double) -> (point: CGPoint, alpha: Double, clickAge: Double?)?`
  - `func warnings(for preset: MotionPreset) -> [Warning]`
  - `static let pointerGlide = 0.7`, `static let pointerLinger = 2.0`

- [ ] **Step 1: Write the failing tests.** Append to `VideoTimelineTests.swift`:

```swift
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
            #"[{"at":1,"spotlight":{"rect":[0,0,10,10],"until":3}},{"at":4,"pop":{"rect":[5,5,20,20],"until":6}}]"#)
        #expect(t.pops == [.init(from: 4, to: 6, rect: CGRect(x: 5, y: 5, width: 20, height: 20))])
        #expect(t.spotlights.map(\.from) == [1, 4])
    }

    @Test func thePointerGlidesIntoEachKeyAndClicks() throws {
        let t = try Self.timeline(
            #"[{"at":1,"pointer":{"point":[100,100]}},{"at":3,"pointer":{"rect":[480,180,40,40],"click":true}}]"#)
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
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoMotionTimelineTests`
Expected: compile failure on `focusKeys`, `pointer(at:)`, `isHook` and `warnings(for:)`.

- [ ] **Step 3: Implement.** In `Sources/AppShotKit/VideoTimeline.swift`:

Add to `CaptionSpan`, after `words`:

```swift
        /// The video's `hook`, shown as its first caption.
        public var isHook = false

        /// The text as read, accent marks dropped: for messages and the report.
        public var plain: String { KineticText.plain(text) }
```

Add these types and constants inside `VideoTimeline`:

```swift
    public struct Span: Sendable, Equatable {
        public let from: Double
        public let to: Double
        public let rect: CGRect
    }

    public struct PointerKey: Sendable, Equatable {
        public let time: Double
        public let point: CGPoint
        public let click: Bool
    }

    /// Something a render can make but a viewer will notice. Listed in the report; never
    /// fails the render.
    public struct Warning: Codable, Sendable, Equatable {
        public var kind: String
        public var at: Double
        public var message: String
    }

    public static let pointerGlide = 0.7
    public static let pointerLinger = 2.0

    public let hook: String?
    public let focusKeys: [VideoCamera.Key]
    /// Every spotlight, including the one each pop implies.
    public let spotlights: [Span]
    public let pops: [Span]
    public let pointerKeys: [PointerKey]
```

In `init`, replace the `captions = captioned...` assignment with a local `var spans` built by the same expression, then add:

```swift
        if let hook = video.hook {
            let next = spans.first?.start ?? video.duration
            let words = KineticText.plain(hook).split(whereSeparator: { $0.isWhitespace }).count
            spans.insert(
                CaptionSpan(
                    text: hook, start: 0, end: min(next, card ?? video.duration, video.duration), words: words,
                    isHook: true), at: 0)
        }
        captions = spans
        hook = video.hook
```

Before the `zooms = …` assignment, add:

```swift
        func region(_ target: String?, _ rect: [Double]?, at time: Double, _ what: String) throws -> CGRect {
            if let rect { return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
            let name = target ?? ""
            // The latest report at or before the beat; an element that moved is wherever
            // the app last said it was.
            guard let found = track.targets.last(where: { $0.name == name && $0.at <= time + 0.001 }) else {
                throw AppShotError.videoRenderFailed(
                    video: video.id,
                    reason: "\(what) at \(time)s targets \"\(name)\", which no pointer cue at or before it reported"
                )
            }
            return CGRect(x: found.rect[0], y: found.rect[1], width: found.rect[2], height: found.rect[3])
        }

        focusKeys = try video.beats.indices.compactMap { i in
            switch video.beats[i].focus {
            case nil: return nil
            case .home: return VideoCamera.Key(time: times[i], rect: nil, fill: nil)
            case .region(let r, let fill)?:
                return VideoCamera.Key(
                    time: times[i], rect: try region(r.target, r.rect, at: times[i], "focus"), fill: fill)
            }
        }

        // `until` moves with its beat, like a caption's: a cue acked late keeps the span
        // the config asked for.
        func spans(_ key: KeyPath<Config.Beat, Config.Emphasis?>, _ what: String) throws -> [Span] {
            try video.beats.indices.compactMap { i in
                guard let e = video.beats[i][keyPath: key] else { return nil }
                let start = times[i]
                return Span(
                    from: start, to: e.until + (start - video.beats[i].at),
                    rect: try region(e.target, e.rect, at: start, what))
            }
        }
        let popSpans = try spans(\.pop, "pop")
        pops = popSpans
        spotlights = (try spans(\.spotlight, "spotlight") + popSpans).sorted { $0.from < $1.from }

        let drawn = video.beats.indices.compactMap { i -> PointerKey? in
            guard let move = video.beats[i].pointer else { return nil }
            let point =
                if let p = move.point {
                    CGPoint(x: p[0], y: p[1])
                } else if let r = move.rect {
                    CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
                } else {
                    CGPoint.zero
                }
            return PointerKey(time: times[i], point: point, click: move.click ?? false)
        }
        pointerKeys =
            !drawn.isEmpty
            ? drawn
            : track.targets.sorted { $0.at < $1.at }.map {
                PointerKey(
                    time: $0.at, point: CGPoint(x: $0.rect[0] + $0.rect[2] / 2, y: $0.rect[1] + $0.rect[3] / 2),
                    click: $0.click)
            }
```

If the compiler rejects the local funcs because `self` is not yet initialized, move them to `private static` functions that take `video`, `track` and `times` as parameters. They capture no `self`, so either form works.

Add the methods:

```swift
    /// The drawn pointer at `t`: where it is, how visible, and how long ago it clicked.
    ///
    /// It appears on its first key 0.25 s before that key's time and glides into each
    /// later key over `pointerGlide` along a slight arc, so it *arrives* on time. It
    /// fades out `pointerLinger` after its last key, or as the end card starts.
    public func pointer(at t: Double) -> (point: CGPoint, alpha: Double, clickAge: Double?)? {
        guard let first = pointerKeys.first, t >= first.time - 0.25 else { return nil }
        let gone = min(pointerKeys[pointerKeys.count - 1].time + Self.pointerLinger, cardStart ?? duration)
        guard t < gone + 0.3 else { return nil }
        var point = first.point
        var clickAge: Double?
        for (i, key) in pointerKeys.enumerated() {
            if t >= key.time {
                point = key.point
                clickAge = key.click ? t - key.time : nil
                continue
            }
            guard i > 0, t >= key.time - Self.pointerGlide else { break }
            let e = Ease.smooth((t - (key.time - Self.pointerGlide)) / Self.pointerGlide)
            let from = pointerKeys[i - 1].point
            let dx = key.point.x - from.x
            let dy = key.point.y - from.y
            let arc = sin(e * .pi) * 0.12
            point = CGPoint(x: from.x + dx * e - dy * arc, y: from.y + dy * e + dx * arc)
            clickAge = nil
            break
        }
        let alpha = min(Ease.clamp01((t - first.time + 0.25) / 0.25), Ease.clamp01((gone + 0.3 - t) / 0.3))
        return (point, alpha, clickAge.flatMap { $0 < 0.5 ? $0 : nil })
    }

    public func warnings(for preset: MotionPreset) -> [Warning] {
        func s(_ x: Double) -> String { String(format: "%.2f", x) }
        var out: [Warning] = []
        for (a, b) in zip(focusKeys, focusKeys.dropFirst()) where b.time - a.time < preset.camera.response {
            out.append(
                Warning(
                    kind: "cameraNeverSettles", at: b.time,
                    message: "focus at \(s(b.time))s comes \(s(b.time - a.time))s after the one before; "
                        + "\(preset.name)'s camera needs \(s(preset.camera.response))s to settle, so the "
                        + "move reads as a whiplash"))
        }
        if pops.count > 3 {
            out.append(
                Warning(
                    kind: "popOverload", at: pops[3].from,
                    message: "\(pops.count) pops: past three, none of them stands out"))
        }
        return out
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter VideoMotionTimelineTests && swift test --filter VideoTimelineTests && swift test --filter VideoRerenderTests`
Expected: all pass, the old tests unchanged.

- [ ] **Step 5: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoTimeline.swift Tests/AppShotKitTests/VideoTimelineTests.swift
git commit -m "feat(video): timeline focus keys, spotlights, pops, the pointer path and the hook"
```

---

## Task 6: Frames from the preset; `zoom` removed

**Files:**
- Create: `Sources/AppShotKit/VideoCanvas.swift`
- Rewrite: `Sources/AppShotKit/VideoFrame.swift`
- Modify: `Sources/AppShotKit/VideoTimeline.swift`. Delete `zooms`, `pointers`, `camera(at:)`, `cursor(at:)`, `zoomTransition`, `pointerTravel` and `ripple`, plus their assignments in `init`.
- Modify: `Sources/AppShotKit/VideoConfig.swift`. Replace `struct Zoom` with `struct Renamed`, and `Beat.zoom: Zoom?` with `Beat.zoom: Renamed?`; drop the `zoom:` init parameter and the zoom validation block, and add the rename check.
- Modify: `Sources/AppShotKit/AppShotError.swift`: the `zoomRenamed` case.
- Modify: `Sources/AppShotKit/VideoCompose.swift`. Pass `preset:` and `timeline:` to `VideoFrame.style`, using `MotionPreset.kinetic` until Task 9 wires `--motion`.
- Modify: `Sources/AppShotKit/ContactSheet.swift:19-21` (comment only), `Sources/AppShotKit/VideoTrack.swift:7` (comment) and `Sources/AppShotFixture/VideoFixture.swift:111` (comment: "zoom" → "focus").
- Modify: `Scripts/fixture-video.config.json`. `{ "zoom": { "target": "row-3", "scale": 1.8 } }` becomes `{ "focus": { "target": "row-3" } }`, and `{ "zoom": { "scale": 1 } }` becomes `{ "focus": "home" }`.
- Test: `Tests/AppShotKitTests/VideoFrameTests.swift`, `VideoTimelineTests.swift` and `VideoConfigTests.swift`.

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces:
  - `VideoCanvas(width:height:)`, with `ctx: CGContext`, `image(_:in:alpha:)`, `text(_:x:baseline:)`, `yUp(_:)` and `makeImage()`. Its space is y-down.
  - `VideoFrame.style(kind:size:config:appearance:video:stage:icon:preset:timeline:) throws -> Style`
  - `Style` fields: `kind`, `size`, `preset`, `stageRect` (the window at rest), `camera: VideoCamera`, `bandHeight`, `margin`, `captionFontSize`, `minDim`
  - `VideoFrame.render(stage:t:timeline:style:) throws -> CGImage`. Its signature is unchanged.
  - `VideoFrame.layers(stage:t:timeline:style:) throws -> CGImage`, a single sample with no blur, used by Task 7.
  - `VideoFrame.cardText(_:style:) throws -> [CardLine]`
  - `VideoFrame.scrim(_ theme: Config.Theme) -> String`
  - `AppShotError.zoomRenamed(video: String, beat: Int)`, slug `zoom_renamed`

- [ ] **Step 1: Write the failing tests.** In `VideoFrameTests.swift`:

(a) Change the static `config()` so its video has a hook and a pop region:

```swift
    static func config() throws -> Config {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 20, "hook": "Hello *there*",
                   "outputs": { "preview": true, "promo": [[1080, 1080]] },
                   "card": { "title": "Armada", "subtitle": "armada.mgcrea.io", "cta": "Get it" },
                   "beats": [{ "at": 2, "caption": "Hello again" }, { "at": 18, "endCard": true }] }]
                """)
        config.fontFamily = "Helvetica"
        return config
    }

    static func styled(
        _ kind: VideoFrame.Kind, _ size: Config.Size, preset: MotionPreset = .kinetic,
        stage: CGSize = CGSize(width: 800, height: 500), appearance: String = "dark"
    ) throws -> (VideoFrame.Style, VideoTimeline) {
        let config = try Self.config()
        let video = try config.video("v")
        let track = VideoTrack.stills(video: video, appearance: appearance, stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: kind, size: size, config: config, appearance: appearance, video: video, stage: stage,
            icon: nil, preset: preset, timeline: timeline)
        return (style, timeline)
    }

    /// A stage of one colour no theme uses, so "is the window on screen" is a pixel test.
    static func green(_ w: Int = 800, _ h: Int = 500) throws -> CGImage {
        let ctx = try #require(Image.context(width: w, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try #require(ctx.makeImage())
    }

    static func hasGreen(_ image: CGImage) throws -> Bool {
        let px = try #require(Image.pixels(image))
        return stride(from: 0, to: px.bytes.count, by: 4).contains {
            px.bytes[$0] < 40 && px.bytes[$0 + 1] > 200 && px.bytes[$0 + 2] < 40
        }
    }
```

Before relying on `hasGreen`, check `Image.pixels`' byte order: if it is BGRA rather than RGBA, swap the red and blue indices.

(b) Update the four existing tests to call `Self.styled(...)`. `previewIsFullBleedOnTheDarkestStop` keeps its assertions. `promoReservesRoomForTheCaption` becomes:

```swift
    @Test func bandCaptionsReserveTheBand() throws {
        let (style, _) = try Self.styled(.promo, .init(width: 1080, height: 1080))
        #expect(style.bandHeight > 100)
        #expect(style.stageRect.minY >= style.bandHeight)
        #expect(style.stageRect.maxY <= 1080)
    }

    @Test func pillCaptionsLetTheWindowFillMoreOfTheFrame() throws {
        let (band, _) = try Self.styled(.promo, .init(width: 1920, height: 1080))
        let (pill, _) = try Self.styled(.promo, .init(width: 1920, height: 1080), preset: .studio)
        #expect(pill.stageRect.width > band.stageRect.width)
    }
```

`endCardCoversThePromo` becomes:

```swift
    @Test func theWindowIsGoneOnceTheCardIsUp() throws {
        for preset in MotionPreset.all {
            let (style, timeline) = try Self.styled(.promo, .init(width: 540, height: 540), preset: preset)
            let frame = try VideoFrame.render(stage: Self.green(), t: 19.5, timeline: timeline, style: style)
            #expect(try !Self.hasGreen(frame), "\(preset.name)")
        }
    }
```

`wrappedCardTextStacksInsideTheMargins` becomes:

```swift
    @Test func wrappedCardTextStacksInsideTheMargins() throws {
        let (style, _) = try Self.styled(.promo, .init(width: 1080, height: 1080))
        let card = Config.Card(
            title: "A product name long enough to need *several lines* on a square promo",
            subtitle: String(repeating: "and a subtitle far too long for one line ", count: 6), icon: nil,
            cta: nil)
        let text = try VideoFrame.cardText(card, style: style)
        let titleRows = Set(text.filter { $0.role == .title }.map(\.baseline))
        let subtitles = text.filter { $0.role == .subtitle }
        #expect(titleRows.count > 1 && subtitles.count > 1)
        #expect((subtitles.first?.baseline ?? 0) > (titleRows.max() ?? .infinity))
        let W = Double(style.size.width)
        #expect(
            text.allSatisfy {
                $0.x >= style.margin - 0.5
                    && $0.x + $0.width - CTLineGetTrailingWhitespaceWidth($0.line) <= W - style.margin + 0.5
            })
    }
```

(c) Add:

```swift
    @Test func kineticOpensOnTheHookWithNoWindow() throws {
        let (style, timeline) = try Self.styled(.promo, .init(width: 320, height: 320))
        let frame = try VideoFrame.render(stage: Self.green(), t: 0.5, timeline: timeline, style: style)
        #expect(try !Self.hasGreen(frame))
        let later = try VideoFrame.render(stage: Self.green(), t: 4, timeline: timeline, style: style)
        #expect(try Self.hasGreen(later))
    }

    @Test func previewsNeverDrawTheHookOrTheCard() throws {
        let (style, timeline) = try Self.styled(.preview, .init(width: 1920, height: 1080))
        for t in [0.9, 19.5] {
            let frame = try VideoFrame.render(stage: Self.green(), t: t, timeline: timeline, style: style)
            #expect(try Self.hasGreen(frame), "t=\(t)")
        }
    }

    @Test func aFrameIsAFunctionOfItsTime() throws {
        let (style, timeline) = try Self.styled(.promo, .init(width: 320, height: 320))
        let a = try VideoFrame.render(stage: Self.green(), t: 3.3, timeline: timeline, style: style)
        let b = try VideoFrame.render(stage: Self.green(), t: 3.3, timeline: timeline, style: style)
        #expect(Image.pngData(a) == Image.pngData(b))
    }

    @Test func theScrimContrastsWithTheCaption() throws {
        let config = try Self.config()
        func luma(_ hex: String) -> Double {
            let c = Image.color(hex: hex)!.components!
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        for (name, theme) in config.themes {
            let gap = abs(luma(VideoFrame.scrim(theme)) - luma(theme.title))
            #expect(gap > 0.4, "\(name)")
        }
    }

    @Test func aHookTooLongForTheCanvasFailsClearly() throws {
        var config = try Self.config()
        config.videos![0].hook = String(repeating: "word ", count: 60)
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        #expect {
            _ = try VideoFrame.style(
                kind: .promo, size: .init(width: 320, height: 200), config: config, appearance: "dark",
                video: video, stage: stage, icon: nil, preset: .kinetic, timeline: timeline)
        } throws: { error in
            guard case .videoRenderFailed(_, let why) = error as? AppShotError else { return false }
            return why.contains("leaves no room")
        }
    }
```

(d) In `VideoConfigTests`, change `valid`'s beat `{ "at": 4, "zoom": { "target": "row-2", "scale": 1.6 } }` to `{ "at": 4, "focus": { "target": "row-2" } }`. Delete the `rejects` argument whose JSON holds `"zoom":{"scale":2}`. Add:

```swift
    @Test func zoomWasRenamedToFocus() throws {
        let config = try Self.config(
            videos: #"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"zoom":{"scale":2}}]}]"#)
        #expect {
            try config.validate()
        } throws: { error in
            guard case .zoomRenamed(let video, let beat) = error as? AppShotError else { return false }
            return video == "x" && beat == 0
                && (error as? AppShotError)?.description.contains("`focus`") == true
        }
    }
```

(e) In `VideoTimelineTests`, delete `cameraEasesToTheTarget`, `zoomOnUnreportedTargetThrows` and `cursorTravelsThenRipples`. In `VideoRerenderTests`, replace `aZoomFindsItsTargetWithTheNewTimes` with:

```swift
    @Test func aFocusFindsItsTargetWithTheNewTimes() throws {
        let target = VideoTrack.Target(seq: 0, name: "row", at: 1, rect: [100, 100, 200, 100], click: false)
        let taken = try VideoTimelineTests.video(
            #"[{"at":1,"cue":"pointer.move","args":{"target":"row"}},{"at":2,"focus":{"target":"row"}}]"#)
        var track = Self.recorded(taken, acks: [1.04])
        track.targets = [target]
        let moved = try VideoTimelineTests.video(
            #"[{"at":1,"cue":"pointer.move","args":{"target":"row"}},{"at":3,"focus":{"target":"row"}}]"#)
        let timeline = try VideoTimeline(video: moved, track: track)
        #expect(timeline.focusKeys.map(\.time) == [3])
        #expect(timeline.focusKeys[0].rect == CGRect(x: 100, y: 100, width: 200, height: 100))
    }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoFrameTests`
Expected: compile failure; `style` has no `preset:` parameter.

- [ ] **Step 3: Create `Sources/AppShotKit/VideoCanvas.swift`**

```swift
import CoreGraphics
import CoreText

/// A bitmap drawn in y-down pixels, the space every rect in a config and a track uses.
final class VideoCanvas {
    let ctx: CGContext
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard let ctx = Image.context(width: width, height: height) else { return nil }
        self.ctx = ctx
        self.width = width
        self.height = height
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
    }

    /// Draws `image` upright in `rect`.
    func image(_ image: CGImage, in rect: CGRect, alpha: Double = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Draws a line of text with its left edge at `x` and its baseline at `baseline`.
    func text(_ line: CTLine, x: Double, baseline: Double) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Runs `draw` in CoreGraphics' own y-up space, for helpers written for it.
    func yUp(_ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: 1, y: -1)
        draw()
        ctx.restoreGState()
    }

    func makeImage() -> CGImage? { ctx.makeImage() }
}
```

Note: a shadow's offset is in device space and ignores the flip, so a shadow falling *down* the frame has a **negative** height offset.

- [ ] **Step 4: Rewrite `Sources/AppShotKit/VideoFrame.swift`**

```swift
import CoreGraphics
import CoreText
import Foundation

/// One rendered video frame: the layers a preset asks for, at time t.
public enum VideoFrame {
    public enum Kind: Sendable { case promo, preview }

    public struct Style: @unchecked Sendable {
        public let kind: Kind
        public let size: Config.Size
        public let preset: MotionPreset
        /// The window at rest (zoom 1), y-down.
        public let stageRect: CGRect
        public let camera: VideoCamera
        /// The caption band's height; 0 for pill captions and previews.
        public let bandHeight: Double
        public let margin: Double
        public let captionFontSize: Double
        public var minDim: Double { Double(min(size.width, size.height)) }
        let captionFont: CTFont
        /// Previews: the caption strip's first baseline.
        let previewBaseline: Double
        let theme: Config.Theme
        let fontFamily: String
        let titleColor: CGColor
        let subtitleColor: CGColor
        let accent: CGColor
        let scrimColor: CGColor
        let card: Config.Card?
        let icon: CGImage?
    }

    static func luma(_ hex: String) -> Double {
        guard let c = Image.color(hex: hex)?.components, c.count >= 3 else { return 1 }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    /// The darkest stop by luma: the preview's surround, which must read as the app's
    /// own backdrop rather than as marketing.
    static func darkest(_ background: Config.Background) -> String {
        background.stops.min { luma($0.color) < luma($1.color) }?.color ?? "#000000"
    }

    /// The gradient stop that contrasts most with the caption colour. The scrim under a
    /// caption must keep it readable over the app, in light themes as in dark ones.
    public static func scrim(_ theme: Config.Theme) -> String {
        let title = luma(theme.title)
        return theme.background.stops.max {
            abs(luma($0.color) - title) < abs(luma($1.color) - title)
        }?.color ?? "#000000"
    }

    public static func style(
        kind: Kind, size: Config.Size, config: Config, appearance: String, video: Config.Video,
        stage: CGSize, icon: CGImage?, preset: MotionPreset, timeline: VideoTimeline
    ) throws -> Style {
        guard let theme = config.themes[appearance] else { throw AppShotError.missingTheme(appearance) }
        let W = Double(size.width)
        let H = Double(size.height)
        let minDim = min(W, H)
        let m = (minDim * 0.05).rounded()
        let titleColor = Image.color(hex: theme.title) ?? CGColor(gray: 1, alpha: 1)
        let accent = theme.accent.flatMap { Image.color(hex: $0) } ?? titleColor

        var box: CGRect
        var band = 0.0
        var fontSize: Double
        var weight = preset.captionWeight
        var previewBaseline = 0.0
        switch kind {
        case .promo:
            fontSize = (preset.captionSize * minDim).rounded()
            if preset.captions == .band {
                // Room for the longest caption, the hook included, so the window never
                // moves between captions.
                let font = try Text.font(stack: config.fontFamily, weight: weight, size: fontSize)
                let rows =
                    timeline.captions.compactMap { KineticText.tokens($0.text) }.map {
                        KineticText.layout(
                            $0, font: font, color: titleColor, accent: titleColor, maxWidth: W - 2 * m
                        ).rows
                    }.max() ?? 0
                band = rows == 0 ? m : Double(rows) * fontSize * 1.15 + 2 * m
                box = CGRect(x: m, y: band, width: W - 2 * m, height: H - band - m)
            } else {
                box = CGRect(x: m, y: m, width: W - 2 * m, height: H - 2 * m)
            }
        case .preview:
            let strip = (H * 0.11).rounded()
            let inset = (m * 0.5).rounded()
            box = CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset - strip)
            fontSize = (strip * 0.42).rounded()
            weight = config.layout.titleWeight
            previewBaseline = H - strip / 2 + fontSize * 0.35
        }
        guard box.width > 1, box.height > 1 else {
            throw AppShotError.videoRenderFailed(
                video: video.id, reason: "\(size.description) leaves no room for the app under the caption")
        }
        let fit = min(box.width / stage.width, box.height / stage.height)
        let w = (stage.width * fit).rounded()
        let h = (stage.height * fit).rounded()
        let stageRect = CGRect(
            x: ((W - w) / 2).rounded(), y: (box.minY + (box.height - h) / 2).rounded(), width: w, height: h)
        let hookCard = kind == .promo && preset.hookCard && timeline.hook != nil
        let camera = VideoCamera(
            preset: preset, stage: stage, canvas: CGSize(width: W, height: H), box: box,
            keys: timeline.focusKeys, entryAt: hookCard ? MotionPreset.hookDuration - 0.25 : 0,
            exitAt: kind == .promo ? timeline.cardStart : nil)

        return Style(
            kind: kind, size: size, preset: preset, stageRect: stageRect, camera: camera, bandHeight: band,
            margin: m, captionFontSize: fontSize,
            captionFont: try Text.font(stack: config.fontFamily, weight: weight, size: fontSize),
            previewBaseline: previewBaseline, theme: theme, fontFamily: config.fontFamily,
            titleColor: titleColor, subtitleColor: Image.color(hex: theme.subtitle) ?? titleColor,
            accent: accent, scrimColor: Image.color(hex: scrim(theme)) ?? CGColor(gray: 0, alpha: 1),
            card: kind == .promo ? video.card : nil, icon: icon)
    }

    public static func render(
        stage: CGImage, t: Double, timeline: VideoTimeline, style: Style
    ) throws -> CGImage {
        try layers(stage: stage, t: t, timeline: timeline, style: style)
    }

    /// One sample of the frame, every layer at exactly `t`.
    static func layers(
        stage: CGImage, t: Double, timeline: VideoTimeline, style: Style
    ) throws -> CGImage {
        guard let canvas = VideoCanvas(width: style.size.width, height: style.size.height) else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no bitmap context")
        }
        drawBackground(canvas, t: t, style: style)
        let placed = style.camera.placement(at: t)
        drawWindow(canvas, stage: stage, placed: placed, style: style)
        try drawCaption(canvas, t: t, timeline: timeline, placed: placed, style: style)
        if style.kind == .promo {
            try drawHook(canvas, t: t, timeline: timeline, style: style)
            try drawCard(canvas, t: t, timeline: timeline, style: style)
        }
        guard let image = canvas.makeImage() else {
            throw AppShotError.videoRenderFailed(video: "", reason: "frame did not render")
        }
        return image
    }

    static func drawBackground(_ canvas: VideoCanvas, t: Double, style: Style) {
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        let ctx = canvas.ctx
        switch style.kind {
        case .preview:
            ctx.setFillColor(Image.color(hex: darkest(style.theme.background)) ?? CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        case .promo:
            var background = style.theme.background
            background.angle += style.preset.swing * sin(2 * .pi * t / 20)
            canvas.yUp { Compose.drawGradient(ctx, background, width: W, height: H) }
            guard style.preset.glow, let clear = style.accent.copy(alpha: 0),
                let glow = style.accent.copy(alpha: 0.28),
                let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [glow, clear] as CFArray,
                    locations: [0, 1])
            else { return }
            let p = CGPoint(
                x: W * (0.5 + 0.3 * sin(2 * .pi * t / 14)), y: H * (0.62 + 0.12 * cos(2 * .pi * t / 11)))
            ctx.drawRadialGradient(
                gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: max(W, H) * 0.55, options: [])
        }
    }

    static func drawWindow(
        _ canvas: VideoCanvas, stage: CGImage, placed: VideoCamera.Placement, style: Style
    ) {
        guard placed.alpha > 0.001, placed.rect.maxY > 0, placed.rect.minY < Double(style.size.height)
        else { return }
        canvas.ctx.saveGState()
        canvas.ctx.setShadow(
            offset: CGSize(width: 0, height: -style.minDim * 0.02), blur: style.minDim * 0.05,
            color: CGColor(gray: 0, alpha: 0.45))
        canvas.image(stage, in: placed.rect, alpha: placed.alpha)
        canvas.ctx.restoreGState()
    }

    // MARK: - Text

    static func drawCaption(
        _ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, placed: VideoCamera.Placement,
        style: Style
    ) throws {
        guard let span = timeline.captions.last(where: { $0.start <= t && t < $0.end }),
            let tokens = KineticText.tokens(span.text)
        else { return }
        // A hook card holds the screen first; its text joins the band as it leaves.
        let from = span.isHook && style.kind == .promo && style.preset.hookCard ? MotionPreset.hookDuration : span.start
        guard t >= from else { return }
        let age = t - from
        let left = span.end - t
        let W = Double(style.size.width)
        let fs = style.captionFontSize
        let ctx = canvas.ctx
        let exit = Ease.clamp01(left / 0.25)

        switch (style.kind, style.preset.captions) {
        case (.preview, _):
            let plain = tokens.map { KineticText.Token(text: $0.text, accent: false) }
            let layout = KineticText.layout(
                plain, font: style.captionFont, color: style.titleColor, accent: style.titleColor,
                maxWidth: W - 2 * style.margin)
            ctx.saveGState()
            ctx.setAlpha(min(Ease.clamp01(age / 0.25), exit))
            for word in layout.words {
                canvas.text(
                    word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                    baseline: style.previewBaseline + Double(word.row) * fs * 1.15)
            }
            ctx.restoreGState()

        case (.promo, .pill):
            let padX = fs * 0.9
            let padY = fs * 0.55
            let plain = tokens.map { KineticText.Token(text: $0.text, accent: false) }
            let layout = KineticText.layout(
                plain, font: style.captionFont, color: style.titleColor, accent: style.titleColor,
                maxWidth: W - 2 * style.margin - 2 * padX)
            let enter = Ease.out(age / 0.4)
            let w = (layout.rowWidths.max() ?? 0) + padX * 2
            let h = Double(layout.rows) * fs * 1.15 - fs * 0.15 + padY * 2
            let y = Double(style.size.height) - style.minDim * 0.07 - h + (1 - enter) * style.minDim * 0.025
            let pill = CGRect(x: (W - w) / 2, y: y, width: w, height: h)
            ctx.saveGState()
            ctx.setAlpha(min(enter, exit))
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: min(h / 2, fs), cornerHeight: min(h / 2, fs), transform: nil))
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 0.72))
            ctx.fillPath()
            for word in layout.words {
                canvas.text(
                    word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                    baseline: pill.minY + padY + fs * 0.8 + Double(word.row) * fs * 1.15)
            }
            ctx.restoreGState()

        case (.promo, .band):
            // A scrim under the band once the camera has pushed the window up into it.
            let intrude = Ease.clamp01((style.bandHeight - placed.rect.minY) / (style.bandHeight * 0.5))
            if intrude > 0, let top = style.scrimColor.copy(alpha: 0.88 * intrude * placed.alpha),
                let clear = style.scrimColor.copy(alpha: 0),
                let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, top, clear] as CFArray,
                    locations: [0, 0.55, 1])
            {
                ctx.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: style.bandHeight * 1.3), options: [])
            }
            let layout = KineticText.layout(
                tokens, font: style.captionFont, color: style.titleColor, accent: style.accent,
                maxWidth: W - 2 * style.margin)
            let step = fs * 1.15
            let top = (style.bandHeight - Double(layout.rows) * step) / 2 + fs * 0.85
            for (index, word) in layout.words.enumerated() {
                var alpha: Double
                var drop = -(1 - exit) * 0.3
                if style.preset.wordStagger > 0 {
                    let e = KineticText.entrance(
                        age: age, index: index, stagger: style.preset.wordStagger, spring: style.preset.wordSpring)
                    alpha = min(e.alpha, exit)
                    drop += e.drop
                } else {
                    alpha = min(Ease.smooth(age / 0.35), exit)
                }
                ctx.saveGState()
                ctx.setAlpha(alpha)
                canvas.text(
                    word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                    baseline: top + Double(word.row) * step + drop * fs)
                ctx.restoreGState()
            }
        }
    }

    static func drawHook(_ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, style: Style) throws {
        guard style.preset.hookCard, let hook = timeline.hook, t < MotionPreset.hookDuration,
            let tokens = KineticText.tokens(hook)
        else { return }
        let W = Double(style.size.width)
        let H = Double(style.size.height)
        let font = try Text.font(stack: style.fontFamily, weight: 800, size: (style.preset.hookSize * style.minDim).rounded())
        let size = CTFontGetSize(font)
        let layout = KineticText.layout(
            tokens, font: font, color: style.titleColor, accent: style.accent, maxWidth: W * 0.84)
        let step = size * 1.08
        let top = (H - Double(layout.rows) * step) / 2 + size * 0.8
        let exit = Ease.clamp01((t - (MotionPreset.hookDuration - 0.35)) / 0.3)
        for (index, word) in layout.words.enumerated() {
            let e = KineticText.entrance(
                age: t - 0.1, index: index, stagger: style.preset.hookStagger,
                spring: Spring(response: 0.45, damping: 0.65))
            canvas.ctx.saveGState()
            canvas.ctx.setAlpha(e.alpha * (1 - exit))
            canvas.text(
                word.line, x: (W - layout.rowWidths[word.row]) / 2 + word.x,
                baseline: top + Double(word.row) * step + (e.drop - exit * exit * 0.8) * size)
            canvas.ctx.restoreGState()
        }
    }

    // MARK: - End card

    public struct CardLine {
        public enum Role: Sendable { case title, subtitle }
        public let line: CTLine
        public let width: Double
        /// Left edge, y-down canvas pixels.
        public let x: Double
        public let baseline: Double
        public let role: Role
    }

    static func cardGeometry(_ style: Style) -> (side: Double, midY: Double) {
        (style.minDim * 0.24, Double(style.size.height) * 0.38)
    }

    /// The card's title (accent marks honoured) and subtitle, wrapped inside the margins,
    /// one baseline per row so a long name stacks instead of overprinting itself.
    static func cardText(_ content: Config.Card, style: Style) throws -> [CardLine] {
        let W = Double(style.size.width)
        let maxWidth = W - 2 * style.margin
        let titleSize = (style.minDim * 0.085).rounded()
        let subSize = (style.minDim * 0.038).rounded()
        let titleFont = try Text.font(stack: style.fontFamily, weight: 800, size: titleSize)
        let subFont = try Text.font(stack: style.fontFamily, weight: 500, size: subSize)
        let card = cardGeometry(style)
        var out: [CardLine] = []
        var baseline = card.midY + card.side / 2 + style.minDim * 0.11
        let title = KineticText.layout(
            KineticText.tokens(content.title) ?? [], font: titleFont, color: style.titleColor,
            accent: style.accent, maxWidth: maxWidth)
        for word in title.words {
            out.append(
                CardLine(
                    line: word.line, width: word.width, x: (W - title.rowWidths[word.row]) / 2 + word.x,
                    baseline: baseline + Double(word.row) * titleSize * 1.08, role: .title))
        }
        baseline += Double(max(title.rows - 1, 0)) * titleSize * 1.08
        if let subtitle = content.subtitle {
            baseline += style.minDim * 0.065
            let lines = Text.wrap(subtitle, font: subFont, color: style.subtitleColor, kern: 0, maxWidth: maxWidth)
            for (i, line) in lines.enumerated() {
                if i > 0 { baseline += subSize * 1.3 }
                out.append(
                    CardLine(
                        line: line.ctLine, width: line.width, x: (W - line.width) / 2, baseline: baseline,
                        role: .subtitle))
            }
        }
        return out
    }

    static func drawCard(_ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, style: Style) throws {
        guard let start = timeline.cardStart, let content = style.card else { return }
        let q = t - start - 0.3
        guard q > 0 else { return }
        let W = Double(style.size.width)
        let ctx = canvas.ctx
        let card = cardGeometry(style)
        let springy = style.preset.card == .spring

        var iconScale = 1.0
        var iconAlpha: Double
        var iconDrop = 0.0
        if springy {
            iconScale = Spring(response: 0.55, damping: 0.55).value(q)
            iconAlpha = Ease.clamp01(q / 0.08)
        } else {
            iconAlpha = Ease.out(q / 0.7)
            iconDrop = (1 - iconAlpha) * style.minDim * 0.04
        }
        if let icon = style.icon {
            let s = card.side * iconScale
            let rect = CGRect(x: (W - s) / 2, y: card.midY - s / 2 + iconDrop, width: s, height: s)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -style.minDim * 0.015), blur: style.minDim * 0.04,
                color: CGColor(gray: 0, alpha: 0.4 * iconAlpha))
            canvas.image(icon, in: rect, alpha: iconAlpha)
            ctx.restoreGState()
        }

        func arrival(_ delay: Double) -> (alpha: Double, drop: Double) {
            let a = q - delay
            if springy {
                return (Ease.clamp01(a / 0.12), (1 - Spring(response: 0.5, damping: 0.7).value(a)) * style.minDim * 0.05)
            }
            let e = Ease.out(a / 0.6)
            return (e, (1 - e) * style.minDim * 0.03)
        }
        let lines = try cardText(content, style: style)
        for line in lines {
            let a = arrival(line.role == .title ? 0.15 : 0.3)
            ctx.saveGState()
            ctx.setAlpha(a.alpha)
            canvas.text(line.line, x: line.x, baseline: line.baseline + a.drop)
            ctx.restoreGState()
        }

        guard let cta = content.cta else { return }
        let a = arrival(0.6)
        guard a.alpha > 0 else { return }
        let font = try Text.font(stack: style.fontFamily, weight: 600, size: (style.minDim * 0.03).rounded())
        let fs = CTFontGetSize(font)
        let line = KineticText.line(cta, font: font, color: springy ? CGColor(gray: 1, alpha: 1) : style.titleColor)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let h = fs * 2.2
        let w = width + fs * 2.4
        let top = (lines.map(\.baseline).max() ?? card.midY) + style.minDim * 0.055 + a.drop
        let pill = CGRect(x: (W - w) / 2, y: top, width: w, height: h)
        ctx.saveGState()
        ctx.setAlpha(a.alpha)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        if springy {
            ctx.setFillColor(style.accent)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(style.titleColor.copy(alpha: 0.5) ?? style.titleColor)
            ctx.setLineWidth(style.minDim * 0.002)
            ctx.strokePath()
        }
        canvas.text(line, x: pill.minX + fs * 1.2, baseline: pill.minY + h / 2 + fs * 0.35)
        ctx.restoreGState()
    }
}
```

- [ ] **Step 5: Remove `zoom`.** In `VideoConfig.swift`, replace the `Zoom` struct and its doc comment with:

```swift
    /// `zoom` became `focus` before videos shipped. The key is still read so validation
    /// can say so instead of silently ignoring it; its content is not.
    public struct Renamed: Codable, Sendable, Equatable {
        public init() {}
        public init(from decoder: Decoder) throws {}
        public func encode(to encoder: Encoder) throws {}
    }
```

Change `Beat`'s `public var zoom: Zoom?` to `public var zoom: Renamed?`, remove `zoom` from `Beat.init`'s parameters and body, and delete the `if let zoom = beat.zoom { … }` validation block. As the first statement inside the beat loop, add:

```swift
                if beat.zoom != nil { throw AppShotError.zoomRenamed(video: video.id, beat: i) }
```

In `AppShotError.swift` add the case `zoomRenamed(video: String, beat: Int)`, this description:

```swift
        case .zoomRenamed(let video, let beat):
            return """
                videos["\(video)"]: beat \(beat) uses `zoom`, which is now `focus`: drop `scale`, the \
                framing is computed. Write "focus": { "rect": [x, y, w, h] } or { "target": name }, \
                and "focus": "home" for the whole window.
                """
```

and this slug: `case .zoomRenamed: return "zoom_renamed"`.

In `VideoTimeline.swift`, delete `zoomTransition`, `pointerTravel`, `ripple`, the `zooms` and `pointers` properties and their `init` assignments, `camera(at:)` and `cursor(at:)`. Keep `fade` and `cardFade` only if something still uses them: grep, and delete them if nothing does.

In `ContactSheet.swift`, replace the `settle` comment with:

```swift
    /// After a beat, the UI may still be animating: 0.8 s covers kinetic's 0.7 s camera
    /// spring and most of studio's 1 s one.
```

Fix the "zoom" comments in `VideoTrack.swift:7` and `VideoFixture.swift:111`, and the fixture config, as listed under Files.

In `VideoCompose.swift`, both `VideoFrame.style(...)` calls gain `preset: .kinetic, timeline: job.timeline`.

- [ ] **Step 6: Run the tests and see them pass**

Run: `swift test --filter VideoFrameTests && swift test --filter VideoConfigTests && swift test --filter VideoTimelineTests && swift test --filter VideoComposeTests`
Expected: all pass. Then confirm `zoom` is gone from the code:

```bash
grep -rn "zoom" Sources Tests Scripts | grep -v -i "zoomCap\|zoomRenamed\|Renamed\|zoom:\s*Double\|\.zoom\b\|zoom buttons\|minimise and zoom"
```

Expected: nothing about a `zoom` *beat key* remains. `zoom` as a camera quantity (`state.zoom`, `Placement.zoom`) is fine.

- [ ] **Step 7: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add -A Sources Tests Scripts
git commit -m "feat(video): render frames from the motion preset; zoom is now focus"
```

---

## Task 7: Spotlight, pop-outs, the pointer and motion blur

**Files:**
- Modify: `Sources/AppShotKit/VideoFrame.swift`
- Test: `Tests/AppShotKitTests/VideoFrameTests.swift`

**Interfaces:**
- Consumes: `VideoTimeline.spotlights`, `.pops` and `.pointer(at:)` (Task 5); `VideoCamera.Placement.map` (Task 4); `Style` and `layers` (Task 6).
- Produces: `VideoFrame.render` averages `preset.blurSamples` sub-frames over `preset.shutter` of a frame whenever the window moved more than `preset.blurThreshold` px in 1/60 s.

- [ ] **Step 1: Write the failing tests.** Add to `VideoFrameTests`:

```swift
    /// A white stage with a red block at `red`, and a video that spotlights or pops it.
    static func emphasis(
        _ key: String, rect: [Double], preset: MotionPreset, size: Config.Size = .init(width: 640, height: 640)
    ) throws -> (VideoFrame.Style, VideoTimeline, CGImage) {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 10, "outputs": { "promo": [[\(size.width), \(size.height)]] },
                   "beats": [{ "at": 1, "\(key)": { "rect": \(rect), "until": 8 } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: .promo, size: size, config: config, appearance: "dark", video: video, stage: stage, icon: nil,
            preset: preset, timeline: timeline)
        let ctx = try #require(Image.context(width: 800, height: 500))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // y-up context: flip the y-down rect.
        ctx.fill(CGRect(x: rect[0], y: 500 - rect[1] - rect[3], width: rect[2], height: rect[3]))
        return (style, timeline, try #require(ctx.makeImage()))
    }

    @Test func aSpotlightDimsEverythingButItsRegion() throws {
        let (style, timeline, stage) = try Self.emphasis("spotlight", rect: [300, 200, 200, 100], preset: .studio)
        let t = 4.0
        let frame = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        let placed = style.camera.placement(at: t)
        let outside = placed.map(CGPoint(x: 100, y: 100))
        let inside = placed.map(CGPoint(x: 310, y: 250))
        let o = try Self.pixel(frame, Int(outside.x), Int(outside.y))
        let i = try Self.pixel(frame, Int(inside.x), Int(inside.y))
        #expect(o[1] < 200)  // white stage, dimmed
        #expect(i[0] > 200)  // red block, not dimmed
    }

    @Test func aPopLiftsAnEnlargedCopyOfItsRegion() throws {
        let (style, timeline, stage) = try Self.emphasis("pop", rect: [300, 200, 200, 100], preset: .kinetic)
        let t = 4.0
        let frame = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        let base = style.camera.placement(at: t).map(CGRect(x: 300, y: 200, width: 200, height: 100))
        let lift = style.minDim * 0.012
        // Just right of the region itself, but inside its 1.32x copy.
        let p = try Self.pixel(frame, Int(base.maxX + base.width * 0.08), Int(base.midY - lift))
        #expect(p[0] > 180 && p[1] < 80)
    }

    @Test func aPopPastTheStageEdgeDrawsOnlyWhatExists() throws {
        let (style, timeline, stage) = try Self.emphasis("pop", rect: [700, 400, 300, 200], preset: .kinetic)
        for t in stride(from: 0.5, through: 9.5, by: 0.5) {
            _ = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        }
    }

    @Test func thePointerIsDrawnOnItsPoint() throws {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 6, "motion": "studio", "outputs": { "promo": [[640, 640]] },
                   "beats": [{ "at": 1, "pointer": { "point": [400, 250] } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 640, height: 640), config: config, appearance: "dark", video: video,
            stage: stage, icon: nil, preset: .studio, timeline: timeline)
        let frame = try VideoFrame.render(stage: Self.stage(), t: 2, timeline: timeline, style: style)
        let placed = style.camera.placement(at: 2)
        let tip = placed.map(CGPoint(x: 400, y: 250))
        let size = style.minDim * 0.03 * placed.zoom.squareRoot()
        let inArrow = try Self.pixel(frame, Int(tip.x + size * 0.12), Int(tip.y + size * 0.6))
        #expect(inArrow[0] < 60)  // the arrow's black fill on a white stage
    }

    @Test func fastMovesAreBlurredAndStillFramesAreNot() throws {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 6, "outputs": { "promo": [[320, 320]] },
                   "beats": [{ "at": 1, "focus": { "rect": [0, 0, 100, 60] } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        var preset = MotionPreset.kinetic
        preset.drift = 0
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 320, height: 320), config: config, appearance: "dark", video: video,
            stage: stage, icon: nil, preset: preset, timeline: timeline)
        let image = try Self.stage()
        let moving = 1.15
        #expect(
            Image.pngData(try VideoFrame.render(stage: image, t: moving, timeline: timeline, style: style))
                != Image.pngData(try VideoFrame.layers(stage: image, t: moving, timeline: timeline, style: style)))
        let still = 5.5
        #expect(
            Image.pngData(try VideoFrame.render(stage: image, t: still, timeline: timeline, style: style))
                == Image.pngData(try VideoFrame.layers(stage: image, t: still, timeline: timeline, style: style)))
    }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoFrameTests`
Expected: the five new tests fail, because nothing draws spotlights, pops or the pointer and nothing blurs. `aPopPastTheStageEdgeDrawsOnlyWhatExists` passes vacuously for now and keeps guarding the clipping fix.

- [ ] **Step 3: Draw the overlays.** In `layers(...)`, after `drawWindow(...)`, add:

```swift
        drawSpotlights(canvas, t: t, timeline: timeline, placed: placed, style: style)
        drawPops(canvas, stage: stage, t: t, timeline: timeline, placed: placed, style: style)
        drawPointer(canvas, t: t, timeline: timeline, placed: placed, style: style)
```

Add to `VideoFrame`:

```swift
    // MARK: - Emphasis

    /// 0 outside the span; rises on `rise` from its start and falls over 0.4 s after it.
    static func envelope(_ t: Double, _ span: VideoTimeline.Span, rise: Spring) -> Double {
        guard t > span.from, t < span.to + 0.4 else { return 0 }
        return min(rise.value(t - span.from), Ease.smooth((span.to + 0.4 - t) / 0.4))
    }

    static func drawSpotlights(
        _ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, placed: VideoCamera.Placement,
        style: Style
    ) {
        let ctx = canvas.ctx
        let pad = style.minDim * 0.012
        for span in timeline.spotlights {
            let env = Ease.clamp01(envelope(t, span, rise: Spring(response: 0.6, damping: 1)))
            guard env > 0.001 else { continue }
            let hole = placed.map(span.rect).insetBy(dx: -pad, dy: -pad)
            // CGPath traps on a corner radius over half a side.
            let corner = min(pad * 1.4, hole.width / 2, hole.height / 2)
            let path = CGMutablePath()
            path.addRect(placed.rect)
            path.addRoundedRect(in: hole, cornerWidth: corner, cornerHeight: corner)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: style.preset.spotlightDim * env * placed.alpha))
            ctx.fillPath(using: .evenOdd)
            if style.preset.spotlightOutline {
                ctx.addPath(CGPath(roundedRect: hole, cornerWidth: corner, cornerHeight: corner, transform: nil))
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35 * env * placed.alpha))
                ctx.setLineWidth(style.minDim * 0.003)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    static func drawPops(
        _ canvas: VideoCanvas, stage: CGImage, t: Double, timeline: VideoTimeline,
        placed: VideoCamera.Placement, style: Style
    ) {
        guard case .lift(let popScale) = style.preset.pop else { return }
        let W = Double(style.size.width)
        let ctx = canvas.ctx
        let bounds = CGRect(x: 0, y: 0, width: stage.width, height: stage.height)
        for pop in timeline.pops {
            let env = envelope(t, pop, rise: style.preset.popSpring)
            // Only the part of the region the stage has: cropping clips silently, and
            // drawing a clipped crop into the full rect would stretch it.
            let region = pop.rect.intersection(bounds).integral
            guard env > 0.001, !region.isEmpty, let crop = stage.cropping(to: region) else { continue }
            let base = placed.map(region)
            let s = min(1 + (popScale - 1) * env, W * 0.94 / base.width)
            var dest = CGRect(
                x: base.midX - base.width * s / 2, y: base.midY - base.height * s / 2, width: base.width * s,
                height: base.height * s)
            dest.origin.x = min(max(dest.minX, W * 0.03), W * 0.97 - dest.width)
            dest.origin.y -= style.minDim * 0.012 * env
            let radius = min(style.minDim * 0.012 * s, dest.width / 2, dest.height / 2)
            let rounded = CGPath(roundedRect: dest, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -style.minDim * 0.02 * env), blur: style.minDim * 0.05 * env,
                color: CGColor(gray: 0, alpha: 0.6 * Ease.clamp01(env)))
            ctx.addPath(rounded)
            ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(rounded)
            ctx.clip()
            canvas.image(crop, in: dest)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(rounded)
            ctx.setStrokeColor(style.accent.copy(alpha: Ease.clamp01(env)) ?? style.accent)
            ctx.setLineWidth(style.minDim * 0.004)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// A plain arrow, drawn rather than borrowed: Apple's cursor artwork is not ours to
    /// ship. Sized with the zoom's square root, so it reads at any framing.
    static func drawPointer(
        _ canvas: VideoCanvas, t: Double, timeline: VideoTimeline, placed: VideoCamera.Placement,
        style: Style
    ) {
        guard let pointer = timeline.pointer(at: t) else { return }
        var size = style.minDim * 0.03 * placed.zoom.squareRoot()
        if let age = pointer.clickAge, age < 0.18 { size *= 1 - 0.15 * sin(age / 0.18 * .pi) }
        let tip = placed.map(pointer.point)
        let ctx = canvas.ctx
        ctx.saveGState()
        ctx.setAlpha(pointer.alpha * placed.alpha)
        if let age = pointer.clickAge {
            let r = size * (0.5 + age / 0.5 * 1.2)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7 * (1 - age / 0.5)))
            ctx.setLineWidth(size * 0.1)
            ctx.strokeEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
        }
        let outline: [(Double, Double)] = [
            (0, 0), (0, 1), (0.28, 0.74), (0.46, 1.1), (0.6, 1.04), (0.43, 0.68), (0.78, 0.68),
        ]
        let path = CGMutablePath()
        path.addLines(between: outline.map { CGPoint(x: tip.x + $0.0 * size, y: tip.y + $0.1 * size) })
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.2, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(size * 0.07)
        ctx.strokePath()
        ctx.restoreGState()
    }
```

- [ ] **Step 4: Blur fast moves.** Replace `render(...)`'s body with:

```swift
        let preset = style.preset
        let now = style.camera.placement(at: t).rect
        let before = style.camera.placement(at: t - 1.0 / 60).rect
        let moved = abs(now.minX - before.minX) + abs(now.minY - before.minY) + abs(now.width - before.width)
        guard preset.blurSamples > 1, moved > preset.blurThreshold else {
            return try layers(stage: stage, t: t, timeline: timeline, style: style)
        }
        // A 90° shutter: 180° smeared fast zoom-outs into mush. Every sub-frame uses the
        // same stage image, because a recorded master only reads forwards.
        guard let canvas = VideoCanvas(width: style.size.width, height: style.size.height) else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no bitmap context")
        }
        let full = CGRect(x: 0, y: 0, width: style.size.width, height: style.size.height)
        let span = preset.shutter / Double(VideoWriter.fps)
        for i in 0..<preset.blurSamples {
            let at = t - span * Double(i) / Double(preset.blurSamples - 1)
            // A running average: sample i weighs 1/(i+1) over the mean of those before it.
            canvas.image(
                try layers(stage: stage, t: at, timeline: timeline, style: style), in: full,
                alpha: 1 / Double(i + 1))
        }
        guard let image = canvas.makeImage() else {
            throw AppShotError.videoRenderFailed(video: "", reason: "frame did not render")
        }
        return image
```

- [ ] **Step 5: Run the tests and see them pass**

Run: `swift test --filter VideoFrameTests`
Expected: all pass. If `fastMovesAreBlurredAndStillFramesAreNot` fails at t = 1.15, print `moved`; the kinetic spring there must move the window by more than 3 px per 1/60 s.

- [ ] **Step 6: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoFrame.swift Tests/AppShotKitTests/VideoFrameTests.swift
git commit -m "feat(video): spotlights, pop-outs, the drawn pointer and motion blur"
```

---

## Task 8: Sheets in stills

**Files:**
- Modify: `Sources/AppShotKit/VideoMaster.swift`. Change `StillsMaster`'s keys and `init`, and its `frame(at:)`.
- Modify: `Sources/AppShotKit/VideoCompose.swift`. The two `StillsMaster(...)` calls pass `sheet: MotionPreset.kinetic.sheet` for now; Task 9 passes the job's preset.
- Test: `Tests/AppShotKitTests/VideoMasterTests.swift`

**Interfaces:**
- Consumes: `Beat.present` (Task 3), `Spring`, `Ease` (Task 1), `VideoCanvas` (Task 6).
- Produces: `StillsMaster(video:sourceDir:appearance:sheet: Spring = MotionPreset.kinetic.sheet)`.

- [ ] **Step 1: Write the failing tests.** Add to `VideoMasterTests`:

```swift
    /// A stills video over three captures: `browser` bare, then `paywall` and `organize`
    /// each presenting a sheet at `sheet`.
    static func sheets(_ dir: URL, sheet: [Int] = [20, 10, 60, 30]) throws -> Config.Video {
        let json = ConfigTests.json.replacingOccurrences(
            of: "\"screens\": [",
            with: """
                "videos": [{ "id": "v", "duration": 6, "outputs": { "promo": [[100, 100]] },
                  "beats": [{ "at": 0, "screen": "browser" },
                            { "at": 2, "screen": "paywall", "present": \(sheet) },
                            { "at": 4, "screen": "organize", "present": \(sheet) }] }],
                "screens": [{ "id": "organize", "title": "Organize" },
                """)
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8)).video("v")
    }

    /// A 100x50 capture: `base` grey, with `inside` filling the y-down rect `r`.
    static func capture(_ base: Double, inside: CGColor? = nil, r: CGRect, to url: URL) throws {
        let ctx = try #require(Image.context(width: 100, height: 50))
        ctx.setFillColor(CGColor(gray: base, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        if let inside {
            ctx.setFillColor(inside)
            ctx.fill(CGRect(x: r.minX, y: 50 - r.maxY, width: r.width, height: r.height))
        }
        try Image.write(try #require(ctx.makeImage()), to: url)
    }

    @Test func aPresentedSheetSpringsUpOverTheWindow() throws {
        let dir = try Self.dir()
        let r = CGRect(x: 20, y: 10, width: 60, height: 30)
        try Self.capture(0, r: r, to: dir.appending(path: "browser~dark.png"))
        try Self.capture(0, inside: CGColor(gray: 1, alpha: 1), r: r, to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(0, r: r, to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        let px = { (img: CGImage, x: Int, y: Int) in Image.pixels(img)!.bytes[(y * 100 + x) * 4] }
        // Mid-spring the sheet is still smaller than its rect: its left edge shows the window.
        #expect(px(try master.frame(at: 2.15), 20, 25) < 128)
        #expect(px(try master.frame(at: 3.5), 21, 25) == 255)
    }

    @Test func swappingSheetsNeverShowsBothAtOnce() throws {
        let dir = try Self.dir()
        let r = CGRect(x: 20, y: 10, width: 60, height: 30)
        // Black everywhere else, so only the sheets carry red or blue.
        try Self.capture(0, r: r, to: dir.appending(path: "browser~dark.png"))
        try Self.capture(
            0, inside: CGColor(red: 1, green: 0, blue: 0, alpha: 1), r: r,
            to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(
            0, inside: CGColor(red: 0, green: 0, blue: 1, alpha: 1), r: r,
            to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        for i in 0..<30 {
            let frame = try master.frame(at: 4 + Double(i) / 30)
            let px = try #require(Image.pixels(frame))
            for y in 10..<40 {
                for x in 20..<80 {
                    let o = (y * 100 + x) * 4
                    #expect(!(px.bytes[o] > 90 && px.bytes[o + 2] > 90), "t=\(4 + Double(i) / 30) at \(x),\(y)")
                }
            }
        }
        let settled = try #require(Image.pixels(try master.frame(at: 5.5)))
        #expect(settled.bytes[(25 * 100 + 50) * 4 + 2] > 200)
    }

    @Test func presentIsInStagePixelsOnTheCenteredCanvas() throws {
        let dir = try Self.dir()
        try Self.capture(0, r: .zero, to: dir.appending(path: "browser~dark.png"))
        // A 60x30 capture is centered on the 100x50 canvas, at (20, 10).
        let small = try #require(Image.context(width: 60, height: 30))
        small.setFillColor(CGColor(gray: 1, alpha: 1))
        small.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        try Image.write(try #require(small.makeImage()), to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(0, r: .zero, to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        // Mid-present the sheet is drawn from the centered canvas at the config's rect: white
        // just inside its left edge, the black window just outside it.
        let mid = try #require(Image.pixels(try master.frame(at: 2.3)))
        #expect(mid.bytes[(25 * 100 + 25) * 4] == 255)
        #expect(mid.bytes[(25 * 100 + 17) * 4] == 0)
    }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoMasterTests`
Expected: the present and swap tests fail, because the master only crossfades. `presentIsInStagePixelsOnTheCenteredCanvas` may already pass; it guards the coordinate space.

- [ ] **Step 3: Implement.** In `StillsMaster`:

Change `keys` to `[(time: Double, image: CGImage, present: CGRect?)]`, add `private let sheet: Spring`, give `init` the new trailing parameter `sheet: Spring = MotionPreset.kinetic.sheet`, assign it, and build the keys with the beat's `present`:

```swift
        let cuts = video.beats.compactMap { beat in
            beat.screen.map { (beat.at, $0, beat.present.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }) }
        }
```

Carry the tuple's third element through the existing centering `map`, so each key is `(cut.0, centered, cut.2)`. The rects are already stage pixels on the centered canvas, so they need no offset.

Replace `frame(at:)` with:

```swift
    public mutating func frame(at t: Double) throws -> CGImage {
        let index = keys.lastIndex { $0.time <= t } ?? 0
        let current = keys[index]
        guard index > 0 else { return current.image }
        let previous = keys[index - 1]
        let q = t - current.time
        guard let sheetRect = current.present else { return crossfade(previous.image, current.image, q) }

        let swap = previous.present != nil
        let duration = max(0.6, sheet.response * 1.6) + (swap ? 0.2 : 0)
        guard q < duration, let canvas = VideoCanvas(width: Int(stageSize.width), height: Int(stageSize.height))
        else { return current.image }
        let full = CGRect(origin: .zero, size: stageSize)
        var presentAge = q
        if let old = previous.present {
            // A crossfade between two sheets double-exposes their text. Instead the old
            // sheet drops away over the bare window, then the new one comes up.
            guard let bare = keys[..<index].last(where: { $0.present == nil }) else {
                return crossfade(previous.image, current.image, q / duration * Self.crossfade)
            }
            canvas.image(current.image, in: full)
            canvas.ctx.saveGState()
            canvas.ctx.clip(to: sheetRect)
            canvas.image(bare.image, in: full)
            canvas.ctx.restoreGState()
            let d = Ease.smooth(q / 0.2)
            drawSheet(canvas, previous.image, old, scale: 1 - 0.05 * d, alpha: 1 - d)
            presentAge = q - 0.16
        } else {
            // Present: the window behind dims in, the sheet springs up from 90%.
            canvas.image(previous.image, in: full)
            canvas.ctx.saveGState()
            let outside = CGMutablePath()
            outside.addRect(full)
            outside.addRect(sheetRect)
            canvas.ctx.addPath(outside)
            canvas.ctx.clip(using: .evenOdd)
            canvas.image(current.image, in: full, alpha: Ease.smooth(q / 0.35))
            canvas.ctx.restoreGState()
        }
        if presentAge > 0 {
            drawSheet(
                canvas, current.image, sheetRect, scale: 0.9 + 0.1 * sheet.value(presentAge),
                alpha: Ease.clamp01(presentAge / 0.2))
        }
        return canvas.makeImage() ?? current.image
    }

    private func crossfade(_ from: CGImage, _ to: CGImage, _ q: Double) -> CGImage {
        let p = q / Self.crossfade
        guard p < 1, let ctx = Image.context(width: Int(stageSize.width), height: Int(stageSize.height)) else {
            return to
        }
        let full = CGRect(origin: .zero, size: stageSize)
        ctx.draw(from, in: full)
        ctx.setAlpha(Ease.smooth(p))
        ctx.draw(to, in: full)
        return ctx.makeImage() ?? to
    }

    /// The region `rect` of `image`, drawn at `scale` of its size about its center.
    private func drawSheet(_ canvas: VideoCanvas, _ image: CGImage, _ rect: CGRect, scale: Double, alpha: Double) {
        guard alpha > 0.001, let crop = image.cropping(to: rect) else { return }
        let dest = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
        // CGPath traps on a corner radius over half a side.
        let radius = min(26 * scale, dest.width / 2, dest.height / 2)
        let rounded = CGPath(roundedRect: dest, cornerWidth: radius, cornerHeight: radius, transform: nil)
        canvas.ctx.saveGState()
        canvas.ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: CGColor(gray: 0, alpha: 0.5 * alpha))
        canvas.ctx.addPath(rounded)
        canvas.ctx.setFillColor(CGColor(gray: 0.12, alpha: alpha))
        canvas.ctx.fillPath()
        canvas.ctx.restoreGState()
        canvas.ctx.saveGState()
        canvas.ctx.addPath(rounded)
        canvas.ctx.clip()
        canvas.image(crop, in: dest, alpha: alpha)
        canvas.ctx.restoreGState()
    }
```

`crossfadesBetweenStills` must still pass, because the crossfade keeps its 0.5 s ease.

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter VideoMasterTests`
Expected: all pass.

- [ ] **Step 5: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add Sources/AppShotKit/VideoMaster.swift Sources/AppShotKit/VideoCompose.swift Tests/AppShotKitTests/VideoMasterTests.swift
git commit -m "feat(video): sheets spring up and swap in stills videos"
```

---

## Task 9: `--motion`, naming, the report and parallel outputs

**Files:**
- Modify: `Sources/AppShotKit/VideoCompose.swift`
- Modify: `Sources/AppShotKit/ContactSheet.swift`. `times(for:beats:)` gains `moments: [Double] = []`, which are added as they are, with no settle.
- Modify: `Sources/appshot/VideoCommands.swift`. `ComposeVideo` gains `--motion`.
- Test: `Tests/AppShotKitTests/VideoComposeTests.swift` and `ContactSheetTests.swift`

**Interfaces:**
- Consumes: everything earlier.
- Produces:
  - `VideoCompose.Options.motions: [String]?`, as a new trailing `init` parameter defaulting to `nil`
  - `Job { video, appearance, track, timeline, icon, preset: MotionPreset, suffix: String? }`, with `var name: String`: `"\(video.id)~\(appearance)"`, or `"\(video.id)~\(suffix)~\(appearance)"` when `--motion` was given
  - `Report.motion: String` and `Report.warnings: [VideoTimeline.Warning]`
  - `render(_ job:options:makeMaster:)`, where `makeMaster` is `@escaping @Sendable () throws -> any VideoMaster`

- [ ] **Step 1: Write the failing tests.** Add to `VideoComposeTests`:

```swift
    @Test func motionsRenderSideBySideNamedApart() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser", "caption": "One" }]"#)
        options.motions = ["kinetic", "studio"]
        _ = try await VideoCompose.run(options)
        for motion in ["kinetic", "studio"] {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "videos/promo/v~\(motion)~dark~320x200.mp4").path))
            let data = try Data(contentsOf: root.appending(path: "videos/report/v~\(motion)~dark.report.json"))
            #expect(try JSONDecoder().decode(VideoCompose.Report.self, from: data).motion == motion)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos/promo/v~dark~320x200.mp4").path))
    }

    @Test func oneMotionOnTheCommandLineIsStillNamed() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        options.motions = ["studio"]
        _ = try await VideoCompose.run(options)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "videos/promo/v~studio~dark~320x200.mp4").path))
    }

    @Test func motionsAndAppearancesNeverCollide() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        let stills = try #require(options.fromStills)
        try VideoMasterTests.solid(400, 250, gray: 0.8, to: stills.appending(path: "browser~light.png"))
        options.appearances = ["dark", "light"]
        options.motions = ["kinetic", "studio"]
        let outputs = try await VideoCompose.run(options)
        let promos = outputs.filter { $0.kind == "promo" }.map(\.url.lastPathComponent)
        #expect(Set(promos).count == 4 && promos.count == 4)
        let reports = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "videos/report").path)
        #expect(reports.filter { $0.hasSuffix(".report.json") }.count == 4)
        #expect(reports.filter { $0.hasSuffix(".contact.png") }.count == 4)
    }

    @Test func anUnknownMotionFailsBeforeWriting() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        options.motions = ["keynote"]
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .unknownMotion(_, let name, _) = error as? AppShotError else { return false }
            return name == "keynote"
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test(arguments: [
        (#"{ "at": 1, "pointer": { "point": [1, 2] } }"#, "pointer"),
        (#"{ "at": 1, "screen": "browser", "present": [0, 0, 10, 10] }"#, "present"),
    ])
    func stillsOnlyKeysFailOnARecordedVideo(beat: String, key: String) async throws {
        var (options, root) = try Self.setup(beats: "[{ \"at\": 0, \"caption\": \"One\" }, \(beat)]")
        options.fromStills = nil
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .invalidVideo(_, let why) = error as? AppShotError else { return false }
            return why.contains("`\(key)`") && why.contains("--from-stills")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func theReportCarriesTheMotionAndItsWarnings() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser" },
                 { "at": 1, "focus": { "rect": [0, 0, 100, 60] } },
                 { "at": 1.3, "focus": "home" }]
                """)
        _ = try await VideoCompose.run(options)
        let data = try Data(contentsOf: root.appending(path: "videos/report/v~dark.report.json"))
        let report = try JSONDecoder().decode(VideoCompose.Report.self, from: data)
        #expect(report.motion == "kinetic")
        #expect(report.warnings.map(\.kind) == ["cameraNeverSettles"])
    }
```

In `midRenderFailureLeavesNoPartialAndNamesTheVideo`, change the call to:

```swift
        nonisolated(unsafe) let good = try master.frame(at: 0)
        await #expect {
            _ = try await VideoCompose.render(job, options: options, makeMaster: { FailingMaster(good: good) })
        } throws: { ... unchanged ... }
```

Also give the `promo/*.mp4` files the same leftover check: no `.mp4` may exist under `options.outDir` after the failure. In `static func job(_:)`, add `preset: .kinetic, suffix: nil` to the `Job` initializer.

In `ContactSheetTests`, add:

```swift
    @Test func momentsAreKeptAsGiven() throws {
        let timeline = try VideoTimelineTests.timeline(VideoTimelineTests.video("[]"))
        #expect(ContactSheet.times(for: timeline, beats: [], moments: [0.6, 8.9]) == [0.6, 8.9])
    }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter VideoComposeTests`
Expected: compile failure on `options.motions`, `makeMaster:` and `Report.motion`.

- [ ] **Step 3: Implement in `VideoCompose.swift`:**

1. Add `public var motions: [String]?` to `Options`, with a trailing `motions: [String]? = nil` `init` parameter.
2. Give `Report` the fields `public var motion: String` and `public var warnings: [VideoTimeline.Warning]`.
3. Change `Job`:

```swift
    /// CGImage is immutable, so a job crosses to the output tasks as it is.
    struct Job: @unchecked Sendable {
        let video: Config.Video
        let appearance: String
        let track: VideoTrack
        let timeline: VideoTimeline
        let icon: CGImage?
        let preset: MotionPreset
        /// The motion's name when `--motion` chose it: comparison runs never overwrite.
        let suffix: String?

        var name: String {
            suffix.map { "\(video.id)~\($0)~\(appearance)" } ?? "\(video.id)~\(appearance)"
        }
    }
```

4. In `run`, before planning jobs:

```swift
        for name in options.motions ?? [] where MotionPreset.named(name) == nil {
            throw AppShotError.unknownMotion(video: "--motion", name: name, known: MotionPreset.all.map(\.name))
        }
```

Inside the per-video loop, before the appearance loop:

```swift
            if options.fromStills == nil {
                for (i, beat) in video.beats.enumerated() {
                    for (key, used) in [("pointer", beat.pointer != nil), ("present", beat.present != nil)] where used {
                        throw AppShotError.invalidVideo(
                            id: video.id,
                            reason: "beat \(i) has `\(key)`, which is for --from-stills: a take already holds "
                                + "the app's own pointer and sheets")
                    }
                }
            }
            let presets: [(MotionPreset, String?)] =
                if let motions = options.motions {
                    motions.compactMap { name in MotionPreset.named(name).map { ($0, name) } }
                } else {
                    [(MotionPreset.named(video.motion ?? MotionPreset.defaultName) ?? .kinetic, nil)]
                }
```

When building jobs, append one per preset:

```swift
                for (preset, suffix) in presets {
                    jobs.append(
                        Job(
                            video: video, appearance: appearance, track: track, timeline: timeline, icon: icon,
                            preset: preset, suffix: suffix))
                }
```

Pass `sheet: MotionPreset.kinetic.sheet` to the `StillsMaster(...)` used only for its size during planning. The caption error now carries the plain text: `caption: short.plain`.

5. Replace both `render` functions and add the per-output task:

```swift
    static func render(_ job: Job, options: Options) async throws -> [Output] {
        let master = Self.masterURL(options, video: job.video.id, appearance: job.appearance)
        return try await render(job, options: options) {
            if let stills = options.fromStills {
                return try StillsMaster(
                    video: job.video, sourceDir: stills, appearance: job.appearance, sheet: job.preset.sheet)
            }
            return try RecordedMaster(url: master, track: job.track)
        }
    }

    struct Target: @unchecked Sendable {
        let style: VideoFrame.Style
        let url: URL
        let kind: String
        /// The poster and the contact sheet come from this one: the last target, a promo
        /// when there is one, which is what a reviewer is judging.
        let keepsFrames: Bool
    }

    struct Rendered: @unchecked Sendable {
        let output: Output
        let poster: CGImage?
        let cells: [ContactSheet.Cell]
    }

    /// Each output renders on its own task, with its own master: a recorded master only
    /// reads forwards, so outputs cannot share one.
    static func render(
        _ job: Job, options: Options, makeMaster: @escaping @Sendable () throws -> any VideoMaster
    ) async throws -> [Output] {
        let config = options.config
        let video = job.video
        let name = job.name
        let stage = job.track.stageSize

        var specs: [(VideoFrame.Style, URL, String)] = []
        do {
            if video.outputs.wantsPreview, let size = Config.previewSize(for: config.resolvedPlatform) {
                let style = try VideoFrame.style(
                    kind: .preview, size: size, config: config, appearance: job.appearance, video: video,
                    stage: stage, icon: nil, preset: job.preset, timeline: job.timeline)
                specs.append((style, options.outDir.appending(path: "preview/\(name).mp4"), "preview"))
            }
            for size in video.outputs.promoSizes {
                let style = try VideoFrame.style(
                    kind: .promo, size: size, config: config, appearance: job.appearance, video: video,
                    stage: stage, icon: job.icon, preset: job.preset, timeline: job.timeline)
                specs.append((style, options.outDir.appending(path: "promo/\(name)~\(size.description).mp4"), "promo"))
            }
        } catch {
            throw Self.named(error, video: video.id)
        }
        let targets = specs.enumerated().map { i, spec in
            Target(style: spec.0, url: spec.1, kind: spec.2, keepsFrames: i == specs.count - 1)
        }

        // Pulled back to the last frame: a poster in the final frame interval would
        // otherwise never be reached.
        let posterTime = min(video.poster ?? min(5, video.duration / 2), job.timeline.lastFrameTime)
        let moments =
            (job.timeline.hook != nil && job.preset.hookCard ? [0.6] : [])
            + job.timeline.pops.map { ($0.from + $0.to) / 2 }
        let sheetTimes = ContactSheet.times(for: job.timeline, beats: job.timeline.beatTimes, moments: moments)

        var finished: [Rendered] = []
        do {
            try await withThrowingTaskGroup(of: Rendered.self) { group in
                for target in targets {
                    group.addTask {
                        try await renderTarget(
                            target, job: job, makeMaster: makeMaster, posterTime: posterTime, sheetTimes: sheetTimes)
                    }
                }
                for try await done in group { finished.append(done) }
            }
        } catch {
            // A throw must leave neither a `.partial` that looks like a recording nor the
            // half of a job's outputs that did finish.
            for target in targets { try? FileManager.default.removeItem(at: target.url) }
            throw Self.named(error, video: video.id)
        }
        let outputs = targets.compactMap { target in finished.first { $0.output.url == target.url }?.output }
        let kept = finished.first { $0.poster != nil || !$0.cells.isEmpty }
        // … the existing poster, website, contact-sheet and report code follows, reading
        //     `kept?.poster` and `kept?.cells ?? []` instead of the old locals. The report
        //     gains `motion: job.preset.name` and `warnings: job.timeline.warnings(for: job.preset)`,
        //     and the captions it lists use `$0.plain`.
    }

    static func renderTarget(
        _ target: Target, job: Job, makeMaster: @Sendable () throws -> any VideoMaster, posterTime: Double,
        sheetTimes: [Double]
    ) async throws -> Rendered {
        var master = try makeMaster()
        let writer = try VideoWriter(url: target.url, size: target.style.size)
        var poster: CGImage?
        var cells: [ContactSheet.Cell] = []
        do {
            for i in 0..<job.timeline.frameCount {
                try Task.checkCancellation()
                let t = Double(i) / Double(VideoWriter.fps)
                let frame = try VideoFrame.render(
                    stage: try master.frame(at: t), t: t, timeline: job.timeline, style: target.style)
                try writer.append(frame)
                guard target.keepsFrames else { continue }
                if poster == nil, t >= posterTime { poster = frame }
                if let next = sheetTimes.dropFirst(cells.count).first, t >= next {
                    let label = job.timeline.caption(at: next).map { KineticText.plain($0.text) } ?? ""
                    cells.append(ContactSheet.Cell(time: next, label: label, image: frame))
                }
            }
            let url = try await writer.finish()
            return Rendered(
                output: Output(url: url, kind: target.kind, size: target.style.size), poster: poster, cells: cells)
        } catch {
            writer.cancel()
            throw error
        }
    }
```

Keep the existing tail of the old `render`, from `if let poster …` through writing the report, verbatim. Swap its locals for `kept?.poster` and `kept?.cells ?? []`, and use `name` for every file name; the website copy uses `name` when `job.suffix != nil`. The comment block above marks the splice point: write the real code there, not the comment.

6. In `ContactSheet.times`, add `moments: [Double] = []` and change `raw` to `beats.map { $0 + settle } + timeline.captions.map { ($0.start + $0.end) / 2 } + moments`.

7. CLI. In `ComposeVideo`, add:

```swift
    @Option(help: "Comma-separated motion presets (kinetic, studio). Each output gets the preset in its name.")
    var motion: String?
```

and pass `motions: motion.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }` into `Options`.

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter VideoComposeTests && swift test --filter ContactSheetTests`
Expected: all pass.

- [ ] **Step 5: Format, lint, run the full suite, commit**

```bash
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
swift test 2>&1 | tail -3
git add -A Sources Tests
git commit -m "feat(video): --motion, per-preset names, warnings in the report, outputs in parallel"
```

---

## Task 10: Fixture and `make bench-motion`

**Files:**
- Modify: `Scripts/fixture-video.config.json`
- Modify: `Makefile`

- [ ] **Step 1: Give the fixture a hook and a pop.** In `Scripts/fixture-video.config.json`, set the video to `"motion": "kinetic", "hook": "Six *rows*."` and the card to `{ "title": "appshot", "subtitle": "fixture", "cta": "make bench-motion" }`. Replace the first beat `{ "at": 0, "caption": "Six rows" }` with `{ "at": 0, "focus": "home" }`, since a caption under the hook is an error. Add `{ "at": 2.4, "pop": { "target": "row-3", "until": 3.5 } }` after the focus beat at 2.0. Leave the cue beats as they are.

Then run: `swift run appshot compose video --config Scripts/fixture-video.config.json --help > /dev/null && swift test --filter VideoConfigTests`. To validate the fixture config itself, run `swift run -c release appshot compose video --config Scripts/fixture-video.config.json --source /nonexistent --out /tmp/x 2>&1 | head -2`. Expected: it fails on the missing track, *not* on validation.

- [ ] **Step 2: Add the Makefile target.** Add `bench-motion` to `.PHONY`, then after `bench-record`:

```make
# Not CI, like bench-record. Records the fixture once, then composes it in every motion
# preset side by side, for a look by eye: .build/fixture/videos/report/*.contact.png.
bench-motion: fixture ## Record the fixture and compose it in every motion preset
	@swift build -c release --product appshot >&2
	.build/release/appshot record --app .build/fixture/AppShotFixture.app \
	  --config Scripts/fixture-video.config.json --out .build/fixture/videos/source --no-activate
	.build/release/appshot compose video --config Scripts/fixture-video.config.json \
	  --source .build/fixture/videos/source --out .build/fixture/videos --motion kinetic,studio
```

Check the GNU make 3.81 trap: `/usr/bin/make -n bench-motion` must print the commands with no error.

- [ ] **Step 3: Run it and look.** First check the user is idle (`apple_desktop_user_activity`); the fixture records with `--no-activate`. Then run `make bench-motion`. Expected: two promos, `fixture~kinetic~dark~1080x1080.mp4` and `fixture~studio~dark~1080x1080.mp4`. Read both contact sheets, and confirm:

- the kinetic hook cell;
- the window filling the frame on the focus;
- the row-3 pop;
- the pointer;
- the end card with the CTA.

If Screen Recording is unavailable, say so and skip this step; do not fake it.

- [ ] **Step 4: Commit**

```bash
git add Scripts/fixture-video.config.json Makefile
git commit -m "build: make bench-motion composes the fixture in every motion preset"
```

---

## Task 11: README, CHANGELOG, the skill and its evals

**Files:**
- Modify: `README.md` (the Videos section), `CHANGELOG.md` (Unreleased → Added)
- Modify: `skills/appshot-video/SKILL.md`, `skills/appshot-video/references/scripting.md`, `skills/appshot-video/references/app-side.md` and `skills/appshot-video/assets/AppShotCues.swift` (one comment)
- Create: `skills/appshot-video/evals/evals.json`

- [ ] **Step 1: README.** After the paragraph ending "Read those instead of watching the video.", insert:

````markdown
### Motion

A beat says what matters; the video's **motion preset** decides how it moves.
`kinetic` (the default) opens on a full-frame hook, brings captions in word by word
with accent words in the theme's `accent` colour, springs the camera onto each focus,
lifts popped regions out of the window and ends on a springing card. `studio` is the
calm one: fades, a caption pill, spotlights with an outline. The camera moves the
whole window and computes its own framing, so no beat names a zoom level.

```json
{ "id": "promo", "duration": 20, "motion": "kinetic",
  "hook": "Your music folder is a *mess*.",
  "card": { "title": "Pochette", "subtitle": "Your music, as files.", "cta": "On the Mac App Store" },
  "beats": [
    { "at": 0,   "screen": "library" },
    { "at": 0.9, "focus": { "rect": [20, 426, 580, 516] } },
    { "at": 1.6, "spotlight": { "rect": [20, 426, 580, 516], "until": 3.9 } },
    { "at": 4.0, "focus": "home" },
    { "at": 4.8, "pointer": { "point": [1482, 51], "click": true } },
    { "at": 5.0, "screen": "rename", "present": [600, 275, 1358, 1047],
      "caption": "Rename every file in *one go*." },
    { "at": 7.6, "pop": { "rect": [640, 1040, 640, 78], "until": 10.2 } },
    { "at": 15.8, "endCard": true } ] }
```

| Key | Meaning |
|---|---|
| `focus` | Frame a region: `{ "rect": [x,y,w,h] }` in stage pixels or `{ "target": name }`, optional `fill` 0.3–1. `"home"` frames the whole window. |
| `spotlight` | Dim everything but a region until `until`. |
| `pop` | Lift a region out as a floating card until `until` (studio draws an outlined spotlight). |
| `pointer` | `--from-stills` only: move the drawn pointer to `point` or a `rect`'s center; `click: true` clicks. A take uses the app's own pointer reports. |
| `present` | `--from-stills` only, on a `screen` beat: that region is a sheet that springs up; sheet to sheet, they swap. |
| `hook` | The opening line; a caption timed before 1.5 s is an error. |

`compose video --motion kinetic,studio` renders every preset side by side, each
named `<id>~<motion>~<appearance>…`. The report lists warnings that do not fail the
render: `cameraNeverSettles` (two focus moves closer than the camera can settle) and
`popOverload` (more than three pops).
````

Then edit the paragraph starting "The take fixes the cues and the length." so it reads "Captions, their timing and `until`, focus, spotlights, pops, the hook, the end card and any beat without a cue are read from the config at render time…", with the rest unchanged.

- [ ] **Step 2: CHANGELOG.** In the Unreleased `compose video` bullet, change "with captions, a drawn pointer, zoom and an end card" to "with motion presets (`kinetic`, `studio`): a camera that frames `focus` regions itself, spotlights, pop-outs, word-by-word captions with accent words, a full-frame hook, a drawn pointer and an end card with a call to action". Add the bullet "`compose video --motion a,b` renders several presets side by side, named apart." Change "caption, timing, zoom and end-card edits" to "caption, timing, focus, emphasis and end-card edits".

- [ ] **Step 3: The skill's `SKILL.md`.**
  - Line 62's "zoom on a fixed rect" becomes "focus, spotlight and pop on fixed rects, a scripted pointer, sheets that spring up".
  - Line 64: the stills Pointer cell becomes "yes, from `pointer` beats".
  - In the example (lines 97–98), replace the zoom beats with `{ "at": 2.2, "pop": { "target": "session-2", "until": 5 } }` and `{ "at": 6, "screen": "transcript", "caption": "…", "focus": "home" }`, and add `"motion": "kinetic", "hook": "Every agent, *one menu bar*."` to the entry. Delete the beat-0 caption, which is now the hook.
  - Replace the `zoom` row of the beat table with the `focus`, `spotlight`, `pop`, `pointer` and `present` rows from the README table, and add a `hook` row.
  - Line 120: "where zooms help" becomes "when to focus, spotlight or pop".
  - Line 207: the error row becomes `focus/spotlight/pop at Ns targets "x", which no pointer cue at or before it reported`, with the same cause and fix, `rect` replacing zoom.
  - Add four rows to the error→fix table:

| Error | Cause | Fix |
|---|---|---|
| `beat N uses zoom, which is now focus` | An old config. | `"focus": { "rect" \| "target" }`, no `scale`; `"focus": "home"` for `scale: 1`. |
| `no motion preset "x"` | A typo, or a preset that does not exist yet. | `kinetic` or `studio`. |
| `caption at Ns starts under the hook` | A caption before 1.5 s in a video with a `hook`. | Move it to 1.5 s or later, or make it the hook. |
| `beat N has pointer/present, which is for --from-stills` | A stills-only key on a recorded video. | Remove it: the take has the real pointer and sheet. |

  - Add "warning: cameraNeverSettles / popOverload in the report" to the review section, with "space focus beats a camera response apart (kinetic 0.7 s, studio 1 s); keep pops to three".

- [ ] **Step 4: `references/scripting.md`.** Replace the zoom guidance (lines 44–45, 55–61 and 72) with a "## Motion" section:

```markdown
## Motion

- **One message per pop, three pops at most in 20 s.** A pop is "this is the point":
  the before/after row, the waiting session. Past three, none stands out (the report
  warns `popOverload`).
- **Focus frames, spotlight points.** Focus a region the size of what the caption talks
  about (a list, a panel), then spotlight or pop the one row inside it.
- **Space focus beats at least a camera response apart**: kinetic 0.7 s, studio 1 s. A
  focus and its return closer than that is a whiplash (`cameraNeverSettles`).
- **The hook is six words or fewer**, and states the problem, not the product. It holds
  the first 1.5 s, then stays on as the first caption.
- **The pointer is for actions that cause a change**: it travels to the button, clicks,
  and the next screen arrives. A pointer wandering over static UI is noise.
- **Sheets**: from stills, `present` the sheet's rect on the `screen` beat that shows it;
  two presenting screens in a row swap sheets instead of crossfading text over text.
- **Accent one phrase per caption** with `*…*`, in the theme's `accent` colour (set it:
  without one, accents look like the rest).
```

In the 20–25 s skeleton table, "cue or cut, zoom in" becomes "cue or cut, focus, pop the point", and "zoom out (`scale: 1`)" becomes `focus: "home"`. In the poster paragraph, "the first zoom's hold" becomes "the first pop".

- [ ] **Step 5: `app-side.md` and `AppShotCues.swift`.** Replace "zoom" with "focus" in `app-side.md` lines 33, 83, 98, 115, 161 and 162: "any element a focus or pop should find", "moves the beat's caption and focus", and so on. In `AppShotCues.swift:140`, "caption or zoom" becomes "caption or focus".

- [ ] **Step 6: Evals.** Create `skills/appshot-video/evals/evals.json` from the three evals in the session workspace's `evals/evals.json`, which are reproduced here so the file is self-contained. Then add eval 4.

```json
{
  "skill_name": "appshot-video",
  "evals": [
    { "id": 1, "name": "armada-x-ad-from-stills", "prompt": "i want a ~20s promo video of Armada for a low budget X ads test, nothing fancy, i don't have time to add recording code to the app yet. the screenshot config is apps/apple/Screenshots/macos/screenshots.config.json in ~/Projects/apps/armada and the captures are already in apps/apple/Screenshots/macos/source. make the video please", "files": [],
      "assertions": [
        "The config copy has a videos[] entry rendered from stills: every cut beat names a `screen`, and the first beat is at 0 with a screen",
        "At least one promo .mp4 was actually rendered into the outputs dir",
        "Promo sizes include a square or vertical size suited to a mobile X feed (1:1 or 4:5), not only 16:9",
        "The video's duration is between 18 and 25 seconds",
        "No App Store preview is requested (outputs.preview absent or false) — Armada ships outside the Mac App Store",
        "The video ends on an end card (an endCard beat plus a card with a title)",
        "Every caption passes the reading rule (report.json caption margins all >= 0)",
        "The reply to the user points to the contact sheet / report and states what was checked in them",
        "The armada repo was not modified"] },
    { "id": 2, "name": "armada-cue-handler", "prompt": "we want to film a real demo of Armada with appshot record instead of slideshows. add whatever Armada's screenshot/demo mode needs (apps/apple/Armada/DemoSeed.swift and ScreenshotMode.swift in ~/Projects/apps/armada) so appshot can drive it, plus a videos[] entry for a first ~20s take", "files": [],
      "assertions": [
        "The code reads both ScreenshotCueFile and ScreenshotEventFile launch arguments and is inert without them",
        "The app emits {\"kind\":\"ready\"} only after the first screen is staged, not at launch",
        "Acks are written after the effect is drawn (deferred at least one runloop turn after the state change)",
        "Unimplemented cues are answered with {\"kind\":\"unknown\",...} rather than ignored or acked",
        "Target rects are converted to global screen points with a top-left origin (flipped against the primary display)",
        "The cue reader buffers a partial line until its newline",
        "The new code never calls orderFrontRegardless and uses no synthetic input (CGEvent, AppleScript, System Events)",
        "A videos[] entry is provided with a `stage` and `cue` beats, and no App Store preview"] },
    { "id": 3, "name": "fix-rerender-vs-rerecord", "prompt": "recorded a take of our mac app with appshot record last night and composed a promo, all good. this morning i tweaked the config: moved the 2nd caption from 4s to 6s and changed the pointer.click target from row-2 to row-3. now compose video says `intro: render failed: the cues changed since the take (cue #0 args differ); re-record with appshot record` and also `intro: the caption \"Track every agent session across all your accounts at a glance\" is on screen for 2.0s but needs 4.0s to read`. what's going on, what exactly do i change? also i'd like to reuse it as the App Store preview: it's 12s long with an end card at 9s, does that work?", "files": [],
      "assertions": [
        "Says moving the caption is a render-only change (no re-record needed for it)",
        "Says the pointer.click target change is what forces the re-record, and offers reverting it as the alternative",
        "Gives a concrete fix for the too-short caption (cut words or move the next caption later) consistent with 1s + 0.3s per word, and does not suggest `until`",
        "Says a 12 s video cannot be an App Store preview (must be 15-30 s)",
        "Says the end card does not appear in / is not allowed in an App Store preview",
        "Says the Mac App Store preview is 1920x1080"] },
    { "id": 4, "name": "pochette-kinetic-from-stills", "prompt": "make a 20s promo of Pochette for X from the screenshots in ~/Projects/apps/pochette/apps/apple/Screenshots/macos (library, rename, organize). it should feel like a real product video, not a slideshow: open on the problem, show the rename preview, end on the icon. don't touch the pochette repo, work on a copy of the config", "files": [],
      "assertions": [
        "The videos[] entry uses `motion: kinetic` (or leaves it to the default) and has a `hook` of six words or fewer",
        "It has at least one `focus` beat and no `zoom` key anywhere",
        "It has at least one `pop` on a single row of the rename or organize diff",
        "The rename and organize screens use `present` with the sheet's rect",
        "A promo .mp4 was rendered and the contact sheet and report were read",
        "The report has no warnings, or the reply explains each one",
        "The pochette repo was not modified"] }
  ]
}
```

- [ ] **Step 7: Commit**

```bash
grep -rn "\"zoom\"\|zoom:" README.md skills | grep -v "zoom buttons" || true   # expect nothing
git add README.md CHANGELOG.md skills/appshot-video
git commit -m "docs(video): motion presets in the README, the changelog and the appshot-video skill"
```

---

## Task 12: Pochette's promo (in the Pochette repo)

**Files (in `~/Projects/apps/pochette`):**
- Modify: `apps/apple/Screenshots/macos/screenshots.config.json`. Add a `videos[]` entry and `accent` in both themes.
- Create: `apps/apple/Screenshots/macos/card-icon.png`, a copy of `apps/website/public/app-icon.png`.

- [ ] **Step 1: Check the repo state.** Run `git -C ~/Projects/apps/pochette status --short`. Someone else's uncommitted work is there; touch none of it. If `screenshots.config.json` itself shows as modified, stop and ask.

- [ ] **Step 2: Build appshot from the worktree**

```bash
cd ~/Projects/appshot-motion && swift build -c release --product appshot
A=~/Projects/appshot-motion/.build/release/appshot
```

- [ ] **Step 3: Add the entry.** In the config's top level, before `"screens"`, add:

```json
  "//videos": "The X promo. Stills only: `appshot compose video --config <this> --from-stills source --out videos`. The rects are stage pixels of the 2560x1600 captures; `present` is the sheet's rect.",
  "videos": [{
    "id": "promo", "duration": 20, "poster": 8.6, "motion": "kinetic",
    "hook": "Your music folder is a *mess*.",
    "outputs": { "promo": [[1200, 1200], [1920, 1080]] },
    "card": { "title": "Pochette", "subtitle": "Your music, as files.", "icon": "card-icon.png",
              "cta": "On the Mac App Store" },
    "beats": [
      { "at": 0, "screen": "library" },
      { "at": 0.9, "focus": { "rect": [20, 426, 580, 516] } },
      { "at": 1.6, "spotlight": { "rect": [20, 426, 580, 516], "until": 3.9 } },
      { "at": 3.4, "pointer": { "point": [1250, 760] } },
      { "at": 4.0, "focus": "home" },
      { "at": 4.8, "pointer": { "point": [1482, 51], "click": true } },
      { "at": 5.0, "screen": "rename", "present": [600, 275, 1358, 1047],
        "caption": "Rename every file in *one go*." },
      { "at": 6.0, "focus": { "rect": [634, 563, 1293, 630] } },
      { "at": 7.3, "pointer": { "point": [1000, 1078] } },
      { "at": 7.6, "pop": { "rect": [640, 1040, 640, 78], "until": 10.2 } },
      { "at": 10.6, "screen": "organize", "present": [600, 275, 1358, 1047],
        "caption": "Then file it all by *artist and album*." },
      { "at": 11.4, "focus": { "rect": [634, 690, 1293, 500] } },
      { "at": 12.8, "pop": { "rect": [640, 1100, 790, 78], "until": 15.3 } },
      { "at": 15.8, "endCard": true }
    ]
  }],
```

Add `"accent": "#C3143D"` to `themes.light` and `"accent": "#FF4D6D"` to `themes.dark`, then copy the icon:

```bash
cp ~/Projects/apps/pochette/apps/website/public/app-icon.png ~/Projects/apps/pochette/apps/apple/Screenshots/macos/card-icon.png
```

- [ ] **Step 4: Render, time it, review it**

```bash
cd ~/Projects/apps/pochette/apps/apple/Screenshots/macos
/usr/bin/time -p $A compose video --config screenshots.config.json --from-stills source --out videos --appearances dark
/usr/bin/time -p $A compose video --config screenshots.config.json --from-stills source --out videos \
  --appearances dark --motion kinetic,studio
```

Expected:
- The first run writes `videos/promo/promo~dark~1200x1200.mp4` and `promo~dark~1920x1080.mp4`.
- Its `real` time is **under 120 s**. That is the success criterion; report the measured number either way.
- The report has `"motion": "kinetic"`, no warnings and every caption margin ≥ 0.

Read `videos/report/promo~dark.contact.png` and check:
- the hook cell;
- the library framed on the messy names with the spotlight;
- the pointer on Rename;
- the sheet;
- the pop on `debussy_prelude.mp3`;
- the organize sheet;
- the end card with the CTA.

If a rect is off, fix the rect in the config, not the code.

- [ ] **Step 5: Commit only these files**

```bash
cd ~/Projects/apps/pochette
git add apps/apple/Screenshots/macos/screenshots.config.json apps/apple/Screenshots/macos/card-icon.png
git diff --cached --stat     # exactly these two files
git commit -m "feat(screenshots): the X promo video, in appshot's kinetic motion"
```

Leave the rendered `videos/` untracked, matching Armada.

---

## Task 13: Armada moves from `zoom` to `focus` (in the Armada repo)

**Files (in `~/Projects/apps/armada`):**
- Modify: `apps/apple/Screenshots/macos/screenshots.config.json`, its two `videos[]` entries only.

The cue beats must stay byte-identical, so `promo-live` re-renders from its existing take with no re-record. The stage is 2400×1604. Each old `zoom { rect, scale }` becomes a focus on the region a scale-*s* crop showed: stage ÷ *s*, centered on the old rect's center, with `fill: 1`.

- [ ] **Step 1: Check the repo state.** Run `git -C ~/Projects/apps/armada status --short`; if the config file is modified, stop and ask.

- [ ] **Step 2: Edit `promo` (stills)**
- Add `"hook": "Too many coding agents to keep track of?"`.
- Beat 0 becomes `{ "at": 0, "screen": "menubar", "focus": { "rect": [533, 134, 1333, 891], "fill": 1 } }`; its caption moves to the hook.
- `{ "at": 3.2, "zoom": { "scale": 1 } }` becomes `{ "at": 3.2, "focus": "home" }`.
- The 4.8 beat becomes `{ "at": 4.8, "focus": { "rect": [208, 420, 1500, 1002], "fill": 1 } }`; add `{ "at": 5.2, "pop": { "rect": [500, 882, 916, 78], "until": 8.0 } }`.
- `{ "at": 8.4, "zoom": { "scale": 1 } }` becomes `{ "at": 8.4, "focus": "home" }`.
- The 10.5 beat becomes `{ "at": 10.5, "focus": { "rect": [548, 804, 1333, 891], "fill": 1 } }`.

- [ ] **Step 3: Edit `promo-live` (recorded)**
- Add the same hook and delete the caption-only beat at 0.
- The 4.6 beat becomes `{ "at": 4.6, "focus": { "rect": [491, 0, 1875, 1253], "fill": 1 } }`; add `{ "at": 5.0, "pop": { "target": "checkout-session", "until": 8.0 } }`.
- `{ "at": 8.4, "zoom": { "scale": 1 } }` becomes `{ "at": 8.4, "focus": "home" }`.
- The 10.6 beat becomes `{ "at": 10.6, "focus": { "rect": [548, 854, 1333, 891], "fill": 1 } }`.
- In the entry's `"//"` comment, replace "zoom rects" with "focus rects" and "Captions, zooms and the card" with "Captions, focus, pops and the card".

- [ ] **Step 4: Render both and review**

```bash
cd ~/Projects/apps/armada/apps/apple/Screenshots/macos
$A compose video --config screenshots.config.json --from-stills source --out videos --videos promo --appearances dark
$A compose video --config screenshots.config.json --source videos/source --out videos --videos promo-live --appearances dark
```

Expected: both render. `promo-live` must not ask for a re-record; if it does, a cue beat changed, so revert it. Read both contact sheets. Each report must have every caption margin ≥ 0 and no warnings.

- [ ] **Step 5: Commit only the config**

```bash
cd ~/Projects/apps/armada
git add apps/apple/Screenshots/macos/screenshots.config.json
git diff --cached --stat
git commit -m "feat(screenshots): promo videos move to appshot's motion presets (focus, pop, hook)"
```

---

## Task 14: Finish

- [ ] **Step 1: Whole-branch review.** A fresh reviewer reads the spec and `git diff main..video-motion`.

- [ ] **Step 2: Merge and clean up**

```bash
cd ~/Projects/appshot
git merge --ff-only video-motion
git worktree remove ../appshot-motion
git branch -d video-motion
git rev-list --count origin/main..main     # report this; do not push
```

- [ ] **Step 3: Update memory.** Update `appshot-video-state.md`: motion presets are on local main with the new tip and unpushed count; Pochette and Armada are migrated; CI has still never run the video work.
