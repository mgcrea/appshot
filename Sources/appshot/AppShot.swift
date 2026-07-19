import AppShotKit
import ArgumentParser
import Foundation

@main
struct AppShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appshot",
        abstract: "App Store screenshot pipeline for Mac apps: capture, gate, compose.",
        /// Keep in step with the git tag. A capture is only traceable to a build if
        /// `--version` reports one — and `make install` prints this, so a stale value
        /// is visible at install time rather than months later in a drifted golden.
        version: "0.2.0",
        subcommands: [
            Run.self,
            CaptureCommand.self,
            Extract.self,
            Check.self,
            Accept.self,
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

    func run() throws {
        try Pipeline.check(
            Pipeline.CheckOptions(paths: paths.values, tolerance: tolerance, config: config))
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
            let icon = result.ok ? "✅" : "❌"
            let name = result.name.padding(toLength: 38, withPad: " ", startingAt: 0)
            print("  \(icon) \(name)\(result.detail)")
        }

        let failed = results.filter { !$0.ok }
        guard failed.isEmpty else {
            throw CLIError(
                "\n\(failed.count) of \(results.count) mutants got the wrong verdict — "
                    + "the gate is not trustworthy")
        }
        print("\n✅ the gate reaches the right verdict on all \(results.count) mutants")
    }
}

// MARK: - Errors

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
