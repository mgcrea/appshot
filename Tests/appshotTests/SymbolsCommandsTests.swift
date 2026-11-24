import ArgumentParser
import Foundation
import Testing

@testable import AppShotKit
@testable import appshot

/// The CLI's own decisions: what parses, which flag wins over `symbols.json`, which
/// extension picks which sheet, and what exits non-zero. What the commands produce is
/// AppShotKit's, pinned in its own suite.
struct SymbolsCommandsTests {
    @Test func parsesBuild() throws {
        let command = try AppShot.parseAsRoot(["symbols", "build", "--from", "g"])
        let build = try #require(command as? SymbolsBuild)
        #expect(build.from == "g")
        #expect(build.out == nil)
    }

    @Test func checkFailsWithFindings() {
        #expect(SymbolsCheck.exitCode(for: [.stale("a")]) == 1)
        #expect(SymbolsCheck.exitCode(for: []) == 0)
    }

    @Test func sheetPicksFormatByExtension() throws {
        #expect(try SymbolSheetFormat(out: URL(fileURLWithPath: "/tmp/sheet.png")) == .png)
        #expect(try SymbolSheetFormat(out: URL(fileURLWithPath: "/tmp/sheet.html")) == .html)
        #expect {
            _ = try SymbolSheetFormat(out: URL(fileURLWithPath: "/tmp/sheet.jpg"))
        } throws: { error in
            guard case .unknownSheetFormat(let url) = error as? AppShotError else { return false }
            return url.lastPathComponent == "sheet.jpg"
        }
    }

    /// `--no-actool` with no sources would check nothing and pass (ruling 2).
    ///
    /// `validate()` is called directly because `parse` wraps what it throws in its own
    /// `CommandError`; this pins that the refusal is a usage error, a `ValidationError`.
    @Test func checkRefusesNoActoolWithoutSources() throws {
        var command = try SymbolsCheck.parse(["--out", "/tmp/x", "--from", "g", "--no-actool"])
        #expect(throws: Never.self) { try command.validate() }
        command.from = nil
        #expect(throws: ValidationError.self) { try command.validate() }
    }

    /// Hand-made mode has no `symbols.json` to give `out`.
    @Test func checkNeedsOutWithoutSources() throws {
        var command = try SymbolsCheck.parse(["--from", "g"])
        #expect(throws: Never.self) { try command.validate() }
        command.from = nil
        #expect(throws: ValidationError.self) { try command.validate() }
    }

    /// Ruling 10: the flag beats `symbols.json`, whose `out` is relative to the sources.
    @Test func outFlagBeatsSettings() throws {
        let sources = URL(fileURLWithPath: "/tmp/glyphs")
        var settings = SymbolSettings()
        settings.out = "../App/Glyphs"

        let fromSettings = try SymbolsOut.resolve(flag: nil, settings: settings, sources: sources)
        #expect(fromSettings.standardizedFileURL.path == "/tmp/App/Glyphs")

        let fromFlag = try SymbolsOut.resolve(flag: "/tmp/elsewhere", settings: settings, sources: sources)
        #expect(fromFlag.path == "/tmp/elsewhere")

        #expect(throws: (any Error).self) {
            _ = try SymbolsOut.resolve(flag: nil, settings: SymbolSettings(), sources: sources)
        }
    }

    static func emptyFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-symbols-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Ruling 3: a hand-made folder with no `.symbolset` fails before `actool` is asked.
    @Test func checkFailsOnAnEmptyHandMadeFolder() throws {
        let out = try Self.emptyFolder()
        defer { try? FileManager.default.removeItem(at: out) }

        let command = try SymbolsCheck.parse(["--out", out.path])
        #expect {
            try command.run()
        } throws: { error in
            guard case .symbolNoSymbols(let url, let flag) = error as? AppShotError else { return false }
            return url.path == out.path && flag == "--out"
                && "\(error)".hasPrefix("no symbols found in \(out.path)")
        }
    }

    /// A sources folder with no SVG would compare nothing and pass.
    @Test func checkFailsOnSourcesWithNoGlyphs() throws {
        let sources = try Self.emptyFolder()
        defer { try? FileManager.default.removeItem(at: sources) }

        let command = try SymbolsCheck.parse([
            "--from", sources.path, "--out", sources.appending(path: "out").path, "--no-actool",
        ])
        #expect {
            try command.run()
        } throws: { error in
            guard case .symbolNoSources(let url) = error as? AppShotError else { return false }
            return url.path == sources.path && "\(error)".hasPrefix("no glyph sources in \(sources.path)")
        }
    }

    /// A mistyped `--from` names the flag and the path in all three commands, before
    /// `symbols.json` is read (which would ask for `--out` instead).
    @Test func aMistypedFromSaysSo() throws {
        let root = try Self.emptyFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let typo = root.appending(path: "glyhps").path
        let commands: [any ParsableCommand] = [
            try SymbolsBuild.parse(["--from", typo]),
            try SymbolsCheck.parse(["--from", typo, "--no-actool"]),
            try SymbolsSheet.parse(["--from", typo, "--out", root.appending(path: "s.png").path]),
        ]
        for command in commands {
            #expect {
                var command = command
                try command.run()
            } throws: { error in
                guard case .symbolFolderMissing(let url, let flag) = error as? AppShotError else {
                    return false
                }
                return url.path == typo && flag == "--from"
            }
        }
    }

    @Test func sheetNeedsFromOrAssets() throws {
        var command = try SymbolsSheet.parse(["--out", "/tmp/x.png", "--from", "g"])
        #expect(throws: Never.self) { try command.validate() }
        command.from = nil
        #expect(throws: ValidationError.self) { try command.validate() }
        command.assets = "a"
        #expect(throws: Never.self) { try command.validate() }
    }

    @Test func sheetRefusesAnEmptyOrMissingAssetsFolder() throws {
        let root = try Self.emptyFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sheet = root.appending(path: "sheet.png")
        let empty = try SymbolsSheet.parse(["--assets", root.path, "--out", sheet.path])
        #expect {
            try empty.run()
        } throws: { error in
            guard case .symbolNoSymbols(_, let flag) = error as? AppShotError else { return false }
            return flag == "--assets"
        }
        let missing = try SymbolsSheet.parse([
            "--assets", root.appending(path: "Missing").path, "--out", sheet.path,
        ])
        #expect {
            try missing.run()
        } throws: { error in
            guard case .symbolFolderMissing(_, let flag) = error as? AppShotError else { return false }
            return flag == "--assets"
        }
        #expect(!FileManager.default.fileExists(atPath: sheet.path))
    }

    static var hasActool: Bool { (try? SymbolCatalog.actool()) != nil }

    /// `sheet --from` alone draws what a build would write, and leaves the lock and the
    /// family's asset folder as they were.
    @Test(.enabled(if: hasActool)) func sheetFromAloneTouchesNeitherTheLockNorTheAssets() async throws {
        let root = try Self.emptyFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appending(path: "glyphs")
        let out = root.appending(path: "Glyphs")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
        <g id="outline"><rect x="10" y="40" width="80" height="20"/></g>
        </svg>
        """.write(to: sources.appending(path: "a.svg"), atomically: true, encoding: .utf8)
        try SymbolsBuild.parse(["--from", sources.path, "--out", out.path]).run()
        // A source the build has not seen: the sheet must not build it into out.
        try FileManager.default.copyItem(
            at: sources.appending(path: "a.svg"), to: sources.appending(path: "b.svg"))
        let before = try Self.tree(root)

        let sheet = root.deletingLastPathComponent().appending(path: "\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: sheet) }
        let command = try SymbolsSheet.parse(["--from", sources.path, "--out", sheet.path])
        try await offPool { try command.run() }
        #expect(FileManager.default.fileExists(atPath: sheet.path))
        #expect(try Self.tree(root) == before)
    }

    /// Every file under `url`, by path, with its bytes and modification date.
    static func tree(_ url: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: url.path) {
            let file = url.appending(path: path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let data = (try? Data(contentsOf: file)).map { $0.base64EncodedString() } ?? "folder"
            files[path] = "\(date) \(data)"
        }
        return files
    }
}
