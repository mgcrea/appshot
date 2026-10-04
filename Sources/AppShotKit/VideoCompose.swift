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
        /// `--motion`: render each of these presets, each named apart. `nil` ⇒ the video's own.
        public var motions: [String]?

        public init(
            config: Config, configDir: URL, sourceDir: URL, outDir: URL, fromStills: URL?,
            videos: [String]?, appearances: [String]?, websiteOut: URL?, motions: [String]? = nil
        ) {
            self.config = config
            self.configDir = configDir
            self.sourceDir = sourceDir
            self.outDir = outDir
            self.fromStills = fromStills
            self.videos = videos
            self.appearances = appearances
            self.websiteOut = websiteOut
            self.motions = motions
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
        public var motion: String
        public var warnings: [VideoTimeline.Warning]
        public var outputs: [String]
        public var frames: Int
        public var maxFrameGap: Double
    }

    /// CGImage is immutable, so a job crosses to the output tasks as it is.
    struct Job: Sendable {
        let video: Config.Video
        let appearance: String
        let track: VideoTrack
        let timeline: VideoTimeline
        let icon: CGImage?
        let preset: MotionPreset
        /// The motion's name when `--motion` chose it: comparison runs never overwrite.
        let suffix: String?

        var name: String {
            suffix.map { "\(video.id)~\($0)~\(appearance)" } ?? "\(video.id)~\(appearance)"
        }
    }

    public static func run(_ options: Options) async throws -> [Output] {
        let config = options.config
        try config.validate()
        let videos = try (options.videos ?? (config.videos ?? []).map(\.id)).map { try config.video($0) }
        let appearances = options.appearances ?? config.appearances
        for name in options.motions ?? [] where MotionPreset.named(name) == nil {
            throw AppShotError.unknownMotion(
                video: "--motion", name: name, known: MotionPreset.all.map(\.name))
        }

        // Plan every job and run every check before writing anything.
        var jobs: [Job] = []
        for video in videos {
            let icon = try video.card?.icon.map { try Image.load(options.configDir.appending(path: $0)) }
            if options.fromStills == nil {
                for (i, beat) in video.beats.enumerated() {
                    for (key, used) in [("pointer", beat.pointer != nil), ("present", beat.present != nil)]
                    where used {
                        throw AppShotError.invalidVideo(
                            id: video.id,
                            reason:
                                "beat \(i) has `\(key)`, which is for --from-stills: a take already holds "
                                + "the app's own pointer and sheets")
                    }
                }
            }
            let presets: [(MotionPreset, String?)] =
                if let motions = options.motions {
                    motions.compactMap { name in MotionPreset.named(name).map { ($0, name) } }
                } else {
                    [(MotionPreset.named(video.motion ?? MotionPreset.defaultName) ?? .kinetic, nil)]
                }
            for appearance in appearances {
                let track: VideoTrack
                if let stills = options.fromStills {
                    let master = try StillsMaster(
                        video: video, sourceDir: stills, appearance: appearance,
                        sheet: MotionPreset.kinetic.sheet)
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
                        video: video.id, caption: short.plain, shown: short.shown, needed: short.needed)
                }
                for (preset, suffix) in presets {
                    jobs.append(
                        Job(
                            video: video, appearance: appearance, track: track, timeline: timeline,
                            icon: icon,
                            preset: preset, suffix: suffix))
                }
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
        let master = Self.masterURL(options, video: job.video.id, appearance: job.appearance)
        return try await render(job, options: options) {
            if let stills = options.fromStills {
                return try StillsMaster(
                    video: job.video, sourceDir: stills, appearance: job.appearance, sheet: job.preset.sheet)
            }
            return try RecordedMaster(url: master, track: job.track)
        }
    }

    struct Target: Sendable {
        let style: VideoFrame.Style
        let url: URL
        let kind: String
        /// The poster and the contact sheet come from this one: the last target, a promo
        /// when there is one, which is what a reviewer is judging.
        let keepsFrames: Bool
    }

    struct Rendered: Sendable {
        let output: Output
        let poster: CGImage?
        let cells: [ContactSheet.Cell]
    }

    /// Each output renders on its own task, with its own master: a recorded master only
    /// reads forwards, so outputs cannot share one.
    static func render(
        _ job: Job, options: Options, makeMaster: @escaping @Sendable () throws -> any VideoMaster
    ) async throws -> [Output] {
        let config = options.config
        let video = job.video
        let name = job.name
        let stage = job.track.stageSize

        var specs: [(VideoFrame.Style, URL, String)] = []
        do {
            if video.outputs.wantsPreview, let size = Config.previewSize(for: config.resolvedPlatform) {
                let style = try VideoFrame.style(
                    kind: .preview, size: size, config: config, appearance: job.appearance, video: video,
                    stage: stage, icon: nil, preset: job.preset, timeline: job.timeline)
                specs.append((style, options.outDir.appending(path: "preview/\(name).mp4"), "preview"))
            }
            for size in video.outputs.promoSizes {
                let style = try VideoFrame.style(
                    kind: .promo, size: size, config: config, appearance: job.appearance, video: video,
                    stage: stage, icon: job.icon, preset: job.preset, timeline: job.timeline)
                specs.append(
                    (style, options.outDir.appending(path: "promo/\(name)~\(size.description).mp4"), "promo"))
            }
        } catch {
            throw Self.named(error, video: video.id)
        }
        let targets = specs.enumerated().map { i, spec in
            Target(style: spec.0, url: spec.1, kind: spec.2, keepsFrames: i == specs.count - 1)
        }

        // Pulled back to the last frame: a poster in the final frame interval would
        // otherwise never be reached.
        let posterTime = min(video.poster ?? min(5, video.duration / 2), job.timeline.lastFrameTime)
        let moments =
            (job.timeline.hook != nil && job.preset.hookCard ? [0.6] : [])
            + job.timeline.pops.map { ($0.from + $0.to) / 2 }
        let sheetTimes = ContactSheet.times(
            for: job.timeline, beats: job.timeline.beatTimes, moments: moments)

        var finished: [Rendered] = []
        do {
            try await withThrowingTaskGroup(of: Rendered.self) { group in
                for target in targets {
                    group.addTask {
                        try await renderTarget(
                            target, job: job, makeMaster: makeMaster, posterTime: posterTime,
                            sheetTimes: sheetTimes)
                    }
                }
                for try await done in group { finished.append(done) }
            }
        } catch {
            // A throw must leave neither a `.partial` that looks like a recording nor the
            // half of a job's outputs that did finish.
            for target in targets { try? FileManager.default.removeItem(at: target.url) }
            throw Self.named(error, video: video.id)
        }
        var outputs = targets.compactMap { target in finished.first { $0.output.url == target.url }?.output }
        let kept = finished.first { $0.poster != nil || !$0.cells.isEmpty }
        let poster = kept?.poster
        let sheet = kept?.cells ?? []

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
            let url = site.appending(path: single && job.suffix == nil ? "\(video.id).mp4" : "\(name).mp4")
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
                    text: $0.plain, start: $0.start, shown: $0.shown, needed: $0.needed,
                    margin: $0.shown - $0.needed)
            },
            motion: job.preset.name, warnings: job.timeline.warnings(for: job.preset),
            outputs: outputs.map(\.url.lastPathComponent),
            frames: job.track.frames, maxFrameGap: job.track.maxFrameGap)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: reportDir.appending(path: "\(name).report.json"), options: .atomic)
        return outputs
    }

    static func renderTarget(
        _ target: Target, job: Job, makeMaster: @Sendable () throws -> any VideoMaster, posterTime: Double,
        sheetTimes: [Double]
    ) async throws -> Rendered {
        var master = try makeMaster()
        let writer = try VideoWriter(url: target.url, size: target.style.size)
        var poster: CGImage?
        var cells: [ContactSheet.Cell] = []
        do {
            for i in 0..<job.timeline.frameCount {
                try Task.checkCancellation()
                let t = Double(i) / Double(VideoWriter.fps)
                let frame = try VideoFrame.render(
                    stage: try master.frame(at: t), t: t, timeline: job.timeline, style: target.style)
                try writer.append(frame)
                guard target.keepsFrames else { continue }
                if poster == nil, t >= posterTime { poster = frame }
                if let next = sheetTimes.dropFirst(cells.count).first, t >= next {
                    let label = job.timeline.caption(at: next).map { KineticText.plain($0.text) } ?? ""
                    cells.append(ContactSheet.Cell(time: next, label: label, image: frame))
                }
            }
            let url = try await writer.finish()
            return Rendered(
                output: Output(url: url, kind: target.kind, size: target.style.size), poster: poster,
                cells: cells)
        } catch {
            writer.cancel()
            throw error
        }
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
