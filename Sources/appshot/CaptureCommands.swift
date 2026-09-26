import AppShotKit
import ArgumentParser
import Foundation

// MARK: - capture

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Launch the app staged onto each screen and photograph its window.",
        discussion: """
            Takes over the pointer and the active app at the moment of each shot — \
            don't use the machine while it runs, and a stray click can land in a \
            capture.

            Only the shutter is exclusive, so two projects can capture at once; \
            --wait queues behind another run instead of failing.

            Needs Screen Recording permission for the terminal running it (System \
            Settings → Privacy & Security). Nothing is granted to the app itself.
            """)

    @Option(help: "Path to the built .app bundle.")
    var app: String

    @Option(help: "Where to write the raw captures.")
    var out: String = Defaults.source

    @Option(
        parsing: .upToNextOption,
        help: """
            Screens as `name[:stage[:settle]]` (stage defaults to name; settle to \
            --settle). `export::6` keeps the default stage and settles 6s.
            """)
    var screens: [String]

    @Option(parsing: .upToNextOption, help: "Appearances to capture.")
    var appearances: [String] = Defaults.appearances

    /// One quoted string, not a repeated option: these all begin with `-`, and
    /// ArgumentParser would read them as flags of its own. Tokenized by
    /// `LaunchArguments.split`, so an inner quoted value keeps its spaces.
    @Option(
        help:
            "Extra launch arguments, quoted: \"-ScreenshotMode YES -AppleLanguages '(en)'\". Inner quotes group, so a value may contain spaces."
    )
    var extraArgs: String = ""

    @Option(help: "Minimum seconds before the frame poll starts; a screen's own settle wins.")
    var settle: Double = Defaults.settle

    @Option(help: "Give up waiting for the window to hold still after this many seconds.")
    var settleMax: Double = Defaults.settleMax

    @Flag(help: "Report where each shot's time went — use this before tuning --settle.")
    var timings = false

    @Option(help: "Config; checks --screens against its screens[].id before capturing.")
    var config: String?

    @Flag(
        help: """
            --screens is a deliberate subset, so do not fail on the ones it leaves out. \
            A name that is in no screens[].id is still an error — that check is what \
            catches a typo staging the wrong screen under the right filename. For \
            iterating on one screen; a run that produces a set to gate must be complete.
            """)
    var partial = false

    @OptionGroup var concurrency: ConcurrencyOptions

    @OptionGroup var ready: ReadyOptions

    @OptionGroup var dev: DeviceOption

    @OptionGroup var sim: SimulatorOptions

    func run() async throws {
        try await Pipeline.capture(
            Pipeline.CaptureOptions(
                app: app, out: out, screens: screens, appearances: appearances,
                extraArgs: extraArgs, settle: settle, settleMax: settleMax,
                timings: timings, config: config, partial: partial, wait: concurrency.wait,
                waitTimeout: concurrency.waitTimeout,
                foregroundLaunch: concurrency.foregroundLaunch,
                noActivate: concurrency.noActivate,
                recolorTrafficLights: concurrency.recolorTrafficLights,
                captureDisplay: concurrency.captureDisplay,
                noWallpaperTint: concurrency.noWallpaperTint,
                readyFile: ready.readyFile, readyArg: ready.readyArg,
                device: dev.device, erase: sim.erase))
    }
}

// MARK: - Readiness

// MARK: - Simulator

/// iOS-only knobs. Inert on a Mac config, which never reaches the simulator driver.
struct SimulatorOptions: ParsableArguments {
    @Flag(
        help: """
            iOS: `simctl erase` each device before booting it. The strongest \
            determinism lever there is — no prior container, no granted permissions, \
            no leftover onboarding, and it clears the simulator's own slow-animations \
            setting. Slow, so it is off by default and runs once per device, not per \
            screen.
            """)
    var erase = false
}

// MARK: - Readiness

/// How the shutter learns the screen is finished, rather than guessing.
struct ReadyOptions: ParsableArguments {
    @Flag(
        help: """
            Wait for the app to signal that its screen is ready, instead of guessing \
            with --settle. appshot passes a file path as a launch argument; the app \
            touches that file once its data has landed. Skips the settle floor \
            entirely, and fails if the signal never comes.
            """)
    var readyFile = false

    /// Needs the `=`: the value starts with a `-`, and without it ArgumentParser reads
    /// it as one of appshot's own flags.
    @Option(help: "Launch argument carrying the ready-file path: --ready-arg=-MyReadyFile")
    var readyArg: String = Defaults.readyArg
}

// MARK: - Concurrency

/// How this run behaves when another one already owns the screen.
///
/// Only the shutter is exclusive — launching, waiting for the window and the settle
/// floor all overlap with other projects' runs — but the shutter still has to take
/// turns, because there is exactly one active application per Mac.
struct ConcurrencyOptions: ParsableArguments {
    /// A flag plus a separate timeout rather than `--wait[=seconds]`: ArgumentParser
    /// has no optional-value option, and `--wait 300` colliding with a positional
    /// would be worse than two names.
    @Flag(help: "Block until a concurrent capture run finishes, instead of failing.")
    var wait = false

    @Option(help: "Give up waiting after this many seconds (with --wait).")
    var waitTimeout: Double = CaptureLock.defaultWaitTimeout

    @Flag(
        help: """
            Launch the app frontmost and hold the capture lock for the whole run, \
            which is what this did before the lock was narrowed to the shutter. For an \
            app whose window never appears when launched in the background, and for a \
            machine where something else competes for focus — an editor, a browser, or \
            the terminal driving the run — which otherwise shows up as \
            "would not come to the front" on a random shot. Costs concurrency: another \
            project's run queues behind this whole run rather than behind each shutter.
            """)
    var foregroundLaunch = false

    @Flag(
        help: """
            Never bring the app to the front: photograph the window where it sits, \
            behind whatever you are working in. Skips the activation, the frontmost \
            checks and the cursor parking, so a run no longer takes the screen or the \
            pointer from you — use this whenever you intend to keep using the Mac. \
            The catch is that macOS renders a window it does not consider active with \
            grey traffic lights and a flatter sidebar, so the app must force SwiftUI's \
            controlActiveState to .key to look right, and the window chrome still will \
            not match a focused capture. Accept goldens from one mode or the other, \
            never a mix. The app is told with -ScreenshotActivation none (focused \
            runs pass focused), so it can skip activating itself here and do it in \
            a focused run, where macOS 14+ needs it.
            """)
    var noActivate = false

    @Flag(
        help: """
            Repaint the window's grey close, minimise and zoom buttons in their active \
            colours after each shot. The half of --no-activate's inactive chrome the app \
            cannot fix for itself: macOS greys those buttons whenever the app is not \
            frontmost. The buttons are found by measurement (three equal discs in the \
            window's top-left corner) and redrawn with AppKit's own artwork for this \
            macOS version and appearance; a shot where they cannot be found fails rather \
            than shipping half-painted. Buttons that are already coloured are left \
            alone. The sidebar and toolbar keep their inactive tone. macOS only.
            """)
    var recolorTrafficLights = false

    @Option(
        help: """
            Which display the app should park its capture window on: main (default, \
            wherever the app would put it), secondary (any display other than the one \
            holding the key window), builtin (the laptop panel) or external. Pair it \
            with --no-activate: that stops a run taking the keyboard, but the window is \
            still drawn over whatever you are reading, and on a laptop plus a monitor \
            one of the two is usually idle. Passed to the app as -ScreenshotDisplay \
            <CGDirectDisplayID>; an app that does not read it is unaffected. Ignored \
            when the named display is absent, or when using it would change the backing \
            scale and so every captured dimension.
            """)
    var captureDisplay: DisplayChoice = .main

    @Flag(
        help: """
            Turn off wallpaper tinting of window backgrounds for the run, then put the \
            setting back exactly as it was. A dark window otherwise takes the colour of \
            the wallpaper behind it, up to 22 levels, so the goldens hold one Mac's \
            wallpaper and fail on a new one, a dynamic one at another hour, or another \
            Mac. No launch argument reaches it, so this writes the global default \
            AppleReduceDesktopTinting, which only apps launched afterwards read. The \
            prior value is recorded first, shared between concurrent runs, restored on \
            Ctrl-C, and restored by the next capture after a crash. macOS only.
            """)
    var noWallpaperTint = false
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

    @Option(parsing: .upToNextOption, help: "Screens as `name[:stage[:settle]]`.")
    var screens: [String]

    @Option(help: "Extra launch arguments, quoted. Inner quotes group, so a value may contain spaces.")
    var extraArgs: String = ""

    /// The floor before the frame poll starts looking, for screens that don't say
    /// otherwise. Raising this taxes every launch — 0.5s across a 16-shot run is 8
    /// seconds — so give the one slow screen its own settle (`export::6`) instead.
    /// A floor that is too short does not fail; it photographs a still-but-unfinished
    /// window, which the poll cannot distinguish from a finished one.
    @Option(help: "Minimum seconds before the frame poll starts; a screen's own settle wins.")
    var settle: Double = Defaults.settle

    @Option(help: "Give up waiting for the window to hold still after this many seconds.")
    var settleMax: Double = Defaults.settleMax

    @Flag(help: "Report where each shot's time went — use this before tuning --settle.")
    var timings = false

    @OptionGroup var concurrency: ConcurrencyOptions

    @OptionGroup var ready: ReadyOptions

    @OptionGroup var dev: DeviceOption

    @OptionGroup var loc: LocaleOption

    @OptionGroup var sim: SimulatorOptions

    @Option(help: "Where to write the App Store composites.")
    var appstoreOut: String = Defaults.appstoreOut

    @Option(help: "Where to write the site images. Omitted ⇒ skip.")
    var websiteOut: String?

    @Option(
        help: """
            family.config.json, for a config whose screens[] names family composites. \
            Its directory is the root holding macos/ and ios/.
            """)
    var familyConfig: String?

    @Option(help: "Max fraction of changed pixels before the gate fails.")
    var tolerance: Double = Defaults.tolerance

    @Flag(help: "Fail if the goldens carry no manifest (see `appshot seal`).")
    var requireManifest = false

    @Option(
        help: """
            Fail if the captures are older than this many seconds. For CI, where             captures are always minutes old and anything else means capture never ran.
            """)
    var maxSourceAge: Double?

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
                settleMax: settleMax,
                timings: timings,
                config: cfg.config,  // checks --screens against screens[].id first
                // `run` captures, gates and composes in one go, so it is a complete set by
                // definition — there is nothing for --partial to mean here.
                partial: false,
                wait: concurrency.wait,
                waitTimeout: concurrency.waitTimeout,
                foregroundLaunch: concurrency.foregroundLaunch,
                noActivate: concurrency.noActivate,
                recolorTrafficLights: concurrency.recolorTrafficLights,
                captureDisplay: concurrency.captureDisplay,
                noWallpaperTint: concurrency.noWallpaperTint,
                readyFile: ready.readyFile,
                readyArg: ready.readyArg,
                device: dev.device,
                erase: sim.erase),
            check: Pipeline.CheckOptions(
                paths: paths.values,
                tolerance: tolerance,
                config: cfg.config,
                // `run` composes straight after the gate, so its output is a build log
                // rather than a verdict to parse. `appshot check --json` is the
                // machine-readable entry point.
                json: false,
                requireManifest: requireManifest,
                device: dev.device),
            compose: Pipeline.ComposeOptions(
                appStore: Pipeline.AppStoreOptions(
                    config: cfg.config,
                    source: paths.source,
                    out: appstoreOut,
                    device: dev.device,
                    locale: loc.locale,
                    familyConfig: familyConfig),
                website: websiteOut.map {
                    Pipeline.WebsiteOptions(
                        config: cfg.config,
                        source: paths.source,
                        out: $0,
                        appearance: appearance,
                        maxWidth: maxWidth,
                        device: dev.device)
                }))
    }
}

/// `--capture-display secondary` on the command line, `.secondary` in the library. The
/// conformance lives here rather than on the type so `AppShotKit` stays free of
/// ArgumentParser.
extension DisplayChoice: ExpressibleByArgument {
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}
