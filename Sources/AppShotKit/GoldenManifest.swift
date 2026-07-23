import CryptoKit
import Foundation

/// A sealed record of what the goldens are, and who made them that way.
///
/// ## Why this exists
///
/// Nothing in appshot writes to the golden directory except `accept` — `selftest`
/// mutates copies in a temp dir, `check` never opens a file for writing. And yet a
/// golden set can still change underneath you: a second terminal running `accept` for
/// the same project, a `git lfs pull`, a branch switch. All three produce the same
/// symptom — every golden's mtime moved and a couple of new files appeared — and none
/// of them leaves any trace of which one it was. Reverting and moving on is the only
/// available response, and it teaches you nothing.
///
/// So `accept` writes down the sha256 of every golden it installs, along with who it
/// was, where, and with what arguments; `check` verifies it before comparing anything.
/// A tool an agent runs unsupervised needs "what wrote to golden and when" to be a
/// question with an answer.
///
/// ## What it can and cannot do
///
/// It cannot make the directory unwritable — that would need file flags that break
/// `git checkout` for everyone. What it does instead is make an out-of-band write
/// **impossible to miss**, and it discriminates the cases that matter:
///
/// - `git lfs pull`, a branch switch, a fresh clone: the manifest is committed
///   alongside the goldens, so it describes whatever tree you are on. Contents agree,
///   nothing fires.
/// - A stray `accept` from another terminal: the manifest is rewritten too, and its
///   `acceptedBy` names the run — the pid, the cwd, the argv.
/// - Anything else that edited the bytes: the shas disagree and `check` refuses to
///   compare against a baseline it cannot vouch for.
public struct GoldenManifest: Codable, Sendable {
    /// Bumped only if the meaning of a field changes. An older appshot reading a
    /// newer manifest is the case worth failing loudly on.
    public static let currentSchema = 1
    public static let fileName = "manifest.json"
    /// Enough accepts to see a pattern, few enough to stay reviewable in a diff.
    public static let historyLimit = 10

    public struct Entry: Codable, Sendable, Equatable {
        public let sha256: String
        public let bytes: Int
        public let width: Int
        public let height: Int
    }

    /// One accept, recorded so the *next* person can tell what happened here.
    public struct Accept: Codable, Sendable {
        public let at: Date
        public let user: String
        public let host: String
        public let cwd: String
        public let argv: [String]
        public let pid: pid_t
        public let appshotVersion: String
        public let count: Int

        static func current(count: Int) -> Accept {
            Accept(
                at: Date(),
                user: NSUserName(),
                host: ProcessInfo.processInfo.hostName,
                cwd: FileManager.default.currentDirectoryPath,
                argv: ProcessInfo.processInfo.arguments,
                pid: ProcessInfo.processInfo.processIdentifier,
                appshotVersion: AppShotVersion.current,
                count: count)
        }

        /// One line a person can act on: who did this, from where, with what.
        public var summary: String {
            let when = Accept.stamp.string(from: at)
            return "\(when) by \(user)@\(host) (pid \(pid), appshot \(appshotVersion)) "
                + "in \(abbreviate(cwd))"
        }

        static let stamp: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }()
    }

    public var schema: Int
    public var entries: [String: Entry]
    /// Newest first. `accepts[0]` is what installed the current goldens.
    public var accepts: [Accept]

    public var accepted: Accept? { accepts.first }

    // MARK: - Drift

    /// A golden that is not what the manifest says it is.
    public struct Change: Sendable {
        public let name: String
        public let modifiedAt: Date?
    }

    public struct Drift: Sendable {
        /// On disk and in the manifest, but the bytes disagree.
        public let changed: [Change]
        /// On disk, unknown to the manifest — a golden nobody accepted.
        public let unknown: [Change]
        /// In the manifest, gone from disk.
        public let vanished: [String]

        public var isEmpty: Bool {
            changed.isEmpty && unknown.isEmpty && vanished.isEmpty
        }
    }

    public enum Status: Sendable {
        /// No manifest — goldens from before this existed, or a project that has
        /// never run `appshot seal`.
        case unsealed
        case sealed(GoldenManifest, Drift)
    }

    // MARK: - Read

    public static func url(in goldenDir: URL) -> URL {
        goldenDir.appending(path: fileName)
    }

    public static func load(in goldenDir: URL) throws -> GoldenManifest? {
        let file = url(in: goldenDir)
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let manifest = try decoder.decode(GoldenManifest.self, from: data)
            guard manifest.schema <= currentSchema else {
                throw AppShotError.goldenManifestUnreadable(
                    file,
                    "schema \(manifest.schema), but this appshot understands \(currentSchema) — "
                        + "the goldens were sealed by a newer version")
            }
            return manifest
        } catch let error as AppShotError {
            throw error
        } catch {
            throw AppShotError.goldenManifestUnreadable(file, "\(error)")
        }
    }

    /// Compare the manifest against what is actually on disk.
    public static func status(of goldenDir: URL) throws -> Status {
        guard let manifest = try load(in: goldenDir) else { return .unsealed }

        let files = (try? Gate.pngs(in: goldenDir)) ?? []
        var changed: [Change] = []
        var unknown: [Change] = []
        var seen: Set<String> = []

        for file in files {
            let name = file.lastPathComponent
            seen.insert(name)
            guard let entry = manifest.entries[name] else {
                unknown.append(Change(name: name, modifiedAt: modified(file)))
                continue
            }
            // Size first: it is a stat, and a changed golden almost always changed
            // size too. Only same-size files pay for a hash.
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int
            if try size != entry.bytes || hex(of: file) != entry.sha256 {
                changed.append(Change(name: name, modifiedAt: modified(file)))
            }
        }

        let vanished = manifest.entries.keys.filter { !seen.contains($0) }.sorted()
        return .sealed(
            manifest,
            Drift(
                changed: changed.sorted { $0.name < $1.name },
                unknown: unknown.sorted { $0.name < $1.name },
                vanished: vanished))
    }

    // MARK: - Write

    /// Seal whatever PNGs are in `goldenDir` right now.
    ///
    /// Called by `accept` after it installs a set, and by `appshot seal` to adopt
    /// goldens that predate the manifest. Carries the previous accepts forward — the
    /// history is the audit trail, and rewriting it from scratch would erase exactly
    /// the record this exists to keep.
    @discardableResult
    public static func seal(goldenDir: URL, accept: Accept? = nil) throws -> GoldenManifest {
        let files = try Gate.pngs(in: goldenDir)
        var entries: [String: Entry] = [:]
        for file in files {
            guard let size = Image.size(file) else { throw AppShotError.imageDecodeFailed(file) }
            let bytes =
                (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int ?? 0
            entries[file.lastPathComponent] = Entry(
                sha256: try hex(of: file),
                bytes: bytes,
                width: size.width,
                height: size.height)
        }

        let previous = (try? load(in: goldenDir))?.accepts ?? []
        let record = accept ?? Accept.current(count: files.count)
        let manifest = GoldenManifest(
            schema: currentSchema,
            entries: entries,
            accepts: Array(([record] + previous).prefix(historyLimit)))

        try encoder.encode(manifest).write(to: url(in: goldenDir), options: .atomic)
        return manifest
    }

    // MARK: - Mid-run guard

    /// What the golden directory looked like at a moment in time.
    ///
    /// Cheap enough (one `stat` per file, no hashing) to take at the start of every
    /// check and again at the end. A `check` that compares against goldens which are
    /// being rewritten *while it runs* reports a verdict about a directory that no
    /// longer exists, and reports it as success about as often as not.
    public struct Snapshot: Equatable, Sendable {
        let files: [String: Stamp]

        struct Stamp: Equatable, Sendable {
            let size: Int
            let modified: Date?
            let inode: UInt64
        }

        public static func take(of dir: URL) -> Snapshot {
            let items =
                (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                ?? []
            var files: [String: Stamp] = [:]
            for item in items {
                let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
                files[item.lastPathComponent] = Stamp(
                    size: attributes?[.size] as? Int ?? -1,
                    modified: attributes?[.modificationDate] as? Date,
                    inode: attributes?[.systemFileNumber] as? UInt64 ?? 0)
            }
            return Snapshot(files: files)
        }

        /// Names that appeared, vanished or changed since `self`.
        public func drift(to now: Snapshot) -> [String] {
            Set(files.keys).union(now.files.keys)
                .filter { files[$0] != now.files[$0] }
                .sorted()
        }
    }

    // MARK: - Helpers

    static func hex(of url: URL) throws -> String {
        try Gate.sha256(of: url).map { String(format: "%02x", $0) }.joined()
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted and pretty because this file is committed and reviewed: an
        // unordered dictionary would churn the diff on every accept for no reason.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
