import Foundation

/// `symbols.lock.json`, beside the sources: what `build` wrote, so `check` can tell a stale
/// or hand-edited asset without regenerating, and `build` removes only its own assets.
///
/// It lives with the sources and not in the asset catalogue, so Xcode's asset editor, which
/// rewrites a `Contents.json` it touches, never drops it. Living there, it ties the family to
/// the one asset folder it was built into (`out`): a build or a check of another folder
/// would otherwise read this folder's lock as that one's.
public struct SymbolLock: Codable, Equatable, Sendable {
    /// `SymbolGeometry.version` when the assets were written.
    public var geometryVersion: Int
    /// The asset folder the lock was written for, as `symbols.json`'s `out` writes it:
    /// relative to the sources folder, POSIX, or absolute when the two share no folder
    /// below the root. Nil in a lock from before it was recorded: unknown, and the next
    /// build fills it in.
    public var out: String?
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

    public init(geometryVersion: Int, out: String? = nil, symbols: [String: Entry]) {
        self.geometryVersion = geometryVersion
        self.out = out
        self.symbols = symbols
    }

    /// Whether the lock was written for `out`; a lock that does not say is taken to be.
    public func isFor(out given: URL, sources: URL) -> Bool {
        guard let out else { return true }
        return Self.canonical(Self.folder(out, sources: sources)).path == Self.canonical(given).path
    }

    /// The folder a recorded `out` names, read against the sources folder.
    public static func folder(_ out: String, sources: URL) -> URL {
        (out.hasPrefix("/") ? URL(fileURLWithPath: out) : sources.appending(path: out))
            .standardizedFileURL
    }

    /// `out` as the lock records it: relative to `sources` when the two share a folder below
    /// the root, absolute otherwise.
    public static func recorded(out: URL, sources: URL) -> String {
        let to = canonical(out).pathComponents
        let from = canonical(sources).pathComponents
        var common = 0
        while common < min(to.count, from.count), to[common] == from[common] { common += 1 }
        // pathComponents starts with "/": sharing only it is sharing nothing.
        guard common > 1 else { return canonical(out).path }
        let path = Array(repeating: "..", count: from.count - common) + to[common...]
        return path.isEmpty ? "." : path.joined(separator: "/")
    }

    /// The path with `.` and `..` gone and every symlink in its existing part resolved
    /// (`/var` and `/private/var` are one folder), so two spellings of a folder compare equal
    /// whether or not it exists yet.
    static func canonical(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.pathComponents.count > 1 {
            tail.insert(head.lastPathComponent, at: 0)
            head = head.deletingLastPathComponent().standardizedFileURL
        }
        var resolved = URL(fileURLWithPath: head.path)
        if let real = realpath(head.path, nil) {
            resolved = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in tail { resolved.append(path: component) }
        return resolved.standardizedFileURL
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
