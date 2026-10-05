import AVFoundation
import Foundation
import Testing

@testable import AppShotKit

struct VideoComposeClipsTests {
    /// The compose tests' stills (browser and paywall, 400×250) plus a clips directory.
    static func setup(beats: String, duration: Double = 3) throws -> (VideoCompose.Options, URL) {
        var (options, root) = try VideoComposeTests.setup(beats: beats, duration: duration)
        let clips = root.appending(path: "clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        options.fromClips = clips
        return (options, root)
    }

    static func report(_ root: URL) throws -> VideoCompose.Report {
        try JSONDecoder().decode(
            VideoCompose.Report.self,
            from: Data(contentsOf: root.appending(path: "videos/report/v~dark.report.json")))
    }

    @Test func mixesAClipAndAStill() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser", "caption": "One" },
                 { "at": 1.5, "screen": "paywall" }]
                """)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 3
        ) { $0 / 3 }
        var lines: [String] = []
        let outputs = try await VideoCompose.run(options) { lines.append($0) }
        let promo = root.appending(path: "videos/promo/v~dark~320x200.mp4")
        #expect(outputs.map(\.url).contains(promo))
        #expect(abs(try await AVURLAsset(url: promo).load(.duration).seconds - 3) < 0.05)
        #expect(lines.contains("v~dark: clips browser · stills paywall"))
        let report = try Self.report(root)
        #expect(report.beats.map(\.source) == ["clip", "still"])
        #expect(report.beats[0].clip?.frames == 90)
        #expect(report.beats[1].clip == nil)
        #expect(report.frames == 90)
    }

    @Test func aClipTooShortFailsBeforeAnyFileIsWritten() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser" }, { "at": 1.5, "screen": "paywall" }]
                """)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 1
        ) { _ in 0 }
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .clipTooShort? = error as? AppShotError else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }

    @Test func clipWarningsReachTheReport() async throws {
        let (options, root) = try Self.setup(beats: #"[{ "at": 0, "screen": "browser" }]"#)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 4,
            frames: 1
        ) { _ in 0 }
        var lines: [String] = []
        _ = try await VideoCompose.run(options) { lines.append($0) }
        #expect(try Self.report(root).warnings.map(\.kind).contains("clipNeverMoved"))
        #expect(lines.contains { $0.hasPrefix("  warning: browser~dark has 1 frames") })
    }

    @Test func anEmptyClipsDirectoryRendersFromStills() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser" }, { "at": 1.5, "screen": "paywall" }]
                """)
        var lines: [String] = []
        _ = try await VideoCompose.run(options) { lines.append($0) }
        let report = try Self.report(root)
        #expect(report.beats.map(\.source) == ["still", "still"])
        #expect(report.frames == 0)
        #expect(lines.contains("v~dark: stills browser, paywall"))
    }

    @Test func aClipsRenderLabelsItsContactSheetCells() async throws {
        let (options, root) = try Self.setup(
            beats: """
                [{ "at": 0, "screen": "browser", "caption": "One" },
                 { "at": 1.5, "screen": "paywall", "caption": "Two" }]
                """)
        try await ClipsMasterTests.writeClip(
            dir: try #require(options.fromClips), screen: "browser", width: 400, height: 250, seconds: 3
        ) { _ in 0.5 }
        let cells = try await VideoCompose.contactLabels(options)
        #expect(cells.contains { $0.hasPrefix("One · clip") })
        #expect(cells.contains { $0.hasPrefix("Two · still") })
        _ = root
    }

    @Test func clipsAreRefusedForAnIOSConfig() async throws {
        // An iOS config only validates with `devices[]`, so this starts from the iPhone
        // setup. Its stills stay set: the refusal must come from `--from-clips` alone.
        var (options, root) = try VideoComposeTests.iosSetup()
        options.fromClips = root.appending(path: "clips")
        await #expect {
            _ = try await VideoCompose.run(options)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason == Recorder.iosReason
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "videos").path))
    }
}
