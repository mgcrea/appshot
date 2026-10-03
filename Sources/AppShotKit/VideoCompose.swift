import CoreGraphics
import Foundation

/// master + track + config → previews, promos, a website loop, a report and a contact
/// sheet.
///
/// Everything that can fail on its inputs — a missing track or master, a caption too
/// short to read, a card icon or a font that does not load — fails before the first
/// file is written.
public enum VideoCompose {
    public struct Options: Sendable {
        public var config: Config
        /// Where `card.icon` paths resolve from.
        public var configDir: URL
        /// `record`'s output: masters and tracks.
        public var sourceDir: URL
        public var outDir: URL
        /// Screenshot captures to build a stand-in master from, instead of `sourceDir`.
        public var fromStills: URL?
        public var videos: [String]?
        public var appearances: [String]?
        public var websiteOut: URL?

        public init(
            config: Config, configDir: URL, sourceDir: URL, outDir: URL, fromStills: URL?,
            videos: [String]?, appearances: [String]?, websiteOut: URL?
        ) {
            self.config = config
            self.configDir = configDir
            self.sourceDir = sourceDir
            self.outDir = outDir
            self.fromStills = fromStills
            self.videos = videos
            self.appearances = appearances
            self.websiteOut = websiteOut
        }
    }

    public struct Output: Sendable {
        public let url: URL
        public let kind: String
        public let size: Config.Size
    }

    public struct Report: Codable, Sendable {
        public struct Beat: Codable, Sendable {
            public var index: Int
            public var scheduled: Double
            public var actual: Double
            public var latency: Double?
        }
        public struct Caption: Codable, Sendable {
            public var text: String
            public var start: Double
            public var shown: Double
            public var needed: Double
            public var margin: Double
        }
        public var video: String
        public var appearance: String
        public var duration: Double
        public var beats: [Beat]
        public var captions: [Caption]
        public var outputs: [String]
        public var frames: Int
        public var maxFrameGap: Double
    }

    struct Job {
        let video: Config.Video
        let appearance: String
        let track: VideoTrack
        let timeline: VideoTimeline
        let icon: CGImage?
    }

    public static func run(_ options: Options) async throws -> [Output] {
        let config = options.config
        try config.validate()
        let videos = try (options.videos ?? (config.videos ?? []).map(\.id)).map { try config.video($0) }
        let appearances = options.appearances ?? config.appearances

        // Plan every job and run every check before writing anything.
        var jobs: [Job] = []
        for video in videos {
            let icon = try video.card?.icon.map { try Image.load(options.configDir.appending(path: $0)) }
            for appearance in appearances {
                let track: VideoTrack
                if let stills = options.fromStills {
                    let master = try StillsMaster(video: video, sourceDir: stills, appearance: appearance)
                    track = .stills(video: video, appearance: appearance, stageSize: master.stageSize)
                } else {
                    let url = VideoTrack.url(in: options.sourceDir, video: video.id, appearance: appearance)
                    let master = Self.masterURL(options, video: video.id, appearance: appearance)
                    let missing = [url, master].filter { !FileManager.default.fileExists(atPath: $0.path) }
                    guard missing.isEmpty else {
                        throw AppShotError.missingCaptures(
                            missing.map(\.lastPathComponent), dir: options.sourceDir)
                    }
                    track = try VideoTrack.read(url)
                }
                let timeline = try VideoTimeline(video: video, track: track)
                if let short = timeline.readingProblems().first {
                    throw AppShotError.captionTooShort(
                        video: video.id, caption: short.text, shown: short.shown, needed: short.needed)
                }
                jobs.append(
                    Job(video: video, appearance: appearance, track: track, timeline: timeline, icon: icon))
            }
        }
        _ = try Text.font(
            stack: config.fontFamily, weight: config.layout.titleWeight, size: config.layout.titleFontSize)

        var outputs: [Output] = []
        for job in jobs {
            outputs += try await render(job, options: options)
        }
        return outputs
    }

    static func masterURL(_ options: Options, video: String, appearance: String) -> URL {
        options.sourceDir.appending(path: "\(video)~\(appearance).mov")
    }

    static func render(_ job: Job, options: Options) async throws -> [Output] {
        let master: any VideoMaster =
            if let stills = options.fromStills {
                try StillsMaster(video: job.video, sourceDir: stills, appearance: job.appearance)
            } else {
                try RecordedMaster(
                    url: Self.masterURL(options, video: job.video.id, appearance: job.appearance),
                    track: job.track)
            }
        return try await render(job, options: options, master: master)
    }

    /// Split from the above so a test can hand in a master that fails mid-stream.
    static func render(_ job: Job, options: Options, master: any VideoMaster) async throws -> [Output] {
        var master = master
        let config = options.config
        let video = job.video
        let name = "\(video.id)~\(job.appearance)"

        var targets: [(style: VideoFrame.Style, writer: VideoWriter, kind: String)] = []
        var outputs: [Output] = []
        var poster: CGImage?
        var sheet: [ContactSheet.Cell] = []
        // A throw from here on must not leave a `.partial` that looks like a recording, nor
        // the half of a job's outputs that did finish.
        do {
            if video.outputs.wantsPreview, let size = Config.previewSize(for: config.resolvedPlatform) {
                let style = try VideoFrame.style(
                    kind: .preview, size: size, config: config, appearance: job.appearance,
                    video: video, stage: master.stageSize, icon: nil)
                let url = options.outDir.appending(path: "preview/\(name).mp4")
                targets.append((style, try VideoWriter(url: url, size: size), "preview"))
            }
            for size in video.outputs.promoSizes {
                let style = try VideoFrame.style(
                    kind: .promo, size: size, config: config, appearance: job.appearance,
                    video: video, stage: master.stageSize, icon: job.icon)
                let url = options.outDir.appending(path: "promo/\(name)~\(size.description).mp4")
                targets.append((style, try VideoWriter(url: url, size: size), "promo"))
            }

            // Pulled back to the last frame: a poster in the final frame interval would
            // otherwise never be reached.
            let posterTime = min(video.poster ?? min(5, video.duration / 2), job.timeline.lastFrameTime)
            let sheetTimes = ContactSheet.times(
                for: job.timeline, beats: job.timeline.beatTimes)
            for i in 0..<job.timeline.frameCount {
                let t = Double(i) / Double(VideoWriter.fps)
                let stage = try master.frame(at: t)
                for (n, target) in targets.enumerated() {
                    let frame = try VideoFrame.render(
                        stage: stage, t: t, timeline: job.timeline, style: target.style)
                    try target.writer.append(frame)
                    guard n == targets.count - 1 else { continue }
                    // The last target is a promo when there is one: the poster and the sheet
                    // show the framed version, which is what a reviewer is judging.
                    if poster == nil, t >= posterTime { poster = frame }
                    if let next = sheetTimes.dropFirst(sheet.count).first, t >= next {
                        let caption = job.timeline.caption(at: next)?.text ?? ""
                        sheet.append(ContactSheet.Cell(time: next, label: caption, image: frame))
                    }
                }
            }

            for target in targets {
                let url = try await target.writer.finish()
                outputs.append(Output(url: url, kind: target.kind, size: target.style.size))
            }
        } catch {
            for target in targets { target.writer.cancel() }
            for output in outputs { try? FileManager.default.removeItem(at: output.url) }
            throw Self.named(error, video: video.id)
        }

        if let poster, video.outputs.wantsPreview || !video.outputs.promoSizes.isEmpty {
            let url = options.outDir.appending(path: "promo/\(name).poster.png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Image.write(poster, to: url)
        }

        if video.outputs.wantsWebsite, let site = options.websiteOut,
            let first = outputs.first(where: { $0.kind == "promo" })
        {
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            let single = (options.appearances ?? config.appearances).count == 1
            let url = site.appending(path: single ? "\(video.id).mp4" : "\(name).mp4")
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: first.url, to: url)
            outputs.append(Output(url: url, kind: "website", size: first.size))
        }

        let reportDir = options.outDir.appending(path: "report")
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        if !sheet.isEmpty {
            try Image.write(
                try ContactSheet.render(sheet), to: reportDir.appending(path: "\(name).contact.png"))
        }
        let report = Report(
            video: video.id, appearance: job.appearance, duration: video.duration,
            beats: Self.reportBeats(video: video, track: job.track, timeline: job.timeline),
            captions: job.timeline.captions.map {
                .init(
                    text: $0.text, start: $0.start, shown: $0.shown, needed: $0.needed,
                    margin: $0.shown - $0.needed)
            },
            outputs: outputs.map(\.url.lastPathComponent),
            frames: job.track.frames, maxFrameGap: job.track.maxFrameGap)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: reportDir.appending(path: "\(name).report.json"), options: .atomic)
        return outputs
    }

    /// Every beat of the config as it is now: scheduled at its `at`, happening when the
    /// timeline says, with a latency only for a cue the app acknowledged.
    static func reportBeats(
        video: Config.Video, track: VideoTrack, timeline: VideoTimeline
    ) -> [Report.Beat] {
        var rank = 0
        return video.beats.enumerated().map { index, beat in
            var latency: Double?
            if beat.cue != nil {
                let cue = track.cues[rank]
                latency = cue.acked.map { $0 - cue.at }
                rank += 1
            }
            return Report.Beat(
                index: index, scheduled: beat.at, actual: timeline.beatTimes[index], latency: latency)
        }
    }

    /// `ContactSheet` and `VideoWriter` do not know which video they serve.
    static func named(_ error: any Error, video: String) -> any Error {
        guard case .videoRenderFailed("", let reason)? = error as? AppShotError else { return error }
        return AppShotError.videoRenderFailed(video: video, reason: reason)
    }
}
