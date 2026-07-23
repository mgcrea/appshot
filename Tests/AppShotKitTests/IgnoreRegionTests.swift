import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Gate ignore regions.
///
/// These exist for one measured, unfixable case: the iPad status bar carries a live
/// date that `simctl status_bar` cannot pin, and at 0.0484% of the canvas it sits under
/// the 0.1% tolerance — so it never fails outright, it just spends half the drift budget
/// every day.
///
/// The feature makes the gate *weaker* by construction, so these tests are as much about
/// what it must still catch as about what it excludes.
struct IgnoreRegionTests {

    /// A 40x40 image with `count` pixels brightened along the top row (y == 0), which is
    /// where a status bar lives.
    static func topStrip(_ image: CGImage, count: Int, row: Int = 0) -> CGImage {
        let px = Image.pixels(image)!
        var bytes = px.bytes
        for x in 0..<count {
            let i = (row * px.width + x) * 4
            bytes[i] = UInt8(min(255, Int(bytes[i]) + 64))
        }
        let ctx = Image.context(width: px.width, height: px.height)!
        ctx.data!.copyMemory(from: bytes, byteCount: bytes.count)
        return ctx.makeImage()!
    }

    // MARK: - The two halves

    @Test func aChangeInsideAnIgnoredRegionDoesNotCount() {
        let gold = GateTests.makeImage()
        let cand = Self.topStrip(gold, count: 40)  // a whole row: far over tolerance

        let mask = Gate.IgnoreMask(
            rects: [Config.Rect(x: 0, y: 0, width: 40, height: 3)], width: 40, height: 40)
        let (fraction, _) = Gate.changedFraction(
            Image.pixels(cand)!, Image.pixels(gold)!, ignore: mask)

        #expect(fraction == 0)
    }

    /// The half that matters more. A rect that swallowed the canvas would pass the test
    /// above happily, so the gate must be shown to still see everything else.
    @Test func aChangeOutsideAnIgnoredRegionStillCounts() {
        let gold = GateTests.makeImage()
        let cand = Self.topStrip(gold, count: 40, row: 20)

        let mask = Gate.IgnoreMask(
            rects: [Config.Rect(x: 0, y: 0, width: 40, height: 3)], width: 40, height: 40)
        let (fraction, _) = Gate.changedFraction(
            Image.pixels(cand)!, Image.pixels(gold)!, ignore: mask)

        #expect(fraction > Gate.defaultTolerance)
    }

    // MARK: - The denominator

    /// Ignored pixels leave the denominator too. Measuring the fraction over pixels that
    /// were never examined would make every remaining screen look more similar as the
    /// ignore list grew — the gate would silently loosen everywhere, not just in the band.
    @Test func ignoredPixelsLeaveTheDenominator() {
        let gold = GateTests.makeImage(width: 100, height: 100)
        // Every changed pixel is in the bottom half, so ignoring the top half removes
        // none of them from the numerator — only from the denominator.
        let cand = Self.topStrip(gold, count: 100, row: 60)

        let none = Gate.IgnoreMask(rects: [], width: 100, height: 100)
        let half = Gate.IgnoreMask(
            rects: [Config.Rect(x: 0, y: 0, width: 100, height: 50)], width: 100, height: 100)

        let (whole, _) = Gate.changedFraction(
            Image.pixels(cand)!, Image.pixels(gold)!, ignore: none)
        let (masked, _) = Gate.changedFraction(
            Image.pixels(cand)!, Image.pixels(gold)!, ignore: half)

        // The relationship, not the absolute count: halving the denominator must double
        // the fraction. Asserting a literal here would pin how the fixture happens to
        // rasterize rather than the behaviour under test.
        #expect(whole > 0)
        #expect(abs(masked - whole * 2) < 0.0001)
    }

    // MARK: - Accounting

    @Test func overlappingRectsAreNotDoubleCounted() {
        let mask = Gate.IgnoreMask(
            rects: [
                Config.Rect(x: 0, y: 0, width: 10, height: 10),
                Config.Rect(x: 5, y: 5, width: 10, height: 10),
            ],
            width: 40, height: 40)

        // 100 + 100 − 25 overlapping = 175, not 200.
        #expect(mask.count == 175)
        #expect(abs(mask.fraction - 175.0 / 1600.0) < 0.000001)
    }

    /// `validate()` rejects these, so this is about a direct API caller: clamping keeps
    /// an overhanging rect from trapping on an out-of-range index.
    @Test func anOverhangingRectIsClampedNotFatal() {
        let mask = Gate.IgnoreMask(
            rects: [Config.Rect(x: 30, y: 30, width: 100, height: 100)], width: 40, height: 40)

        #expect(mask.count == 100)  // only the 10x10 that overlaps
    }

    @Test func noRectsMeansNothingIsIgnored() {
        let mask = Gate.IgnoreMask(rects: [], width: 40, height: 40)

        #expect(mask.count == 0)
        #expect(mask.fraction == 0)
        #expect(!mask.ignores(0))
    }

    // MARK: - Through the whole gate

    @Test func theReportSaysWhatItIgnored() throws {
        let dirs = try GateTests.tempDirs()
        let gold = GateTests.makeImage()
        try GateTests.write(gold, "a~dark.png", in: dirs.gold)
        try GateTests.write(gold, "b~dark.png", in: dirs.gold)
        // Differ from their goldens only inside the band.
        try GateTests.write(Self.topStrip(gold, count: 40), "a~dark.png", in: dirs.cand)
        try GateTests.write(
            Self.topStrip(GateTests.makeImage(rgb: (200, 40, 40)), count: 40), "b~dark.png",
            in: dirs.cand)

        let report = try Gate.compare(
            candidateDir: dirs.cand, goldenDir: dirs.gold,
            options: Gate.Options(
                ignore: [Config.Rect(x: 0, y: 0, width: 40, height: 3)]))

        #expect(report.ignoredPixels == 120)
        #expect(abs(report.ignoredFraction - 120.0 / 1600.0) < 0.000001)
    }

    /// Nothing was compared, so nothing was ignored — a run that matched entirely by
    /// hash must not claim to have excluded pixels it never looked at.
    @Test func anAllHashMatchRunReportsNothingIgnored() throws {
        let dirs = try GateTests.tempDirs()
        // Two *different* screens, each byte-identical to its own golden. Reusing one
        // image under both names would trip the duplicate check instead — correctly,
        // which is the trap this fixture has to avoid rather than assert around.
        for (name, rgb) in [("a~dark.png", (120, 130, 140)), ("b~dark.png", (200, 40, 40))] {
            let image = GateTests.makeImage(
                rgb: (UInt8(rgb.0), UInt8(rgb.1), UInt8(rgb.2)))
            try GateTests.write(image, name, in: dirs.gold)
            try GateTests.write(image, name, in: dirs.cand)
        }

        let report = try Gate.compare(
            candidateDir: dirs.cand, goldenDir: dirs.gold,
            options: Gate.Options(
                ignore: [Config.Rect(x: 0, y: 0, width: 40, height: 3)]))

        #expect(report.passed)
        #expect(report.ignoredPixels == 0)
    }
}
