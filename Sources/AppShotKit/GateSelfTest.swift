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
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    public enum Mutation: Sendable, CaseIterable {
        case identity
        case alphaWipe
        case subThresholdNoise
        case visibleRect
        case sizeDrift
        case deleteCandidate

        var spec: Case {
            switch self {
            case .identity:
                return Case(name: "identity copy", expectPass: true, expectReason: nil)
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

        return try Mutation.allCases.map { try runCase($0, sample: sample) }
    }

    private static func runCase(_ mutation: Mutation, sample: [URL]) throws -> Result {
        let spec = mutation.spec
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

        let victim = cand.appending(path: sample[0].lastPathComponent)
        try mutate(mutation, at: victim)

        let report: Gate.Report
        do {
            report = try Gate.compare(
                candidateDir: cand,
                goldenDir: gold,
                options: Gate.Options(diffDir: tmp.appending(path: "diff")))
        } catch {
            return Result(
                name: spec.name, ok: false, detail: "gate threw: \(error)")
        }

        if report.passed != spec.expectPass {
            let got = report.passed ? "PASS" : "FAIL"
            let want = spec.expectPass ? "PASS" : "FAIL"
            let why = report.failures.map(\.reason).joined(separator: "; ")
            return Result(
                name: spec.name,
                ok: false,
                detail: "expected \(want), got \(got)" + (why.isEmpty ? "" : " (\(why))"))
        }

        if let needle = spec.expectReason {
            let reasons = report.failures.map(\.reason).joined(separator: " ").lowercased()
            guard reasons.contains(needle.lowercased()) else {
                return Result(
                    name: spec.name,
                    ok: false,
                    detail: "failed for the wrong reason (no \"\(needle)\" in: \(reasons))")
            }
        }

        return Result(name: spec.name, ok: true, detail: "")
    }

    private static func mutate(_ mutation: Mutation, at url: URL) throws {
        switch mutation {
        case .identity:
            return

        case .deleteCandidate:
            try FileManager.default.removeItem(at: url)
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
