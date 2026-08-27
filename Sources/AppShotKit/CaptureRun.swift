import Foundation

/// A record of the capture run that produced the PNGs sitting in `source/`.
///
/// ## Why this exists
///
/// `check` compares whatever is in the source directory against the goldens. It has
/// never had any way to know whether those captures came from *this* run — and when the
/// answer is "no", the failure is silent and green.
///
/// Measured: a project's build broke, so `appshot capture` never executed. `check` ran
/// anyway, found twenty PNGs left over from a run **fifteen days earlier**, compared
/// them to the goldens they were accepted from, and reported
/// `✓ 20 screenshot(s) match their goldens`, exit 0. Nothing in that output was false.
/// It simply answered a question nobody asked.
///
/// Chaining through `appshot run` stops at the build failure, so this only bites when
/// `check` is invoked on its own — which is exactly what CI, a Makefile target, and an
/// agent all do.
///
/// ## What it can and cannot tell you
///
/// It records when the captures were taken, by what argv, from which app bundle. That
/// makes "how old is this evidence" answerable, which is all the silhouette case needed:
/// a line reading *captures are 15 days old* is impossible to walk past.
///
/// It deliberately does **not** try to decide staleness for you by default. "Captured
/// Monday, reviewed Tuesday" is a legitimate workflow, and a tool that failed on it
/// would be turned off. `--max-source-age` is there for CI, where the captures should
/// always be minutes old and anything else is a broken pipeline.
///
/// Note what it cannot catch: if a build fails and leaves the *previous* app bundle in
/// place, the app fingerprint recorded here still matches that bundle. Age is the signal
/// that works, which is why age is the thing reported.
public struct CaptureRun: Codable, Sendable {
    public static let currentSchema = 1
    public static let fileName = "run.json"

    public let schema: Int
    public let at: Date
    public let user: String
    public let host: String
    public let cwd: String
    public let argv: [String]
    public let pid: pid_t
    public let appshotVersion: String
    /// The app bundle these captures came out of, and when it was last built.
    public let appPath: String?
    public let appModifiedAt: Date?
    /// The capture filenames written, so a partially overwritten set is visible.
    public let names: [String]

    public init(appPath: URL?, names: [String]) {
        self.schema = CaptureRun.currentSchema
        self.at = Date()
        self.user = NSUserName()
        self.host = ProcessInfo.processInfo.hostName
        self.cwd = FileManager.default.currentDirectoryPath
        self.argv = ProcessInfo.processInfo.arguments
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.appshotVersion = AppShotVersion.current
        self.appPath = appPath?.path
        self.appModifiedAt =
            appPath.flatMap {
                try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]
                    as? Date
            }
        self.names = names.sorted()
    }

    public var age: TimeInterval { Date().timeIntervalSince(at) }

    /// Age in the coarsest unit that still reads honestly. "15 days" is the sentence
    /// that makes a stale run obvious; "1296000 seconds" is not.
    public var ageDescription: String {
        let seconds = max(0, age)
        switch seconds {
        case ..<90: return "\(Int(seconds))s"
        case ..<5400: return "\(Int(seconds / 60))m"
        case ..<172_800: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400)) days"
        }
    }

    public var summary: String {
        "captured \(ageDescription) ago by \(user)@\(host) (appshot \(appshotVersion))"
    }

    // MARK: - Disk

    public static func url(in directory: URL) -> URL {
        directory.appending(path: fileName)
    }

    public static func write(_ run: CaptureRun, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: url(in: directory), options: .atomic)
    }

    /// Absent is not an error: a source directory captured before this existed, or
    /// filled by `extract` from an xcresult, simply has nothing to say.
    public static func read(from directory: URL) -> CaptureRun? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureRun.self, from: data)
    }
}
