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

        /// The same paths with this device's directory level appended — or unchanged,
        /// when the device has no slug. That is the whole flat-vs-nested difference.
        func scoped(to device: Config.ResolvedDevice) -> PathValues {
            guard let slug = device.slug else { return self }
            return PathValues(
                source: source + "/" + slug,
                golden: golden + "/" + slug,
                diff: diff.map { $0 + "/" + slug })
        }
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
        let wait: Bool
        let waitTimeout: Double
        let foregroundLaunch: Bool
        let readyFile: Bool
        let readyArg: String
        /// iOS only: restrict the run to one entry of `devices[]`.
        let device: String?
        /// iOS only: `simctl erase` each device before booting it.
        let erase: Bool

        init(
            app: String, out: String, screens: [String], appearances: [String],
            extraArgs: String, settle: Double, settleMax: Double, timings: Bool,
            config: String?, wait: Bool, waitTimeout: Double, foregroundLaunch: Bool,
            readyFile: Bool, readyArg: String, device: String?, erase: Bool
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
            self.wait = wait
            self.waitTimeout = waitTimeout
            self.foregroundLaunch = foregroundLaunch
            self.readyFile = readyFile
            self.readyArg = readyArg
            self.device = device
            self.erase = erase
        }
    }

    struct CheckOptions {
        let paths: PathValues
        let tolerance: Double
        let config: String?
        let json: Bool
        let requireManifest: Bool
        let device: String?

        init(
            paths: PathValues, tolerance: Double, config: String?, json: Bool,
            requireManifest: Bool, device: String?
        ) {
            self.paths = paths
            self.tolerance = tolerance
            self.config = config
            self.json = json
            self.requireManifest = requireManifest
            self.device = device
        }
    }

    struct AppStoreOptions {
        let config: String
        let source: String
        let out: String
        /// Which device slug to compose, or nil for all of them. Always nil on Mac,
        /// which has no device axis.
        let device: String?

        init(config: String, source: String, out: String, device: String?) {
            self.config = config
            self.source = source
            self.out = out
            self.device = device
        }
    }

    struct WebsiteOptions {
        let config: String
        let source: String
        let out: String
        let appearance: String
        let maxWidth: Int
        let device: String?

        init(
            config: String, source: String, out: String, appearance: String, maxWidth: Int,
            device: String?
        ) {
            self.config = config
            self.source = source
            self.out = out
            self.appearance = appearance
            self.maxWidth = maxWidth
            self.device = device
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

        // Which driver runs is the config's decision, not a flag's. A `--platform ios`
        // that could disagree with the `output` size the config declares would be two
        // sources of truth for one fact, and the failure would land as a store
        // rejection rather than as an error here.
        if let path = options.config {
            let config = try Config.load(URL(fileURLWithPath: path))
            if config.resolvedPlatform == .ios {
                return try await captureIOS(options, parsed: parsed, config: config)
            }
        }

        let captureOptions = Capture.Options(
            app: URL(fileURLWithPath: options.app),
            outDir: URL(fileURLWithPath: options.out),
            screens: parsed,
            appearances: options.appearances,
            extraArgs: options.extraArgs.split(separator: " ").map(String.init),
            readyArg: options.readyArg,
            useReadyFile: options.readyFile,
            settle: options.settle,
            settleMax: options.settleMax,
            wait: options.wait,
            waitTimeout: options.waitTimeout,
            foregroundLaunch: options.foregroundLaunch)

        let shots = try await Capture.run(captureOptions) { shot in
            let mark = shot.settled ? "✓" : "!"
            print("  \(mark) \(shot.url.lastPathComponent)  (\(shot.size.description))")
        } onLockWait: { held, waited in
            // stderr, not stdout: being blocked is not part of a run's output, and an
            // agent parsing progress should not have to filter it out. Naming the
            // holder is the point — "in progress" without a name is what cost a `ps`.
            let who =
                held.holder.map(\.summary) ?? held.pid.map { "pid \($0)" } ?? "another capture run"
            let line =
                waited < 1
                ? "⏳ waiting for \(who)"
                : "⏳ still waiting for \(who) — \(CaptureLock.duration(waited)) so far"
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }

        print("\n✅ captured \(shots.count) screenshot(s) into \(options.out)")
        report(shots: shots, options: options)
    }

    /// What a capture says about itself once the images are written.
    ///
    /// Shared by both drivers deliberately: these three findings — a capture that never
    /// settled, an unexpected size group, where the time went — are properties of the
    /// *result*, not of how it was obtained, and letting them drift apart per platform
    /// is how one driver quietly stops reporting the thing the other does.
    static func report(shots: [Capture.Shot], options: CaptureOptions) {
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
        //
        // On iOS an extra group means something else and is worth knowing: the devices
        // disagreed about their own screen size, which is a wrong device in devices[].
        let groups = Dictionary(grouping: shots) { $0.size.description }
        print("\nWindow sizes:")
        for (size, group) in groups.sorted(by: { $0.key < $1.key }) {
            print("  \(group.count) x \(size)")
        }

        if options.timings {
            print("")
            for line in timingReport(shots, settle: options.settle) { print(line) }
        }
    }

    /// The iOS leg: one simulator per device, each writing into its own directory.
    ///
    /// Sequential rather than concurrent even though the per-device lock would allow
    /// overlap — two simulators booting and screenshotting at once is a lot of machine,
    /// and the failure mode (a frame poll starved of CPU reads as "never settled") would
    /// look like a flaky app rather than a busy Mac.
    private static func captureIOS(
        _ options: CaptureOptions, parsed: [Capture.Screen], config: Config
    ) async throws {
        let devices = try devices(of: config, only: options.device)

        var all: [Capture.Shot] = []
        for device in devices {
            heading(device)
            let outDir = device.directory(under: URL(fileURLWithPath: options.out))

            let shots = try await Simulator.run(
                Simulator.Options(
                    app: URL(fileURLWithPath: options.app),
                    outDir: outDir,
                    device: device,
                    screens: parsed.filter { screen in
                        // A device may ship a subset of screens[]; capturing the others
                        // onto it would write files its own config says nothing about.
                        device.screens.contains { $0.id == screen.name }
                    },
                    appearances: options.appearances,
                    extraArgs: options.extraArgs.split(separator: " ").map(String.init),
                    settle: options.settle,
                    settleMax: options.settleMax,
                    erase: options.erase)
            ) { held, waited in
                let who =
                    held.holder.map(\.summary) ?? held.pid.map { "pid \($0)" }
                    ?? "another capture run"
                FileHandle.standardError.write(
                    Data("⏳ waiting for \(who) — \(CaptureLock.duration(waited)) so far\n".utf8))
            } progress: { shot in
                let mark = shot.settled ? "✓" : "!"
                print("  \(mark) \(shot.url.lastPathComponent)  (\(shot.size.description))")
            }
            all.append(contentsOf: shots)
        }

        print("\n✅ captured \(all.count) screenshot(s) into \(options.out)")
        report(shots: all, options: options)
    }

    /// The settle defaults were reasoned from the shape of the capture loop, never
    /// measured against a real app. This is what closes that gap: it says where the
    /// time actually goes, and — via the frame count — whether the poll is doing
    /// anything or the floor is simply covering everything.
    ///
    /// Returns lines rather than printing them, so the report can be asserted on
    /// without a window server. It is otherwise unreachable in a test: producing a
    /// single real `Timings` costs a permission grant and the pointer, which is how
    /// a report nobody can run ships with its formatting never once executed.
    static func timingReport(_ shots: [Capture.Shot], settle: Double) -> [String] {
        guard let profile = Capture.profile(shots.map(\.timings)) else { return [] }

        // Header labels are right-aligned to the same widths the rows format to, so
        // the columns cannot drift apart when one of them is edited.
        func right(_ text: String, _ width: Int) -> String {
            String(repeating: " ", count: max(0, width - text.count)) + text
        }

        var lines = [
            String(
                format: "Timing — %d shot(s), %.1fs total, %.2fs/shot:",
                profile.shots, profile.total, profile.total / Double(profile.shots)),
            "  " + "phase".padding(toLength: 10, withPad: " ", startingAt: 0)
                + " " + right("median", 7) + "   " + right("worst", 7) + "   " + right("share", 5),
        ]
        for phase in profile.phases {
            // Padded in Swift rather than with %s: that takes a C string, and the
            // pointer from a bridged temporary is not guaranteed to outlive the call.
            let name = phase.name.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append(
                String(
                    format: "  %@ %6.2fs   %6.2fs   %4.0f%%",
                    name, phase.median, phase.worst, phase.share * 100))
        }
        lines.append("  frames      \(profile.framesMedian) median, \(profile.framesWorst) worst")

        // What to do with the numbers, since the point of collecting them is a
        // decision. The floor is the only knob a reader can act on immediately.
        let floor = profile.phases.first { $0.name == "floor" }
        let ready = profile.phases.first { $0.name == "ready" }

        // With a ready signal there is no floor left to tune, and the advice below
        // would be nonsense. What replaced it is worth naming: this is the number
        // --settle was a guess at, measured instead of padded.
        if let ready, ready.median > 0 {
            lines.append(
                String(
                    format: "  → the app signalled ready after %.2fs (worst %.2fs). That is what a "
                        + "fixed --settle was guessing at.", ready.median, ready.worst))
        }
        if profile.framesMedian <= Capture.pollMatches + 1, (floor?.median ?? 0) > 0 {
            lines.append(
                String(
                    format: "  → the typical window was already still on arrival, so the %.1fs "
                        + "floor — not the poll — is what each shot costs. Lower --settle "
                        + "until a screen starts capturing early.", settle))
        }
        // Contention reads as an inexplicably slow run otherwise: the shots are the
        // same shots, they just took turns with another project.
        if let lock = profile.phases.first(where: { $0.name == "lock" }), lock.share > 0.05 {
            lines.append(
                String(
                    format: "  → %.0f%% of the run was spent waiting for another capture run. "
                        + "Nothing here is tunable — the machine has one active app.",
                    lock.share * 100))
        }
        if let poll = profile.phases.first(where: { $0.name == "poll" }), poll.share > 0.5 {
            lines.append(
                "  → the poll dominates. If windows are settling, the per-frame capture "
                    + "cost is the thing to attack, not --settle.")
        }
        let overhead = profile.phases
            .filter { ["launch", "window", "teardown"].contains($0.name) }
            .reduce(0) { $0 + $1.share }
        if overhead > 0.5 {
            lines.append(
                String(
                    format: "  → %.0f%% of the run is launching and killing the app, not "
                        + "waiting for it to draw. Settle tuning cannot help that.",
                    overhead * 100))
        }
        return lines
    }

    /// The gate, in either of its two voices.
    ///
    /// `--json` is not a second implementation: the same comparison runs, and only the
    /// rendering differs. Anything that fails *before* the comparison is caught here and
    /// rendered into the document too, so a caller in JSON mode always gets exactly one
    /// parseable line — never prose on one run and JSON on the next.
    static func check(_ options: CheckOptions) throws {
        do {
            try compare(options)
        } catch let error as AppShotError where options.json {
            CheckReport(error: error, paths: options.paths, tolerance: options.tolerance).emit()
            throw ExitCode.failure
        }
    }

    private static func compare(_ options: CheckOptions) throws {
        // A device axis means a gate per device: each has its own captures, its own
        // goldens, its own manifest and its own ignore rects. Failing on the first
        // device would hide the second's regressions behind it, so every device is
        // compared and the verdicts are combined at the end.
        guard let configPath = options.config else {
            try compareOne(options, device: nil, paths: options.paths)
            return
        }

        let config = try Config.load(URL(fileURLWithPath: configPath))
        let devices = try devices(of: config, only: options.device)
        var failed = false

        for device in devices {
            let paths = options.paths.scoped(to: device)
            if devices.count > 1, !options.json { heading(device) }
            do {
                try compareOne(options, device: device, paths: paths, config: config)
            } catch is ExitCode {
                failed = true
            } catch let error as CLIError {
                // Report it here rather than throwing, so the remaining devices still
                // get compared — the whole point of running them all.
                FileHandle.standardError.write(Data("\(error.description)\n".utf8))
                failed = true
            }
        }
        if failed { throw ExitCode.failure }
    }

    @discardableResult
    private static func compareOne(
        _ options: CheckOptions,
        device: Config.ResolvedDevice?,
        paths: PathValues,
        config: Config? = nil
    ) throws -> Bool {
        // Before the goldens, because the goldens cannot see this: a screen missing
        // from the captures *and* the goldens agrees with itself. Only the config knows
        // the set was meant to be bigger. Naming the screens beats counting them —
        // "readiness~dark.png is missing" is actionable, "found 15, expected 16" is not.
        if let config {
            let expected =
                device.map { $0.expectedCaptures(appearances: config.appearances) }
                ?? config.expectedCaptures()
            let missing = try Gate.missing(expected, in: paths.sourceURL)
            guard missing.isEmpty else {
                throw AppShotError.missingCaptures(missing, dir: paths.sourceURL)
            }
        }

        let report = try Gate.compare(
            candidateDir: paths.sourceURL,
            goldenDir: paths.goldenURL,
            options: Gate.Options(
                tolerance: options.tolerance,
                diffDir: paths.diffURL,
                requireManifest: options.requireManifest,
                ignore: device?.ignore ?? []))

        if options.json {
            CheckReport(report: report, paths: paths, device: device?.slug).emit()
            guard report.passed else { throw ExitCode.failure }
            return true
        }

        // Ignore rects weaken the gate by construction, so what they cost is stated
        // every run rather than left in the config for someone to find later.
        if report.ignoredPixels > 0 {
            print(
                String(
                    format: "  ignoring %d px per capture (%.3f%% of the canvas) in %d region(s)",
                    report.ignoredPixels, report.ignoredFraction * 100,
                    device?.ignore.count ?? 0))
        }

        // A warning, not a failure: a project that predates the manifest must keep
        // working. But an unsealed baseline is one nothing can vouch for, and staying
        // silent about that is how a golden set gets quietly rewritten and nobody
        // finds out for weeks.
        if !report.sealed {
            FileHandle.standardError.write(
                Data(
                    """
                    ⚠️  the goldens in \(paths.golden) are not sealed — nothing can tell an \
                    accepted baseline from one that was edited or overwritten.
                        Seal them once you are satisfied they are right:  appshot seal \
                    --golden \(paths.golden)

                    """.utf8))
        }

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
        return true
    }

    static func appStore(_ options: AppStoreOptions) throws {
        let config = try loadConfig(options.config)
        var total = 0

        for device in try devices(of: config, only: options.device) {
            heading(device)
            let outputs = try Compose.appStore(
                config: config,
                device: device,
                sourceDir: device.directory(under: URL(fileURLWithPath: options.source)),
                outDir: device.directory(under: URL(fileURLWithPath: options.out)),
                warnings: { FileHandle.standardError.write(Data("⚠️  \($0)\n".utf8)) })

            for output in outputs {
                print(
                    "✅ \(output.url.lastPathComponent)  "
                        + "(\(output.size.description), window \(output.windowSize.description))")
            }
            total += outputs.count
        }
        print("\n\(total) App Store visual(s) written to \(options.out)")
    }

    static func website(_ options: WebsiteOptions) throws {
        let config = try loadConfig(options.config)
        var total = 0

        for device in try devices(of: config, only: options.device) {
            heading(device)
            let outputs = try Compose.website(
                config: config,
                device: device,
                sourceDir: device.directory(under: URL(fileURLWithPath: options.source)),
                outDir: device.directory(under: URL(fileURLWithPath: options.out)),
                appearances: Pipeline.appearances(from: options.appearance),
                maxWidth: options.maxWidth)

            for output in outputs {
                print("✅ \(output.url.lastPathComponent)  (\(output.size.description))")
            }
            total += outputs.count
        }
        print("\n\(total) website capture(s) written to \(options.out)")
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

    /// The devices a leg should run over, narrowed by `--device` if given.
    ///
    /// A Mac config yields exactly one device with no slug, so every leg walks the same
    /// loop and the flat directory layout is what falls out — rather than being a second
    /// code path that has to be kept in step with the first.
    static func devices(
        of config: Config, only requested: String? = nil
    ) throws -> [Config.ResolvedDevice] {
        let all = try config.resolvedDevices()
        guard let requested else { return all }
        guard let match = all.first(where: { $0.slug == requested }) else {
            throw AppShotError.unknownDevice(
                requested, known: all.compactMap(\.slug))
        }
        return [match]
    }

    /// The (device, paths) pairs a leg should walk.
    ///
    /// One pair with a nil device when there is no config or no device axis, so a leg
    /// written against this walks a Mac project exactly as it always did. Used by the
    /// legs that take no config of their own — `accept`, `seal`, `selftest` — which
    /// would otherwise look for PNGs in a directory that only holds device folders and
    /// report "did capture run?" about a capture that ran perfectly well.
    static func devicePaths(
        config: String?, device requested: String?, paths: PathValues
    ) throws -> [(device: Config.ResolvedDevice?, paths: PathValues)] {
        guard let config else { return [(nil, paths)] }
        let loaded = try Config.load(URL(fileURLWithPath: config))
        return try devices(of: loaded, only: requested).map { device in
            (device.slug == nil ? nil : device, paths.scoped(to: device))
        }
    }

    /// Name the device when there is a device axis at all. A Mac run has no slug and so
    /// prints no header — its output is byte-for-byte what it was before iOS existed.
    static func heading(_ device: Config.ResolvedDevice) {
        guard let slug = device.slug else { return }
        print("\n\(slug) (\(device.output.description)):")
    }

    /// "light, dark" → ["light", "dark"]. Tolerates spaces and a trailing comma;
    /// `Compose.website` rejects an empty list and any name the config doesn't declare.
    static func appearances(from raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
