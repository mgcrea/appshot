import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoComposeTests {
    static func setup(beats: String, duration: Double = 3) throws -> (VideoCompose.Options, URL) {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": \(duration), "outputs": { "promo": [[320, 200]], "website": true },
                   "card": { "title": "T" }, "beats": \(beats) }]
                """)
        config.fontFamily = "Helvetica"
        config.appearances = ["dark"]
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "vc-\(UUID())")
        let stills = root.appending(path: "shots")
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        try VideoMasterTests.solid(400, 250, gray: 0.9, to: stills.appending(path: "browser~dark.png"))
        try VideoMasterTests.solid(400, 250, gray: 0.2, to: stills.appending(path: "paywall~dark.png"))
        let options = VideoCompose.Options(
            config: config, configDir: root, sourceDir: root.appending(path: "source"),
            outDir: root.appending(path: "videos"), fromStills: stills, videos: nil, appearances: nil,
            websiteOut: root.appending(path: "site"))
        return (options, root)
    }

    @Test func composesAPromoFromStills() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser", "caption": "One" },
                 { "at": 1.5, "screen": "paywall" }]
                """)
        let outputs = try await VideoCompose.run(options)
        let promo = root.appending(path: "videos/promo/v~dark~320x200.mp4")
        #expect(outputs.map(\.url).contains(promo))
        let asset = AVURLAsset(url: promo)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.05)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "videos/promo/v~dark.poster.png").path))
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "videos/report/v~dark.report.json").path))
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "videos/report/v~dark.contact.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "site/v.mp4").path))
    }

    @Test func shortCaptionFailsBeforeWriting() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser", "caption": "far too many words to read here" },
                 { "at": 1, "caption": "next" }]
                """)
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .captionTooShort(_, let caption, _, _) = error as? AppShotError else { return false }
            return caption.hasPrefix("far too many")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func reportCarriesCaptionMargins() async throws {
        let (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser", "caption": "One" }]"#)
        _ = try await VideoCompose.run(options)
        let data = try Data(contentsOf: root.appending(path: "videos/report/v~dark.report.json"))
        let report = try JSONDecoder().decode(VideoCompose.Report.self, from: data)
        // "One": 1 word needs 1.3s, shown for the whole 3s.
        #expect(abs((report.captions.first?.margin ?? 0) - 1.7) < 0.01)
    }

    @Test func aPosterInTheLastFrameIntervalIsKept() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        options.config.videos![0].poster = 2.99
        _ = try await VideoCompose.run(options)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "videos/promo/v~dark.poster.png").path))
    }

    /// The second video's icon is missing; the first must not have been rendered.
    @Test func aMissingCardIconFailsBeforeAnyVideoIsWritten() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        var second = try options.config.video("v")
        second.id = "w"
        second.card = .init(title: "W", subtitle: nil, icon: "missing-icon.png")
        options.config.videos!.append(second)
        await #expect(throws: AppShotError.self) { _ = try await VideoCompose.run(options) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func aTrackWithoutItsMasterFailsBeforeWriting() async throws {
        var (options, root) = try Self.setup(beats: #"[{ "at": 0, "caption": "One" }]"#)
        options.fromStills = nil
        try FileManager.default.createDirectory(at: options.sourceDir, withIntermediateDirectories: true)
        let video = try options.config.video("v")
        try VideoTrack.stills(video: video, appearance: "dark", stageSize: CGSize(width: 400, height: 250))
            .write(to: VideoTrack.url(in: options.sourceDir, video: "v", appearance: "dark"))
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .missingCaptures(let names, _) = error as? AppShotError else { return false }
            return names == ["v~dark.mov"]
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func reportBeatsFollowTheConfigAndTheAcks() throws {
        let taken = try VideoTimelineTests.video(#"[{"at":0,"caption":"a"},{"at":2,"cue":"x"}]"#)
        let track = VideoRerenderTests.recorded(taken, acks: [2.05])
        // A caption added after the take is reported at its own time, with no latency.
        let edited = try VideoTimelineTests.video(
            #"[{"at":0,"caption":"a"},{"at":2,"cue":"x"},{"at":5,"caption":"b"}]"#)
        let timeline = try VideoTimeline(video: edited, track: track)
        let beats = VideoCompose.reportBeats(video: edited, track: track, timeline: timeline)
        #expect(beats.map(\.index) == [0, 1, 2])
        #expect(beats.map(\.scheduled) == [0, 2, 5])
        #expect(beats.map(\.actual) == [0, 2.05, 5])
        #expect(beats[0].latency == nil && beats[2].latency == nil)
        #expect(abs((beats[1].latency ?? 0) - 0.05) < 1e-9)
    }

    /// Fails on the second second of a 3 s video, after the writers have started.
    struct FailingMaster: VideoMaster {
        let stageSize = CGSize(width: 400, height: 250)
        var good: CGImage
        mutating func frame(at t: Double) throws -> CGImage {
            if t >= 1 { throw AppShotError.videoRenderFailed(video: "", reason: "boom") }
            return good
        }
    }

    @Test func midRenderFailureLeavesNoPartialAndNamesTheVideo() async throws {
        let (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        let stills = try #require(options.fromStills)
        var master = try StillsMaster(
            video: try options.config.video("v"), sourceDir: stills, appearance: "dark")
        let job = try Self.job(options)
        let good = try master.frame(at: 0)
        await #expect {
            _ = try await VideoCompose.render(
                job, options: options, master: FailingMaster(good: good))
        } throws: { error in
            guard case .videoRenderFailed(let video, _)? = error as? AppShotError else { return false }
            return video == "v"
        }
        let found = FileManager.default.enumerator(at: options.outDir, includingPropertiesForKeys: nil)
        let leftovers = (found?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "partial" }
        #expect(leftovers.isEmpty)
        _ = root
    }

    static func job(_ options: VideoCompose.Options) throws -> VideoCompose.Job {
        let video = try options.config.video("v")
        let stills = try #require(options.fromStills)
        let master = try StillsMaster(video: video, sourceDir: stills, appearance: "dark")
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: master.stageSize)
        return VideoCompose.Job(
            video: video, appearance: "dark", track: track,
            timeline: try VideoTimeline(video: video, track: track), icon: nil)
    }
}
