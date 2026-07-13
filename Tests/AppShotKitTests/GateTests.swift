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
        try Self.write(image, "new.png", in: cand)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.name == "new.png" })
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
