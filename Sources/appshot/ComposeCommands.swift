import AppShotKit
import ArgumentParser
import Foundation

struct ConfigOption: ParsableArguments {
    @Option(name: .long, help: "Path to screenshots.config.json.")
    var config: String = Defaults.config

    var configURL: URL { URL(fileURLWithPath: config) }

    func load() throws -> Config {
        let cfg = try Config.load(configURL)
        try cfg.validate()
        return cfg
    }
}

/// `--config` where it is optional rather than required.
///
/// Separate from `ConfigOption`, which defaults the path: for `accept`, `seal` and
/// `selftest` a config is only needed to learn about a device axis, and defaulting it
/// would make those commands fail on a project that has no config file at all.
struct OptionalConfigOption: ParsableArguments {
    @Option(
        name: .long,
        help: "Config, read only to find devices[] (iOS). Omitted ⇒ flat directories.")
    var config: String?
}

/// `--device`, for the commands that fan out over `devices[]`.
///
/// Omitted means every device the config declares, which is what you want almost
/// always; naming one is for iterating on a single device without paying for the
/// others. Meaningless on Mac, where `resolvedDevices()` returns a single unnamed
/// device — passing it there fails with the list of known devices, which is empty.
struct DeviceOption: ParsableArguments {
    @Option(
        name: .long,
        help: "Only this device from the config's devices[] (iOS). Omitted ⇒ all of them.")
    var device: String?
}

// MARK: - compose

struct Compose_: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Frame the captures into store visuals (and website images).",
        subcommands: [AppStore.self, Website.self, Both.self],
        defaultSubcommand: Both.self
    )
}

struct AppStore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appstore",
        abstract: "Compose framed + captioned App Store visuals.")

    @OptionGroup var cfg: ConfigOption
    @OptionGroup var dev: DeviceOption

    @Option(help: "Directory of raw captures.")
    var source: String = Defaults.source

    @Option(help: "Where to write the composites.")
    var out: String = Defaults.appstoreOut

    func run() throws {
        try Pipeline.appStore(
            Pipeline.AppStoreOptions(
                config: cfg.config, source: source, out: out, device: dev.device))
    }
}

struct Website: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Emit bare app captures for the marketing site.")

    @OptionGroup var cfg: ConfigOption
    @OptionGroup var dev: DeviceOption

    @Option(help: "Directory of raw captures.")
    var source: String = Defaults.source

    @Option(help: "Where to write the site images.")
    var out: String

    @Option(
        help: """
            Which appearance(s) the site renders. Comma-separated for more than one \
            (e.g. light,dark), which suffixes the filenames <basename>~<appearance>.png.
            """)
    var appearance: String = Defaults.appearance

    @Option(help: "Downscale anything wider than this.")
    var maxWidth: Int = Defaults.maxWidth

    func run() throws {
        try Pipeline.website(
            Pipeline.WebsiteOptions(
                config: cfg.config, source: source, out: out,
                appearance: appearance, maxWidth: maxWidth, device: dev.device))
    }
}

struct Both: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "both",
        abstract: "Compose the App Store set, and the website set if --website-out is given.")

    @OptionGroup var cfg: ConfigOption
    @OptionGroup var dev: DeviceOption

    @Option(help: "Directory of raw captures.")
    var source: String = Defaults.source

    @Option(help: "Where to write the App Store composites.")
    var out: String = Defaults.appstoreOut

    @Option(help: "Where to write the site images. Omitted ⇒ skip the website set.")
    var websiteOut: String?

    @Option(
        help: """
            Which appearance(s) the site renders. Comma-separated for more than one \
            (e.g. light,dark). Does not affect the App Store set, which always composes \
            every appearance the config declares.
            """)
    var appearance: String = Defaults.appearance

    @Option(help: "Downscale site images wider than this.")
    var maxWidth: Int = Defaults.maxWidth

    func run() throws {
        try Pipeline.compose(
            Pipeline.ComposeOptions(
                appStore: Pipeline.AppStoreOptions(
                    config: cfg.config, source: source, out: out, device: dev.device),
                website: websiteOut.map {
                    Pipeline.WebsiteOptions(
                        config: cfg.config, source: source, out: $0,
                        appearance: appearance, maxWidth: maxWidth, device: dev.device)
                }))
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the things that fail silently: font, permission, config.")

    @OptionGroup var cfg: ConfigOption

    func run() throws {
        var problems: [String] = []

        // Config + output size.
        let config: Config
        do {
            config = try Config.load(cfg.configURL)
            print("✓ config parses: \(cfg.config)")
        } catch {
            throw CLIError("\(error)")
        }
        // Output sizes, per device. The old message said "Mac App Store size" while
        // `validate()` accepted iOS ones too — a check whose report disagreed with
        // what it checked.
        var devices: [Config.ResolvedDevice] = []
        do {
            try config.validate()
            devices = try config.resolvedDevices()
            let store = config.resolvedPlatform == .ios ? "iOS" : "Mac"
            for device in devices {
                let name = device.slug.map { "\($0): " } ?? ""
                print("✓ \(name)output size \(device.output.description) is a valid \(store) App Store size")
            }
        } catch {
            problems.append("\(error)")
        }

        // The font. This is the one that ships silently: librsvg substitutes a
        // missing family rather than erroring, so captions render in the wrong
        // typeface on every machine but the one that built the pipeline.
        let family = Text.primaryFamily(config.fontFamily)
        do {
            _ = try Text.font(
                stack: config.fontFamily, weight: config.layout.titleWeight,
                size: config.layout.titleFontSize)
            print("✓ caption font resolves: \(family)")
        } catch {
            problems.append("\(error)")
        }

        switch config.resolvedPlatform {
        case .mac:
            // Screen Recording, without which captures lose their transparent corners.
            if Capture.hasScreenRecordingPermission() {
                print("✓ Screen Recording permission granted")
            } else {
                problems.append("\(AppShotError.screenRecordingDenied)")
            }

            // Not a problem — a fact. A capture that is about to queue behind another
            // project should say so here rather than 90 seconds into a run.
            if let held = CaptureLock.holder() {
                let who = held.holder.map(\.summary) ?? held.pid.map { "pid \($0)" } ?? "unknown"
                print("• capture lock is held by \(who) — a run would wait (use --wait)")
            } else {
                print("✓ capture lock is free")
            }

        case .ios:
            // Deliberately NOT checked here: Screen Recording. A simulator capture goes
            // through simctl and needs no such grant, and failing an iOS project for a
            // permission its driver never uses would be a doctor that lies.
            do {
                let installed = try Simulator.available()
                print("✓ simctl works — \(installed.types.count) device type(s) installed")

                for device in devices {
                    guard let simulator = device.simulator else { continue }
                    do {
                        let resolved = try installed.resolve(
                            type: simulator, runtime: device.runtime)
                        print("✓ \(device.name): \(simulator) on \(resolved.runtime.name)")
                    } catch {
                        problems.append("\(error)")
                    }

                    // The iPad date is unpinnable, sits under the tolerance, and is
                    // therefore invisible until a golden mysteriously drifts weeks
                    // later. Naming it here is the only warning anyone will get.
                    if simulator.localizedCaseInsensitiveContains("ipad"), device.ignore.isEmpty {
                        print(
                            """
                            • \(device.name): iPad status bars show a live date that \
                            simctl cannot pin.
                              It moves ~0.05% of the canvas — under the 0.1% tolerance, so \
                              it will not fail the
                              gate; it just spends half the drift budget every day. Add an \
                              `ignore` rect covering
                              the status bar to this device if its goldens start drifting.
                            """)
                    }
                }
            } catch {
                problems.append("\(error)")
            }
        }

        print("")
        guard problems.isEmpty else {
            throw CLIError(
                "\(problems.count) problem(s):\n"
                    + problems.map { "   ✗ \($0)" }.joined(separator: "\n"))
        }
        print("✅ ready to capture")
    }
}
