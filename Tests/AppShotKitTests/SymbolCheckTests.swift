import AppKit
import Foundation
import Testing

@testable import AppShotKit

/// `check` compares a folder of sources with the assets and the lock `build` wrote, without
/// regenerating anything, so these start each from a folder `build` made, change one thing,
/// and pin the one finding it gives; every run also pins that `check` wrote nothing.
struct SymbolCheckTests {
    typealias Folders = SymbolBuildTests.Folders

    /// Two sources, built.
    static func built() throws -> Folders {
        let f = try Folders()
        try f.source("a", SymbolBuildTests.ring)
        try f.source("b", SymbolBuildTests.bar)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        return f
    }

    /// Each file's modification date under `out` and the lock's.
    static func dates(_ f: Folders) throws -> [String: Date] {
        var dates: [String: Date] = [:]
        let lock = f.sources.appending(path: SymbolLock.fileName)
        for url in [lock]
            + (FileManager.default.enumerator(at: f.out, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? [])
        {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            dates[url.path] = attributes[.modificationDate] as? Date
        }
        return dates
    }

    /// Runs the check and expects it to have written nothing.
    static func check(_ f: Folders, sources: Bool = true, actool: Bool = false) throws -> [SymbolFinding] {
        let before = try dates(f)
        let findings = try SymbolCheck.run(
            sources: sources ? f.sources : nil, out: f.out, settings: SymbolSettings(), actool: actool)
        #expect(try dates(f) == before, "check wrote under out or to the lock")
        return findings
    }

    static func edit(_ url: URL, _ change: (String) -> String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try change(text).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func cleanIsEmpty() throws {
        let f = try Self.built()
        defer { f.remove() }
        #expect(try Self.check(f) == [])
    }

    @Test func sourceEdited() throws {
        let f = try Self.built()
        defer { f.remove() }
        let handle = try FileHandle(forWritingTo: f.sources.appending(path: "a.svg"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        #expect(try Self.check(f) == [.stale("a")])
    }

    @Test func templateEdited() throws {
        let f = try Self.built()
        defer { f.remove() }
        try Self.edit(f.out.appending(path: "a.symbolset/a.svg")) { $0 + "\n" }
        #expect(try Self.check(f) == [.editedByHand("a")])
    }

    @Test func newSource() throws {
        let f = try Self.built()
        defer { f.remove() }
        try f.source("c", SymbolBuildTests.bar)
        #expect(try Self.check(f) == [.unbuilt("c")])
    }

    @Test func sourceDeleted() throws {
        let f = try Self.built()
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.sources.appending(path: "b.svg"))
        #expect(try Self.check(f) == [.orphaned("b")])
    }

    @Test func oldGeometry() throws {
        let f = try Self.built()
        defer { f.remove() }
        var lock = try #require(try SymbolLock.read(in: f.sources))
        lock.geometryVersion = 0
        try lock.write(in: f.sources)
        #expect(try Self.check(f) == [.olderGeometry(found: 0, current: SymbolGeometry.version)])
        #expect(SymbolGeometry.version == 1)
    }

    @Test func unsupportedSource() throws {
        let f = try Self.built()
        defer { f.remove() }
        try f.source("a", #"<g id="outline"><text x="10" y="10">A</text></g>"#)
        let findings = try Self.check(f)
        #expect(findings.count == 1)
        guard case .unsupported(let message) = findings.first else {
            Issue.record("\(findings)")
            return
        }
        #expect(message.contains("a.svg") && message.contains("text"))
    }

    @Test func neverWrites() throws {
        // Every change above at once; `check` pins the dates on its own as well.
        let f = try Self.built()
        defer { f.remove() }
        try Self.edit(f.sources.appending(path: "a.svg")) { $0 + " " }
        try Self.edit(f.out.appending(path: "b.symbolset/b.svg")) { $0 + " " }
        try f.source("c", SymbolBuildTests.bar)
        var lock = try #require(try SymbolLock.read(in: f.sources))
        lock.geometryVersion = 0
        lock.symbols["d"] = lock.symbols["a"]
        try lock.write(in: f.sources)
        let findings = try Self.check(f)
        #expect(
            findings == [
                .olderGeometry(found: 0, current: 1), .stale("a"), .editedByHand("b"), .unbuilt("c"),
                .orphaned("d"),
            ])
        if SymbolTemplateTests.hasActool {
            _ = try Self.check(f, actool: true)
            _ = try Self.check(f, sources: false, actool: true)
        }
    }

    @Test func messagesNameTheSymbol() {
        #expect(SymbolFinding.stale("a").message.contains("a"))
        #expect(SymbolFinding.olderGeometry(found: 0, current: 1).message.contains("build"))
        #expect(SymbolFinding.empty("a", mode: "palette").message.contains("palette"))
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func actoolRejects() throws {
        let f = try Self.built()
        defer { f.remove() }
        try Self.edit(f.out.appending(path: "a.symbolset/a.svg")) {
            $0.replacingOccurrences(of: #"id="Regular-M""#, with: #"id="Regular-X""#)
        }
        let findings = try Self.check(f, actool: true)
        #expect(findings.contains(.editedByHand("a")))
        let rejected = findings.compactMap { finding -> String? in
            guard case .rejected(let why) = finding else { return nil }
            return why
        }
        #expect(rejected.count == 1, "\(findings)")
        #expect(rejected.first?.contains("a.symbolset") == true, "\(rejected)")
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func handMadeMode() throws {
        let f = try Self.built()
        defer { f.remove() }
        // The sources are gone: only the asset folder is checked.
        try FileManager.default.removeItem(at: f.sources)
        #expect(try Self.checkHandMade(f) == [])
    }

    /// `check` with no sources, which reads no lock; the dates under `out` stay.
    static func checkHandMade(_ f: Folders) throws -> [SymbolFinding] {
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.out.path)
        let findings = try SymbolCheck.run(sources: nil, out: f.out, settings: SymbolSettings(), actool: true)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: f.out.path) == before)
        return findings
    }

    /// Each mode draws something at 16 points: what hand-made mode asks of every symbol.
    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func rendersInEveryMode() throws {
        let f = try Self.built()
        defer { f.remove() }
        let bundle = try SymbolCatalog.compile(f.out).bundle
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL.deletingLastPathComponent()) }
        let image = try #require(NSImage(symbolName: "a", bundle: bundle, variableValue: 1))
        #expect(SymbolCheck.emptyModes(image) == [])
        // An image with nothing in it is empty in every mode.
        #expect(SymbolCheck.emptyModes(NSImage(size: NSSize(width: 16, height: 16))).count == 3)
    }

    @Test(.enabled(if: SymbolTemplateTests.hasActool)) func handMadeEmptyGlyph() throws {
        let f = try Self.built()
        defer { f.remove() }
        // A hand edit hides the only layer in monochrome, as the wash is hidden.
        try Self.edit(f.out.appending(path: "a.symbolset/a.svg")) {
            $0.replacingOccurrences(
                of: ".monochrome-0 {fill:#000000}", with: ".monochrome-0 {fill:#000000;opacity:0.0}")
        }
        try FileManager.default.removeItem(at: f.sources)
        #expect(try Self.checkHandMade(f) == [.empty("a", mode: "monochrome")])
    }

    @Test func noActoolIsOneClearError() throws {
        let f = try Self.built()
        defer { f.remove() }
        let missing = URL(fileURLWithPath: "/nonexistent/appshot-\(UUID().uuidString)/xcrun")
        try SymbolCatalog.$xcrun.withValue(missing) {
            for sources in [true, false] {
                #expect {
                    try Self.check(f, sources: sources, actool: true)
                } throws: { error in
                    guard case .symbolNoActool = error as? AppShotError else { return false }
                    return "\(error)".contains("xcode-select")
                }
            }
        }
    }

    /// A stand-in `xcrun` that finds a stand-in `actool` which never finishes.
    @Test func actoolThatHangsIsStopped() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-hang-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appending(path: "Glyphs"), withIntermediateDirectories: true)
        let tool = dir.appending(path: "actool")
        let xcrun = dir.appending(path: "xcrun")
        try "#!/bin/sh\nexec sleep 60\n".write(to: tool, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho '\(tool.path)'\n".write(to: xcrun, atomically: true, encoding: .utf8)
        for url in [tool, xcrun] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let start = Date()
        try SymbolCatalog.$xcrun.withValue(xcrun) {
            try SymbolCatalog.$actoolTimeout.withValue(1) {
                #expect {
                    try SymbolCatalog.compile(dir.appending(path: "Glyphs"))
                } throws: { error in
                    guard case .symbolCatalogRejected(let why) = error as? AppShotError else { return false }
                    return why == "actool did not finish in 1 s"
                }
            }
        }
        #expect(Date().timeIntervalSince(start) < 20)
        #expect(SymbolCatalog.actoolTimeout == 120)
    }
}
