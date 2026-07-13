import AppShotKit
import ArgumentParser
import Foundation

@main
struct AppShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appshot",
        abstract: "App Store screenshot pipeline for Mac apps: capture, gate, compose.",
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

struct PathOptions: ParsableArguments {
    @Option(name: .long, help: "Directory of freshly captured PNGs.")
    var source: String = "screenshots/source"

    @Option(name: .long, help: "Directory of accepted golden PNGs.")
    var golden: String = "screenshots/golden"

    @Option(name: .long, help: "Where to write visual diffs.")
    var diff: String?

    var sourceURL: URL { URL(fileURLWithPath: source) }
    var goldenURL: URL { URL(fileURLWithPath: golden) }
    var diffURL: URL? { diff.map { URL(fileURLWithPath: $0) } }
}

// MARK: - check

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fail if the captures drifted from the goldens.")

    @OptionGroup var paths: PathOptions

    @Option(help: "Max fraction of changed pixels.")
    var tolerance: Double = Gate.defaultTolerance

    @Option(help: "Path to screenshots.config.json; omitted ⇒ skip the set check.")
    var config: String?

    func run() throws {
        // Before the goldens, because the goldens cannot see this: a screen missing
        // from the captures *and* the goldens agrees with itself. Only the config knows
        // the set was meant to be bigger. Naming the screens beats counting them —
        // "readiness~dark.png is missing" is actionable, "found 15, expected 16" is not.
        if let config {
            let expected = try Config.load(URL(fileURLWithPath: config)).expectedCaptures()
            let missing = try Gate.missing(expected, in: paths.sourceURL)
            guard missing.isEmpty else {
                throw AppShotError.missingCaptures(missing, dir: paths.sourceURL)
            }
        }

        let report = try Gate.compare(
            candidateDir: paths.sourceURL,
            goldenDir: paths.goldenURL,
            options: Gate.Options(tolerance: tolerance, diffDir: paths.diffURL))

        guard report.passed else {
            var out = ""

            // First: this one is not drift, it's a broken capture. Accepting it would
            // bury it in the baseline, so say so before offering `accept` below.
            if !report.duplicates.isEmpty {
                out += "Duplicate captures: \(report.duplicates.count) set(s)\n"
                for duplicate in report.duplicates {
                    out += "   ✗ \(duplicate.reason)\n"
                }
                out += "\nThis is a staging failure, not a visual change. Do not accept it.\n\n"
            }

            if !report.failures.isEmpty {
                out += "Screenshot regression: \(report.failures.count) problem(s)\n"
                for failure in report.failures {
                    out += "   ✗ \(failure.name): \(failure.reason)\n"
                    if let diff = failure.diffPath {
                        out += "     diff → \(diff.path)\n"
                    }
                }
                out += "\nReview the diffs, then accept deliberately with `appshot accept`."
            }
            throw CLIError(out)
        }

        print(String(
            format: "✓ %d screenshot(s) match their goldens (tolerance %.3f%%)",
            report.matched, tolerance * 100))
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
            throw CLIError("""
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
