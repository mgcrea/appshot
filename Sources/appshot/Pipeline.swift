import AppShotKit
import ArgumentParser
import Foundation

/// The work each command does, as plain functions over plain values.
///
/// The invariant this file exists to enforce: **no `ParsableCommand` is ever constructed
/// outside ArgumentParser's parser.** `run` used to orchestrate by instantiating `Check()`
/// and `Both()` and assigning their properties one by one. That reads as a memberwise copy
/// but isn't one — a declared default is stored as an unparsed *definition*, so any property
/// the caller forgot to assign trapped on read and exited(1). Nothing checked the copy was
/// exhaustive, and the failure landed 90 seconds in, after the capture was already paid for.
///
/// Hence the option structs below, whose memberwise inits deliberately declare **no default
/// parameter values**: adding a knob to a command must fail to compile at every construction
/// site. That, not the tests, is what keeps this fixed. Do not write `= 2560` into one of
/// these inits, however natural it looks next to the `@Option` that already declares it.
///
/// These stay in the CLI target rather than AppShotKit on purpose: they print, and AppShotKit
/// is the half that never does (see Package.swift).
enum Pipeline {

    // MARK: - Options

    /// A `PathOptions` that has been parsed, reduced to values. `PathOptions` is itself
    /// `ParsableArguments`, so it cannot be constructed off the parse path either.
    struct PathValues {
        let source: String
        let golden: String
        let diff: String?

        init(source: String, golden: String, diff: String?) {
            self.source = source
            self.golden = golden
            self.diff = diff
        }

        var sourceURL: URL { URL(fileURLWithPath: source) }
        var goldenURL: URL { URL(fileURLWithPath: golden) }
        var diffURL: URL? { diff.map { URL(fileURLWithPath: $0) } }
    }

    struct CaptureOptions {
        let app: String
        let out: String
        let screens: [String]
        let appearances: [String]
        let extraArgs: String
        let settle: Double
        let settleMax: Double
        let timings: Bool
        let config: String?

        init(
            app: String, out: String, screens: [String], appearances: [String],
            extraArgs: String, settle: Double, settleMax: Double, timings: Bool,
            config: String?
        ) {
            self.app = app
            self.out = out
            self.screens = screens
            self.appearances = appearances
            self.extraArgs = extraArgs
            self.settle = settle
            self.settleMax = settleMax
            self.timings = timings
            self.config = config
        }
    }

    struct CheckOptions {
        let paths: PathValues
        let tolerance: Double
        let config: String?

        init(paths: PathValues, tolerance: Double, config: String?) {
            self.paths = paths
            self.tolerance = tolerance
            self.config = config
        }
    }

    struct AppStoreOptions {
        let config: String
        let source: String
        let out: String

        init(config: String, source: String, out: String) {
            self.config = config
            self.source = source
            self.out = out
        }
    }

    struct WebsiteOptions {
        let config: String
        let source: String
        let out: String
        let appearance: String
        let maxWidth: Int

        init(config: String, source: String, out: String, appearance: String, maxWidth: Int) {
            self.config = config
            self.source = source
            self.out = out
            self.appearance = appearance
            self.maxWidth = maxWidth
        }
    }

    /// `website` nil ⇒ skip the site leg, which is what `--website-out` omitted means.
    struct ComposeOptions {
        let appStore: AppStoreOptions
        let website: WebsiteOptions?

        init(appStore: AppStoreOptions, website: WebsiteOptions?) {
            self.appStore = appStore
            self.website = website
        }
    }

    struct Plan {
        let capture: CaptureOptions
        let check: CheckOptions
        let compose: ComposeOptions

        init(capture: CaptureOptions, check: CheckOptions, compose: ComposeOptions) {
            self.capture = capture
            self.check = check
            self.compose = compose
        }
    }

    // MARK: - Legs

    static func capture(_ options: CaptureOptions) async throws {
        let parsed = try options.screens.map(Capture.Screen.init(spec:))

        // A capture is named for its screen, and the config keys everything downstream
        // off screens[].id. If the two lists disagree, the run still "succeeds" — it just
        // writes files nothing expects and omits ones everything does, and you find out
        // two steps later. Cheaper to say so before spending 90s seizing the screen.
        if let config = options.config {
            let cfg = try Config.load(URL(fileURLWithPath: config))
            let declared = Set(cfg.screens.map(\.id))
            let capturing = Set(parsed.map(\.name))

            let unknown = capturing.subtracting(declared).sorted()
            let uncaptured = declared.subtracting(capturing).sorted()
            guard unknown.isEmpty && uncaptured.isEmpty else {
                var message = "--screens and \(config) disagree:\n"
                for name in unknown {
                    message += "   • \(name): captured, but no screens[].id — nothing will use it\n"
                }
                for name in uncaptured {
                    message += "   • \(name): in screens[], but not captured — it will be missing\n"
                }
                throw CLIError(message)
            }
        }

        // Per-screen settles are invisible in the output otherwise: a screen with a
        // long one just looks slow, and one with a short one just looks flaky.
        let overrides = parsed.compactMap { screen in
            screen.settle.map { "\(screen.name) \($0)s" }
        }
        if !overrides.isEmpty {
            print("Settle \(options.settle)s, except: \(overrides.joined(separator: ", "))")
        }

        let captureOptions = Capture.Options(
            app: URL(fileURLWithPath: options.app),
            outDir: URL(fileURLWithPath: options.out),
            screens: parsed,
            appearances: options.appearances,
            extraArgs: options.extraArgs.split(separator: " ").map(String.init),
            settle: options.settle,
            settleMax: options.settleMax)

        let shots = try await Capture.run(captureOptions) { shot in
            let mark = shot.settled ? "✓" : "!"
            print("  \(mark) \(shot.url.lastPathComponent)  (\(shot.size.description))")
        }

        print("\n✅ captured \(shots.count) screenshot(s) into \(options.out)")

        // Never settling is not a failure — the image may well be fine — but it is the
        // one thing the gate cannot tell you later. A window still animating at the
        // ceiling captures at an arbitrary point in that animation, so it disagrees
        // with its golden on some runs and not others, and reads as flakiness.
        let restless = shots.filter { !$0.settled }
        if !restless.isEmpty {
            let names = restless.map { "\($0.name)~\($0.appearance)" }.sorted()
            FileHandle.standardError.write(
                Data(
                    """
                    ⚠️  \(restless.count) capture(s) never held still within \
                    \(options.settleMax)s: \(names.joined(separator: ", "))
                        Something is still moving — a spinner outliving its data, a live \
                        clock, an animation. These will gate flakily.

                    """.utf8))
        }

        // Sizes must be stable and intentional — not necessarily identical, since a
        // panel is legitimately smaller. The golden gate will NOT catch a
        // wrong-but-stable size: it matches its own golden run after run. Expect one
        // group per intended window size; an unexplained extra group is the bug.
        let groups = Dictionary(grouping: shots) { $0.size.description }
        print("\nWindow sizes:")
        for (size, group) in groups.sorted(by: { $0.key < $1.key }) {
            print("  \(group.count) x \(size)")
        }

        if options.timings { printTimings(shots, settle: options.settle) }
    }

    /// The settle defaults were reasoned from the shape of the capture loop, never
    /// measured against a real app. This is what closes that gap: it says where the
    /// time actually goes, and — via the frame count — whether the poll is doing
    /// anything or the floor is simply covering everything.
    static func printTimings(_ shots: [Capture.Shot], settle: Double) {
        guard let profile = Capture.profile(shots.map(\.timings)) else { return }

        print(
            String(
                format: "\nTiming — %d shot(s), %.1fs total, %.2fs/shot:",
                profile.shots, profile.total, profile.total / Double(profile.shots)))
        print("  phase       median    worst     share")
        for phase in profile.phases {
            print(
                String(
                    format: "  %-10s %6.2fs   %6.2fs   %4.0f%%",
                    (phase.name as NSString).utf8String!, phase.median, phase.worst,
                    phase.share * 100))
        }
        print("  frames      \(profile.framesMedian) median, \(profile.framesWorst) worst")

        // What to do with the numbers, since the point of collecting them is a
        // decision. The floor is the only knob a reader can act on immediately.
        let minimumFrames = Capture.pollMatches + 1
        if profile.framesMedian <= minimumFrames {
            print(
                String(
                    format: """
                          → the typical window was already still on arrival, so the \
                        %.1fs floor — not the poll — is what each shot costs. Lower \
                        --settle until a screen starts capturing early.
                        """, settle))
        }
        if let poll = profile.phases.first(where: { $0.name == "poll" }), poll.share > 0.5 {
            print(
                "  → the poll dominates. If windows are settling, the per-frame capture "
                    + "cost is the thing to attack, not --settle.")
        }
        let overhead = profile.phases
            .filter { ["launch", "window", "teardown"].contains($0.name) }
            .reduce(0) { $0 + $1.share }
        if overhead > 0.5 {
            print(
                String(
                    format: """
                          → %.0f%% of the run is launching and killing the app, not \
                        waiting for it to draw. Settle tuning cannot help that.
                        """, overhead * 100))
        }
    }

    static func check(_ options: CheckOptions) throws {
        let paths = options.paths

        // Before the goldens, because the goldens cannot see this: a screen missing
        // from the captures *and* the goldens agrees with itself. Only the config knows
        // the set was meant to be bigger. Naming the screens beats counting them —
        // "readiness~dark.png is missing" is actionable, "found 15, expected 16" is not.
        if let config = options.config {
            let expected = try Config.load(URL(fileURLWithPath: config)).expectedCaptures()
            let missing = try Gate.missing(expected, in: paths.sourceURL)
            guard missing.isEmpty else {
                throw AppShotError.missingCaptures(missing, dir: paths.sourceURL)
            }
        }

        let report = try Gate.compare(
            candidateDir: paths.sourceURL,
            goldenDir: paths.goldenURL,
            options: Gate.Options(tolerance: options.tolerance, diffDir: paths.diffURL))

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

        print(
            String(
                format: "✓ %d screenshot(s) match their goldens (tolerance %.3f%%)",
                report.matched, options.tolerance * 100))
    }

    static func appStore(_ options: AppStoreOptions) throws {
        let config = try loadConfig(options.config)
        let outputs = try Compose.appStore(
            config: config,
            sourceDir: URL(fileURLWithPath: options.source),
            outDir: URL(fileURLWithPath: options.out),
            warnings: { FileHandle.standardError.write(Data("⚠️  \($0)\n".utf8)) })

        for output in outputs {
            print(
                "✅ \(output.url.lastPathComponent)  "
                    + "(\(output.size.description), window \(output.windowSize.description))")
        }
        print("\n\(outputs.count) App Store visual(s) written to \(options.out)")
    }

    static func website(_ options: WebsiteOptions) throws {
        let config = try loadConfig(options.config)
        let outputs = try Compose.website(
            config: config,
            sourceDir: URL(fileURLWithPath: options.source),
            outDir: URL(fileURLWithPath: options.out),
            appearances: Pipeline.appearances(from: options.appearance),
            maxWidth: options.maxWidth)

        for output in outputs {
            print("✅ \(output.url.lastPathComponent)  (\(output.size.description))")
        }
        print("\n\(outputs.count) website capture(s) written to \(options.out)")
    }

    static func compose(_ options: ComposeOptions) throws {
        try appStore(options.appStore)

        guard let site = options.website else { return }
        print("")
        try website(site)
    }

    static func execute(_ plan: Plan) async throws {
        try await capture(plan.capture)
        print("")
        try check(plan.check)
        print("")
        try compose(plan.compose)
    }

    // MARK: - Helpers

    static func loadConfig(_ path: String) throws -> Config {
        let config = try Config.load(URL(fileURLWithPath: path))
        try config.validate()
        return config
    }

    /// "light, dark" → ["light", "dark"]. Tolerates spaces and a trailing comma;
    /// `Compose.website` rejects an empty list and any name the config doesn't declare.
    static func appearances(from raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
