import CoreGraphics
import CryptoKit
import Foundation

/// Golden-image regression gate.
///
/// A faithful port of `compare_goldens.py` — same noise floor, same per-channel
/// max (not luminance: a pure-blue shift barely moves luminance but is a real
/// change), same x12 amplified diffs, same sha256 fast path, same failure
/// conditions — plus the one check the original could not make.
///
/// ## The alpha trap
///
/// The original composites RGBA over opaque black before comparing, so alpha is
/// discarded by design. That means it cannot see the regression it exists to
/// catch: a capture that lost its transparent window corners (the fallback path
/// when Screen Recording isn't granted) still scores zero difference.
///
/// And folding alpha into the fractional diff does not fix it either. The
/// transparent corners are only ~0.056% of a 2880x1800 capture, while the
/// tolerance is 0.1% — so a *total* alpha wipe scores under tolerance and passes.
/// Measured against real goldens, it passed on 12 of 14 images.
///
/// Alpha loss is categorical, not gradual drift. It gets its own check, with its
/// own message, outside the tolerance. `Gate.selfTest` proves it fires.
public enum Gate {
    /// Per-channel delta above which a pixel counts as changed. Strictly greater:
    /// a delta of exactly 8 is noise, 9 is a change.
    public static let channelNoiseFloor: UInt8 = 8
    public static let defaultTolerance = 0.001  // 0.1%
    /// Max drift in the transparent-pixel count before it reads as a real change.
    public static let defaultAlphaTolerance = 0.20

    public struct Failure: Sendable {
        public let name: String
        public let reason: String
        /// Written only for tolerance failures — a size or alpha failure has no
        /// meaningful pixel diff.
        public let diffPath: URL?
    }

    public struct Report: Sendable {
        public let matched: Int
        public let failures: [Failure]
        public let tolerance: Double
        public var passed: Bool { failures.isEmpty }
    }

    public struct Options: Sendable {
        public var tolerance: Double
        public var alphaTolerance: Double
        public var diffDir: URL?

        public init(
            tolerance: Double = Gate.defaultTolerance,
            alphaTolerance: Double = Gate.defaultAlphaTolerance,
            diffDir: URL? = nil
        ) {
            self.tolerance = tolerance
            self.alphaTolerance = alphaTolerance
            self.diffDir = diffDir
        }
    }

    // MARK: - Compare

    public static func compare(
        candidateDir: URL,
        goldenDir: URL,
        options: Options = Options()
    ) throws -> Report {
        let candidates = try pngs(in: candidateDir)
        guard !candidates.isEmpty else { throw AppShotError.noCaptures(candidateDir) }

        let goldens = (try? pngs(in: goldenDir)) ?? []
        guard !goldens.isEmpty else { throw AppShotError.noGoldens(goldenDir) }
        let goldenNames = Set(goldens.map(\.lastPathComponent))

        // Sibling of the candidate dir, matching the original's default.
        let diffDir = options.diffDir ?? candidateDir.deletingLastPathComponent()
            .appending(path: "diff")
        var failures: [Failure] = []
        var matched = 0

        for candidate in candidates {
            let name = candidate.lastPathComponent
            let golden = goldenDir.appending(path: name)

            guard goldenNames.contains(name) else {
                failures.append(Failure(
                    name: name,
                    reason: "new screen, no golden. Review it, then accept with `appshot accept`.",
                    diffPath: nil))
                continue
            }

            // Identical bytes cannot be a visual difference, and a clean run is the
            // normal case. A gate that feels slow is one someone takes out of the
            // default target, and then it protects nothing.
            if try identicalBytes(candidate, golden) {
                matched += 1
                continue
            }

            let candImage = try Image.load(candidate)
            let goldImage = try Image.load(golden)

            guard
                candImage.width == goldImage.width,
                candImage.height == goldImage.height
            else {
                failures.append(Failure(
                    name: name,
                    reason: "size changed \(goldImage.width)x\(goldImage.height) -> "
                        + "\(candImage.width)x\(candImage.height). "
                        + "The window is no longer pinned to a deterministic size.",
                    diffPath: nil))
                continue
            }

            guard
                let cand = Image.pixels(candImage),
                let gold = Image.pixels(goldImage)
            else {
                throw AppShotError.imageDecodeFailed(candidate)
            }

            if let reason = alphaRegression(cand, gold, tolerance: options.alphaTolerance) {
                failures.append(Failure(name: name, reason: reason, diffPath: nil))
                continue
            }

            let (fraction, diff) = changedFraction(cand, gold)
            if fraction > options.tolerance {
                var written: URL?
                if let image = diff {
                    let out = diffDir.appending(path: name)
                    try? Image.write(image, to: out)
                    written = out
                }
                failures.append(Failure(
                    name: name,
                    reason: String(
                        format: "%.3f%% of pixels changed (tolerance %.3f%%)",
                        fraction * 100, options.tolerance * 100),
                    diffPath: written))
                continue
            }

            matched += 1
        }

        // The dangerous direction: the capture stopped early and nobody noticed.
        for name in goldenNames.subtracting(candidates.map(\.lastPathComponent)).sorted() {
            failures.append(Failure(
                name: name,
                reason: "golden exists but nothing was captured. Did the run stop early?",
                diffPath: nil))
        }

        return Report(matched: matched, failures: failures, tolerance: options.tolerance)
    }

    // MARK: - Accept

    /// Accept the candidates as the new goldens.
    ///
    /// Refuses on a partial capture unless `prune`: in projects where the goldens
    /// are not committed, this directory is the only copy, and one truncated run
    /// plus one accept would destroy the baseline with nothing to recover from.
    @discardableResult
    public static func accept(
        candidateDir: URL,
        goldenDir: URL,
        prune: Bool = false
    ) throws -> (accepted: Int, orphans: [String]) {
        let candidates = try pngs(in: candidateDir)
        guard !candidates.isEmpty else { throw AppShotError.noCaptures(candidateDir) }

        try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
        let existing = (try? pngs(in: goldenDir)) ?? []
        let candidateNames = Set(candidates.map(\.lastPathComponent))
        let orphans = existing.map(\.lastPathComponent)
            .filter { !candidateNames.contains($0) }
            .sorted()

        if !orphans.isEmpty && !prune {
            return (0, orphans)
        }

        for old in existing {
            try FileManager.default.removeItem(at: old)
        }
        for candidate in candidates {
            // Copy the bytes. Re-encoding would rewrite the file and drop the ICC
            // profile, so the goldens would stop being what was actually captured.
            try FileManager.default.copyItem(
                at: candidate, to: goldenDir.appending(path: candidate.lastPathComponent))
        }
        return (candidates.count, [])
    }

    // MARK: - Checks

    /// Non-opaque pixels — in practice, the rounded window corners.
    static func nonOpaqueCount(_ p: Image.Pixels) -> Int {
        var count = 0
        for i in stride(from: 3, to: p.bytes.count, by: 4) where p.bytes[i] < 255 {
            count += 1
        }
        return count
    }

    /// Categorical alpha check. See the type doc for why this is separate from the
    /// changed-pixel fraction rather than folded into it.
    static func alphaRegression(
        _ cand: Image.Pixels,
        _ gold: Image.Pixels,
        tolerance: Double
    ) -> String? {
        let g = nonOpaqueCount(gold)
        guard g > 0 else { return nil }
        let c = nonOpaqueCount(cand)
        if c == 0 {
            return "lost all transparency (golden has \(g) non-opaque px, candidate has 0) — "
                + "the capture almost certainly fell back to an opaque-corner screenshot"
        }
        let drift = abs(Double(c - g)) / Double(g)
        if drift > tolerance {
            return String(
                format: "transparent-pixel count %d vs golden %d (%.0f%% drift)",
                c, g, drift * 100)
        }
        return nil
    }

    /// Fraction of pixels differing beyond the noise floor, plus an amplified diff
    /// image for review.
    ///
    /// Collapses the per-channel difference with a **max**, not a luminance
    /// average — a pure-blue shift barely moves luminance but is a real change.
    ///
    /// Compares RGB only. The pixels are premultiplied, so their RGB is already the
    /// colour composited over black — the same flattening the Python gate did
    /// explicitly, which keeps transparent corners from reading as differences.
    /// Alpha is handled categorically by `alphaRegression`, not here.
    static func changedFraction(
        _ cand: Image.Pixels,
        _ gold: Image.Pixels
    ) -> (fraction: Double, diff: CGImage?) {
        let count = cand.count
        var changed = 0
        var amplified = [UInt8](repeating: 255, count: count * 4)

        for i in 0..<count {
            let c = cand[i]
            let g = gold[i]
            let dr = c.r > g.r ? c.r - g.r : g.r - c.r
            let dg = c.g > g.g ? c.g - g.g : g.g - c.g
            let db = c.b > g.b ? c.b - g.b : g.b - c.b
            if max(dr, max(dg, db)) > channelNoiseFloor { changed += 1 }

            // x12, clamped — an unamplified diff of a few units is invisible.
            let j = i * 4
            amplified[j] = amp(dr)
            amplified[j + 1] = amp(dg)
            amplified[j + 2] = amp(db)
        }

        let fraction = count > 0 ? Double(changed) / Double(count) : 0
        let diff = makeImage(amplified, width: cand.width, height: cand.height)
        return (fraction, diff)
    }

    @inline(__always)
    private static func amp(_ v: UInt8) -> UInt8 {
        UInt8(min(255, Int(v) * 12))
    }

    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let ctx = Image.context(width: width, height: height) else { return nil }
        guard let data = ctx.data else { return nil }
        data.copyMemory(from: rgba, byteCount: rgba.count)
        return ctx.makeImage()
    }

    // MARK: - Files

    static func pngs(in dir: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return items
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func identicalBytes(_ a: URL, _ b: URL) throws -> Bool {
        let sizeA = try FileManager.default.attributesOfItem(atPath: a.path)[.size] as? Int
        let sizeB = try FileManager.default.attributesOfItem(atPath: b.path)[.size] as? Int
        guard sizeA == sizeB else { return false }
        let hashA = SHA256.hash(data: try Data(contentsOf: a))
        let hashB = SHA256.hash(data: try Data(contentsOf: b))
        return hashA == hashB
    }
}
