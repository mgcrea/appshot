import AppShotKit
import ArgumentParser
import Foundation

struct ComposeVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Render App Store previews and promos from a recording, or from stills.")

    @OptionGroup var cfg: ConfigOption

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
                websiteOut: websiteOut.map { URL(fileURLWithPath: $0) }))
        for output in outputs {
            print(
                "  \(output.kind.padding(toLength: 8, withPad: " ", startingAt: 0)) \(output.size.description)  \(output.url.path)"
            )
        }
        print("review: \(out)/report/*.contact.png and *.report.json")
    }
}
