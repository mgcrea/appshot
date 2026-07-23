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
        /// What went wrong, as a value rather than a sentence.
        ///
        /// `reason` is written for a person and will keep being reworded; something
        /// driving `check` from a script must not have to match on its prose. That is
        /// not hypothetical — grepping for `✗` and a percentage out of human-formatted
        /// output is what an agent had to do to decide pass/fail.
        public enum Kind: String, Sendable, Codable {
            case newScreen = "new_screen"
            case sizeChanged = "size_changed"
            case alphaLost = "alpha_lost"
            case alphaDrift = "alpha_drift"
            case pixelDrift = "pixel_drift"
            case missingCapture = "missing_capture"
        }

        public let name: String
        public let kind: Kind
        public let reason: String
        /// Fraction of pixels beyond the noise floor, for `.pixelDrift`. The number
        /// the reason used to format away.
        public let pixelDiffFraction: Double?
        /// Written only for tolerance failures — a size or alpha failure has no
        /// meaningful pixel diff.
        public let diffPath: URL?

        init(
            name: String,
            kind: Kind,
            reason: String,
            pixelDiffFraction: Double? = nil,
            diffPath: URL? = nil
        ) {
            self.name = name
            self.kind = kind
            self.reason = reason
            self.pixelDiffFraction = pixelDiffFraction
            self.diffPath = diffPath
        }
    }

    /// Two or more captures that are the same image under different names.
    public struct Duplicate: Sendable {
        public let names: [String]
        public let reason: String
    }

    public struct Report: Sendable {
        /// The screens that agreed with their goldens. Named, not just counted: a
        /// machine-readable verdict has to say which screen it is talking about, and
        /// a count cannot be joined against anything.
        public let matchedNames: [String]
        public var matched: Int { matchedNames.count }
        public let failures: [Failure]
        /// Kept off `failures` deliberately: a duplicate is a property of the set, not
        /// a bad file, and folding it in would double-count screens that are also
        /// failing their golden.
        public let duplicates: [Duplicate]
        public let tolerance: Double
        /// Whether the goldens carry a manifest. False is not a failure — it is a
        /// project that has not run `appshot seal` yet — but it is worth saying,
        /// because an unsealed baseline is one nothing can vouch for.
        public let sealed: Bool
        /// Pixels per capture excluded from the comparison by `Options.ignore`.
        ///
        /// Reported rather than merely applied. An ignore list is the one setting here
        /// that makes the gate *weaker*, and a weakening nobody can see is how "ignore
        /// the status bar" grows into "ignore the top third of the screen" one commit
        /// at a time.
        public let ignoredPixels: Int
        /// `ignoredPixels` as a fraction of one capture's canvas.
        public let ignoredFraction: Double
        public var passed: Bool { failures.isEmpty && duplicates.isEmpty }
    }

    public struct Options: Sendable {
        public var tolerance: Double
        public var alphaTolerance: Double
        public var duplicateTolerance: Double
        public var diffDir: URL?
        /// Fail if the goldens are not sealed at all. Off by default so a project
        /// that predates the manifest keeps working; on in CI, where the difference
        /// between a reviewed baseline and an arbitrary one is the whole point.
        public var requireManifest: Bool
        /// Regions excluded from the pixel comparison, in capture pixels.
        ///
        /// For content that is genuinely outside the project's control — measured case:
        /// the iPad status bar carries a live date that `simctl status_bar` cannot pin,
        /// and at 0.0484% of the canvas it sits *under* the 0.1% tolerance, so it never
        /// fails outright and instead spends half the drift budget every day.
        ///
        /// Applies to the drift comparison only. `alphaRegression` and the duplicate
        /// check still see the whole image: the first is measuring transparency, which
        /// lives in the corners an ignore rect has no business covering, and the second
        /// is asking whether two captures are the same screen — a question that gets
        /// *easier* to answer wrongly the more pixels you discard.
        public var ignore: [Config.Rect]

        public init(
            tolerance: Double = Gate.defaultTolerance,
            alphaTolerance: Double = Gate.defaultAlphaTolerance,
            duplicateTolerance: Double = Gate.defaultDuplicateTolerance,
            diffDir: URL? = nil,
            requireManifest: Bool = false,
            ignore: [Config.Rect] = []
        ) {
            self.tolerance = tolerance
            self.alphaTolerance = alphaTolerance
            self.duplicateTolerance = duplicateTolerance
            self.diffDir = diffDir
            self.requireManifest = requireManifest
            self.ignore = ignore
        }
    }

    /// A per-pixel "skip this" lookup built once per comparison.
    ///
    /// Built as a flat mask rather than testing each pixel against every rect: the rect
    /// list is short but the pixel loop runs millions of times, and the mask turns a
    /// per-pixel loop over rects into one array read.
    struct IgnoreMask {
        let skip: [Bool]
        let count: Int
        let width: Int
        let height: Int

        init(rects: [Config.Rect], width: Int, height: Int) {
            self.width = width
            self.height = height
            guard !rects.isEmpty else {
                skip = []
                count = 0
                return
            }
            var mask = [Bool](repeating: false, count: width * height)
            var marked = 0
            for rect in rects {
                // Clamped, so a rect that overhangs the canvas masks the part that
                // overlaps instead of trapping on an out-of-range index. `validate()`
                // rejects those up front; this is what keeps a direct API caller safe.
                let x0 = max(0, rect.x), y0 = max(0, rect.y)
                let x1 = min(width, rect.x + rect.width)
                let y1 = min(height, rect.y + rect.height)
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    let row = y * width
                    for x in x0..<x1 where !mask[row + x] {
                        mask[row + x] = true
                        // Counted as it is marked, so overlapping rects are not
                        // double-counted and the reported figure is the true one.
                        marked += 1
                    }
                }
            }
            skip = mask
            count = marked
        }

        @inline(__always)
        func ignores(_ index: Int) -> Bool {
            !skip.isEmpty && skip[index]
        }

        var fraction: Double {
            let total = width * height
            return total > 0 ? Double(count) / Double(total) : 0
        }
    }

    // MARK: - Compare

    public static func compare(
        candidateDir: URL,
        goldenDir: URL,
        options: Options = Options()
    ) throws -> Report {
        let candidates = try pngs(in: candidateDir)
        guard !candidates.isEmpty else { throw noCapturesReason(candidateDir) }

        let goldens = (try? pngs(in: goldenDir)) ?? []
        guard !goldens.isEmpty else { throw AppShotError.noGoldens(goldenDir) }

        // Before the hash fast path, not at decode time. In a clone that has not run
        // `git lfs pull`, the goldens are byte-identical text pointers — so the fast
        // path would call every screenshot a clean match and pass the gate.
        try Image.rejectLFSPointers(candidates + goldens)

        // After the LFS check, so an unpulled clone gets the message that names the
        // actual problem rather than a wall of sha mismatches. Before everything else,
        // because a baseline nobody can vouch for is not worth comparing against: the
        // answer would be about whatever happens to be in the directory today.
        let sealed = try verifyGoldens(goldenDir, requireManifest: options.requireManifest)

        // Taken now and re-read at the very end. A `check` racing an `accept` in
        // another terminal otherwise reports a verdict about a directory that no
        // longer exists — and reports it as success about as often as not.
        let before = GoldenManifest.Snapshot.take(of: goldenDir)

        // Against the set itself, before anything is compared to a golden — this is
        // the one failure a per-file golden check is structurally blind to.
        let duplicates = try duplicates(
            in: candidateDir, tolerance: options.duplicateTolerance)

        let goldenNames = Set(goldens.map(\.lastPathComponent))

        // Sibling of the candidate dir, matching the original's default.
        let diffDir =
            options.diffDir
            ?? candidateDir.deletingLastPathComponent()
            .appending(path: "diff")
        var failures: [Failure] = []
        var matched: [String] = []
        // Built from the first pair actually compared, since it needs the canvas size.
        // Nil until then, and stays nil for a run where every capture matched by hash —
        // which is correct: nothing was ignored because nothing was compared.
        var mask: IgnoreMask?

        for candidate in candidates {
            let name = candidate.lastPathComponent
            let golden = goldenDir.appending(path: name)

            guard goldenNames.contains(name) else {
                failures.append(
                    Failure(
                        name: name,
                        kind: .newScreen,
                        reason: "new screen, no golden. Review it, then accept with `appshot accept`."
                    ))
                continue
            }

            // Identical bytes cannot be a visual difference, and a clean run is the
            // normal case. A gate that feels slow is one someone takes out of the
            // default target, and then it protects nothing.
            if try identicalBytes(candidate, golden) {
                matched.append(name)
                continue
            }

            let candImage = try Image.load(candidate)
            let goldImage = try Image.load(golden)

            guard
                candImage.width == goldImage.width,
                candImage.height == goldImage.height
            else {
                failures.append(
                    Failure(
                        name: name,
                        kind: .sizeChanged,
                        reason: "size changed \(goldImage.width)x\(goldImage.height) -> "
                            + "\(candImage.width)x\(candImage.height). "
                            + "The window is no longer pinned to a deterministic size."))
                continue
            }

            guard
                let cand = Image.pixels(candImage),
                let gold = Image.pixels(goldImage)
            else {
                throw AppShotError.imageDecodeFailed(candidate)
            }

            if let alpha = alphaRegression(cand, gold, tolerance: options.alphaTolerance) {
                failures.append(Failure(name: name, kind: alpha.kind, reason: alpha.reason))
                continue
            }

            let ignore =
                mask
                ?? IgnoreMask(
                    rects: options.ignore, width: cand.width, height: cand.height)
            mask = ignore

            let (fraction, diff) = changedFraction(cand, gold, ignore: ignore)
            if fraction > options.tolerance {
                var written: URL?
                if let image = diff {
                    let out = diffDir.appending(path: name)
                    try? Image.write(image, to: out)
                    written = out
                }
                failures.append(
                    Failure(
                        name: name,
                        kind: .pixelDrift,
                        reason: String(
                            format: "%.3f%% of pixels changed (tolerance %.3f%%)",
                            fraction * 100, options.tolerance * 100),
                        pixelDiffFraction: fraction,
                        diffPath: written))
                continue
            }

            matched.append(name)
        }

        // The dangerous direction: the capture stopped early and nobody noticed.
        for name in goldenNames.subtracting(candidates.map(\.lastPathComponent)).sorted() {
            failures.append(
                Failure(
                    name: name,
                    kind: .missingCapture,
                    reason: "golden exists but nothing was captured. Did the run stop early?"))
        }

        let drifted = before.drift(to: GoldenManifest.Snapshot.take(of: goldenDir))
        guard drifted.isEmpty else {
            throw AppShotError.goldenChangedMidRun(drifted, dir: goldenDir)
        }

        return Report(
            matchedNames: matched.sorted(),
            failures: failures,
            duplicates: duplicates,
            tolerance: options.tolerance,
            sealed: sealed,
            ignoredPixels: mask?.count ?? 0,
            ignoredFraction: mask?.fraction ?? 0)
    }

    /// Are the goldens what the last `accept` left behind?
    ///
    /// Returns whether they are sealed at all; throws when they are sealed and no
    /// longer match. See `GoldenManifest` for why this is detection rather than
    /// prevention, and for the cases it deliberately stays quiet about.
    @discardableResult
    public static func verifyGoldens(_ goldenDir: URL, requireManifest: Bool = false) throws -> Bool {
        switch try GoldenManifest.status(of: goldenDir) {
        case .unsealed:
            guard !requireManifest else { throw AppShotError.goldenUnsealed(goldenDir) }
            return false
        case .sealed(let manifest, let drift):
            guard drift.isEmpty else {
                throw AppShotError.goldenDrift(drift, manifest: manifest, dir: goldenDir)
            }
            return true
        }
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
        guard !candidates.isEmpty else { throw noCapturesReason(candidateDir) }

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

        // Copy everything into a staging directory *first*, and only then destroy the
        // old baseline. The copies are the part that can fail — a full disk, a
        // permission, a candidate that vanished — and the previous version deleted all
        // 18 goldens before writing the first byte of the new ones. In a project where
        // the goldens are not committed, one such failure left nothing to recover from.
        let fm = FileManager.default
        let staging = goldenDir.deletingLastPathComponent()
            .appending(path: ".appshot-accept-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for candidate in candidates {
            // Copy the bytes. Re-encoding would rewrite the file and drop the ICC
            // profile, so the goldens would stop being what was actually captured.
            try fm.copyItem(
                at: candidate, to: staging.appending(path: candidate.lastPathComponent))
        }

        for old in existing {
            try fm.removeItem(at: old)
        }
        // Renames within a volume are metadata operations: they cannot half-succeed,
        // and they cannot run out of disk.
        for file in try pngs(in: staging) {
            try fm.moveItem(at: file, to: goldenDir.appending(path: file.lastPathComponent))
        }

        // Last, so a manifest never describes a set that was not fully installed.
        try GoldenManifest.seal(goldenDir: goldenDir)
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

        return
            groups
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
    ) -> (kind: Failure.Kind, reason: String)? {
        let g = nonOpaqueCount(gold)
        guard g > 0 else { return nil }
        let c = nonOpaqueCount(cand)
        if c == 0 {
            return (
                .alphaLost,
                "lost all transparency (golden has \(g) non-opaque px, candidate has 0) — "
                    + "the capture almost certainly fell back to an opaque-corner screenshot"
            )
        }
        let drift = abs(Double(c - g)) / Double(g)
        if drift > tolerance {
            return (
                .alphaDrift,
                String(
                    format: "transparent-pixel count %d vs golden %d (%.0f%% drift)",
                    c, g, drift * 100)
            )
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
    ///
    /// Ignored regions are excluded from **both** the numerator and the denominator: a
    /// fraction measured over pixels that were never examined would shrink as the ignore
    /// list grew, quietly making every remaining screen look more similar than it is.
    static func changedFraction(
        _ cand: Image.Pixels,
        _ gold: Image.Pixels,
        ignore: IgnoreMask = IgnoreMask(rects: [], width: 0, height: 0)
    ) -> (fraction: Double, diff: CGImage?) {
        let count = cand.count
        var changed = 0
        var compared = 0
        var amplified = [UInt8](repeating: 255, count: count * 4)

        for i in 0..<count {
            let j = i * 4
            if ignore.ignores(i) {
                // Marked in the diff so a reviewer sees what was excluded rather than
                // reading black as "identical here". Blue is not a value `amp` can
                // produce from a real difference, which is what makes it legible.
                amplified[j] = 0
                amplified[j + 1] = 0
                amplified[j + 2] = 90
                continue
            }
            compared += 1

            let c = cand[i]
            let g = gold[i]
            let dr = c.r > g.r ? c.r - g.r : g.r - c.r
            let dg = c.g > g.g ? c.g - g.g : g.g - c.g
            let db = c.b > g.b ? c.b - g.b : g.b - c.b
            if max(dr, max(dg, db)) > channelNoiseFloor { changed += 1 }

            // x12, clamped — an unamplified diff of a few units is invisible.
            amplified[j] = amp(dr)
            amplified[j + 1] = amp(dg)
            amplified[j + 2] = amp(db)
        }

        let fraction = compared > 0 ? Double(changed) / Double(compared) : 0
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

    /// "No PNGs here" — but say so more precisely when the PNGs are one level down.
    ///
    /// An iOS run writes into `source/<device>/`, so a command pointed at `source` with
    /// no `--config` finds nothing and would otherwise ask "did capture run?" about a
    /// capture that ran perfectly well. The directory listing already knows the answer.
    static func noCapturesReason(_ dir: URL) -> AppShotError {
        let subdirectories =
            ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && !(((try? pngs(in: $0)) ?? []).isEmpty)
            }
            .map(\.lastPathComponent)
            .sorted()

        guard !subdirectories.isEmpty else { return .noCaptures(dir) }
        return .capturesAreInDeviceDirectories(subdirectories, dir: dir)
    }

    static func pngs(in dir: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return
            items
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
