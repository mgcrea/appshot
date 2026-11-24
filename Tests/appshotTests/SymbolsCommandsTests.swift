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

    /// `--no-actool` with no sources would check nothing and pass.
    @Test func checkRefusesNoActoolWithoutSources() {
        #expect(throws: (any Error).self) {
            _ = try SymbolsCheck.parse(["--out", "/tmp/x", "--no-actool"])
        }
        #expect(throws: Never.self) {
            _ = try SymbolsCheck.parse(["--out", "/tmp/x", "--from", "g", "--no-actool"])
        }
    }

    /// Hand-made mode has no `symbols.json` to give `out`.
    @Test func checkNeedsOutWithoutSources() {
        #expect(throws: (any Error).self) { _ = try SymbolsCheck.parse([]) }
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
}
