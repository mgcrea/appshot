import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Round spotlights and pops: a circle for a round element, a ring for one generation
/// of a fan chart. They must light and lift that shape, not the rectangle around it.
struct VideoShapeTests {
    @Test func aRingSectorIsBoundedByItsArcs() throws {
        // The quarter from straight up (270°) to east (360°), y-down.
        let quarter = VideoShape.ring(
            center: CGPoint(x: 100, y: 100), inner: 10, outer: 20, from: 270, to: 360)
        #expect(quarter.bounds == CGRect(x: 100, y: 80, width: 20, height: 20))
        // The upper half crosses straight up, so its top is the outer radius above the centre.
        let upper = VideoShape.ring(center: CGPoint(x: 100, y: 100), inner: 10, outer: 20, from: 180, to: 360)
        #expect(upper.bounds == CGRect(x: 80, y: 80, width: 40, height: 20))
        let circle = VideoShape.circle(center: CGPoint(x: 50, y: 60), radius: 5)
        #expect(circle.bounds == CGRect(x: 45, y: 55, width: 10, height: 10))
    }

    @Test(arguments: [
        (#"{"at":2,"spotlight":{"circle":[1,2],"until":3}}"#, "circle must be [cx, cy, radius]"),
        (#"{"at":2,"spotlight":{"circle":[1,2,0],"until":3}}"#, "circle must be [cx, cy, radius]"),
        (#"{"at":2,"pop":{"circle":[1,2,3],"rect":[0,0,1,1],"until":3}}"#, "exactly one of"),
        (#"{"at":2,"spotlight":{"ring":{"center":[1],"inner":1,"outer":2},"until":3}}"#, "center must be"),
        (
            #"{"at":2,"spotlight":{"ring":{"center":[1,2],"inner":3,"outer":2},"until":3}}"#,
            "0 <= inner < outer"
        ),
        (
            #"{"at":2,"spotlight":{"ring":{"center":[1,2],"inner":1,"outer":2,"from":10},"until":3}}"#,
            "both from and to"
        ),
        (
            #"{"at":2,"spotlight":{"ring":{"center":[1,2],"inner":1,"outer":2,"from":0,"to":400},"until":3}}"#,
            "at most 360"
        ),
    ])
    func rejectsABadShape(beat: String, reason: String) throws {
        let config = try VideoConfigTests.config(
            videos: """
                [{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},
                  "beats":[{"at":0,"screen":"browser"},\(beat)]}]
                """)
        #expect {
            try config.validate()
        } throws: { error in
            "\(error)".contains(reason)
        }
    }

    @Test func aGoodShapeValidates() throws {
        let config = try VideoConfigTests.config(
            videos: """
                [{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},
                  "beats":[{"at":0,"screen":"browser"},
                           {"at":2,"spotlight":{"ring":{"center":[1,2],"inner":0,"outer":2,"from":180,"to":360},"until":3}},
                           {"at":4,"pop":{"circle":[1,2,3],"until":6}}]}]
                """)
        #expect(throws: Never.self) { try config.validate() }
    }

    /// A white 800x500 stage with a red disk of radius 80 at (400, 250), and a video that
    /// spotlights or pops `region` from 1 s to 8 s.
    static func render(
        _ key: String, _ region: String, preset: MotionPreset, at t: Double = 4
    ) throws -> (frame: CGImage, style: VideoFrame.Style, t: Double) {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 10, "outputs": { "promo": [[640, 640]] },
                   "beats": [{ "at": 1, "\(key)": { \(region), "until": 8 } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stageSize = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stageSize)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 640, height: 640), config: config, appearance: "dark",
            video: video, stage: stageSize, icon: nil, preset: preset, timeline: timeline)
        let ctx = try #require(Image.context(width: 800, height: 500))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 320, y: 170, width: 160, height: 160))  // symmetric, so y-up is fine
        let stage = try #require(ctx.makeImage())
        return (try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style), style, t)
    }

    static func at(_ r: (frame: CGImage, style: VideoFrame.Style, t: Double), _ x: Double, _ y: Double) throws
        -> [UInt8]
    {
        let p = r.style.camera.placement(at: r.t).map(CGPoint(x: x, y: y))
        return try VideoFrameTests.pixel(r.frame, Int(p.x), Int(p.y))
    }

    @Test func aCircleSpotlightLightsTheCircleNotItsCorners() throws {
        let r = try Self.render("spotlight", #""circle": [400, 250, 100]"#, preset: .studio)
        // Inside the circle but off the red disk: white, undimmed.
        #expect(try Self.at(r, 400, 160)[1] > 230)
        // The corner of the circle's square: dimmed.
        #expect(try Self.at(r, 315, 165)[1] < 200)
    }

    @Test func aRingSpotlightLightsOnlyItsSector() throws {
        // The upper half of the ring from 90 to 140 px out.
        let r = try Self.render(
            "spotlight",
            #""ring": { "center": [400, 250], "inner": 90, "outer": 140, "from": 180, "to": 360 }"#,
            preset: .studio)
        #expect(try Self.at(r, 400, 135)[1] > 230)  // in the sector, above the centre
        #expect(try Self.at(r, 400, 365)[1] < 200)  // the same radius below: not in the sector
        #expect(try Self.at(r, 400, 250)[0] < 200)  // inside the inner radius: the disk, dimmed
    }

    @Test func aCirclePopLiftsARoundCopy() throws {
        let r = try Self.render("pop", #""circle": [400, 250, 80]"#, preset: .kinetic)
        let placed = r.style.camera.placement(at: r.t)
        let base = placed.map(CGRect(x: 320, y: 170, width: 160, height: 160))
        let lift = r.style.minDim * 0.012
        // Past the disk's own edge but inside its 1.32x round copy: red.
        let inside = try VideoFrameTests.pixel(
            r.frame, Int(base.midX + base.width / 2 * 1.15), Int(base.midY - lift))
        #expect(inside[0] > 180 && inside[1] < 80)
        // The corner of the lifted square is outside the round copy, so it shows the dimmed
        // window: not red, and not the white a square copy of the crop would put there.
        let s = 1.32
        let corner = try VideoFrameTests.pixel(
            r.frame, Int(base.midX + base.width / 2 * s * 0.92),
            Int(base.midY - lift - base.height / 2 * s * 0.92))
        #expect(corner[1] > 60 && corner[1] < 200)
    }
}
