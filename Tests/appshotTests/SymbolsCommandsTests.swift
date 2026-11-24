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
            (error as? CLIError)?.description == "no symbols found in \(out.path)"
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
            (error as? CLIError)?.description == "no glyph sources in \(sources.path)"
        }
    }
}
