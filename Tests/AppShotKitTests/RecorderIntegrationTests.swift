import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Needs Screen Recording for the test runner and `make fixture` first. Never on CI.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["APPSHOT_INTEGRATION"] == "1"))
struct RecorderIntegrationTests {
    static let app = URL(fileURLWithPath: ".build/fixture/AppShotFixture.app")

    @Test func recordsTheFixtureWithEveryCueAcked() async throws {
        let config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-video.config.json"))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(
                app: Self.app, outDir: out, screens: [], appearances: ["dark"], noActivate: true),
            videos: [try config.video("fixture")])
        let takes = try await Recorder.run(options)
        let track = try VideoTrack.read(try #require(takes.first).track)
        let video = try config.video("fixture")
        #expect(track.cues.map(\.cue) == video.beats.compactMap(\.cue))
        #expect(track.cues.allSatisfy { $0.acked != nil })
        #expect(track.cues.allSatisfy { ($0.acked ?? 9) - $0.at < CuePolicy.failLatency })
        // The take renders against the config it was recorded from.
        _ = try VideoTimeline(video: video, track: track)
        #expect(track.targets.contains { $0.name == "row-3" && $0.click })
        let master = try RecordedMaster(url: try #require(takes.first).master, track: track)
        let frame = try master.frame(at: 0.2)
        let px = try #require(Image.pixels(frame))
        // A window corner is transparent; the window's middle is not. Thresholds rather
        // than 0 and 255: HEVC alpha is lossy, and the spike read 253 for an opaque pixel.
        let middle: Int = ((frame.height / 2) * frame.width + frame.width / 2) * 4 + 3
        #expect(px.bytes[3] <= 5)
        #expect(px.bytes[middle] >= 250)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov.partial").path))
    }

    /// The second window opens beside the first, so its pixels can only be in the master
    /// if it joined the recording: before the cue that spot is outside every window.
    @Test func aWindowOpenedMidTakeJoinsTheRecording() async throws {
        var config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-video.config.json"))
        config.videos![0].beats.insert(.init(at: 1.0, cue: "fixture.window"), at: 2)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(
                app: Self.app, outDir: out, screens: [], appearances: ["dark"], noActivate: true),
            videos: [config.videos![0]])
        let take = try #require(try await Recorder.run(options).first)
        let track = try VideoTrack.read(take.track)
        let window = try #require(track.targets.first { $0.name == "window-2" })
        let x = Int(window.rect[0] + window.rect[2] / 2)
        let y = Int(window.rect[1] + window.rect[3] / 2)
        let master = try RecordedMaster(url: take.master, track: track)
        func alpha(at t: Double) throws -> UInt8 {
            let px = try #require(Image.pixels(try master.frame(at: t)))
            return px.bytes[(y * px.width + x) * 4 + 3]
        }
        #expect(try alpha(at: 0.5) <= 5)
        #expect(try alpha(at: 3) >= 250)
        #expect(Capture.pids(named: "AppShotFixture").isEmpty)
    }

    @Test func unknownCueFailsAndLeavesNothingRunning() async throws {
        var config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-video.config.json"))
        config.videos![0].beats.insert(.init(at: 0.5, cue: "no.such.cue"), at: 1)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(
                app: Self.app, outDir: out, screens: [], appearances: ["dark"], noActivate: true),
            videos: [config.videos![0]])
        await #expect {
            _ = try await Recorder.run(options)
        } throws: { error in
            guard case .cueFailed(_, _, let cue, _) = error as? AppShotError else { return false }
            return cue == "no.such.cue"
        }
        #expect(Capture.pids(named: "AppShotFixture").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov").path))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov.partial").path))
    }

    /// The `instant` stage opens a window but never speaks the event contract.
    @Test func neverReadyFailsAndLeavesNothingRunning() async throws {
        var config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-video.config.json"))
        config.videos![0].stage = "instant"
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(
                app: Self.app, outDir: out, screens: [], appearances: ["dark"], settleMax: 1, noActivate: true
            ),
            videos: [config.videos![0]])
        await #expect {
            _ = try await Recorder.run(options)
        } throws: { error in
            guard case .recordFailed(_, let reason) = error as? AppShotError else { return false }
            return reason.contains("no ready event")
        }
        #expect(Capture.pids(named: "AppShotFixture").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov").path))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "fixture~dark.mov.partial").path))
    }
}
