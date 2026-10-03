import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoFrameTests {
    /// A stage that is solid white, so anything drawn on top is easy to find.
    static func stage(_ w: Int = 800, _ h: Int = 500) throws -> CGImage {
        let ctx = try #require(Image.context(width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try #require(ctx.makeImage())
    }

    static func config() throws -> Config {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 20, "outputs": { "preview": true, "promo": [[1080, 1080]] },
                   "card": { "title": "Armada", "subtitle": "armada.mgcrea.io" },
                   "beats": [{ "at": 0, "caption": "Hello there" }, { "at": 18, "endCard": true }] }]
                """)
        config.fontFamily = "Helvetica"
        return config
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let px = try #require(Image.pixels(image))
        let i = (y * px.width + x) * 4
        return Array(px.bytes[i..<i + 4])
    }

    @Test func previewIsFullBleedOnTheDarkestStop() throws {
        let config = try Self.config()
        let video = try config.video("v")
        let stageSize = CGSize(width: 800, height: 500)
        let style = try VideoFrame.style(
            kind: .preview, size: .init(width: 1920, height: 1080), config: config,
            appearance: "dark", video: video, stage: stageSize, icon: nil)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stageSize)
        let timeline = try VideoTimeline(video: video, track: track)
        let frame = try VideoFrame.render(stage: Self.stage(), t: 19, timeline: timeline, style: style)
        #expect(frame.width == 1920 && frame.height == 1080)
        // Corner: the darkest stop #0D0E11, no gradient and no end card in a preview.
        #expect(try Self.pixel(frame, 2, 2).prefix(3) == [0x0D, 0x0E, 0x11])
        // The stage covers the middle.
        #expect(try Self.pixel(frame, 960, 480).prefix(3) == [255, 255, 255])
    }

    @Test func promoReservesRoomForTheCaption() throws {
        let config = try Self.config()
        let video = try config.video("v")
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 1080, height: 1080), config: config,
            appearance: "dark", video: video, stage: CGSize(width: 800, height: 500), icon: nil)
        #expect(style.stageRect.minY > 100)
        #expect(style.stageRect.maxY <= 1080)
    }

    @Test func endCardCoversThePromo() throws {
        let config = try Self.config()
        let video = try config.video("v")
        let stageSize = CGSize(width: 800, height: 500)
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 1080, height: 1080), config: config,
            appearance: "dark", video: video, stage: stageSize, icon: nil)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stageSize)
        let timeline = try VideoTimeline(video: video, track: track)
        let frame = try VideoFrame.render(stage: Self.stage(), t: 19.9, timeline: timeline, style: style)
        // Where the white stage was, the card's gradient now is.
        let center = try Self.pixel(frame, Int(style.stageRect.midX), Int(style.stageRect.maxY) - 10)
        #expect(center[0] < 200)
    }
}
