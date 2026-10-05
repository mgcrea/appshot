import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Runs inside `FixtureIntegrationTests`, which gates it and keeps it from running
/// beside the other suites that film the fixture.
extension FixtureIntegrationTests {
    @Suite struct ClipRecorderIntegrationTests {
        @Test func recordsAMovingClipAndADeafOneThenComposesThem() async throws {
            let config = try Config.load(URL(fileURLWithPath: "Scripts/fixture-clips.config.json"))
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clips-\(UUID())")
            let options = ClipRecorder.Options(
                capture: Capture.Options(
                    app: RecorderIntegrationTests.app, outDir: out,
                    screens: [
                        try Capture.Screen(spec: "moving:instant"),
                        try Capture.Screen(spec: "deaf:clip-deaf"),
                    ],
                    appearances: ["dark"], noActivate: true),
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
                !ClipsMaster.warnings(for: segments, stillsDir: nil).contains {
                    $0.message.hasPrefix("moving")
                })

            var master = try ClipsMaster(segments: segments, video: "clips")
            let px = try #require(Image.pixels(try master.frame(at: 1)))
            #expect(px.bytes[3] <= 5)  // a window corner stays transparent

            // The still of the same stage puts the same sRGB values on the canvas, or a
            // crossfade between a clip and a still fallback jumps.
            var stills = options.capture
            stills.outDir = out.appending(path: "stills")
            stills.screens = [try Capture.Screen(spec: "moving:instant")]
            let shot = try #require(try await Capture.run(stills).first)
            let still = try #require(Image.pixels(try Image.load(shot.url)))
            #expect(abs(Double(still.width) - moving.size.width) <= ClipsMaster.sizeTolerance)
            #expect(abs(Double(still.height) - moving.size.height) <= ClipsMaster.sizeTolerance)
            // The clip sits centred on the master's canvas; the still is drawn the same way.
            let dx = (px.width - Int(moving.size.width)) / 2
            let dy = (px.height - Int(moving.size.height)) / 2
            for (name, region, tolerance) in Self.flatRegions(width: still.width, height: still.height) {
                let s = Self.mean(still, region)
                let c = Self.mean(px, region.offsetBy(dx: Double(dx), dy: Double(dy)))
                let worst = zip(s, c).map { abs($0 - $1) }.max() ?? 0
                #expect(worst <= tolerance, "\(name): still \(s), clip \(c)")
            }

            let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter {
                $0.hasSuffix(".partial")
            }
            #expect(leftovers.isEmpty)
            #expect(Capture.pids(named: "AppShotFixture").isEmpty)
        }

        /// Flat regions of the fixture's window, y-down in window pixels, with the tone
        /// tolerance for each: the body's dark grey, and the header's saturated blue. Both
        /// stay clear of the rows, of the orange square that moves at x 560-660 pt, and of
        /// the window's top-left corner. The content view is 800x520 pt at the bottom of the
        /// window, under the title bar.
        static func flatRegions(width: Int, height: Int) -> [(String, CGRect, Double)] {
            let scale = Double(width) / 800
            let top = Double(height) - 520 * scale
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
                CGRect(x: x * scale, y: top + y * scale, width: w * scale, height: h * scale)
            }
            return [("body grey", rect(40, 390, 260, 100), 2), ("header blue", rect(120, 12, 380, 40), 4)]
        }

        /// The mean of each colour channel over `rect`, y-down.
        static func mean(_ px: Image.Pixels, _ rect: CGRect) -> [Double] {
            var sum: [Double] = [0, 0, 0]
            var count = 0.0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    for c in 0..<3 { sum[c] += Double(px.at(x, y, c)) }
                    count += 1
                }
            }
            return sum.map { ($0 / max(count, 1) * 10).rounded() / 10 }
        }
    }
}
