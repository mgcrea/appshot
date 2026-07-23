import AppShotKit
import Foundation

/// `appshot check --json`, as a value.
///
/// The prose report is written for a person reading a terminal, and it will keep being
/// reworded. Something driving `check` — a script, an agent, a CI step — needs a verdict
/// it can read without matching on that prose; the alternative, observed in the wild, is
/// grepping for `✗` and a percentage and hoping neither ever changes.
///
/// Two rules this format keeps:
///
/// - **Always one document.** A failure *before* the comparison — a missing capture, an
///   LFS pointer, drifted goldens — populates `error` instead of escaping as text, so a
///   caller never has to handle "sometimes JSON, sometimes not".
/// - **Exit codes are unchanged.** Non-zero whenever `passed` is false, in both modes.
struct CheckReport: Encodable {
    /// Bumped when a field changes meaning, so a consumer can refuse a format it does
    /// not understand rather than silently misreading it.
    let schema = 1
    let passed: Bool
    let tolerance: Double
    let matched: Int
    /// Whether the goldens carry a manifest. `false` means nothing can vouch for the
    /// baseline this verdict is measured against — see `appshot seal`.
    let sealed: Bool
    let source: String
    let golden: String
    /// Keyed by capture filename: `browser~dark.png`.
    let screens: [String: Screen]
    let duplicates: [Duplicate]
    let error: Failure?

    struct Screen: Encodable {
        /// `match`, or the failure kind: `pixel_drift`, `size_changed`, `alpha_lost`,
        /// `alpha_drift`, `new_screen`, `missing_capture`.
        let status: String
        let reason: String?
        /// Present for `pixel_drift` only. Percent, not fraction — the same number the
        /// prose reports, so the two can never disagree.
        let pixelDiffPercent: Double?
        let diffPath: String?
    }

    struct Duplicate: Encodable {
        let names: [String]
        let reason: String
    }

    struct Failure: Encodable {
        let kind: String
        let message: String
    }

    // MARK: - Building

    init(report: Gate.Report, paths: Pipeline.PathValues) {
        var screens: [String: Screen] = [:]
        for name in report.matchedNames {
            screens[name] = Screen(
                status: "match", reason: nil, pixelDiffPercent: nil, diffPath: nil)
        }
        for failure in report.failures {
            screens[failure.name] = Screen(
                status: failure.kind.rawValue,
                reason: failure.reason,
                pixelDiffPercent: failure.pixelDiffFraction.map { $0 * 100 },
                diffPath: failure.diffPath?.path)
        }

        self.passed = report.passed
        self.tolerance = report.tolerance
        self.matched = report.matched
        self.sealed = report.sealed
        self.source = paths.source
        self.golden = paths.golden
        self.screens = screens
        self.duplicates = report.duplicates.map {
            Duplicate(names: $0.names, reason: $0.reason)
        }
        self.error = nil
    }

    /// The comparison never happened. Everything measurable is absent rather than
    /// guessed at — `passed: false` and an `error` saying why.
    init(error: Error, paths: Pipeline.PathValues, tolerance: Double) {
        self.passed = false
        self.tolerance = tolerance
        self.matched = 0
        // Whether a manifest *exists*, not whether it verifies — the error already
        // says the goldens drifted, and reporting `sealed: false` for a sealed set
        // that failed verification would contradict it.
        self.sealed = ((try? GoldenManifest.load(in: paths.goldenURL)) ?? nil) != nil
        self.source = paths.source
        self.golden = paths.golden
        self.screens = [:]
        self.duplicates = []
        self.error = Failure(
            kind: (error as? AppShotError)?.slug ?? "error",
            message: "\(error)")
    }

    // MARK: - Encoding

    /// Written out rather than synthesized for one reason: the synthesized encoder
    /// uses `encodeIfPresent` for optionals, so a clean run would *omit* `error`
    /// entirely. A caller reading `.error` would then see "absent" on success and
    /// "absent" on a malformed document, which are not the same thing. Every key is
    /// always present; `error` is explicitly null.
    enum CodingKeys: String, CodingKey {
        case schema, passed, tolerance, matched, sealed, source, golden
        case screens, duplicates, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(passed, forKey: .passed)
        try container.encode(tolerance, forKey: .tolerance)
        try container.encode(matched, forKey: .matched)
        try container.encode(sealed, forKey: .sealed)
        try container.encode(source, forKey: .source)
        try container.encode(golden, forKey: .golden)
        try container.encode(screens, forKey: .screens)
        try container.encode(duplicates, forKey: .duplicates)
        try container.encode(error, forKey: .error)
    }

    /// One line of JSON on stdout and nothing else, so `| jq` works and a partial
    /// write is not mistaken for a document.
    func emit() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
