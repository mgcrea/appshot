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
    /// A 40x40 fill. `changing` shifts the colour far past the noise floor, standing
    /// in for content that is still drawing.
    static func frame(_ shade: UInt8) -> CGImage {
        let ctx = Image.context(width: 40, height: 40)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
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
        let (_, settled) = try await Capture.settledImage(Self.quick(maxFrames: 50)) { next() }

        #expect(settled)
        // matchesRequired comparisons, so matchesRequired + 1 frames — and crucially
        // not the 50 the ceiling would have allowed.
        #expect(count() == Capture.pollMatches + 1)
    }

    @Test("a window still changing keeps polling, then settles once it stops")
    func movingWindowWaits() async throws {
        // Three distinct frames before it holds still.
        let (count, next) = Self.source([10, 90, 170, 250])
        let (image, settled) = try await Capture.settledImage(Self.quick(maxFrames: 50)) { next() }

        #expect(settled)
        #expect(count() > Capture.pollMatches + 1)
        // It settled on the *last* state, not an early one it happened to pass through.
        #expect(Capture.isStill(image, Self.frame(250)))
    }

    /// The spinner-that-outlives-its-data case. It must end, and must say it did not
    /// settle — that flag is the only warning anyone gets.
    @Test("a window that never holds still ends at the ceiling, unsettled")
    func restlessWindowHitsCeiling() async throws {
        let alternating: [UInt8] = Array(0..<60).map { $0.isMultiple(of: 2) ? 20 : 200 }
        let (count, next) = Self.source(alternating)
        let (_, settled) = try await Capture.settledImage(Self.quick(maxFrames: 8)) { next() }

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
