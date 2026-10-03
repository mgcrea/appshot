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
        let cued = track.beats.filter { config.videos![0].beats[$0.index].cue != nil }
        #expect(cued.allSatisfy { $0.acked != nil })
        #expect(cued.allSatisfy { ($0.acked ?? 9) - $0.scheduled < CuePolicy.failLatency })
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
