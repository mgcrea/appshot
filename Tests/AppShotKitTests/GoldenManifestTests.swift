import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The manifest exists because a golden set changed underneath a session and nobody
/// could say what did it — 18 files modified, two new ones, and no `accept` in the
/// shell history. These pin the discrimination that makes that answerable: which
/// changes fire, and — just as important — which ones deliberately do not.
struct GoldenManifestTests {
    static func dirs() throws -> (root: URL, cand: URL, gold: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-manifest-\(UUID().uuidString)")
        let cand = root.appending(path: "source")
        let gold = root.appending(path: "golden")
        try FileManager.default.createDirectory(at: cand, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gold, withIntermediateDirectories: true)
        return (root, cand, gold)
    }

    static func write(_ name: String, in dir: URL, shade: UInt8 = 120) throws {
        let ctx = Image.context(width: 20, height: 20)!
        let v = Double(shade) / 255
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.clear(CGRect(x: 0, y: 0, width: 3, height: 3))
        try Image.write(ctx.makeImage()!, to: dir.appending(path: name))
    }

    static func drift(_ dirs: (root: URL, cand: URL, gold: URL)) throws -> GoldenManifest.Drift {
        guard case .sealed(_, let drift) = try GoldenManifest.status(of: dirs.gold) else {
            Issue.record("expected a sealed golden directory")
            return GoldenManifest.Drift(changed: [], unknown: [], vanished: [])
        }
        return drift
    }

    // MARK: - Seal and verify

    @Test("sealed goldens verify against themselves")
    func sealedGoldensVerify() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        try Self.write("b~dark.png", in: dirs.gold)
        let manifest = try GoldenManifest.seal(goldenDir: dirs.gold)

        #expect(manifest.entries.count == 2)
        #expect(manifest.accepted?.count == 2)
        #expect(try Self.drift(dirs).isEmpty)
        #expect(try Gate.verifyGoldens(dirs.gold))
    }

    /// The case that started this. A golden rewritten by anything other than `accept`
    /// has to be named, not merely counted.
    @Test("an edited golden is named")
    func editedGoldenIsNamed() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        try Self.write("b~dark.png", in: dirs.gold)
        try GoldenManifest.seal(goldenDir: dirs.gold)

        try Self.write("a~dark.png", in: dirs.gold, shade: 200)

        let drift = try Self.drift(dirs)
        #expect(drift.changed.map(\.name) == ["a~dark.png"])
        #expect(drift.unknown.isEmpty)
        #expect(drift.vanished.isEmpty)

        #expect(throws: AppShotError.self) { try Gate.verifyGoldens(dirs.gold) }
    }

    /// "Two new ones materialized directly in golden/" — a golden nobody accepted is
    /// exactly as suspicious as one that was edited, and the old gate would have
    /// happily compared against it.
    @Test("a golden nobody accepted is flagged")
    func unknownGoldenIsFlagged() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        try GoldenManifest.seal(goldenDir: dirs.gold)
        try Self.write("smuggled~dark.png", in: dirs.gold)

        #expect(try Self.drift(dirs).unknown.map(\.name) == ["smuggled~dark.png"])
    }

    @Test("a golden deleted behind the manifest's back is flagged")
    func vanishedGoldenIsFlagged() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        try Self.write("b~dark.png", in: dirs.gold)
        try GoldenManifest.seal(goldenDir: dirs.gold)
        try FileManager.default.removeItem(at: dirs.gold.appending(path: "b~dark.png"))

        #expect(try Self.drift(dirs).vanished == ["b~dark.png"])
    }

    /// The false positive worth designing against: `git lfs pull`, a branch switch and
    /// a fresh clone all rewrite every golden's mtime, and none of them is a problem.
    /// The manifest is committed with the goldens, so it describes whatever tree you
    /// are on, and only the *contents* are consulted.
    @Test("touching a golden without changing its bytes is not drift")
    func mtimeAloneIsNotDrift() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        try GoldenManifest.seal(goldenDir: dirs.gold)

        let file = dirs.gold.appending(path: "a~dark.png")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: file.path)

        #expect(try Self.drift(dirs).isEmpty)
    }

    @Test("unsealed goldens are not a failure, unless asked for")
    func unsealedIsOptional() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)

        #expect(try Gate.verifyGoldens(dirs.gold) == false)
        #expect(throws: AppShotError.self) {
            try Gate.verifyGoldens(dirs.gold, requireManifest: true)
        }
    }

    /// The audit trail. One accept must not erase what the previous one recorded —
    /// that history is the only account of who has been writing here.
    @Test("accepts accumulate, newest first, capped")
    func historyAccumulates() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        for index in 0..<(GoldenManifest.historyLimit + 3) {
            try GoldenManifest.seal(
                goldenDir: dirs.gold,
                accept: GoldenManifest.Accept(
                    at: Date().addingTimeInterval(Double(index)),
                    user: "u", host: "h", cwd: "/tmp", argv: ["appshot", "accept", "\(index)"],
                    pid: 1, appshotVersion: AppShotVersion.current, count: 1))
        }

        let manifest = try #require(try GoldenManifest.load(in: dirs.gold))
        #expect(manifest.accepts.count == GoldenManifest.historyLimit)
        #expect(manifest.accepts.first?.argv.last == "\(GoldenManifest.historyLimit + 2)")
    }

    // MARK: - Accept

    @Test("accept seals what it installed")
    func acceptSeals() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        // Two *different* screens: identical captures are a staging failure, and
        // `accept` refuses them — see `Gate.duplicates`.
        try Self.write("a~dark.png", in: dirs.cand, shade: 90)
        try Self.write("b~dark.png", in: dirs.cand, shade: 200)
        let (accepted, orphans) = try Gate.accept(candidateDir: dirs.cand, goldenDir: dirs.gold)

        #expect(accepted == 2)
        #expect(orphans.isEmpty)
        #expect(try Gate.verifyGoldens(dirs.gold))
        let manifest = try #require(try GoldenManifest.load(in: dirs.gold))
        #expect(manifest.accepts.count == 1)
    }

    /// `accept` used to delete every golden before writing the first byte of the new
    /// ones. In a project whose goldens are not committed, one failed copy left
    /// nothing to recover from — so the copies now all happen in staging first.
    @Test("a failed accept leaves the previous baseline intact")
    func failedAcceptKeepsTheBaseline() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold, shade: 90)
        try GoldenManifest.seal(goldenDir: dirs.gold)
        let sealed = try GoldenManifest.hex(of: dirs.gold.appending(path: "a~dark.png"))

        // A candidate that is a directory, not a file: `copyItem` fails on it partway
        // through the set, which is the shape of a real mid-accept failure.
        try Self.write("a~dark.png", in: dirs.cand, shade: 200)
        try FileManager.default.createDirectory(
            at: dirs.cand.appending(path: "b~dark.png/inner"), withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try Gate.accept(candidateDir: dirs.cand, goldenDir: dirs.gold, prune: true)
        }

        // The old baseline is still there, byte for byte, and still verifies.
        #expect(try GoldenManifest.hex(of: dirs.gold.appending(path: "a~dark.png")) == sealed)
        #expect(try Gate.verifyGoldens(dirs.gold))
    }

    // MARK: - Mid-run guard

    /// A `check` racing an `accept` in another terminal reports a verdict about a
    /// directory that no longer exists — and reports it as success about as often as
    /// not. The snapshot is what refuses to answer instead of guessing.
    @Test("a golden directory that changes mid-comparison is caught")
    func midRunChangeIsCaught() throws {
        let dirs = try Self.dirs()
        defer { try? FileManager.default.removeItem(at: dirs.root) }

        try Self.write("a~dark.png", in: dirs.gold)
        let before = GoldenManifest.Snapshot.take(of: dirs.gold)

        try Self.write("b~dark.png", in: dirs.gold)
        #expect(before.drift(to: GoldenManifest.Snapshot.take(of: dirs.gold)) == ["b~dark.png"])

        try FileManager.default.removeItem(at: dirs.gold.appending(path: "b~dark.png"))
        #expect(before.drift(to: GoldenManifest.Snapshot.take(of: dirs.gold)).isEmpty)
    }
}
