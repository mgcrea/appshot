import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// A percentage says a screen changed. It does not say *where*, and it does not say
/// whether the change is content or tone — and the diff PNG is amplified 12x, which
/// makes those two look identical at a glance.
///
/// Both misreadings cost real time in a fleet audit: a uniform background shift was read
/// as a redesign, and a footer whose copy changed was read as a timestamp column. These
/// pin the two answers that would have settled it immediately.
struct DriftLocationTests {
    /// A flat field, optionally with a band of a different shade across some rows.
    static func field(
        width: Int = 40, height: Int = 40, shade: UInt8,
        band: (rows: Range<Int>, shade: UInt8)? = nil
    ) -> Image.Pixels {
        let ctx = Image.context(width: width, height: height)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let band {
            let b = Double(band.shade) / 255
            ctx.setFillColor(CGColor(srgbRed: b, green: b, blue: b, alpha: 1))
            // CoreGraphics origin is bottom-left; Pixels indexes from the top.
            ctx.fill(
                CGRect(
                    x: 0, y: height - band.rows.upperBound,
                    width: width, height: band.rows.count))
        }
        return Image.pixels(ctx.makeImage()!)!
    }

    // MARK: - Where

    /// The status-bar case: a drift confined to a band of rows should report that band,
    /// so a reviewer can crop straight to it.
    @Test func localizesABandOfRowsToItsBoundingBox() {
        let gold = Self.field(shade: 100)
        let cand = Self.field(shade: 100, band: (rows: 30..<35, shade: 200))

        let (fraction, _, drift) = Gate.changedFraction(cand, gold)
        #expect(fraction > 0)
        let box = try! #require(drift.box)
        #expect(box.minY == 30)
        #expect(box.maxY == 34)
        // The band spans the full width, so the box does too.
        #expect(box.minX == 0)
        #expect(box.maxX == 39)
    }

    @Test func busiestRowsPointAtTheDensestRows() {
        let gold = Self.field(shade: 100)
        let cand = Self.field(shade: 100, band: (rows: 10..<13, shade: 200))

        let (_, _, drift) = Gate.changedFraction(cand, gold)
        let rows = Set(drift.busiestRows.map(\.y))
        #expect(rows == Set([10, 11, 12]))
        // Full-width band, so every reported row carries the whole width.
        #expect(drift.busiestRows.allSatisfy { $0.count == 40 })
    }

    /// Identical images have nowhere to point, and must not invent a box.
    @Test func identicalImagesReportNoLocation() {
        let gold = Self.field(shade: 100)
        let cand = Self.field(shade: 100)

        let (fraction, _, drift) = Gate.changedFraction(cand, gold)
        #expect(fraction == 0)
        #expect(drift.box == nil)
        #expect(drift.busiestRows.isEmpty)
        #expect(drift.maxDelta == 0)
    }

    // MARK: - Content or tone

    /// The reading that cost the most time: a whole canvas shifted by a couple of units
    /// breaches nothing, so the verdict says "almost nothing changed" while the
    /// amplified diff lights up everywhere. The dominant sub-floor delta is what names
    /// it as a tonal shift.
    @Test func uniformSubFloorShiftIsNamedAsTone() {
        let gold = Self.field(shade: 100)
        let cand = Self.field(shade: 100 + UInt8(Gate.channelNoiseFloor))

        let (fraction, _, drift) = Gate.changedFraction(cand, gold)
        // Under the floor, so the gate is right that nothing "changed".
        #expect(fraction == 0)
        // But it is not nothing, and this is where that shows.
        #expect(drift.dominantSubFloorDelta == Int(Gate.channelNoiseFloor))
        #expect(drift.dominantSubFloorFraction > 0.99)
        #expect(drift.summary.contains("uniform tonal change"))
    }

    /// A real content change in one region must NOT be described as a tonal shift, or
    /// the signal is worse than useless.
    @Test func localizedContentChangeIsNotCalledTone() {
        let gold = Self.field(shade: 100)
        let cand = Self.field(shade: 100, band: (rows: 30..<35, shade: 220))

        let (_, _, drift) = Gate.changedFraction(cand, gold)
        #expect(drift.dominantSubFloorFraction < 0.25)
        #expect(!drift.summary.contains("uniform tonal change"))
        #expect(drift.summary.contains("y[30"))
    }

    @Test func maxDeltaReportsTheLargestChannelMove() {
        let gold = Self.field(shade: 10)
        let cand = Self.field(shade: 10, band: (rows: 0..<2, shade: 200))

        let (_, _, drift) = Gate.changedFraction(cand, gold)
        #expect(drift.maxDelta >= 180)
    }
}
