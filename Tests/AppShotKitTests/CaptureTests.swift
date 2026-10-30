import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// `Capture.run` itself is untestable in CI — it needs a real .app, Screen Recording
/// permission and exclusive control of the pointer. What *is* testable is the spec
/// parsing in front of it, which is where a typo turns into a 90-second run that
/// captures the wrong thing.
struct CaptureScreenSpecTests {
    @Test("a bare name stages itself and takes the default settle")
    func bareName() throws {
        let screen = try Capture.Screen(spec: "export")
        #expect(screen.name == "export")
        #expect(screen.stage == "export")
        #expect(screen.settle == nil)
    }

    @Test("name:stage keeps the settle defaulted")
    func namedStage() throws {
        let screen = try Capture.Screen(spec: "export:export-pane")
        #expect(screen.name == "export")
        #expect(screen.stage == "export-pane")
        #expect(screen.settle == nil)
    }

    @Test("a third field is that screen's settle")
    func perScreenSettle() throws {
        let screen = try Capture.Screen(spec: "export:export-pane:6.5")
        #expect(screen.name == "export")
        #expect(screen.stage == "export-pane")
        #expect(screen.settle == 6.5)
    }

    /// The whole point of the empty middle: asking for a settle must not force you to
    /// restate a stage that already defaults correctly.
    @Test("an empty stage still means stage == name")
    func emptyStageWithSettle() throws {
        let screen = try Capture.Screen(spec: "export::6")
        #expect(screen.stage == "export")
        #expect(screen.settle == 6)
    }

    @Test("zero is a settle, not a missing one")
    func zeroSettle() throws {
        #expect(try Capture.Screen(spec: "export::0").settle == 0)
    }

    /// Silently ignoring these is the failure mode worth avoiding: `export:pane:six`
    /// would capture at the default settle and look like it worked.
    @Test(
        "a non-numeric or negative settle is rejected",
        arguments: [
            "export:pane:six", "export:pane:", "export:pane:-1", "export:pane:2s", ":pane:2", "",
        ])
    func rejected(spec: String) {
        #expect(throws: AppShotError.self) {
            try Capture.Screen(spec: spec)
        }
    }
}

/// The frame poll replaced a fixed sleep, so the thing to pin is that it stops for
/// the right reason: a still window returns early, a moving one waits, and the
/// ceiling always ends it. The poll is generic over its frame source precisely so
/// this needs no window server — the real caller passes a ScreenCaptureKit capture.
struct CaptureQuiescenceTests {
    /// A 40x40 window with content in it; the shade shifts the whole frame far past the
    /// noise floor, standing in for content that is still drawing.
    ///
    /// The rows are not decoration. The poll requires a frame to be still *and* drawn,
    /// so a flat fill now reads as a window that has not drawn yet and is deliberately
    /// never settled on — see `undrawnWindowKeepsPolling`.
    static func frame(_ shade: UInt8) -> CGImage {
        let ctx = Image.context(width: 40, height: 40)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let ink = v > 0.5 ? 0.0 : 1.0
        ctx.setFillColor(CGColor(srgbRed: ink, green: ink, blue: ink, alpha: 1))
        for row in 0..<5 {
            ctx.fill(CGRect(x: 4, y: row * 8 + 2, width: 32, height: 3))
        }
        return ctx.makeImage()!
    }

    /// Fast: the ceiling is expressed in frames, so a tiny interval keeps the poll's
    /// arithmetic intact without the test sleeping for it.
    static func quick(maxFrames: Int) -> Capture.Quiescence {
        Capture.Quiescence(
            interval: .milliseconds(1), maxFrames: maxFrames, matchesRequired: Capture.pollMatches)
    }

    /// Serves each shade in turn, then repeats the last one forever.
    static func source(_ shades: [UInt8]) -> (count: () -> Int, next: () -> CGImage) {
        final class Cursor: @unchecked Sendable {
            var index = 0
        }
        let cursor = Cursor()
        return (
            { cursor.index },
            {
                let shade = shades[min(cursor.index, shades.count - 1)]
                cursor.index += 1
                return frame(shade)
            }
        )
    }

    @Test("a window that is already still returns as soon as it has its matches")
    func stillWindowReturnsEarly() async throws {
        let (count, next) = Self.source([100])
        let (_, settled) = try await Capture.settledImage(Self.quick(maxFrames: 50), within: .none) { next() }

        #expect(settled)
        // matchesRequired comparisons, so matchesRequired + 1 frames — and crucially
        // not the 50 the ceiling would have allowed.
        #expect(count() == Capture.pollMatches + 1)
    }

    @Test("a window still changing keeps polling, then settles once it stops")
    func movingWindowWaits() async throws {
        // Three distinct frames before it holds still.
        let (count, next) = Self.source([10, 90, 170, 250])
        let (image, settled) = try await Capture.settledImage(Self.quick(maxFrames: 50), within: .none) {
            next()
        }

        #expect(settled)
        #expect(count() > Capture.pollMatches + 1)
        // It settled on the *last* state, not an early one it happened to pass through.
        #expect(Capture.isStill(image, Self.frame(250)))
    }

    /// A launched-but-undrawn window: one flat colour, plus the sliver of system chrome
    /// the simulator draws over it. Measured on real iOS captures, a blank frame runs
    /// 0.36-0.54% off its dominant colour where every drawn screen runs 36-71%.
    static func blank(shade: UInt8 = 0) -> CGImage {
        let ctx = Image.context(width: 200, height: 200)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        // ~0.2% of the canvas, standing in for the status bar and home indicator.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 192, width: 30, height: 3))
        return ctx.makeImage()!
    }

    /// A drawn screen: enough structure that no one colour owns the canvas.
    static func drawn() -> CGImage {
        let ctx = Image.context(width: 200, height: 200)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        for row in 0..<10 {
            ctx.fill(CGRect(x: 10, y: row * 20 + 4, width: 180, height: 8))
        }
        return ctx.makeImage()!
    }

    /// Serves each frame in turn, then repeats the last one forever.
    static func imageSource(_ images: [CGImage]) -> (count: () -> Int, next: () -> CGImage) {
        final class Cursor: @unchecked Sendable { var index = 0 }
        let cursor = Cursor()
        return (
            { cursor.index },
            {
                let image = images[min(cursor.index, images.count - 1)]
                cursor.index += 1
                return image
            }
        )
    }

    /// The blank-capture bug: a window that has launched but not drawn is perfectly
    /// still, so stillness alone declares it ready and the shutter fires on nothing.
    /// Cadence shipped four byte-identical black iPhone captures this way.
    @Test("a window that has not drawn yet does not settle, however still it is")
    func undrawnWindowKeepsPolling() async throws {
        let drawn = Self.drawn()
        let (_, next) = Self.imageSource([Self.blank(), Self.blank(), Self.blank(), drawn])
        let (image, settled) = try await Capture.settledImage(Self.quick(maxFrames: 50), within: .none) {
            next()
        }

        #expect(settled)
        #expect(Capture.isStill(image, drawn))
    }

    /// The floor is a claim about two measured populations, so pin both ends rather
    /// than leaving the number to be retuned on a hunch. Measured inside the safe area of
    /// real iOS captures, a blank window runs 0.00% off its dominant colour and the
    /// sparsest drawn screen (Cadence's person stage) 3.7%. A screen that reads as blank
    /// now fails its capture, so the floor keeps 2x margin under that screen.
    @Test("the content floor sits between a blank frame and the sparsest real screen")
    func contentFloorSeparatesBlankFromDrawn() {
        func canvas(coverage: Double) -> CGImage {
            let ctx = Image.context(width: 1000, height: 1000)!
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: Int(1000 * coverage)))
            return ctx.makeImage()!
        }

        #expect(Capture.isContentless(canvas(coverage: 0.005), within: .none))
        #expect(!Capture.isContentless(canvas(coverage: 0.037 / 2), within: .none))
        #expect(!Capture.isContentless(canvas(coverage: 0.36), within: .none))
    }

    /// The spinner-that-outlives-its-data case. It must end, and must say it did not
    /// settle — that flag is the only warning anyone gets.
    @Test("a window that never holds still ends at the ceiling, unsettled")
    func restlessWindowHitsCeiling() async throws {
        let alternating: [UInt8] = Array(0..<60).map { $0.isMultiple(of: 2) ? 20 : 200 }
        let (count, next) = Self.source(alternating)
        let (_, settled) = try await Capture.settledImage(Self.quick(maxFrames: 8), within: .none) { next() }

        #expect(!settled)
        #expect(count() == 8)
    }

    /// Otherwise a tight ceiling would return frame one and quietly disable the poll.
    @Test("the ceiling never funds fewer frames than a match needs")
    func ceilingBelowFloorStillPolls() {
        let q = Capture.quiescence(floor: 10, ceiling: 2)
        #expect(q.maxFrames >= Capture.pollMatches + 1)
    }

    @Test("the ceiling funds only what the floor has not already spent")
    func ceilingFundsTheRemainder() {
        let q = Capture.quiescence(floor: 1, ceiling: 8)
        #expect(q.maxFrames == Int(7 / Capture.pollInterval))
    }

    /// The tolerance is the whole design, and it is a claim about two specific things:
    /// a caret keeps blinking in a window that is *finished*, a spinner turns in one
    /// that is not. Both are small, so only the scale separates them — which makes
    /// this worth pinning at a plausible capture size rather than asserting in a
    /// comment. Fails if anyone retunes `stabilityTolerance` without meaning to.
    @Test("a caret reads as still; a spinner does not")
    func caretVersusSpinner() {
        let base = Image.context(width: 1400, height: 900)!
        base.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        base.fill(CGRect(x: 0, y: 0, width: 1400, height: 900))
        let still = base.makeImage()!

        func brightening(_ pixels: Int) -> CGImage {
            let px = Image.pixels(still)!
            var bytes = px.bytes
            for i in 0..<pixels {
                bytes[(px.width * (px.height / 2) + i) * 4] = 255
            }
            let ctx = Image.context(width: px.width, height: px.height)!
            ctx.data!.copyMemory(from: bytes, byteCount: bytes.count)
            return ctx.makeImage()!
        }

        #expect(Capture.isStill(still, brightening(40)))  // caret
        #expect(!Capture.isStill(still, brightening(1024)))  // 32pt spinner
    }

    @Test("a resized window is never still, however similar it looks")
    func sizeChangeIsNotStill() {
        let ctx = Image.context(width: 40, height: 41)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 41))
        #expect(!Capture.isStill(Self.frame(0), ctx.makeImage()!))
    }
}

/// The timing report only earns its place if the numbers are right — a profile that
/// misattributes where a run spends its time is worse than none, because it would be
/// acted on. The measurement itself needs a window server; this arithmetic does not.
struct CaptureProfileTests {
    static func timings(
        launch: Double = 0, window: Double = 0, ready: Double = 0, floor: Double = 0,
        lockWait: Double = 0, poll: Double = 0, frames: Int = 3, encode: Double = 0,
        teardown: Double = 0
    ) -> Capture.Timings {
        Capture.Timings(
            launch: launch, window: window, ready: ready, floor: floor, lockWait: lockWait,
            poll: poll, frames: frames, encode: encode, teardown: teardown)
    }

    @Test("an empty run has no profile rather than a profile of zeroes")
    func emptyRun() {
        #expect(Capture.profile([]) == nil)
    }

    /// The reason for a median: one screen riding the ceiling must not be able to
    /// make the typical shot look expensive, since the typical shot is what the
    /// defaults are tuned against.
    @Test("one outlier moves the worst case, not the median")
    func outlierDoesNotDragTheMedian() throws {
        let profile = try #require(
            Capture.profile([
                Self.timings(poll: 0.5), Self.timings(poll: 0.5), Self.timings(poll: 8.0),
            ]))
        let poll = try #require(profile.phases.first { $0.name == "poll" })

        #expect(poll.median == 0.5)
        #expect(poll.worst == 8.0)
    }

    @Test("shares are of the whole run, and account for all of it")
    func sharesSumToOne() throws {
        let profile = try #require(
            Capture.profile([
                Self.timings(launch: 0.5, window: 0.25, floor: 1.0, poll: 0.75, teardown: 0.5)
            ]))

        #expect(abs(profile.phases.reduce(0) { $0 + $1.share } - 1.0) < 1e-9)
        #expect(profile.total == 3.0)

        let floor = try #require(profile.phases.first { $0.name == "floor" })
        #expect(abs(floor.share - 1.0 / 3.0) < 1e-9)
    }

    @Test("frame counts are reported as whole frames")
    func framesAreWholeNumbers() throws {
        let profile = try #require(
            Capture.profile([
                Self.timings(frames: 3), Self.timings(frames: 4), Self.timings(frames: 31),
            ]))
        #expect(profile.framesMedian == 4)
        #expect(profile.framesWorst == 31)
    }

    /// Lower median on an even count — picked so a frame count never lands halfway
    /// between two frames.
    @Test("an even count takes the lower median")
    func evenCountTakesLowerMedian() {
        #expect(Capture.median([1, 2, 3, 4]) == 2)
        #expect(Capture.median([10]) == 10)
        #expect(Capture.median([Int]()) == nil)
    }
}

/// Only the config can exempt a screen from `--recolor-traffic-lights`, and only the
/// screens it names.
struct CaptureChromeTests {
    @Test("a screen the config declares chromeless skips the repaint; the rest do not")
    func appliesOnlyToDeclaredScreens() throws {
        var declared = try ConfigTests.decode()
        declared.screens[1].chrome = Config.Chrome.none

        let parsed = try ["browser", "paywall"].map(Capture.Screen.init(spec:))
        let applied = Capture.Screen.applyingChrome(parsed, from: declared)
        #expect(applied.map(\.chromeless) == [false, true])
    }

    @Test("a spec alone never marks a screen chromeless")
    func specDefaultsToChrome() throws {
        #expect(try Capture.Screen(spec: "paywall:paywall:2").chromeless == false)
    }
}

/// The deadline around every ScreenCaptureKit call. SCK can leak its continuation and
/// never answer, and a shot waiting on it holds the capture lock for every project.
struct CaptureDeadlineTests {
    @Test("work that finishes in time returns its value")
    func finishesInTime() async throws {
        let value = try await Capture.withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("work that never finishes times out without waiting for it")
    func neverFinishes() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let value: Int? = try await Capture.withDeadline(.milliseconds(100)) {
            // Stands in for a leaked continuation: never cancelled, never done in time.
            try await Task.sleep(for: .seconds(60))
            return 1
        }
        #expect(value == nil)
        // What this proves is "did not wait for the work", and the work sleeps 60s. The
        // bound was 5s and failed CI at 9.8s and 15.5s: under the parallel suite a 3-core
        // runner's cooperative pool is saturated, so the 100ms timer task resumes late.
        // Half the work's duration still separates the two outcomes by a wide margin.
        #expect(clock.now - start < .seconds(30))
    }

    @Test("an error from the work is thrown, not swallowed as a timeout")
    func propagatesErrors() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await Capture.withDeadline(.seconds(5)) { () async throws -> Int in throw Boom() }
        }
    }
}

/// The content measure on frames shaped like a real iPhone 17 Pro Max capture.
///
/// 0.22.1 shipped seven identical blank iPhone captures: the system's status bar,
/// Dynamic Island and home indicator alone put a blank light frame 2.3-2.8% off its
/// background, over the 2% floor. The 200x200 `blank()` above could never show it,
/// because its chrome is a sliver.
struct CaptureSafeAreaTests {
    static let width = 1320
    static let height = 2868
    /// The Pro Max's safe-area insets at 3x: 62pt over the status bar and Dynamic
    /// Island, 34pt over the home indicator.
    static let safeArea = Capture.SafeArea(top: 186, bottom: 102)

    static func gray(_ v: Double, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: v, green: v, blue: v, alpha: alpha)
    }

    /// A Pro Max frame: the window, with the app's page drawn over it at `opacity`
    /// (nil for a window that has drawn nothing), under the chrome the system draws.
    ///
    /// The page is as sparse as the sparsest real one, Cadence's person stage, which
    /// measured 3.7% off its background: eleven rows of text. Corners are transparent,
    /// as `--mask=alpha` returns them.
    static func proMax(page opacity: Double?, dark: Bool = false) -> CGImage {
        let ctx = Image.context(width: width, height: height)!
        let background = dark ? 0.0 : 1.0
        let ink = 1 - background
        ctx.addPath(
            CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                cornerWidth: 186, cornerHeight: 186, transform: nil))
        ctx.setFillColor(gray(background))
        ctx.fillPath()

        // Drawing space is bottom-up: a row `y` from the top is at `height - y`.
        if let opacity {
            ctx.setFillColor(gray(ink, alpha: opacity))
            for row in 0..<11 {
                ctx.fill(CGRect(x: 60, y: height - 320 - row * 200, width: 1000, height: 14))
            }
        }

        ctx.setFillColor(gray(ink))
        ctx.fill(CGRect(x: 150, y: height - 110, width: 160, height: 50))  // the time
        ctx.fill(CGRect(x: 1000, y: height - 100, width: 200, height: 36))  // signal, battery
        ctx.fill(CGRect(x: 450, y: 24, width: 420, height: 15))  // home indicator
        // The Dynamic Island is black in both appearances.
        ctx.addPath(
            CGPath(
                roundedRect: CGRect(x: 471, y: height - 144, width: 378, height: 111),
                cornerWidth: 55, cornerHeight: 55, transform: nil))
        ctx.setFillColor(gray(0))
        ctx.fillPath()
        return ctx.makeImage()!
    }

    @Test("a blank Pro Max frame is contentless once the system chrome is left out")
    func blankWindowUnderChrome() {
        let blank = Self.proMax(page: nil)
        // The bug: measured over the whole frame, the chrome alone clears the floor.
        #expect(!Capture.isContentless(blank, within: .none))
        #expect(Capture.isContentless(blank, within: Self.safeArea))
    }

    /// The 0.11.0 case: a dark blank was already caught, and must stay caught.
    @Test("a dark blank Pro Max frame stays contentless")
    func darkBlankWindow() {
        #expect(Capture.isContentless(Self.proMax(page: nil, dark: true), within: Self.safeArea))
    }

    @Test("a sparse drawn screen still counts as drawn", arguments: [false, true])
    func sparseDrawnScreen(dark: Bool) {
        #expect(!Capture.isContentless(Self.proMax(page: 1, dark: dark), within: Self.safeArea))
    }

    /// The person~light capture: a faint ghost of the page, caught mid fade-in. An
    /// ease-in starts slowly, and there each poll moves a pixel less than the noise
    /// floor, so frame to frame it reads as still while the page is plainly arriving.
    @Test("a page fading in is not taken at 10% opacity")
    func fadeInIsNotTakenEarly() async throws {
        let blanks = 2
        // 2% a poll at first, about 5 levels of 255, under the floor of 8; then quick.
        let steps = [0.10, 0.12, 0.14, 0.16, 0.40, 0.75, 1.0]
        final class Cursor: @unchecked Sendable { var index = 0 }
        let cursor = Cursor()
        let (image, settled) = try await Capture.settledImage(
            CaptureQuiescenceTests.quick(maxFrames: blanks + steps.count + 10),
            within: Self.safeArea
        ) {
            defer { cursor.index += 1 }
            let i = cursor.index - blanks
            return Self.proMax(page: i < 0 ? nil : steps[min(i, steps.count - 1)])
        }

        #expect(settled)
        #expect(Capture.isStill(image, Self.proMax(page: 1)))
        #expect(!Capture.isStill(image, Self.proMax(page: 0.10)))
    }
}
