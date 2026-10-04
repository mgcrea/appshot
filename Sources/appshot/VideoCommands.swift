import AppShotKit
import ArgumentParser
import Foundation

struct ComposeVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Render App Store previews and promos from a recording, or from stills.")

    @OptionGroup var cfg: ConfigOption
    @OptionGroup var dev: DeviceOption

    @Option(help: "Directory of masters and tracks written by `appshot record`.")
    var source: String = Defaults.videoSource

    @Option(help: "Where to write preview/, promo/ and report/.")
    var out: String = Defaults.videoOut

    @Option(
        help: """
            Build the video from these screenshot captures instead of a recording. Each \
            beat that names a `screen` cuts to it.
            """)
    var fromStills: String?

    @Option(parsing: .upToNextOption, help: "Only these videos[] ids. Omitted ⇒ all.")
    var videos: [String] = []

    @Option(help: "Comma-separated appearances. Omitted ⇒ the config's.")
    var appearances: String?

    @Option(
        help: """
            Comma-separated motion presets (\(MotionPreset.all.map(\.name).joined(separator: ", "))). \
            Each output gets the preset in its name.
            """)
    var motion: String?

    @Option(help: "Where the website loop goes, for videos with outputs.website.")
    var websiteOut: String?

    func run() async throws {
        let config = try cfg.load()
        let outputs = try await VideoCompose.run(
            VideoCompose.Options(
                config: config,
                configDir: cfg.configURL.deletingLastPathComponent(),
                sourceDir: URL(fileURLWithPath: source),
                outDir: URL(fileURLWithPath: out),
                fromStills: fromStills.map { URL(fileURLWithPath: $0) },
                videos: videos.isEmpty ? nil : videos,
                appearances: appearances.map(Pipeline.appearances(from:)),
                websiteOut: websiteOut.map { URL(fileURLWithPath: $0) },
                motions: motion.map {
                    $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                }, device: dev.device))
        for output in outputs {
            print(
                "  \(output.kind.padding(toLength: 8, withPad: " ", startingAt: 0)) \(output.size.description)  \(output.url.path)"
            )
        }
        for device in try config.resolvedDevices(only: dev.device) {
            let reports = device.directory(under: URL(fileURLWithPath: out)).appending(path: "report").path
            print("review: \(reports)/*.contact.png and *.report.json")
        }
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record scripted videos of the app (macOS). Nothing is clicked or typed.")

    @OptionGroup var cfg: ConfigOption

    @Option(help: "The .app to record.")
    var app: String

    @Option(help: "Where masters and tracks go.")
    var out: String = Defaults.videoSource

    @Option(parsing: .upToNextOption, help: "Only these videos[] ids. Omitted ⇒ all.")
    var videos: [String] = []

    @Option(help: "Comma-separated appearances. Omitted ⇒ the config's.")
    var appearances: String?

    @Option(help: "Extra launch arguments, as one string: --extra-args=\"-ScreenshotMode YES\".")
    var extraArgs: String = ""

    @Flag(help: "Launch and keep the app in the background; you can keep working during a take.")
    var noActivate = false

    @Flag(help: "Wait for another project's capture to finish instead of failing.")
    var wait = false

    @Option(help: "Seconds to wait for the app's ready event.")
    var settleMax: Double = Defaults.settleMax

    func run() async throws {
        let config = try cfg.load()
        try Recorder.requireMac(config)
        let ids = videos.isEmpty ? (config.videos ?? []).map(\.id) : videos
        let chosen = try ids.map { try config.video($0) }
        let capture = Capture.Options(
            app: URL(fileURLWithPath: app), outDir: URL(fileURLWithPath: out), partial: true,
            screens: [], appearances: appearances.map(Pipeline.appearances(from:)) ?? config.appearances,
            extraArgs: LaunchArguments.split(extraArgs), settleMax: settleMax, wait: wait,
            noActivate: noActivate)
        let takes = try await Recorder.run(Recorder.Options(capture: capture, videos: chosen)) { take in
            print("  \(take.video)~\(take.appearance)  \(take.master.lastPathComponent)")
            for warning in take.warnings { print("    warning: \(warning)") }
        }
        print("recorded \(takes.count) take(s) → \(out). Next: appshot compose video --source \(out)")
    }
}
