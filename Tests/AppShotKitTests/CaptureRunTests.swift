import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// These pin the false green.
///
/// A project's build broke, `appshot capture` never ran, and `check` compared twenty
/// PNGs left over from fifteen days earlier — reporting a clean match, exit 0. Nothing
/// it printed was untrue; it had simply never been given a way to know its inputs were
/// stale. What follows is that case, and the boundaries of what the fix can honestly
/// claim.
struct CaptureRunTests {
    static func dirs() throws -> (cand: URL, gold: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-run-\(UUID().uuidString)")
        let cand = root.appending(path: "source")
        let gold = root.appending(path: "golden")
        try FileManager.default.createDirectory(at: cand, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gold, withIntermediateDirectories: true)
        return (cand, gold)
    }

    static func write(_ name: String, in dir: URL, shade: UInt8 = 120) throws {
        let ctx = Image.context(width: 20, height: 20)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.clear(CGRect(x: 0, y: 0, width: 3, height: 3))
        try Image.write(ctx.makeImage()!, to: dir.appending(path: name))
    }

    /// Backdate a run record, which is the only way to test staleness without waiting.
    static func plant(age: TimeInterval, in dir: URL, names: [String]) throws {
        let run = CaptureRun(appPath: nil, names: names)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object =
            try JSONSerialization.jsonObject(with: encoder.encode(run))
            as! [String: Any]
        let stamp = ISO8601DateFormatter()
        object["at"] = stamp.string(from: Date().addingTimeInterval(-age))
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: CaptureRun.url(in: dir))
    }

    // MARK: - The record itself

    @Test func roundTripsThroughDisk() throws {
        let (cand, _) = try Self.dirs()
        try CaptureRun.write(CaptureRun(appPath: nil, names: ["b.png", "a.png"]), to: cand)

        let read = try #require(CaptureRun.read(from: cand))
        // Sorted on the way in, so a set written in whatever order the driver finished
        // in still diffs cleanly against the next run's.
        #expect(read.names == ["a.png", "b.png"])
        #expect(read.appshotVersion == AppShotVersion.current)
        #expect(read.age < 5)
    }

    /// Absent is not an error. A directory captured before this existed, or filled by
    /// `extract` from an xcresult, simply has nothing to say — and must still gate.
    @Test func absentRecordIsNotAnError() throws {
        let (cand, gold) = try Self.dirs()
        try Self.write("main~light.png", in: cand)
        try Self.write("main~light.png", in: gold)

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(report.passed)
        #expect(report.capturedBy == nil)
    }

    @Test func ageReadsInTheCoarsestHonestUnit() throws {
        let (cand, _) = try Self.dirs()
        try Self.plant(age: 15 * 86400, in: cand, names: [])
        let read = try #require(CaptureRun.read(from: cand))
        #expect(read.ageDescription == "15 days")
        #expect(read.summary.contains("15 days"))
    }

    // MARK: - The silhouette case

    /// The whole point: a *passing* gate against captures nobody just took still
    /// surfaces how old they are.
    @Test func staleCapturesAreVisibleEvenWhenEverythingMatches() throws {
        let (cand, gold) = try Self.dirs()
        try Self.write("main~light.png", in: cand)
        try Self.write("main~light.png", in: gold)
        try Self.plant(age: 15 * 86400, in: cand, names: ["main~light.png"])

        let report = try Gate.compare(candidateDir: cand, goldenDir: gold)
        #expect(report.passed)
        let run = try #require(report.capturedBy)
        #expect(run.ageDescription == "15 days")
    }

    @Test func maxSourceAgeFailsStaleCaptures() throws {
        let (cand, gold) = try Self.dirs()
        try Self.write("main~light.png", in: cand)
        try Self.write("main~light.png", in: gold)
        try Self.plant(age: 15 * 86400, in: cand, names: ["main~light.png"])

        #expect(throws: AppShotError.self) {
            try Gate.compare(
                candidateDir: cand, goldenDir: gold,
                options: Gate.Options(maxSourceAge: 3600))
        }
    }

    /// A fresh capture must pass the same bound, or the flag is unusable in the one
    /// place it is meant for.
    @Test func maxSourceAgeAcceptsAFreshRun() throws {
        let (cand, gold) = try Self.dirs()
        try Self.write("main~light.png", in: cand)
        try Self.write("main~light.png", in: gold)
        try CaptureRun.write(
            CaptureRun(appPath: nil, names: ["main~light.png"]), to: cand)

        let report = try Gate.compare(
            candidateDir: cand, goldenDir: gold,
            options: Gate.Options(maxSourceAge: 3600))
        #expect(report.passed)
    }

    /// Asking for an age bound against captures that cannot be aged has to fail rather
    /// than pass silently — "unknown" is the exact case the flag was set to catch.
    @Test func maxSourceAgeRefusesAnUnageableDirectory() throws {
        let (cand, gold) = try Self.dirs()
        try Self.write("main~light.png", in: cand)
        try Self.write("main~light.png", in: gold)

        #expect(throws: AppShotError.self) {
            try Gate.compare(
                candidateDir: cand, goldenDir: gold,
                options: Gate.Options(maxSourceAge: 3600))
        }
    }
}
