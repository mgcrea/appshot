import Foundation
import Testing

@testable import AppShotKit

/// `build` turns a folder of sources into `.symbolset`s and a lock beside the sources, so
/// these pin what it writes, that a second run writes nothing new, which settings mark an
/// asset stale, that it only ever removes what its lock lists, and that one bad source
/// stops the whole build before anything is written.
struct SymbolBuildTests {
    /// A sources folder and an asset folder under one temp root.
    struct Folders {
        let root: URL
        var sources: URL { root.appending(path: "glyphs") }
        var out: URL { root.appending(path: "Assets.xcassets/Glyphs") }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "appshot-symbols-build-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        }

        func source(_ name: String, _ body: String) throws {
            try """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
            \(body)
            </svg>
            """.write(to: sources.appending(path: "\(name).svg"), atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static let ring = #"<g id="outline"><circle cx="50" cy="50" r="40" fill="none" stroke="black"/></g>"#
    static let bar = #"<g id="outline"><rect x="10" y="40" width="80" height="20"/></g>"#

    /// Every file under `url`, by relative path, with its bytes.
    static func snapshot(_ url: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let base = url.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        else { return files }
        for case let file as URL in walker {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(base.count))
            files[path] = try Data(contentsOf: file)
        }
        return files
    }

    @Test func writesSymbolsetsAndLock() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("b", Self.bar)

        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.written == ["a", "b"])
        #expect(report.unchanged.isEmpty && report.removed.isEmpty && report.warnings.isEmpty)

        for name in ["a", "b"] {
            let set = f.out.appending(path: "\(name).symbolset")
            let svg = try String(contentsOf: set.appending(path: "\(name).svg"), encoding: .utf8)
            #expect(svg.contains("Regular-M"))
            let contents = try JSONSerialization.jsonObject(
                with: Data(contentsOf: set.appending(path: "Contents.json")))
            let expected: NSDictionary = [
                "info": ["author": "xcode", "version": 1],
                "symbols": [["filename": "\(name).svg", "idiom": "universal"]],
            ]
            #expect((contents as? NSDictionary) == expected)
        }

        let lock = try #require(try SymbolLock.read(in: f.sources))
        #expect(lock.geometryVersion == 1)
        #expect(Set(lock.symbols.keys) == ["a", "b"])
        let template = try Data(contentsOf: f.out.appending(path: "a.symbolset/a.svg"))
        let source = try Data(contentsOf: f.sources.appending(path: "a.svg"))
        #expect(lock.symbols["a"]?.template == SymbolBuild.sha256(template))
        #expect(
            lock.symbols["a"]?.source
                == SymbolBuild.sourceFingerprint(svg: source, settings: SymbolSettings()))
    }

    @Test func idempotent() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("b", Self.bar)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        let before = try Self.snapshot(f.root)

        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.unchanged == ["a", "b"])
        #expect(report.written.isEmpty && report.removed.isEmpty)
        #expect(try Self.snapshot(f.root) == before)
    }

    @Test func settingsChangeTheFingerprint() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("b", Self.bar)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        let first = try #require(try SymbolLock.read(in: f.sources))

        _ = try SymbolBuild.run(
            sources: f.sources, out: f.out, settings: SymbolSettings(strokeWidth: 6))
        let thinner = try #require(try SymbolLock.read(in: f.sources))
        for name in ["a", "b"] {
            #expect(thinner.symbols[name]?.source != first.symbols[name]?.source)
        }

        _ = try SymbolBuild.run(
            sources: f.sources, out: f.out,
            settings: SymbolSettings(
                companions: ["cube"],
                variants: [SymbolVariant(name: "tint", colors: ["primary", "accent", "#112233"])]))
        let sheetOnly = try #require(try SymbolLock.read(in: f.sources))
        #expect(sheetOnly == first)
    }

    @Test func removesOnlyWhatItWrote() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("b", Self.bar)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())

        let handMade = f.out.appending(path: "c.symbolset")
        try FileManager.default.createDirectory(at: handMade, withIntermediateDirectories: true)
        try Data("hand".utf8).write(to: handMade.appending(path: "c.svg"))
        let accent = f.out.appending(path: "AccentColor.colorset")
        try FileManager.default.createDirectory(at: accent, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: accent.appending(path: "Contents.json"))
        let others = try Self.snapshot(handMade).merging(try Self.snapshot(accent)) { a, _ in a }

        try FileManager.default.removeItem(at: f.sources.appending(path: "b.svg"))
        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.removed == ["b"])
        #expect(report.unchanged == ["a"])
        #expect(!FileManager.default.fileExists(atPath: f.out.appending(path: "b.symbolset").path))
        #expect(FileManager.default.fileExists(atPath: f.out.appending(path: "a.symbolset").path))
        let after = try Self.snapshot(handMade).merging(try Self.snapshot(accent)) { a, _ in a }
        #expect(after == others)
        let lock = try #require(try SymbolLock.read(in: f.sources))
        #expect(Array(lock.symbols.keys) == ["a"])
    }

    @Test func refusesWholeOnABadSource() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("b", Self.bar)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        let outBefore = try Self.snapshot(f.out)
        let lockBefore = try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName))

        // a changes too, so a build that wrote before reading everything would show it.
        try f.source("a", Self.bar)
        try f.source("c", #"<g id="outline"><text x="10" y="50">A</text></g>"#)
        #expect {
            try SymbolBuild.run(
                sources: f.sources, out: f.out, settings: SymbolSettings(strokeWidth: 6))
        } throws: { error in
            guard case .symbolUnsupported(let url, _, _) = error as? AppShotError else { return false }
            return url.lastPathComponent == "c.svg"
        }
        #expect(try Self.snapshot(f.out) == outBefore)
        #expect(try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName)) == lockBefore)
    }

    @Test func refusesASymbolThatDrawsNothing() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("empty", #"<g id="outline"><path d=""/></g>"#)
        #expect {
            try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        } throws: { error in
            guard case .symbolNoOutline(let url) = error as? AppShotError else { return false }
            return url.lastPathComponent == "empty.svg"
        }
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
        #expect(try SymbolLock.read(in: f.sources) == nil)
    }

    @Test func overhangWarns() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("wide", #"<g id="outline"><rect x="-55" y="20" width="105" height="60"/></g>"#)
        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.warnings.count == 1)
        let warning = try #require(report.warnings.first)
        #expect(warning.contains("wide") && warning.contains("left"))
        #expect(report.written == ["wide"])

        try f.source("wide", #"<g id="outline"><rect x="-45" y="20" width="95" height="60"/></g>"#)
        let within = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(within.warnings.isEmpty)
    }

    @Test func lockSortedAndPretty() throws {
        let f = try Folders()
        defer { f.remove() }
        for name in ["zeta", "alpha", "mid"] { try f.source(name, Self.bar) }
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())

        let text = try String(
            contentsOf: f.sources.appending(path: SymbolLock.fileName), encoding: .utf8)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\n  \"geometryVersion\" : 1,\n"))
        let order = ["\"geometryVersion\"", "\"symbols\"", "\"alpha\"", "\"mid\"", "\"zeta\""].map {
            text.range(of: $0)?.lowerBound
        }
        let found = order.compactMap { $0 }
        #expect(found.count == order.count && found == found.sorted())
        let entry = try #require(text.range(of: "\"source\""))
        let template = try #require(text.range(of: "\"template\""))
        #expect(entry.lowerBound < template.lowerBound)
    }
}
