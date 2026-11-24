import Foundation

/// `symbols.lock.json`, beside the sources: what `build` wrote, so `check` can tell a stale
/// or hand-edited asset without regenerating, and `build` removes only its own assets.
///
/// It lives with the sources and not in the asset catalogue, so Xcode's asset editor, which
/// rewrites a `Contents.json` it touches, never drops it.
public struct SymbolLock: Codable, Equatable, Sendable {
    /// `SymbolGeometry.version` when the assets were written.
    public var geometryVersion: Int
    /// By asset name.
    public var symbols: [String: Entry]

    public struct Entry: Codable, Equatable, Sendable {
        /// `SymbolBuild.sourceFingerprint`: the SVG and the settings that bear on it.
        public var source: String
        /// SHA-256 of the template SVG written.
        public var template: String

        public init(source: String, template: String) {
            self.source = source
            self.template = template
        }
    }

    public static let fileName = "symbols.lock.json"

    public init(geometryVersion: Int, symbols: [String: Entry]) {
        self.geometryVersion = geometryVersion
        self.symbols = symbols
    }

    /// The sources folder's lock, or nil when it has none.
    public static func read(in sources: URL) throws -> SymbolLock? {
        let url = sources.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let lock: SymbolLock
        do {
            lock = try JSONDecoder().decode(SymbolLock.self, from: Data(contentsOf: url))
        } catch {
            throw AppShotError.invalidConfig(
                url,
                "the lock cannot be read (\(error.localizedDescription)); delete it and run "
                    + "appshot symbols build again, after moving aside any asset it should not remove")
        }
        // Build removes `<key>.symbolset` in `out`, so a key must be an asset name, never a path.
        for name in lock.symbols.keys.sorted() where name.wholeMatch(of: SymbolSource.namePattern) == nil {
            throw AppShotError.symbolLockBadName(url, name: name)
        }
        return lock
    }

    /// The bytes written: sorted keys, pretty-printed, ending with a newline, so it diffs cleanly.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return data + Data("\n".utf8)
    }

    /// Writes the lock, leaving the file untouched when its bytes would not change.
    public func write(in sources: URL) throws {
        let url = sources.appending(path: Self.fileName)
        let data = encoded()
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}
