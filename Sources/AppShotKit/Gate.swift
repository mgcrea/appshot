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
///
/// ## The duplicate trap
///
/// The same shape, one level up. Every check in the pipeline compares a capture to
/// *its own* golden, or checks that a *name* arrived, or that a file *exists*. None
/// of them ever compares two captures to each other. So a run that photographed one
/// screen twice — a stage argument the app didn't recognise, a menu click the window
/// swallowed — writes both images under the right two names and sails through: the
/// set is complete, the count is right, every file is a valid PNG.
///
/// The golden gate catches it only while a good golden survives to disagree with.
/// One `accept` (which only ever copies bytes — it never decodes one) blesses the
/// duplicate as the baseline, and every run afterwards is green forever.
///
/// So the candidate set is checked against *itself* too. See `duplicates(in:)`.
public enum Gate {
    /// Per-channel delta above which a pixel counts as changed. Strictly greater:
    /// a delta of exactly 8 is noise, 9 is a change.
    public static let channelNoiseFloor: UInt8 = 8
    public static let defaultTolerance = 0.001  // 0.1%
    /// Max drift in the transparent-pixel count before it reads as a real change.
    public static let defaultAlphaTolerance = 0.20
    /// Below this fraction of changed pixels, two captures are the same screen.
    ///
    /// Two orders of magnitude of margin in each direction, which is why one number
    /// works for every project: on a 2880x1800 capture this is a budget of ~518px,
    /// while a blinking caret is ~40px and the *smallest* genuine difference in a
    /// real screen set — one screen plus an open dropdown — is tens of thousands.
    public static let defaultDuplicateTolerance = 0.0001  // 0.01%

    public struct Failure: Sendable {
        public let name: String
        public let reason: String
        /// Written only for tolerance failures — a size or alpha failure has no
        /// meaningful pixel diff.
        public let diffPath: URL?
    }

    /// Two or more captures that are the same image under different names.
    public struct Duplicate: Sendable {
        public let names: [String]
        public let reason: String
    }

    public struct Report: Sendable {
        public let matched: Int
        public let failures: [Failure]
        /// Kept off `failures` deliberately: a duplicate is a property of the set, not
        /// a bad file, and folding it in would double-count screens that are also
        /// failing their golden.
        public let duplicates: [Duplicate]
        public let tolerance: Double
        public var passed: Bool { failures.isEmpty && duplicates.isEmpty }
    }

    public struct Options: Sendable {
        public var tolerance: Double
        public var alphaTolerance: Double
        public var duplicateTolerance: Double
        public var diffDir: URL?

        public init(
            tolerance: Double = Gate.defaultTolerance,
            alphaTolerance: Double = Gate.defaultAlphaTolerance,
            duplicateTolerance: Double = Gate.defaultDuplicateTolerance,
            diffDir: URL? = nil
        ) {
            self.tolerance = tolerance
            self.alphaTolerance = alphaTolerance
            self.duplicateTolerance = duplicateTolerance
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

        // Against the set itself, before anything is compared to a golden — this is
        // the one failure a per-file golden check is structurally blind to.
        let duplicates = try duplicates(
            in: candidateDir, tolerance: options.duplicateTolerance)

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

        return Report(
            matched: matched,
            failures: failures,
            duplicates: duplicates,
            tolerance: options.tolerance)
    }

    // MARK: - Accept

    /// Accept the candidates as the new goldens.
    ///
    /// Refuses on a partial capture unless `prune`: in projects where the goldens
    /// are not committed, this directory is the only copy, and one truncated run
    /// plus one accept would destroy the baseline with nothing to recover from.
    ///
    /// Refuses on duplicates always, with no escape hatch. A partial capture is at
    /// least obvious once accepted — files are missing. A duplicate accepted into the
    /// baseline is invisible forever after: the gate compares it to itself and agrees.
    @discardableResult
    public static func accept(
        candidateDir: URL,
        goldenDir: URL,
        prune: Bool = false
    ) throws -> (accepted: Int, orphans: [String]) {
        let candidates = try pngs(in: candidateDir)
        guard !candidates.isEmpty else { throw AppShotError.noCaptures(candidateDir) }

        // The point of no return. Accepting a duplicate makes it the baseline, and a
        // baseline that disagrees with nothing can never be caught again.
        let duplicates = try duplicates(in: candidateDir)
        guard duplicates.isEmpty else { throw AppShotError.duplicateCaptures(duplicates) }

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

    // MARK: - Duplicates

    /// Captures that are the same image under two names — the tell that a stage
    /// argument did nothing, or that a click was swallowed and one screen got
    /// photographed twice.
    ///
    /// Two tiers, cheap one first:
    ///
    /// 1. **sha256 of the file bytes.** N hashes, no decode, no pairs. Catches the
    ///    clean case, where the app rendered the identical static screen twice.
    ///
    /// 2. **Near-identity.** Byte-identity alone is defeated by a *single* pixel — a
    ///    blinking caret, a thumbnail that finished loading between the two shots —
    ///    and the duplicate would sail through, which is exactly the trap the alpha
    ///    check exists to avoid. So survivors are bucketed by pixel dimensions (read
    ///    from the PNG header; a duplicate always shares its twin's size, so this
    ///    discards most pairs without decoding anything) and same-size pairs are
    ///    compared pixel-wise.
    ///
    /// The pixel scan early-exits the moment the budget is blown, so two genuinely
    /// different screens cost a few thousand pixels, not a few million. A clean run
    /// stays fast — and a gate that feels slow is one someone takes out of the
    /// default target, and then it protects nothing.
    public static func duplicates(
        in dir: URL,
        tolerance: Double = Gate.defaultDuplicateTolerance
    ) throws -> [Duplicate] {
        let files = try pngs(in: dir)
        guard files.count > 1 else { return [] }

        var groups: [[URL]] = []

        // Tier 1: exact bytes.
        var byDigest: [SHA256Digest: [URL]] = [:]
        for file in files {
            byDigest[try sha256(of: file), default: []].append(file)
        }
        let exact = byDigest.values.filter { $0.count > 1 }
        groups.append(contentsOf: exact)
        let claimed = Set(exact.flatMap { $0 })

        // Tier 2: near-identity, bucketed by size so most pairs never get decoded.
        var byDimension: [Dimension: [URL]] = [:]
        for file in files where !claimed.contains(file) {
            guard let size = Image.size(file) else { throw AppShotError.imageDecodeFailed(file) }
            byDimension[Dimension(width: size.width, height: size.height), default: []]
                .append(file)
        }

        for bucket in byDimension.values where bucket.count > 1 {
            // One bucket at a time: these buffers are ~20MB each.
            var pixels: [URL: Image.Pixels] = [:]
            for file in bucket {
                guard let px = Image.pixels(try Image.load(file)) else {
                    throw AppShotError.imageDecodeFailed(file)
                }
                pixels[file] = px
            }

            var pending = bucket
            while !pending.isEmpty {
                let head = pending.removeFirst()
                guard let a = pixels[head] else { continue }
                var group = [head]
                pending.removeAll { other in
                    guard let b = pixels[other],
                          nearlyIdentical(a, b, tolerance: tolerance)
                    else { return false }
                    group.append(other)
                    return true
                }
                if group.count > 1 { groups.append(group) }
            }
        }

        return groups
            .map { urls -> Duplicate in
                let names = urls.map(\.lastPathComponent).sorted()
                return Duplicate(names: names, reason: reason(for: names))
            }
            .sorted { $0.names[0] < $1.names[0] }
    }

    private struct Dimension: Hashable {
        let width: Int
        let height: Int
    }

    /// Name the staging axis that collapsed. The filenames are `<id>~<appearance>`,
    /// so which half they disagree on says *which* argument stopped working — and
    /// that is the difference between a message you can act on and one you can't.
    static func reason(for names: [String]) -> String {
        let parts = names.map { name -> (id: String, appearance: String?) in
            let stem = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
            let halves = stem.split(separator: "~", maxSplits: 1).map(String.init)
            return (halves.first ?? stem, halves.count > 1 ? halves[1] : nil)
        }
        let ids = Set(parts.map(\.id))
        let appearances = Set(parts.compactMap(\.appearance))

        let list = names.joined(separator: " ≡ ")
        if ids.count == 1 && appearances.count > 1 {
            return "\(list) are identical images. Appearance staging had no effect — the "
                + "app rendered the same appearance for both."
        }
        if ids.count > 1 {
            return "\(list) are identical images. The stage argument had no effect — the "
                + "same screen was photographed twice."
        }
        return "\(list) are identical images."
    }

    /// Do these two differ in fewer than `tolerance` of their pixels?
    ///
    /// Same per-channel max and same noise floor as `changedFraction`, so "changed"
    /// means one thing everywhere. Two differences: it early-exits as soon as the
    /// budget is blown, and it builds no diff image — a duplicate has no meaningful
    /// pixel diff to look at, and the amplified buffer costs 20MB a call.
    static func nearlyIdentical(
        _ a: Image.Pixels,
        _ b: Image.Pixels,
        tolerance: Double
    ) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let count = a.count
        let budget = Int(Double(count) * tolerance)
        var changed = 0

        for i in 0..<count {
            let p = a[i]
            let q = b[i]
            let dr = p.r > q.r ? p.r - q.r : q.r - p.r
            let dg = p.g > q.g ? p.g - q.g : q.g - p.g
            let db = p.b > q.b ? p.b - q.b : q.b - p.b
            if max(dr, max(dg, db)) > channelNoiseFloor {
                changed += 1
                if changed > budget { return false }
            }
        }
        return true
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

    /// Which of `expected` are not in `dir`.
    ///
    /// The gate can only compare what it was given, and a screen that is missing from
    /// *both* the captures and the goldens is a consistent pair of nothings: it agrees
    /// with itself and nobody notices. That is not hypothetical — a UI-test driver that
    /// skips a screen it cannot reach produces exactly this. The config is the only
    /// place that knows the set was meant to be bigger.
    public static func missing(_ expected: [String], in dir: URL) throws -> [String] {
        let found = Set((try? pngs(in: dir))?.map(\.lastPathComponent) ?? [])
        return expected.filter { !found.contains($0) }.sorted()
    }

    static func pngs(in dir: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return items
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func sha256(of url: URL) throws -> SHA256Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    private static func identicalBytes(_ a: URL, _ b: URL) throws -> Bool {
        let sizeA = try FileManager.default.attributesOfItem(atPath: a.path)[.size] as? Int
        let sizeB = try FileManager.default.attributesOfItem(atPath: b.path)[.size] as? Int
        guard sizeA == sizeB else { return false }
        return try sha256(of: a) == sha256(of: b)
    }
}
