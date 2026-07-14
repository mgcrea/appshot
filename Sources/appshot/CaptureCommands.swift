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
    var out: String = "screenshots/source"

    @Option(
        parsing: .upToNextOption,
        help: "Screens as `name:stage` pairs (stage defaults to name).")
    var screens: [String]

    @Option(parsing: .upToNextOption, help: "Appearances to capture.")
    var appearances: [String] = ["dark", "light"]

    /// One quoted string, not a repeated option: these all begin with `-`, and
    /// ArgumentParser would read them as flags of its own.
    @Option(help: "Extra launch arguments, quoted: \"-ScreenshotMode YES -isProUnlocked YES\"")
    var extraArgs: String = ""

    @Option(help: "Seconds to let async content settle before the shot.")
    var settle: Double = 2.5

    @Option(help: "Config; checks --screens against its screens[].id before capturing.")
    var config: String?

    func run() async throws {
        let parsed = screens.map(Capture.Screen.init(pair:))

        // A capture is named for its screen, and the config keys everything downstream
        // off screens[].id. If the two lists disagree, the run still "succeeds" — it just
        // writes files nothing expects and omits ones everything does, and you find out
        // two steps later. Cheaper to say so before spending 90s seizing the screen.
        if let config {
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

        let options = Capture.Options(
            app: URL(fileURLWithPath: app),
            outDir: URL(fileURLWithPath: out),
            screens: parsed,
            appearances: appearances,
            extraArgs: extraArgs.split(separator: " ").map(String.init),
            settle: settle)

        let shots = try await Capture.run(options) { shot in
            print("  ✓ \(shot.url.lastPathComponent)  (\(shot.size.description))")
        }

        print("\n✅ captured \(shots.count) screenshot(s) into \(out)")

        // Sizes must be stable and intentional — not necessarily identical, since a
        // panel is legitimately smaller. The golden gate will NOT catch a
        // wrong-but-stable size: it matches its own golden run after run. Expect one
        // group per intended window size; an unexplained extra group is the bug.
        let groups = Dictionary(grouping: shots) { $0.size.description }
        print("\nWindow sizes:")
        for (size, group) in groups.sorted(by: { $0.key < $1.key }) {
            print("  \(group.count) x \(size)")
        }
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
    var out: String = "screenshots/source"

    @Option(help: "Config, used to check the exact expected set was captured.")
    var config: String?

    func run() throws {
        let expected = try config
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

    @Option(help: "Where to write the App Store composites.")
    var appstoreOut: String = "screenshots/appstore"

    @Option(help: "Where to write the site images. Omitted ⇒ skip.")
    var websiteOut: String?

    func run() async throws {
        let config = try cfg.load()

        var capture = CaptureCommand()
        capture.app = app
        capture.out = paths.source
        capture.screens = screens
        capture.appearances = config.appearances
        capture.extraArgs = extraArgs
        capture.config = cfg.config  // checks --screens against screens[].id first
        try await capture.run()

        print("")
        var check = Check()
        check.paths = paths
        check.config = cfg.config
        try check.run()

        print("")
        var compose = Both()
        compose.cfg = cfg
        compose.source = paths.source
        compose.out = appstoreOut
        compose.websiteOut = websiteOut
        try compose.run()
    }
}
