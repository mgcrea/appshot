import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit
@testable import appshot

/// `--json` is a contract with something that cannot read prose. These pin the shape,
/// because the alternative — the state this replaced — is an agent grepping for `✗`
/// and a percentage out of human-formatted output and hoping neither ever changes.
struct CheckReportTests {
    static func dirs() throws -> (root: URL, cand: URL, gold: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-json-\(UUID().uuidString)")
        let cand = root.appending(path: "source")
        let gold = root.appending(path: "golden")
        try FileManager.default.createDirectory(at: cand, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gold, withIntermediateDirectories: true)
        return (root, cand, gold)
    }

    static func write(_ name: String, in dir: URL, shade: UInt8) throws {
        let ctx = Image.context(width: 20, height: 20)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.clear(CGRect(x: 0, y: 0, width: 3, height: 3))
        try Image.write(ctx.makeImage()!, to: dir.appending(path: name))
    }

    static func paths(_ dirs: (root: URL, cand: URL, gold: URL)) -> Pipeline.PathValues {
        Pipeline.PathValues(source: dirs.cand.path, golden: dirs.gold.path, diff: nil)
    }

    /// Round-trips through JSON rather than inspecting the struct: the encoded
    /// document is what a caller actually reads, and a key that fails to encode would
    /// be invisible to a test that only looks at properties.
    static func encode(_ report: CheckReport) throws -> [String: Any] {
        let data = try JSONEncoder().encode(report)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a clean run reports every screen as a match")
    func cleanRun() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        for (name, shade) in [("a~dark.png", UInt8(90)), ("b~dark.png", UInt8(200))] {
            try Self.write(name, in: dirs.gold, shade: shade)
            try Self.write(name, in: dirs.cand, shade: shade)
        }
        try GoldenManifest.seal(goldenDir: dirs.gold)

        let report = try Gate.compare(candidateDir: dirs.cand, goldenDir: dirs.gold)
        let json = try Self.encode(CheckReport(report: report, paths: Self.paths(dirs)))

        #expect(json["passed"] as? Bool == true)
        #expect(json["matched"] as? Int == 2)
        #expect(json["sealed"] as? Bool == true)
        // Present and null, never absent: "no error" and "malformed document" must
        // not look the same to a caller reading this key.
        #expect(json["error"] is NSNull)

        let screens = try #require(json["screens"] as? [String: Any])
        let a = try #require(screens["a~dark.png"] as? [String: Any])
        #expect(a["status"] as? String == "match")
    }

    /// The number an agent actually wants: a percentage it can compare, not a
    /// substring it has to parse out of a sentence.
    @Test("a drifted screen reports its kind and its percentage")
    func driftedScreen() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold, shade: 90)
        try Self.write("a~dark.png", in: dirs.cand, shade: 220)

        let report = try Gate.compare(
            candidateDir: dirs.cand, goldenDir: dirs.gold,
            options: Gate.Options(diffDir: dirs.root.appending(path: "diff")))
        let json = try Self.encode(CheckReport(report: report, paths: Self.paths(dirs)))

        #expect(json["passed"] as? Bool == false)
        // Unsealed goldens are reported, not fatal — the flag is how a caller decides.
        #expect(json["sealed"] as? Bool == false)

        let screens = try #require(json["screens"] as? [String: Any])
        let a = try #require(screens["a~dark.png"] as? [String: Any])
        #expect(a["status"] as? String == "pixel_drift")
        #expect(try #require(a["pixelDiffPercent"] as? Double) > 0)
        #expect(a["diffPath"] as? String != nil)
    }

    @Test("duplicate captures survive into the document")
    func duplicates() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold, shade: 90)
        try Self.write("b~dark.png", in: dirs.gold, shade: 200)
        // The staging failure: one screen photographed twice under two names.
        try Self.write("a~dark.png", in: dirs.cand, shade: 90)
        try Self.write("b~dark.png", in: dirs.cand, shade: 90)

        let report = try Gate.compare(candidateDir: dirs.cand, goldenDir: dirs.gold)
        let json = try Self.encode(CheckReport(report: report, paths: Self.paths(dirs)))

        #expect(json["passed"] as? Bool == false)
        let duplicates = try #require(json["duplicates"] as? [[String: Any]])
        #expect(duplicates.count == 1)
        #expect(duplicates[0]["names"] as? [String] == ["a~dark.png", "b~dark.png"])
    }

    /// The rule that makes this usable from a script: one document, always. A failure
    /// before the comparison must not escape as prose on stderr and leave the caller
    /// with nothing to parse.
    @Test("a failure before the comparison is still a document")
    func preComparisonFailure() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        let error = AppShotError.missingCaptures(["home~dark.png"], dir: dirs.cand)
        let json = try Self.encode(
            CheckReport(error: error, paths: Self.paths(dirs), tolerance: Defaults.tolerance))

        #expect(json["passed"] as? Bool == false)
        #expect(json["matched"] as? Int == 0)
        #expect((json["screens"] as? [String: Any])?.isEmpty == true)

        let failure = try #require(json["error"] as? [String: Any])
        #expect(failure["kind"] as? String == "missing_captures")
        #expect(try #require(failure["message"] as? String).contains("home~dark.png"))
    }

    /// Slugs are what a caller branches on, so they are spelled out case by case in
    /// `AppShotError.slug` rather than derived from Swift case names — renaming a case
    /// must not silently change the wire format.
    @Test("the errors a check can hit all have stable slugs")
    func errorSlugs() {
        let dir = URL(fileURLWithPath: "/tmp/golden")
        #expect(AppShotError.noCaptures(dir).slug == "no_captures")
        #expect(AppShotError.noGoldens(dir).slug == "no_goldens")
        #expect(AppShotError.gitLFSPointer(dir).slug == "git_lfs_pointer")
        #expect(AppShotError.goldenUnsealed(dir).slug == "golden_unsealed")
        #expect(AppShotError.goldenChangedMidRun(["a.png"], dir: dir).slug == "golden_changed_mid_run")
    }
}
