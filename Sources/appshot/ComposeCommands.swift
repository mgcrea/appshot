import AppShotKit
import ArgumentParser
import Foundation

struct ConfigOption: ParsableArguments {
    @Option(name: .long, help: "Path to screenshots.config.json.")
    var config: String = "screenshots/screenshots.config.json"

    var configURL: URL { URL(fileURLWithPath: config) }

    func load() throws -> Config {
        let cfg = try Config.load(configURL)
        try cfg.validate()
        return cfg
    }
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

    @Option(help: "Directory of raw captures.")
    var source: String = "screenshots/source"

    @Option(help: "Where to write the composites.")
    var out: String = "screenshots/appstore"

    func run() throws {
        let config = try cfg.load()
        let outputs = try Compose.appStore(
            config: config,
            sourceDir: URL(fileURLWithPath: source),
            outDir: URL(fileURLWithPath: out),
            warnings: { FileHandle.standardError.write(Data("⚠️  \($0)\n".utf8)) })

        for output in outputs {
            print(
                "✅ \(output.url.lastPathComponent)  "
                    + "(\(output.size.description), window \(output.windowSize.description))")
        }
        print("\n\(outputs.count) App Store visual(s) written to \(out)")
    }
}

struct Website: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Emit bare app captures for the marketing site.")

    @OptionGroup var cfg: ConfigOption

    @Option(help: "Directory of raw captures.")
    var source: String = "screenshots/source"

    @Option(help: "Where to write the site images.")
    var out: String

    @Option(
        help: """
            Which appearance(s) the site renders. Comma-separated for more than one \
            (e.g. light,dark), which suffixes the filenames <basename>~<appearance>.png.
            """)
    var appearance: String = "dark"

    @Option(help: "Downscale anything wider than this.")
    var maxWidth: Int = 2560

    func run() throws {
        let config = try cfg.load()
        let outputs = try Compose.website(
            config: config,
            sourceDir: URL(fileURLWithPath: source),
            outDir: URL(fileURLWithPath: out),
            appearances: Website.appearances(from: appearance),
            maxWidth: maxWidth)

        for output in outputs {
            print("✅ \(output.url.lastPathComponent)  (\(output.size.description))")
        }
        print("\n\(outputs.count) website capture(s) written to \(out)")
    }

    /// "light, dark" → ["light", "dark"]. Tolerates spaces and a trailing comma;
    /// `Compose.website` rejects an empty list and any name the config doesn't declare.
    static func appearances(from raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct Both: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "both",
        abstract: "Compose the App Store set, and the website set if --website-out is given.")

    @OptionGroup var cfg: ConfigOption

    @Option(help: "Directory of raw captures.")
    var source: String = "screenshots/source"

    @Option(help: "Where to write the App Store composites.")
    var out: String = "screenshots/appstore"

    @Option(help: "Where to write the site images. Omitted ⇒ skip the website set.")
    var websiteOut: String?

    @Option(
        help: """
            Which appearance(s) the site renders. Comma-separated for more than one \
            (e.g. light,dark). Does not affect the App Store set, which always composes \
            every appearance the config declares.
            """)
    var appearance: String = "dark"

    @Option(help: "Downscale site images wider than this.")
    var maxWidth: Int = 2560

    func run() throws {
        var store = AppStore()
        store.cfg = cfg
        store.source = source
        store.out = out
        try store.run()

        guard let websiteOut else { return }
        print("")
        var site = Website()
        site.cfg = cfg
        site.source = source
        site.out = websiteOut
        site.appearance = appearance
        site.maxWidth = maxWidth
        try site.run()
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
        do {
            try config.validate()
            print("✓ output size \(config.output.description) is a valid Mac App Store size")
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

        // Screen Recording, without which captures lose their transparent corners.
        if Capture.hasScreenRecordingPermission() {
            print("✓ Screen Recording permission granted")
        } else {
            problems.append("\(AppShotError.screenRecordingDenied)")
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
