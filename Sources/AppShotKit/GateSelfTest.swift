import CoreGraphics
import Foundation

/// The gate for the gate.
///
/// `accept` only ever copies files — it never decodes one — so a gate whose
/// comparison path is broken will still install a baseline, bless it, and print
/// success. You then get months of green from a check that has never once
/// compared two images. That is not hypothetical: the Python gate this replaces
/// reported "14 screenshots match" on a total alpha wipe.
///
/// So synthesize mutants from real goldens and assert the gate reaches the right
/// verdict *for the right reason*. The negative control — sub-threshold noise must
/// PASS — matters as much as the failures: it proves the gate isn't simply failing
/// on everything.
public enum GateSelfTest {
    public struct Case: Sendable {
        public let name: String
        public let expectPass: Bool
        /// Substring the failure reason must contain, so a case can't pass for the
        /// wrong reason.
        public let expectReason: String?
    }

    public struct Result: Sendable {
        /// Three outcomes, not two.
        ///
        /// A case that could not be *posed* is not a case that passed. The alpha mutant
        /// on an all-opaque golden set is the live example: setting alpha to 255 on an
        /// image that has none is a no-op, so the gate correctly reports no difference —
        /// and a two-state self-test would call that "expected FAIL, got PASS" and
        /// declare the gate untrustworthy. Reporting it as skipped, with the reason, is
        /// the only honest answer; folding it into `ok` would claim a proof nobody made.
        public enum Verdict: Sendable, Equatable {
            case ok
            case failed
            case skipped
        }

        public let name: String
        public let verdict: Verdict
        public let detail: String

        /// Not a failure — which is what decides the exit code. Skipped cases are
        /// reported distinctly by the CLI rather than counted as proofs.
        public var ok: Bool { verdict != .failed }

        init(name: String, verdict: Verdict, detail: String) {
            self.name = name
            self.verdict = verdict
            self.detail = detail
        }
    }

    public enum Mutation: Sendable, CaseIterable {
        case identity
        case alphaWipe
        case subThresholdNoise
        case visibleRect
        case sizeDrift
        case deleteCandidate
        case duplicateCapture
        case duplicateCaptureWithDrift
        case changeInsideIgnoredRegion
        case changeOutsideIgnoredRegion

        var spec: Case {
            switch self {
            case .identity:
                return Case(name: "identity copy", expectPass: true, expectReason: nil)

            case .duplicateCapture:
                return Case(
                    name: "one screen captured twice",
                    expectPass: false,
                    expectReason: "identical")

            case .duplicateCaptureWithDrift:
                return Case(
                    name: "captured twice, one pixel apart",
                    expectPass: false,
                    expectReason: "identical")
            case .alphaWipe:
                return Case(
                    name: "alpha wipe (opaque corners)",
                    expectPass: false,
                    expectReason: "transparen")
            case .subThresholdNoise:
                return Case(
                    name: "sub-threshold noise (negative control)",
                    expectPass: true,
                    expectReason: nil)
            case .visibleRect:
                return Case(
                    name: "visible rect over ~0.5% of pixels",
                    expectPass: false,
                    expectReason: "changed")
            case .sizeDrift:
                return Case(name: "size drift (+1px wide)", expectPass: false, expectReason: "size")
            case .deleteCandidate:
                return Case(
                    name: "candidate missing",
                    expectPass: false,
                    expectReason: "nothing was captured")

            // The two halves of the ignore-rect feature. Only asserting the first would
            // prove the gate can be blinded, not that it still sees — and a rect that
            // silently swallowed the whole canvas would pass that half happily.
            case .changeInsideIgnoredRegion:
                return Case(
                    name: "change inside an ignored region",
                    expectPass: true,
                    expectReason: nil)
            case .changeOutsideIgnoredRegion:
                return Case(
                    name: "change outside an ignored region",
                    expectPass: false,
                    expectReason: "changed")
            }
        }
    }

    /// Run every mutant against `goldenDir`, in a scratch directory that is cleaned
    /// up afterwards. Returns one result per case.
    public static func run(goldenDir: URL) throws -> [Result] {
        let goldens = try Gate.pngs(in: goldenDir)
        guard goldens.count >= 2 else { throw AppShotError.noGoldens(goldenDir) }
        // A representative sample: enough to exercise every path without decoding
        // the whole set on every self-test.
        let sample = Array(goldens.prefix(3))

        // Whether these goldens have any transparency to lose. An iOS set captured
        // without `--mask=alpha`, or one extracted from an XCUITest, has none — and the
        // alpha mutant is then unposeable rather than failing. Asked once, from the
        // image the mutant would actually modify.
        let transparent = (try? Image.load(sample[0])).map { !Image.isOpaque($0) } ?? true

        return try Mutation.allCases.map {
            try runCase($0, sample: sample, transparent: transparent)
        }
    }

    private static func runCase(
        _ mutation: Mutation, sample: [URL], transparent: Bool
    ) throws -> Result {
        let spec = mutation.spec

        if mutation == .alphaWipe, !transparent {
            return Result(
                name: spec.name,
                verdict: .skipped,
                detail: "these goldens are fully opaque — no transparency to lose. "
                    + "The categorical alpha check cannot be posed here, so it is not "
                    + "proven by this run.")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-selftest-\(UUID().uuidString)")
        let gold = tmp.appending(path: "golden")
        let cand = tmp.appending(path: "source")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: gold, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cand, withIntermediateDirectories: true)
        for file in sample {
            let name = file.lastPathComponent
            try FileManager.default.copyItem(at: file, to: gold.appending(path: name))
            try FileManager.default.copyItem(at: file, to: cand.appending(path: name))
        }

        try mutate(mutation, cand: cand, gold: gold, sample: sample)

        let report: Gate.Report
        do {
            report = try Gate.compare(
                candidateDir: cand,
                goldenDir: gold,
                options: Gate.Options(
                    diffDir: tmp.appending(path: "diff"),
                    ignore: try ignoreRects(for: mutation, sample: sample)))
        } catch {
            return Result(
                name: spec.name, verdict: .failed, detail: "gate threw: \(error)")
        }

        if report.passed != spec.expectPass {
            let got = report.passed ? "PASS" : "FAIL"
            let want = spec.expectPass ? "PASS" : "FAIL"
            let why = report.failures.map(\.reason).joined(separator: "; ")
            return Result(
                name: spec.name,
                verdict: .failed,
                detail: "expected \(want), got \(got)" + (why.isEmpty ? "" : " (\(why))"))
        }

        if let needle = spec.expectReason {
            let reasons = (report.failures.map(\.reason) + report.duplicates.map(\.reason))
                .joined(separator: " ").lowercased()
            guard reasons.contains(needle.lowercased()) else {
                return Result(
                    name: spec.name,
                    verdict: .failed,
                    detail: "failed for the wrong reason (no \"\(needle)\" in: \(reasons))")
            }
        }

        return Result(name: spec.name, verdict: .ok, detail: "")
    }

    /// The ignored band for the two ignore-rect mutations, sized from the real golden.
    ///
    /// Modelled on the case that motivated the feature: a status-bar strip across the
    /// top. Every other mutation gets no rects, so none of them can pass by accident
    /// because something was quietly excluded.
    static func ignoreRects(for mutation: Mutation, sample: [URL]) throws -> [Config.Rect] {
        switch mutation {
        case .changeInsideIgnoredRegion, .changeOutsideIgnoredRegion:
            guard let size = Image.size(sample[0]) else { return [] }
            return [
                Config.Rect(
                    x: 0, y: 0, width: size.width, height: max(1, size.height / 8))
            ]
        default:
            return []
        }
    }

    /// A rect covering ~0.5% of the image — the same budget `visibleRect` uses, so it is
    /// comfortably over the 0.1% tolerance and the verdict turns on *where* it lands,
    /// not on how big it is.
    private static func paintedSide(_ image: CGImage) -> Int {
        Int((Double(image.width * image.height) * 0.005).squareRoot())
    }

    private static func mutate(
        _ mutation: Mutation,
        cand: URL,
        gold: URL,
        sample: [URL]
    ) throws {
        let url = cand.appending(path: sample[0].lastPathComponent)

        switch mutation {
        case .identity:
            return

        case .deleteCandidate:
            try FileManager.default.removeItem(at: url)
            return

        case .duplicateCapture, .duplicateCaptureWithDrift:
            // Overwrite one capture with another's bytes — in *both* dirs, so every
            // candidate still matches its golden exactly. The golden axis stays clean
            // and the duplicate is the only fault, which is the whole point: this is
            // the failure a per-file golden check is structurally unable to see.
            for dir in [cand, gold] {
                let target = dir.appending(path: sample[0].lastPathComponent)
                try FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: sample[1], to: target)
            }
            guard mutation == .duplicateCaptureWithDrift else { return }

            // Now nudge the candidate off byte-identity, the way a blinking caret or a
            // late-loading thumbnail would. Under the duplicate budget (so it is still
            // the same screen) and under the golden tolerance (so nothing else fires),
            // which means only the pixel tier can catch it — the hash cannot.
            let px = try Image.load(url)
            let budget = Int(Double(px.width * px.height) * Gate.defaultDuplicateTolerance)
            let drift = budget / 4
            // Mid-image, where the pixels are opaque. The buffer is premultiplied, so
            // brightening a transparent corner would be clamped straight back to zero
            // on write and this mutant would quietly decay into the exact-bytes case.
            let row = px.height / 2
            let start = px.width / 4
            try transform(url) { p, i, x, y in
                if y == row && x >= start && x < start + drift {
                    p[i] = UInt8(min(255, Int(p[i]) + 64))
                }
            }
            return

        case .alphaWipe:
            // Exactly the regression the gate exists to catch: the capture fell back
            // to an opaque-corner screenshot. Only ~0.056% of pixels, which is why
            // it can never trip the fractional tolerance.
            try transform(url) { p, i, _, _ in
                p[i + 3] = 255
            }

        case .subThresholdNoise:
            // Anti-aliasing-scale jitter. Must NOT trip the gate.
            try transform(url) { p, i, _, _ in
                p[i] = UInt8(min(255, Int(p[i]) + 5))
            }

        case .visibleRect:
            let image = try Image.load(url)
            let side = Int((Double(image.width * image.height) * 0.005).squareRoot())
            try transform(url) { p, i, x, y in
                if x > 10 && x < 10 + side && y > 10 && y < 10 + side {
                    p[i] = 255
                    p[i + 1] = 0
                    p[i + 2] = 255
                    p[i + 3] = 255
                }
            }

        case .changeInsideIgnoredRegion, .changeOutsideIgnoredRegion:
            let image = try Image.load(url)
            let side = paintedSide(image)
            let band = max(1, image.height / 8)
            // Inside: wholly within the ignored band. Outside: starts one row below it,
            // so the two differ *only* in position — which is exactly the property
            // under test.
            let top =
                mutation == .changeInsideIgnoredRegion
                ? 0
                : band + 1
            // A band of height/8 must actually contain the painted rect, or "inside"
            // would silently be "partly outside" and the case would prove nothing.
            let height = mutation == .changeInsideIgnoredRegion ? min(side, band) : side
            try transform(url) { p, i, x, y in
                if x < side && y >= top && y < top + height {
                    p[i] = 255
                    p[i + 1] = 0
                    p[i + 2] = 255
                    p[i + 3] = 255
                }
            }

        case .sizeDrift:
            let image = try Image.load(url)
            guard let ctx = Image.context(width: image.width + 1, height: image.height) else {
                throw AppShotError.imageDecodeFailed(url)
            }
            ctx.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width + 1, height: image.height))
            guard let out = ctx.makeImage() else { throw AppShotError.imageDecodeFailed(url) }
            try Image.write(out, to: url)
        }
    }

    /// Rewrite a PNG's pixels in place. The closure receives the premultiplied RGBA
    /// buffer, the byte index of the pixel, and its (x, y). Both `Image.pixels` and
    /// `Image.context` are premultiplied, so the buffer round-trips as-is.
    private static func transform(
        _ url: URL,
        _ body: (inout [UInt8], Int, Int, Int) -> Void
    ) throws {
        let image = try Image.load(url)
        guard let px = Image.pixels(image) else { throw AppShotError.imageDecodeFailed(url) }
        var bytes = px.bytes
        for y in 0..<px.height {
            for x in 0..<px.width {
                body(&bytes, (y * px.width + x) * 4, x, y)
            }
        }

        guard let ctx = Image.context(width: px.width, height: px.height),
            let data = ctx.data
        else { throw AppShotError.imageDecodeFailed(url) }
        data.copyMemory(from: bytes, byteCount: bytes.count)
        guard let out = ctx.makeImage() else { throw AppShotError.imageDecodeFailed(url) }
        try Image.write(out, to: url)
    }
}
