import CoreGraphics
import Foundation
import Testing
@testable import AppShotKit

/// The gate is the thing everything downstream trusts, and a broken one still
/// installs baselines and prints success. These pin its behaviour directly; the
/// end-to-end proof is `appshot selftest`, which mutates real goldens.
struct GateTests {
    // MARK: - Helpers

    /// An image with a transparent border ring, standing in for the rounded
    /// window corners the real captures carry.
    static func makeImage(
        width: Int = 40,
        height: Int = 40,
        rgb: (UInt8, UInt8, UInt8) = (120, 130, 140),
        transparentCorner: Bool = true
    ) -> CGImage {
        let ctx = Image.context(width: width, height: height)!
        ctx.setFillColor(
            CGColor(
                srgbRed: Double(rgb.0) / 255, green: Double(rgb.1) / 255,
                blue: Double(rgb.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if transparentCorner {
            ctx.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, _ name: String, in dir: URL) throws {
        try Image.write(image, to: dir.appending(path: name))
    }

    /// The same image, with `pixels` opaque pixels brightened past the noise floor —
    /// a stand-in for a blinking caret. Mid-image, because the buffer is premultiplied
    /// and a brightened transparent corner would be clamped back to zero on write.
    static func drift(_ image: CGImage, pixels: Int) -> CGImage {
        let px = Image.pixels(image)!
        var bytes = px.bytes
        let row = px.height / 2
        for x in 0..<pixels {
            let i = (row * px.width + px.width / 4 + x) * 4
            bytes[i] = UInt8(min(255, Int(bytes[i]) + 64))
        }
        let ctx = Image.context(width: px.width, height: px.height)!
        ctx.data!.copyMemory(from: bytes, byteCount: bytes.count)
        return ctx.makeImage()!
    }

    static func tempDirs() throws -> (root: URL, cand: URL, gold: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-test-\(UUID().uuidString)")
        let cand = root.appending(path: "source")
        let gold = root.appending(path: "golden")
        try FileManager.default.createDirectory(at: cand, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gold, withIntermediateDirectories: true)
        return (root, cand, gold)
    }

    // MARK: - Alpha

    /// The whole reason this tool exists. The Python gate composited alpha away and
    /// reported a total alpha wipe as a clean match; folding alpha into the pixel
    /// diff would not have saved it either, because the transparent corners are far
    /// under the tolerance.
    @Test func alphaLossFailsEvenThoughItIsUnderTolerance() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.write(Self.makeImage(transparentCorner: true), "a.png", in: gold)
        try Self.write(Self.makeImage(transparentCorner: false), "a.png", in: cand)

        // Establish that it really is under tolerance: 16 corner px of 1600 = 1%,
        // but in RGB terms the flattened-over-black corner is the only difference,
        // and the categorical check — not the fraction — is what must catch it.
        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.failures.first?.reason.contains("transparen") == true)
    }

    @Test func identicalImagesPass() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = Self.makeImage()
        try Self.write(image, "a.png", in: gold)
        try Self.write(image, "a.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(report.passed)
        #expect(report.matched == 1)
    }

    /// The negative control. A gate that fails on everything is not a gate.
    @Test func subThresholdNoisePasses() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.write(Self.makeImage(rgb: (120, 130, 140)), "a.png", in: gold)
        // +8 is exactly the noise floor, which is strictly-greater, so it must pass.
        try Self.write(Self.makeImage(rgb: (128, 138, 148)), "a.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(report.passed, "a delta of exactly the noise floor must not count")
    }

    @Test func aboveThresholdChangeFails() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.write(Self.makeImage(rgb: (120, 130, 140)), "a.png", in: gold)
        try Self.write(Self.makeImage(rgb: (200, 130, 140)), "a.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.failures.first?.reason.contains("changed") == true)
    }

    // MARK: - Structural failures

    @Test func sizeChangeIsNeverTolerated() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.write(Self.makeImage(width: 40, height: 40), "a.png", in: gold)
        try Self.write(Self.makeImage(width: 41, height: 40), "a.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.failures.first?.reason.contains("size changed") == true)
    }

    /// The dangerous direction: the run stopped early and nobody noticed.
    @Test func goldenWithoutCandidateFails() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = Self.makeImage()
        try Self.write(image, "a.png", in: gold)
        try Self.write(image, "b.png", in: gold)
        try Self.write(image, "a.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.name == "b.png" })
    }

    @Test func newScreenWithoutGoldenFails() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = Self.makeImage()
        try Self.write(image, "a.png", in: gold)
        try Self.write(image, "a.png", in: cand)
        // Distinct on purpose: a copy of `a` would be a duplicate capture, and this
        // test would then pass on a fault it does not name.
        try Self.write(Self.makeImage(rgb: (10, 200, 60)), "new.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.name == "new.png" })
        #expect(report.duplicates.isEmpty)
    }

    // MARK: - Duplicates

    /// The failure every other check is blind to: one screen photographed twice under
    /// two names. The set is complete, the count is right, both files are valid PNGs,
    /// and each one matches its golden — because the golden was blessed from the same
    /// broken run.
    @Test func oneScreenCapturedTwiceFails() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = Self.makeImage()
        for dir in [gold, cand] {
            try Self.write(image, "main~dark.png", in: dir)
            try Self.write(image, "models~dark.png", in: dir)
        }

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed, "every candidate matches its golden — only the set is wrong")
        #expect(report.failures.isEmpty)
        #expect(report.duplicates.count == 1)
        #expect(report.duplicates.first?.names == ["main~dark.png", "models~dark.png"])
        #expect(report.duplicates.first?.reason.contains("stage argument") == true)
    }

    /// Byte-identity alone is defeated by a single pixel. A caret blinks, a thumbnail
    /// finishes loading — the hashes diverge and the duplicate sails through. Only the
    /// pixel tier can see this one.
    @Test func captureDuplicatedWithSlightDriftStillFails() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1000x1000 = 1M px, so the duplicate budget is 100px. Drift 4 pixels: far
        // under that, but enough to change the file's bytes.
        let base = Self.makeImage(width: 1000, height: 1000)
        let drifted = Self.drift(base, pixels: 4)
        try Self.write(base, "a~light.png", in: cand)
        try Self.write(drifted, "b~light.png", in: cand)
        try Self.write(base, "a~light.png", in: gold)
        try Self.write(drifted, "b~light.png", in: gold)

        // Establish that the hash tier really cannot see it.
        #expect(try Gate.sha256(of: cand.appending(path: "a~light.png"))
            != Gate.sha256(of: cand.appending(path: "b~light.png")))

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.duplicates.count == 1)
    }

    /// The negative control. A duplicate check that fires on genuinely different
    /// screens is worse than none — it would train people to pass `--force`.
    @Test func genuinelyDifferentScreensPass() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        for dir in [gold, cand] {
            try Self.write(Self.makeImage(rgb: (120, 130, 140)), "main~dark.png", in: dir)
            try Self.write(Self.makeImage(rgb: (20, 200, 90)), "models~dark.png", in: dir)
        }

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(report.passed)
        #expect(report.duplicates.isEmpty)
    }

    /// Two captures of the same screen at different sizes are not a duplicate — and
    /// bucketing by dimension is what keeps the check cheap, so pin it.
    @Test func sameImageAtDifferentSizesIsNotADuplicate() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        for dir in [gold, cand] {
            try Self.write(Self.makeImage(width: 40, height: 40), "a~dark.png", in: dir)
            try Self.write(Self.makeImage(width: 60, height: 60), "b~dark.png", in: dir)
        }

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(report.duplicates.isEmpty)
    }

    /// Which staging argument stopped working is the difference between a message you
    /// can act on and one you can't.
    @Test func reasonNamesTheAxisThatCollapsed() {
        #expect(Gate.reason(for: ["main~dark.png", "main~light.png"])
            .contains("Appearance staging"))
        #expect(Gate.reason(for: ["browser~dark.png", "paywall~dark.png"])
            .contains("stage argument"))
    }

    /// The laundering path. Without this, one `make screenshots-update` makes the
    /// duplicate the baseline, the gate compares it to itself, agrees, and the bug is
    /// invisible forever after.
    @Test func acceptRefusesToLaunderADuplicateIntoTheBaseline() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.write(Self.makeImage(rgb: (5, 5, 5)), "main~dark.png", in: gold)
        try Self.write(Self.makeImage(rgb: (9, 9, 9)), "models~dark.png", in: gold)

        let image = Self.makeImage()
        try Self.write(image, "main~dark.png", in: cand)
        try Self.write(image, "models~dark.png", in: cand)

        #expect(throws: AppShotError.self) {
            try Gate.accept(candidateDir: cand, goldenDir: gold)
        }
        // And it left the baseline exactly as it was.
        #expect(try Gate.sha256(of: gold.appending(path: "main~dark.png"))
            != Gate.sha256(of: gold.appending(path: "models~dark.png")))
    }

    // MARK: - Accept

    /// These goldens are, in some projects, the only copy. One truncated run plus one
    /// accept would otherwise destroy the baseline with nothing to recover from.
    @Test func acceptRefusesOnAPartialCapture() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = Self.makeImage()
        try Self.write(image, "a.png", in: gold)
        try Self.write(image, "b.png", in: gold)
        try Self.write(image, "a.png", in: cand)  // b was never captured

        let (accepted, orphans) = try Gate.accept(candidateDir: cand, goldenDir: gold)
        #expect(accepted == 0)
        #expect(orphans == ["b.png"])
        // And it left the baseline alone.
        #expect(try Gate.pngs(in: gold).count == 2)
    }

    @Test func acceptPrunesWhenAsked() throws {
        let (root, cand, gold) = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = Self.makeImage()
        try Self.write(image, "a.png", in: gold)
        try Self.write(image, "b.png", in: gold)
        try Self.write(image, "a.png", in: cand)

        let (accepted, orphans) = try Gate.accept(
            candidateDir: cand, goldenDir: gold, prune: true)
        #expect(accepted == 1)
        #expect(orphans.isEmpty)
        #expect(try Gate.pngs(in: gold).map(\.lastPathComponent) == ["a.png"])
    }
}
