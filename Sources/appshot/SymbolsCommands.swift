import AppShotKit
import ArgumentParser
import Foundation

// MARK: - symbols

struct Symbols_: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "symbols",
        abstract: "Build custom SF Symbols from layered SVG glyphs, check them, and sheet them.",
        discussion: """
            Takes glyphs you already drew, one SVG per symbol on a 100 by 100 box with \
            up to three groups (outline, touch, wash), and does the mechanical part: \
            strokes outlined, the box set on the baseline and cap line, margins from \
            the outlined bounds, the layers classed for palette, hierarchical and \
            monochrome, and a lock that says what was built from what.

            It deliberately does not own what is *in* the glyph — that is per-project \
            design, and a tool that drew it would be guessing.

            The sheet is drawn from the compiled symbols, as macOS draws them, never \
            from the SVGs: the margins and baselines are where custom symbols go \
            wrong, and a sheet of the sources would hide exactly that. Its --out \
            extension picks what it writes:

              .png    the sheet alone, fine to commit
              .html   the review page, with the reference images symbols.json lists;
                      never committed, since references are often other vendors' icons

              appshot symbols build --from design/glyphs \\
                  --out App/Assets.xcassets/Glyphs

              appshot symbols check --from design/glyphs \\
                  --out App/Assets.xcassets/Glyphs

              appshot symbols sheet --from design/glyphs --out /tmp/glyphs.html

            --out may be left out when design/glyphs/symbols.json gives "out", a path \
            relative to that folder; a flag always beats the file. The lock, \
            design/glyphs/symbols.lock.json, ties the family to the one folder it was \
            built into: build and check refuse another, until the lock is deleted.

            sheet --from alone builds the glyphs into a scratch folder, without the \
            lock, and draws that; --assets draws a folder already built instead.
            """,
        subcommands: [SymbolsBuild.self, SymbolsCheck.self, SymbolsSheet.self]
    )
}

/// A folder a flag names, refused before anything else is read when it is not there: a
/// mistyped path would otherwise surface as a missing `symbols.json` key or a bad SVG.
enum SymbolsFolder {
    static func require(_ path: String, flag: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue
        else { throw AppShotError.symbolFolderMissing(url, flag: flag) }
        return url
    }
}

/// Where the assets go: `--out` when given, else `symbols.json`'s `out`, read against the
/// sources folder so the file means the same thing from any working directory.
enum SymbolsOut {
    static func resolve(flag: String?, settings: SymbolSettings, sources: URL) throws -> URL {
        if let flag { return URL(fileURLWithPath: flag) }
        guard let out = settings.out else {
            // Not a ValidationError: this is found in `run`, after symbols.json is read, where
            // ArgumentParser would print the root command's usage beside it.
            throw CLIError(
                """
                --out is required: give it, or set "out" in \
                \(sources.appending(path: SymbolSettings.fileName).path), a path relative to \
                that folder.
                """)
        }
        let expanded = (out as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : sources.appending(path: expanded)
    }
}

/// Which file `symbols sheet --out` is asking for.
///
/// Derived from the extension rather than a `--format` flag, as `IconFormat` is: the
/// two differ in what may be committed, and a flag that could disagree with the path is
/// a way to write the reference images into a file that then gets committed.
enum SymbolSheetFormat: Equatable {
    case png
    case html

    init(out: URL) throws {
        switch out.pathExtension.lowercased() {
        case "png": self = .png
        case "html": self = .html
        default: throw AppShotError.unknownSheetFormat(out)
        }
    }
}

// MARK: - symbols build

struct SymbolsBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Write a .symbolset for every glyph source, and the lock beside them.")

    @Option(name: .long, help: "The folder of glyph SVGs, with its symbols.json if any.")
    var from: String

    @Option(
        name: .long,
        help: """
            The folder the .symbolsets go into, usually a folder in an asset catalogue. \
            Defaults to symbols.json's "out", relative to --from.
            """)
    var out: String?

    func run() throws {
        let sources = try SymbolsFolder.require(from, flag: "--from")
        let settings = try SymbolSettings.read(in: sources)
        let outURL = try SymbolsOut.resolve(flag: out, settings: settings, sources: sources)

        // Warnings first and on stderr, as `icon build` says its own: none stops the
        // build, and each names the glyph it is about.
        let report = try SymbolBuild.run(sources: sources, out: outURL, settings: settings)
        for warning in report.warnings {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }
        for name in report.written { print("✓ wrote \(name).symbolset") }
        for name in report.removed { print("✓ removed \(name).symbolset, its source is gone") }
        print("  \(report.unchanged.count) unchanged, in \(outURL.path)")
    }
}

// MARK: - symbols check

struct SymbolsCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Fail if the symbols drifted from their sources, or actool refuses them.",
        discussion: """
            With --from, compares every asset with its source and the lock: a source \
            or setting changed since the build, a template edited by hand, a source \
            with no asset, an asset whose source is gone, a lock from an older \
            geometry. It never rebuilds to compare, so that part gives the same \
            answer on any Mac. Then it compiles the folder with actool, as Xcode would.

            Without --from, --out is a hand-made folder (one drawn in the SF Symbols \
            app): actool must accept it, and every symbol must load and draw in all \
            three rendering modes.

            --no-actool skips the compile where Xcode is absent. It needs --from, \
            since without sources there would be nothing left to check.
            """)

    @Option(
        name: .long,
        help: """
            The folder of .symbolsets. Defaults, with --from, to symbols.json's "out", \
            relative to --from.
            """)
    var out: String?

    @Option(name: .long, help: "The folder of glyph SVGs the assets were built from.")
    var from: String?

    @Flag(name: .customLong("no-actool"), help: "Skip compiling with actool. Needs --from.")
    var noActool = false

    func validate() throws {
        guard from == nil else { return }
        if noActool {
            throw ValidationError(
                "--no-actool needs --from: without sources and without actool there is nothing to check.")
        }
        if out == nil { throw ValidationError("--out is required without --from.") }
    }

    /// 1 when anything was found, 0 otherwise.
    static func exitCode(for findings: [SymbolFinding]) -> Int32 {
        findings.isEmpty ? 0 : 1
    }

    func run() throws {
        let sources = try from.map { try SymbolsFolder.require($0, flag: "--from") }
        let settings = try sources.map { try SymbolSettings.read(in: $0) } ?? SymbolSettings()
        // A check that checked nothing must not pass, in either mode: a mistyped path
        // would otherwise be green in CI forever. Both are refused before actool runs.
        let outURL: URL
        let sourceCount: Int
        if let sources {
            sourceCount = try SymbolBuild.sourceFiles(in: sources).count
            guard sourceCount > 0 else { throw AppShotError.symbolNoSources(sources) }
            outURL = try SymbolsOut.resolve(flag: out, settings: settings, sources: sources)
        } else {
            // `validate` made sure of it.
            outURL = try SymbolsFolder.require(out ?? ".", flag: "--out")
            sourceCount = 0
            guard !SymbolCheck.symbolsets(in: outURL).isEmpty else {
                throw AppShotError.symbolNoSymbols(outURL, flag: "--out")
            }
        }

        let findings = try SymbolCheck.run(
            sources: sources, out: outURL, settings: settings, actool: !noActool)
        for finding in findings { print("✗ \(finding.message)") }

        let code = Self.exitCode(for: findings)
        guard code == 0 else { throw ExitCode(code) }
        if sources != nil {
            // The sources, not the .symbolsets: `out` may hold hand-made ones beside them,
            // which have no source to match.
            print(
                "✓ \(outURL.path): \(sourceCount) symbol(s) match their sources"
                    + (noActool ? " (actool skipped)" : ", and actool accepts them"))
        } else {
            let count = SymbolCheck.symbolsets(in: outURL).count
            print("✓ \(outURL.path): \(count) symbol(s) compile and draw in all three modes")
        }
    }
}

// MARK: - symbols sheet

struct SymbolsSheet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sheet",
        abstract: "Draw the compiled symbols in every rendering mode, beside stock ones.")

    @Option(
        name: .long,
        help: """
            A folder of .symbolsets already built, to compile and draw. Without it, the \
            --from glyphs are built into a scratch folder and drawn.
            """)
    var assets: String?

    @Option(
        name: .long,
        help: """
            The folder of glyph SVGs: its symbols.json gives the companions, the variant \
            columns and the reference images, read against this folder. Without --assets, \
            the glyphs themselves are drawn, built without reading or writing the lock.
            """)
    var from: String?

    @Option(name: .long, help: "The sheet to write, .png or .html. The extension picks which.")
    var out: String

    func validate() throws {
        if assets == nil, from == nil {
            throw ValidationError(
                "give --from (the glyphs, built for the sheet) or --assets (a folder already built).")
        }
    }

    func run() throws {
        let outURL = URL(fileURLWithPath: out)
        // Before anything is compiled: a wrong extension is a typo, not a slow failure.
        let format = try SymbolSheetFormat(out: outURL)
        let sources = try from.map { try SymbolsFolder.require($0, flag: "--from") }
        var assetsURL = try assets.map { try SymbolsFolder.require($0, flag: "--assets") }
        // Without --from there are no settings, so no references to resolve either.
        let settings = try sources.map { try SymbolSettings.read(in: $0) } ?? SymbolSettings()

        // No --assets: what a build would write, drawn from a scratch folder that never
        // touches the lock or the family's asset folder.
        var scratch: SymbolBuild.Scratch?
        defer { scratch?.remove() }
        if assetsURL == nil, let sources {
            let built = try SymbolBuild.scratch(sources: sources, settings: settings)
            scratch = built
            assetsURL = built.assets
            for warning in built.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
        }
        // `validate` made sure one of the two is there.
        guard let assetsURL else { throw ValidationError("give --from or --assets.") }

        let data: Data
        switch format {
        case .png:
            data = try SymbolSheet.png(assets: assetsURL, settings: settings)
        case .html:
            data = Data(
                try SymbolSheet.html(
                    assets: assetsURL, settings: settings, referencesRoot: sources ?? assetsURL
                ).utf8)
        }
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outURL, options: .atomic)
        print("✓ wrote \(out)")
        if format == .html, !settings.references.isEmpty {
            print("  holds \(settings.references.count) reference image(s); do not commit it")
        }
    }
}
