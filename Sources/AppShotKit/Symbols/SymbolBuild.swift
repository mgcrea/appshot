import CryptoKit
import Foundation

/// Builds a folder of glyph sources into `.symbolset`s and writes the lock beside them.
///
/// Every source is read and outlined before anything is written, so one bad source refuses
/// the whole build and leaves the assets and the lock as they were. Only the `.symbolset`s
/// the lock lists are ever removed: a hand-made asset in the same folder, or one Xcode
/// made, is left alone.
public enum SymbolBuild {
    public struct Report: Sendable {
        /// Asset names whose files were written, sorted.
        public var written: [String]
        /// Asset names whose files already held exactly what would be written.
        public var unchanged: [String]
        /// Asset names the lock listed whose source is gone, and whose `.symbolset` went.
        public var removed: [String]
        /// One line each, naming the symbol; none stops the build.
        public var warnings: [String]
    }

    /// How far, in box units, an outlined glyph may run past the 0…100 box before the build
    /// warns. A family matching stock symbols overhangs about 30 (a glyph that only fills the
    /// box renders at 13 pt against `cube`'s 17), so this only catches a drawing at the
    /// wrong scale.
    static let overhangLimit = 50.0

    /// The settings that bear on the drawing, in the lock's fingerprint.
    private struct Drawn: Encodable {
        let prefix: String
        let sideBearing: Double
        let strokeWidth: Double
    }

    /// SHA-256 of the SVG's bytes followed by the canonical JSON (sorted keys) of the
    /// settings that bear on the drawing: `strokeWidth`, `sideBearing`, `prefix`.
    public static func sourceFingerprint(svg: Data, settings: SymbolSettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let drawn = Drawn(
            prefix: settings.prefix, sideBearing: settings.sideBearing,
            strokeWidth: settings.strokeWidth)
        let json = (try? encoder.encode(drawn)) ?? Data()
        return sha256(svg + json)
    }

    /// Lowercase hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One asset ready to write.
    private struct Planned {
        let name: String
        let svg: Data
        let contents: Data
        let entry: SymbolLock.Entry
    }

    public static func run(sources: URL, out: URL, settings: SymbolSettings) throws -> Report {
        let previous = try SymbolLock.read(in: sources)

        // Read and outline everything first; nothing is written until every source is good.
        var planned: [Planned] = []
        var warnings: [String] = []
        let files = try sourceFiles(in: sources)
        try checkDistinctNames(files, prefix: settings.prefix)
        for url in files {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw AppShotError.symbolUnreadable(url, reason: error.localizedDescription)
            }
            let drawing = try SymbolSource.read(url, prefix: settings.prefix)
            let outlined = SymbolGeometry.outline(drawing, strokeWidth: settings.strokeWidth)
            guard !outlined.layers.isEmpty else { throw AppShotError.symbolNoOutline(url) }
            warnings += overhang(outlined)
            let svg = Data(SymbolTemplate.svg(outlined, sideBearing: settings.sideBearing).utf8)
            planned.append(
                Planned(
                    name: drawing.name, svg: svg,
                    contents: SymbolTemplate.contentsJSON(svgName: "\(drawing.name).svg"),
                    entry: SymbolLock.Entry(
                        source: sourceFingerprint(svg: data, settings: settings),
                        template: sha256(svg))))
        }

        // A set the lock does not list is someone else's, unless it already holds exactly
        // what build would write (a first build, or a rebuild after a lost lock).
        for asset in planned where previous?.symbols[asset.name] == nil {
            let set = out.appending(path: "\(asset.name).symbolset")
            guard FileManager.default.fileExists(atPath: set.path) else { continue }
            guard holdsExactly(asset, set) else {
                throw AppShotError.symbolAssetExists(name: asset.name, set)
            }
        }

        var report = Report(written: [], unchanged: [], removed: [], warnings: warnings)
        for asset in planned {
            let set = out.appending(path: "\(asset.name).symbolset")
            let svgURL = set.appending(path: "\(asset.name).svg")
            let contentsURL = set.appending(path: "Contents.json")
            if (try? Data(contentsOf: svgURL)) == asset.svg,
                (try? Data(contentsOf: contentsURL)) == asset.contents
            {
                report.unchanged.append(asset.name)
                continue
            }
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            // Atomic: each file goes to a temp file beside it and is moved into place.
            try asset.svg.write(to: svgURL, options: .atomic)
            try asset.contents.write(to: contentsURL, options: .atomic)
            report.written.append(asset.name)
        }

        let names = Set(planned.map(\.name))
        for name in (previous?.symbols.keys).map(Array.init)?.sorted() ?? [] where !names.contains(name) {
            let set = out.appending(path: "\(name).symbolset")
            if FileManager.default.fileExists(atPath: set.path) {
                try FileManager.default.removeItem(at: set)
            }
            report.removed.append(name)
        }

        let lock = SymbolLock(
            geometryVersion: SymbolGeometry.version,
            symbols: Dictionary(uniqueKeysWithValues: planned.map { ($0.name, $0.entry) }))
        try lock.write(in: sources)
        return report
    }

    /// Refuses two sources that make one asset name (`a.svg` and `a.SVG` on a case-sensitive
    /// volume), by the rule `SymbolSource.read` names an asset with.
    static func checkDistinctNames(_ files: [URL], prefix: String) throws {
        var seen: [String: URL] = [:]
        for url in files {
            let name = prefix + url.deletingPathExtension().lastPathComponent
            if let first = seen[name] { throw AppShotError.symbolDuplicateName(name: name, first, url) }
            seen[name] = url
        }
    }

    /// Whether `set` holds the asset's two files, byte for byte, and nothing else
    /// (hidden files such as `.DS_Store` aside).
    private static func holdsExactly(_ asset: Planned, _ set: URL) -> Bool {
        let files = try? FileManager.default.contentsOfDirectory(
            at: set, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard let names = files?.map(\.lastPathComponent),
            Set(names) == ["Contents.json", "\(asset.name).svg"]
        else { return false }
        return (try? Data(contentsOf: set.appending(path: "\(asset.name).svg"))) == asset.svg
            && (try? Data(contentsOf: set.appending(path: "Contents.json"))) == asset.contents
    }

    /// The folder's `.svg` files, sorted by name; subfolders are not read.
    static func sourceFiles(in sources: URL) throws -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        } catch {
            throw AppShotError.symbolUnreadable(sources, reason: error.localizedDescription)
        }
        return names.filter { $0.lowercased().hasSuffix(".svg") }.sorted()
            .map { sources.appending(path: $0) }
    }

    /// A warning for each side the outlined glyph runs more than `overhangLimit` past.
    static func overhang(_ symbol: OutlinedSymbol) -> [String] {
        let b = symbol.bounds
        let sides: [(String, Double)] = [
            ("left", -b.minX), ("top", -b.minY), ("right", b.maxX - 100), ("bottom", b.maxY - 100),
        ]
        return sides.filter { $0.1 > overhangLimit }.map { side, by in
            "\(symbol.name) runs \(SymbolTemplate.number(by)) box units past the \(side) of the "
                + "100 box (more than \(Int(overhangLimit))); is it drawn at the family's scale?"
        }
    }
}
