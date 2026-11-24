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

    @Test func refusesToOverwriteAHandMadeSet() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())

        let handMade = f.out.appending(path: "c.symbolset")
        try FileManager.default.createDirectory(at: handMade, withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: handMade.appending(path: "drawn.svg"))
        try SymbolTemplate.contentsJSON(svgName: "drawn.svg")
            .write(to: handMade.appending(path: "Contents.json"))
        let outBefore = try Self.snapshot(f.out)
        let lockBefore = try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName))

        try f.source("a", Self.bar)
        try f.source("c", Self.bar)
        #expect {
            try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        } throws: { error in
            guard case .symbolAssetExists(let name, let url) = error as? AppShotError else {
                return false
            }
            return name == "c" && url.lastPathComponent == "c.symbolset"
        }
        #expect(try Self.snapshot(f.out) == outBefore)
        #expect(try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName)) == lockBefore)
    }

    @Test func rebuildsAfterALostLock() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        try FileManager.default.removeItem(at: f.sources.appending(path: SymbolLock.fileName))

        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.unchanged == ["a"])
        #expect(try SymbolLock.read(in: f.sources)?.symbols.keys.sorted() == ["a"])
    }

    @Test func refusesALockKeyThatIsAPath() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        let outside = f.root.appending(path: "x.symbolset")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "Contents.json"))
        let lock = SymbolLock(
            geometryVersion: 1, symbols: ["../x": SymbolLock.Entry(source: "s", template: "t")])
        try lock.write(in: f.sources)

        #expect {
            try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        } throws: { error in
            guard case .symbolLockBadName(let url, let name) = error as? AppShotError else {
                return false
            }
            return name == "../x" && url.lastPathComponent == SymbolLock.fileName
        }
        #expect(try Data(contentsOf: outside.appending(path: "Contents.json")) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
    }

    @Test func refusesTwoSourcesForOneName() throws {
        let dir = URL(fileURLWithPath: "/glyphs")
        let files = [dir.appending(path: "a.svg"), dir.appending(path: "a.SVG")]
        #expect {
            try SymbolBuild.checkDistinctNames(files, prefix: "")
        } throws: { error in
            guard case .symbolDuplicateName(let name, let first, let second) = error as? AppShotError
            else { return false }
            return name == "a" && first.lastPathComponent == "a.svg"
                && second.lastPathComponent == "a.SVG"
        }
        #expect(throws: Never.self) {
            try SymbolBuild.checkDistinctNames(
                [dir.appending(path: "a.svg"), dir.appending(path: "b.svg")], prefix: "")
        }
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

    // MARK: - The lock's out

    /// The reviewer's first reproduction: a build into another folder read the first
    /// folder's lock as that folder's, so its "set the lock does not list" guard never ran
    /// and a hand-made set there was written over.
    @Test func refusesAnotherFolderThanTheLocks() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        let lockBefore = try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName))

        let other = f.root.appending(path: "Other.xcassets/Glyphs")
        let handMade = other.appending(path: "a.symbolset")
        try FileManager.default.createDirectory(at: handMade, withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: handMade.appending(path: "a.svg"))
        let otherBefore = try Self.snapshot(other)

        #expect {
            try SymbolBuild.run(sources: f.sources, out: other, settings: SymbolSettings())
        } throws: { error in
            guard case .symbolLockOtherOut(let lock, let recorded, let given) = error as? AppShotError
            else { return false }
            let message = "\(error)"
            return lock.lastPathComponent == SymbolLock.fileName
                && recorded == "../Assets.xcassets/Glyphs" && given == other
                && message.contains("--out \(SymbolLock.canonical(f.out).path)")
                && message.contains("delete the lock")
        }
        #expect(try Self.snapshot(other) == otherBefore)
        #expect(try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName)) == lockBefore)
    }

    @Test func lockRecordsOutAsSymbolsJsonWouldWriteIt() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(try SymbolLock.read(in: f.sources)?.out == "../Assets.xcassets/Glyphs")

        // The same folder spelt another way is the same folder.
        let spelt = f.root.appending(path: "glyphs/../Assets.xcassets/./Glyphs")
        let again = try SymbolBuild.run(sources: f.sources, out: spelt, settings: SymbolSettings())
        #expect(again.unchanged == ["a"])
        let resolved = f.out.resolvingSymlinksInPath()
        #expect(throws: Never.self) {
            try SymbolBuild.run(sources: f.sources, out: resolved, settings: SymbolSettings())
        }
    }

    /// The lock records `out` relative to the symlink-resolved sources folder, so it is read back
    /// against that folder too: read against the link, `..` climbed out of the wrong parent and
    /// every rebuild was refused, naming a folder that did not exist (final review, 2026-11-24).
    @Test func rebuildsThroughASymlinkedSourcesFolder() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        // `link` beside the real folder's parent, pointing in with a relative path: `../A` read
        // against `link` lexically lands on `<root>/A`, which does not exist.
        let real = f.root.appending(path: "real/glyphs")
        try FileManager.default.createDirectory(
            at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.sources, to: real)
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: "real/glyphs")
        // Relative to the folder they are typed in, as the CLI makes them from `--from link
        // --out real/A`: an absolute URL hid the bug, Foundation then reading `link/..` through
        // the link.
        let here = URL(fileURLWithPath: f.root.path, isDirectory: true)
        let link = URL(fileURLWithPath: "link", relativeTo: here)
        let out = URL(fileURLWithPath: "real/A", relativeTo: here)

        _ = try SymbolBuild.run(sources: link, out: out, settings: SymbolSettings())
        #expect(try SymbolLock.read(in: link)?.out == "../A")
        let again = try SymbolBuild.run(sources: link, out: out, settings: SymbolSettings())
        #expect(again.unchanged == ["a"])
        #expect(try SymbolLock.read(in: link)?.isFor(out: out, sources: link) == true)
    }

    @Test func recordedOutIsRelativeOrAbsolute() {
        let sources = URL(fileURLWithPath: "/nonexistent-appshot/repo/design/glyphs")
        #expect(
            SymbolLock.recorded(
                out: URL(fileURLWithPath: "/nonexistent-appshot/repo/App/Assets.xcassets/Glyphs"),
                sources: sources) == "../../App/Assets.xcassets/Glyphs")
        #expect(SymbolLock.recorded(out: sources, sources: sources) == ".")
        #expect(
            SymbolLock.recorded(out: sources.appending(path: "out"), sources: sources) == "out")
        // Nothing in common below the root: absolute.
        #expect(
            SymbolLock.recorded(out: URL(fileURLWithPath: "/nonexistent-other/Glyphs"), sources: sources)
                == "/nonexistent-other/Glyphs")
        #expect(
            SymbolLock(geometryVersion: 1, out: "/nonexistent-other/Glyphs", symbols: [:])
                .isFor(out: URL(fileURLWithPath: "/nonexistent-other/x/../Glyphs"), sources: sources))
    }

    /// A lock from before `out` was recorded builds as before, and the build records it.
    @Test func aLockWithoutOutBuildsAndGainsIt() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        var lock = try #require(try SymbolLock.read(in: f.sources))
        lock.out = nil
        try lock.write(in: f.sources)
        let text = try String(contentsOf: f.sources.appending(path: SymbolLock.fileName), encoding: .utf8)
        #expect(!text.contains("\"out\""))

        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.unchanged == ["a"])
        #expect(try SymbolLock.read(in: f.sources)?.out == "../Assets.xcassets/Glyphs")
    }

    // MARK: - Refusals

    /// A generator that clears its folder and fails must not wipe the app's glyphs.
    @Test func refusesASourcesFolderWithNoGlyphs() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        let outBefore = try Self.snapshot(f.out)
        let lockBefore = try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName))
        try FileManager.default.removeItem(at: f.sources.appending(path: "a.svg"))

        #expect {
            try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        } throws: { error in
            guard case .symbolNoSources(let url) = error as? AppShotError else { return false }
            return url == f.sources && "\(error)".hasPrefix("no glyph sources in \(f.sources.path)")
        }
        #expect(try Self.snapshot(f.out) == outBefore)
        #expect(try Data(contentsOf: f.sources.appending(path: SymbolLock.fileName)) == lockBefore)
    }

    /// A mistyped `--from` says so, naming the flag, not that the folder is a bad SVG.
    @Test func refusesASourcesFolderThatIsNotThere() throws {
        let f = try Folders()
        defer { f.remove() }
        let typo = f.root.appending(path: "glyhps")
        #expect {
            try SymbolBuild.run(sources: typo, out: f.out, settings: SymbolSettings())
        } throws: { error in
            guard case .symbolFolderMissing(let url, let flag) = error as? AppShotError else { return false }
            return url == typo && flag == "--from" && "\(error)".contains("--from \(typo.path)")
        }
    }

    // MARK: - Scratch

    /// What `sheet --from` draws without `--assets`: the sets, in a folder of their own,
    /// with the lock and the family's asset folder untouched.
    @Test func scratchLeavesTheLockAndTheOutFolderAlone() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.source("a", Self.ring)
        try f.source("b", Self.bar)
        _ = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        try f.source("b", Self.ring)
        try f.source("c", Self.bar)
        let before = try Self.snapshot(f.root)

        let scratch = try SymbolBuild.scratch(sources: f.sources, settings: SymbolSettings())
        #expect(try Self.snapshot(f.root) == before)
        #expect(scratch.assets.lastPathComponent == "glyphs")
        #expect(!scratch.assets.path.hasPrefix(f.root.path))
        let sets = SymbolCheck.symbolsets(in: scratch.assets).map(\.lastPathComponent).sorted()
        #expect(sets == ["a.symbolset", "b.symbolset", "c.symbolset"])
        scratch.remove()
        #expect(!FileManager.default.fileExists(atPath: scratch.assets.deletingLastPathComponent().path))
    }

    // MARK: - The fixtures

    /// `Tests/Fixtures/Symbols`, copied into a fresh sources folder (build writes the lock
    /// beside the sources, and the repo's copy stays clean).
    static func fixtures(into f: Folders) throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/Symbols")
        for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
        where name.hasSuffix(".svg") {
            try FileManager.default.copyItem(
                at: fixtures.appending(path: name), to: f.sources.appending(path: name))
        }
    }

    @Test func fixturesBuildAndCheckClean() async throws {
        let f = try Folders()
        defer { f.remove() }
        try Self.fixtures(into: f)
        let report = try SymbolBuild.run(sources: f.sources, out: f.out, settings: SymbolSettings())
        #expect(report.written == ["block.rounded", "cube.arrow.up"])
        #expect(report.warnings.isEmpty)
        let (sources, out) = (f.sources, f.out)
        let findings = try await offPool {
            try SymbolCheck.run(
                sources: sources, out: out, settings: SymbolSettings(), actool: SymbolTemplateTests.hasActool)
        }
        #expect(findings == [])
    }
}
