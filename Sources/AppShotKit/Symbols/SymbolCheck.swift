import AppKit
import Foundation

/// One thing `check` found wrong with a symbol folder; the CLI prints each `message`.
public enum SymbolFinding: Equatable, Sendable {
    /// The source, or a setting that bears on it, changed since its asset was built.
    case stale(String)
    /// The asset's template no longer matches the hash the lock holds for it.
    case editedByHand(String)
    /// A source with no asset.
    case unbuilt(String)
    /// An asset the lock lists whose source is gone.
    case orphaned(String)
    /// The lock was written by an older geometry than this appshot's.
    case olderGeometry(found: Int, current: Int)
    /// A source outside the subset: the error's message.
    case unsupported(String)
    /// `actool`'s error.
    case rejected(String)
    /// Hand-made mode: a symbol that draws nothing in a rendering mode.
    case empty(String, mode: String)

    public var message: String {
        switch self {
        case .stale(let name):
            return
                "\(name): the source or its settings changed since it was built; run appshot symbols build."
        case .editedByHand(let name):
            return """
                \(name): its template was edited by hand since appshot wrote it; edit the source \
                \(name).svg instead and run appshot symbols build, which writes over the edit.
                """
        case .unbuilt(let name):
            return "\(name): the source has no asset; run appshot symbols build."
        case .orphaned(let name):
            return """
                \(name): the lock lists this asset but its source \(name).svg is gone; run \
                appshot symbols build to remove it, or restore the source.
                """
        case .olderGeometry(let found, let current):
            return """
                The assets were built with geometry version \(found), and this appshot draws \
                version \(current); run appshot symbols build.
                """
        case .unsupported(let message):
            return message
        case .rejected(let why):
            return "actool refused the symbols:\n\(why)"
        case .empty(let name, let mode):
            return "\(name) draws nothing at 16 points in \(mode); give the layer that mode shows a shape."
        }
    }
}

/// Checks a symbol folder against its sources and lock, and optionally against `actool`.
/// It never writes and never regenerates an asset to compare.
public enum SymbolCheck {
    /// The findings, empty when all is well.
    ///
    /// With `sources`, the assets in `out` are compared with the sources and the lock, then,
    /// with `actool`, compiled. Without `sources`, `out` is a hand-made folder: with
    /// `actool`, it is compiled, and every symbol must load and draw in all three modes.
    ///
    /// - Throws: `AppShotError.symbolNoActool` only, when `actool` is asked for and not found.
    public static func run(sources: URL?, out: URL, settings: SymbolSettings, actool: Bool) throws
        -> [SymbolFinding]
    {
        var findings: [SymbolFinding] = []
        if let sources { findings += try compare(sources: sources, out: out, settings: settings) }
        guard actool else { return findings }
        _ = try SymbolCatalog.actool()
        // Nothing to compile: the drift findings already say why.
        guard !symbolsets(in: out).isEmpty || sources == nil else { return findings }

        let bundle: Bundle
        do {
            bundle = try SymbolCatalog.compile(out).bundle
        } catch let error as AppShotError {
            if case .symbolNoActool = error { throw error }
            if case .symbolCatalogRejected(let why) = error { return findings + [.rejected(why)] }
            return findings + [.rejected(error.description)]
        } catch {
            return findings + [.rejected(error.localizedDescription)]
        }
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL.deletingLastPathComponent()) }
        guard sources == nil else { return findings }

        for name in symbolsets(in: out).map({ $0.deletingPathExtension().lastPathComponent }).sorted() {
            guard let image = NSImage(symbolName: name, bundle: bundle, variableValue: 1) else {
                findings.append(.rejected("\(name).symbolset compiled, but no symbol \(name) loads from it"))
                continue
            }
            findings += emptyModes(image).map { .empty(name, mode: $0) }
        }
        return findings
    }

    /// Sources against the lock and the assets, in the order: geometry, each source by name,
    /// then each orphan by name.
    static func compare(sources: URL, out: URL, settings: SymbolSettings) throws -> [SymbolFinding] {
        let lock = try SymbolLock.read(in: sources)
        var findings: [SymbolFinding] = []
        if let lock, lock.geometryVersion < SymbolGeometry.version {
            findings.append(.olderGeometry(found: lock.geometryVersion, current: SymbolGeometry.version))
        }

        var names: Set<String> = []
        for url in try SymbolBuild.sourceFiles(in: sources) {
            let name = settings.prefix + url.deletingPathExtension().lastPathComponent
            names.insert(name)
            do {
                _ = try SymbolSource.read(url, prefix: settings.prefix)
            } catch let error as AppShotError {
                findings.append(.unsupported(error.description))
                continue
            }
            let template = out.appending(path: "\(name).symbolset/\(name).svg")
            guard let entry = lock?.symbols[name], let written = try? Data(contentsOf: template) else {
                findings.append(.unbuilt(name))
                continue
            }
            let svg: Data
            do {
                svg = try Data(contentsOf: url)
            } catch {
                throw AppShotError.symbolUnreadable(url, reason: error.localizedDescription)
            }
            if SymbolBuild.sourceFingerprint(svg: svg, settings: settings) != entry.source {
                findings.append(.stale(name))
            }
            if SymbolBuild.sha256(written) != entry.template { findings.append(.editedByHand(name)) }
        }
        for name in (lock?.symbols.keys).map(Array.init)?.sorted() ?? [] where !names.contains(name) {
            findings.append(.orphaned(name))
        }
        return findings
    }

    /// Every `.symbolset` under `out`, in groups too, as an asset catalogue holds them.
    public static func symbolsets(in out: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)
        else { return [] }
        var sets: [URL] = []
        for case let url as URL in walker where url.pathExtension == "symbolset" {
            sets.append(url)
            walker.skipDescendants()
        }
        return sets
    }

    /// The modes in which `image`, at 16 points, draws no pixel that is not transparent.
    static func emptyModes(_ image: NSImage) -> [String] {
        let modes: [(String, NSImage.SymbolConfiguration)] = [
            ("monochrome", .preferringMonochrome()),
            ("hierarchical", .preferringHierarchical()),
            ("palette", .init(paletteColors: [.black, .red, .gray])),
        ]
        let size = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return modes.filter { _, mode in
            guard let drawn = image.withSymbolConfiguration(size.applying(mode)) else { return true }
            return !drawsAnything(drawn)
        }.map(\.0)
    }

    /// Whether `image`, drawn into a bitmap at twice its size, leaves any pixel not transparent.
    static func drawsAnything(_ image: NSImage) -> Bool {
        let width = max(1, Int((image.size.width * 2).rounded(.up)))
        let height = max(1, Int((image.size.height * 2).rounded(.up)))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return false }
        // Pixels are RGBA, 8 bits each, row by row with any padding at each row's end.
        for y in 0..<height {
            let row = data + y * rep.bytesPerRow
            for x in 0..<width where row[x * 4 + 3] != 0 { return true }
        }
        return false
    }
}
