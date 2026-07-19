import AppShotKit
import ArgumentParser
import Foundation

// MARK: - capture

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Launch the app staged onto each screen and photograph its window.",
        discussion: """
            Takes over the pointer and the active app for its duration — don't use the \
            machine while it runs, and a stray click can land in a capture.

            Needs Screen Recording permission for the terminal running it (System \
            Settings → Privacy & Security). Nothing is granted to the app itself.
            """)

    @Option(help: "Path to the built .app bundle.")
    var app: String

    @Option(help: "Where to write the raw captures.")
    var out: String = Defaults.source

    @Option(
        parsing: .upToNextOption,
        help: "Screens as `name:stage` pairs (stage defaults to name).")
    var screens: [String]

    @Option(parsing: .upToNextOption, help: "Appearances to capture.")
    var appearances: [String] = Defaults.appearances

    /// One quoted string, not a repeated option: these all begin with `-`, and
    /// ArgumentParser would read them as flags of its own.
    @Option(help: "Extra launch arguments, quoted: \"-ScreenshotMode YES -isProUnlocked YES\"")
    var extraArgs: String = ""

    @Option(help: "Seconds to let async content settle before the shot.")
    var settle: Double = Defaults.settle

    @Option(help: "Config; checks --screens against its screens[].id before capturing.")
    var config: String?

    func run() async throws {
        try await Pipeline.capture(
            Pipeline.CaptureOptions(
                app: app, out: out, screens: screens, appearances: appearances,
                extraArgs: extraArgs, settle: settle, config: config))
    }
}

// MARK: - extract

struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export screenshot attachments from an .xcresult bundle.",
        discussion: """
            For projects whose captures come from an XCUITest rather than the staged \
            shell driver. The test runner is sandboxed out of the repo, so each capture \
            travels as an XCTAttachment named <screen>~<appearance>.png.
            """)

    @Option(help: "Path to the .xcresult bundle.")
    var xcresult: String

    @Option(help: "Where to write the extracted PNGs.")
    var out: String = Defaults.source

    @Option(help: "Config, used to check the exact expected set was captured.")
    var config: String?

    func run() throws {
        let expected =
            try config
            .map { try Config.load(URL(fileURLWithPath: $0)).expectedCaptures() }

        let extracted = try Extractor.run(
            xcresult: URL(fileURLWithPath: xcresult),
            outDir: URL(fileURLWithPath: out),
            expected: expected)

        for name in extracted.sorted() {
            print("  ✓ \(name)")
        }
        print("\n✅ extracted \(extracted.count) PNG(s) into \(out)")
    }
}

// MARK: - run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "The whole chain: capture → gate → compose.")

    @OptionGroup var cfg: ConfigOption
    @OptionGroup var paths: PathOptions

    @Option(help: "Path to the built .app bundle.")
    var app: String

    @Option(parsing: .upToNextOption, help: "Screens as `name:stage` pairs.")
    var screens: [String]

    @Option(help: "Extra launch arguments, quoted.")
    var extraArgs: String = ""

    /// Sized for the slowest screen. There is no per-screen settle, so a screen that
    /// renders an async result needs longer than a static pane and every launch pays it.
    /// Too short does not fail — it photographs a half-drawn screen.
    @Option(help: "Seconds to let async content settle before each shot.")
    var settle: Double = Defaults.settle

    @Option(help: "Where to write the App Store composites.")
    var appstoreOut: String = Defaults.appstoreOut

    @Option(help: "Where to write the site images. Omitted ⇒ skip.")
    var websiteOut: String?

    @Option(help: "Max fraction of changed pixels before the gate fails.")
    var tolerance: Double = Defaults.tolerance

    @Option(help: "Which appearance(s) the site renders. Comma-separated for more than one.")
    var appearance: String = Defaults.appearance

    @Option(help: "Downscale site images wider than this.")
    var maxWidth: Int = Defaults.maxWidth

    func run() async throws {
        try await Pipeline.execute(plan(appearances: try cfg.load().appearances))
    }

    /// Pure: no I/O, so the wiring can be asserted as a value in tests. The appearances
    /// to capture are the config's, which is the one thing `run` cannot decide alone —
    /// hence the parameter rather than a `cfg.load()` in here.
    func plan(appearances: [String]) -> Pipeline.Plan {
        Pipeline.Plan(
            capture: Pipeline.CaptureOptions(
                app: app,
                out: paths.source,
                screens: screens,
                appearances: appearances,
                extraArgs: extraArgs,
                settle: settle,
                config: cfg.config),  // checks --screens against screens[].id first
            check: Pipeline.CheckOptions(
                paths: paths.values,
                tolerance: tolerance,
                config: cfg.config),
            compose: Pipeline.ComposeOptions(
                appStore: Pipeline.AppStoreOptions(
                    config: cfg.config,
                    source: paths.source,
                    out: appstoreOut),
                website: websiteOut.map {
                    Pipeline.WebsiteOptions(
                        config: cfg.config,
                        source: paths.source,
                        out: $0,
                        appearance: appearance,
                        maxWidth: maxWidth)
                }))
    }
}
