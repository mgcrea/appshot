import AppShotKit
import ArgumentParser
import Foundation

@main
struct AppShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appshot",
        abstract: "App Store screenshot pipeline for Mac apps: capture, gate, compose.",
        /// Keep in step with the git tag — the constant lives in AppShotKit because
        /// the capture lock and the golden manifest stamp it into files that outlive
        /// the run. `make install` prints it, so a stale value is visible at install
        /// time rather than months later in a drifted golden.
        version: AppShotVersion.current,
        subcommands: [
            Run.self,
            CaptureCommand.self,
            Extract.self,
            Check.self,
            Accept.self,
            Seal.self,
            SelfTest.self,
            Compose_.self,
            Doctor.self,
        ]
    )
}

// MARK: - Shared options

/// One home for every option default. `run` re-declares the knobs its legs own, so a
/// literal written twice is a `--help` that lies: `appshot run --max-width` and
/// `appshot compose both --max-width` would document different numbers and nothing
/// would catch it. `runAndBothAgreeOnDefaults` guards the pairs this enum can't merge.
enum Defaults {
    static let tolerance = Gate.defaultTolerance
    static let appearance = "dark"
    static let maxWidth = 2560
    static let source = "screenshots/source"
    static let golden = "screenshots/golden"
    static let appstoreOut = "screenshots/appstore"
    static let config = "screenshots/screenshots.config.json"
    static let settle = Capture.defaultSettle
    static let settleMax = Capture.defaultSettleMax
    static let appearances = ["dark", "light"]
    static let readyArg = "-ScreenshotReadyFile"
}

struct PathOptions: ParsableArguments {
    @Option(name: .long, help: "Directory of freshly captured PNGs.")
    var source: String = Defaults.source

    @Option(name: .long, help: "Directory of accepted golden PNGs.")
    var golden: String = Defaults.golden

    @Option(name: .long, help: "Where to write visual diffs.")
    var diff: String?

    var sourceURL: URL { URL(fileURLWithPath: source) }
    var goldenURL: URL { URL(fileURLWithPath: golden) }
    var diffURL: URL? { diff.map { URL(fileURLWithPath: $0) } }

    var values: Pipeline.PathValues {
        Pipeline.PathValues(source: source, golden: golden, diff: diff)
    }
}

// MARK: - check

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fail if the captures drifted from the goldens.")

    @OptionGroup var paths: PathOptions

    @Option(help: "Max fraction of changed pixels.")
    var tolerance: Double = Defaults.tolerance

    @Option(help: "Path to screenshots.config.json; omitted ⇒ skip the set check.")
    var config: String?

    @Flag(
        help: """
            Report the verdict as one JSON document on stdout, for a script or an agent \
            driving this. Exit codes are unchanged.
            """)
    var json = false

    @Flag(help: "Fail if the goldens carry no manifest (see `appshot seal`).")
    var requireManifest = false

    @OptionGroup var dev: DeviceOption

    func run() throws {
        try Pipeline.check(
            Pipeline.CheckOptions(
                paths: paths.values, tolerance: tolerance, config: config, json: json,
                requireManifest: requireManifest, device: dev.device))
    }
}

// MARK: - seal

struct Seal: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record what the goldens are, so a later change to them is visible.",
        discussion: """
            `accept` seals automatically. Run this once by hand to adopt goldens that \
            predate the manifest, or deliberately after an out-of-band change you have \
            reviewed and want to keep.

            The manifest is a text file inside the golden directory. Commit it with them: \
            it travels with the baseline, which is what lets `check` tell a `git lfs pull` \
            or a branch switch from something that actually rewrote the images.
            """)

    @OptionGroup var paths: PathOptions

    func run() throws {
        let existing = try? GoldenManifest.load(in: paths.goldenURL)
        let manifest = try GoldenManifest.seal(goldenDir: paths.goldenURL)

        if let previous = (existing ?? nil)?.accepted {
            print("Previously sealed \(previous.summary)")
        }
        print("✓ sealed \(manifest.entries.count) golden(s) in \(paths.golden)")
        print("  Commit \(GoldenManifest.url(in: paths.goldenURL).path) alongside them.")
    }
}

// MARK: - accept

struct Accept: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Accept the current captures as the new goldens.")

    @OptionGroup var paths: PathOptions

    @Flag(help: "Drop goldens that have no candidate (a removed screen).")
    var prune = false

    func run() throws {
        let (accepted, orphans) = try Gate.accept(
            candidateDir: paths.sourceURL,
            goldenDir: paths.goldenURL,
            prune: prune)

        guard orphans.isEmpty else {
            throw CLIError(
                """
                refusing to accept — these goldens have no candidate:
                \(orphans.map { "   • \($0)" }.joined(separator: "\n"))

                The capture may have stopped early. Re-capture, or pass --prune if the \
                screens were removed on purpose.
                """)
        }
        print("✓ accepted \(accepted) golden(s) in \(paths.golden)")
    }
}

// MARK: - selftest

struct SelfTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest",
        abstract: "Prove the golden gate actually fails when it should.")

    @OptionGroup var paths: PathOptions

    func run() throws {
        let results = try GateSelfTest.run(goldenDir: paths.goldenURL)
        print("Self-testing the golden gate against synthesized mutants:")
        for result in results {
            let icon =
                switch result.verdict {
                case .ok: "✅"
                case .failed: "❌"
                // Not ✅. A check that could not be posed has proven nothing, and
                // rendering it as a pass is how a self-test starts overstating what it
                // established — which is the exact failure this command exists to catch.
                case .skipped: "⊘"
                }
            let name = result.name.padding(toLength: 38, withPad: " ", startingAt: 0)
            print("  \(icon) \(name)\(result.detail)")
        }

        let failed = results.filter { $0.verdict == .failed }
        guard failed.isEmpty else {
            throw CLIError(
                "\n\(failed.count) of \(results.count) mutants got the wrong verdict — "
                    + "the gate is not trustworthy")
        }

        let proven = results.filter { $0.verdict == .ok }.count
        let skipped = results.count - proven
        if skipped > 0 {
            print(
                "\n✅ the gate reaches the right verdict on \(proven) of \(results.count) "
                    + "mutants (\(skipped) could not be posed against these goldens)")
        } else {
            print("\n✅ the gate reaches the right verdict on all \(results.count) mutants")
        }
    }
}

// MARK: - Errors

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
