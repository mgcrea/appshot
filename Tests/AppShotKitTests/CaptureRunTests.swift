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

    // MARK: - Which build

    /// A bundle with an executable, a Debug-style code dylib and an Info.plist, the
    /// bundle directory itself backdated as Xcode's incremental build leaves it.
    static func bundle(ios: Bool) throws -> (app: URL, code: URL) {
        let fm = FileManager.default
        let app = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-bundle-\(UUID().uuidString)/Fixture.app")
        let exeDir = ios ? app : app.appending(path: "Contents/MacOS")
        let plistDir = ios ? app : app.appending(path: "Contents")
        try fm.createDirectory(at: exeDir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "io.example.fixture",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: plistDir.appending(path: "Info.plist"))
        try Data("stub".utf8).write(to: exeDir.appending(path: "Fixture"))
        let code = exeDir.appending(path: "Fixture.debug.dylib")
        try Data("code".utf8).write(to: code)
        if ios {
            try fm.createDirectory(at: app.appending(path: "Base.lproj"), withIntermediateDirectories: true)
        }

        let old = Date().addingTimeInterval(-8 * 86_400)
        for url in [
            app, plistDir, exeDir, exeDir.appending(path: "Fixture"),
            plistDir.appending(path: "Info.plist"),
        ] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        return (app, code)
    }

    /// The case that was wrong: the code was rebuilt a minute ago, the bundle directory
    /// says eight days, and the record used to report the eight days.
    @Test(arguments: [false, true])
    func appModifiedAtIsTheNewestBuiltFileNotTheBundleDirectory(ios: Bool) throws {
        let (app, code) = try Self.bundle(ios: ios)
        let fresh = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: fresh], ofItemAtPath: code.path)

        let built = try #require(CaptureRun.builtAt(app))
        #expect(abs(built.timeIntervalSince(fresh)) < 1)
        #expect(CaptureRun(appPath: app, names: []).appModifiedAt == built)
    }

    @Test func aPathThatIsNotABundleFallsBackToItsOwnDate() throws {
        let (cand, _) = try Self.dirs()
        #expect(CaptureRun.builtAt(cand) != nil)
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
