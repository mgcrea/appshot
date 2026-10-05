import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Needs Screen Recording for the test runner and `make fixture` first. Never on CI.
/// Waits for the capture lock, which `RecorderIntegrationTests` takes at the same time.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["APPSHOT_INTEGRATION"] == "1"))
struct ClipRecorderIntegrationTests {
    @Test func recordsAMovingClipAndADeafOneThenComposesThem() async throws {
        let config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-clips.config.json"))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clips-\(UUID())")
        let options = ClipRecorder.Options(
            capture: Capture.Options(
                app: RecorderIntegrationTests.app, outDir: out,
                screens: [
                    try Capture.Screen(spec: "moving:instant"), try Capture.Screen(spec: "deaf:clip-deaf"),
                ],
                appearances: ["dark"], wait: true, noActivate: true),
            config: config, videos: config.videos ?? [])
        let clips = try await ClipRecorder.run(options)
        #expect(clips.map(\.screen) == ["deaf", "moving"])

        let moving = try ClipInfo.read(ClipInfo.url(in: out, screen: "moving", appearance: "dark"))
        // Held 2 s, plus the crossfade and the margin.
        #expect(moving.length >= 3 - 0.05)
        // The fixture animates every 0.1 s: a 3 s clip has far more than a handful of frames.
        #expect(moving.frames > 10)
        #expect(moving.stage == "instant")

        let video = try config.video("clips")
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: out, stillsDir: nil)
        try ClipsMaster.check(video: video, segments: segments)
        #expect(
            ClipsMaster.warnings(for: segments, stillsDir: nil).map(\.message).contains {
                $0.hasPrefix("deaf~dark has")
            })
        #expect(
            !ClipsMaster.warnings(for: segments, stillsDir: nil).contains { $0.message.hasPrefix("moving") })

        var master = try ClipsMaster(segments: segments, video: "clips")
        let px = try #require(Image.pixels(try master.frame(at: 1)))
        #expect(px.bytes[3] <= 5)  // a window corner stays transparent

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter {
            $0.hasSuffix(".partial")
        }
        #expect(leftovers.isEmpty)
        #expect(Capture.pids(named: "AppShotFixture").isEmpty)
    }
}
