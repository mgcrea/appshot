import CoreGraphics
import CoreText
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
                [{ "id": "v", "duration": 20, "hook": "Hello *there*",
                   "outputs": { "preview": true, "promo": [[1080, 1080]] },
                   "card": { "title": "Armada", "subtitle": "armada.mgcrea.io", "cta": "Get it" },
                   "beats": [{ "at": 2, "caption": "Hello again" }, { "at": 18, "endCard": true }] }]
                """)
        config.fontFamily = "Helvetica"
        return config
    }

    static func styled(
        _ kind: VideoFrame.Kind, _ size: Config.Size, preset: MotionPreset = .kinetic,
        stage: CGSize = CGSize(width: 800, height: 500), appearance: String = "dark"
    ) throws -> (VideoFrame.Style, VideoTimeline) {
        let config = try Self.config()
        let video = try config.video("v")
        let track = VideoTrack.stills(video: video, appearance: appearance, stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: kind, size: size, config: config, appearance: appearance, video: video, stage: stage,
            icon: nil, preset: preset, timeline: timeline)
        return (style, timeline)
    }

    /// A stage of one colour no theme uses, so "is the window on screen" is a pixel test.
    static func green(_ w: Int = 800, _ h: Int = 500) throws -> CGImage {
        let ctx = try #require(Image.context(width: w, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try #require(ctx.makeImage())
    }

    static func hasGreen(_ image: CGImage) throws -> Bool {
        let px = try #require(Image.pixels(image))
        return stride(from: 0, to: px.bytes.count, by: 4).contains {
            px.bytes[$0] < 40 && px.bytes[$0 + 1] > 200 && px.bytes[$0 + 2] < 40
        }
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let px = try #require(Image.pixels(image))
        let i = (y * px.width + x) * 4
        return Array(px.bytes[i..<i + 4])
    }

    @Test func previewIsFullBleedOnTheDarkestStop() throws {
        let (style, timeline) = try Self.styled(.preview, .init(width: 1920, height: 1080))
        let frame = try VideoFrame.render(stage: Self.stage(), t: 19, timeline: timeline, style: style)
        #expect(frame.width == 1920 && frame.height == 1080)
        // Corner: the darkest stop #0D0E11, no gradient and no end card in a preview.
        #expect(try Self.pixel(frame, 2, 2).prefix(3) == [0x0D, 0x0E, 0x11])
        // The stage covers the middle.
        #expect(try Self.pixel(frame, 960, 480).prefix(3) == [255, 255, 255])
    }

    @Test func bandCaptionsReserveTheBand() throws {
        let (style, _) = try Self.styled(.promo, .init(width: 1080, height: 1080))
        #expect(style.bandHeight > 100)
        #expect(style.stageRect.minY >= style.bandHeight)
        #expect(style.stageRect.maxY <= 1080)
    }

    @Test func pillCaptionsLetTheWindowFillMoreOfTheFrame() throws {
        let (band, _) = try Self.styled(.promo, .init(width: 1920, height: 1080))
        let (pill, _) = try Self.styled(.promo, .init(width: 1920, height: 1080), preset: .studio)
        #expect(pill.stageRect.width > band.stageRect.width)
    }

    @Test func theWindowIsGoneOnceTheCardIsUp() throws {
        for preset in MotionPreset.all {
            let (style, timeline) = try Self.styled(.promo, .init(width: 540, height: 540), preset: preset)
            let frame = try VideoFrame.render(stage: Self.green(), t: 19.5, timeline: timeline, style: style)
            #expect(try !Self.hasGreen(frame), "\(preset.name)")
        }
    }

    /// A title or subtitle too long for one line wraps inside the margins, each line on
    /// its own baseline, and the subtitle starts below the title's last line.
    @Test func wrappedCardTextStacksInsideTheMargins() throws {
        let (style, _) = try Self.styled(.promo, .init(width: 1080, height: 1080))
        let card = Config.Card(
            title: "A product name long enough to need *several lines* on a square promo",
            subtitle: String(repeating: "and a subtitle far too long for one line ", count: 6), icon: nil,
            cta: nil)
        let text = try VideoFrame.cardText(card, style: style)
        let titleRows = Set(text.filter { $0.role == .title }.map(\.baseline))
        let subtitles = text.filter { $0.role == .subtitle }
        #expect(titleRows.count > 1 && subtitles.count > 1)
        #expect((subtitles.first?.baseline ?? 0) > (titleRows.max() ?? .infinity))
        let W = Double(style.size.width)
        #expect(
            text.allSatisfy {
                $0.x >= style.margin - 0.5
                    && $0.x + $0.width - CTLineGetTrailingWhitespaceWidth($0.line) <= W - style.margin + 0.5
            })
    }

    @Test func kineticOpensOnTheHookWithNoWindow() throws {
        let (style, timeline) = try Self.styled(.promo, .init(width: 320, height: 320))
        let frame = try VideoFrame.render(stage: Self.green(), t: 0.5, timeline: timeline, style: style)
        #expect(try !Self.hasGreen(frame))
        let later = try VideoFrame.render(stage: Self.green(), t: 4, timeline: timeline, style: style)
        #expect(try Self.hasGreen(later))

        // The hook is drawn: the same moment without one is a different frame.
        var config = try Self.config()
        config.videos![0].hook = nil
        let video = try config.video("v")
        let stageSize = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stageSize)
        let bare = try VideoTimeline(video: video, track: track)
        let bareStyle = try VideoFrame.style(
            kind: .promo, size: .init(width: 320, height: 320), config: config, appearance: "dark",
            video: video, stage: stageSize, icon: nil, preset: .kinetic, timeline: bare)
        let without = try VideoFrame.render(stage: Self.green(), t: 0.5, timeline: bare, style: bareStyle)
        #expect(Image.pngData(frame) != Image.pngData(without))
    }

    @Test func previewsNeverDrawTheHookOrTheCard() throws {
        let (style, timeline) = try Self.styled(.preview, .init(width: 1920, height: 1080))
        let inside = style.stageRect.insetBy(dx: 4, dy: 4)
        for t in [0.9, 19.5] {
            let frame = try VideoFrame.render(stage: Self.green(), t: t, timeline: timeline, style: style)
            let px = try #require(Image.pixels(frame))
            // The hook and the card title are centred, so either would land on the window.
            var other = 0
            for y in Int(inside.minY)..<Int(inside.maxY) {
                for x in Int(inside.minX)..<Int(inside.maxX) {
                    let i = (y * px.width + x) * 4
                    if !(px.bytes[i] < 40 && px.bytes[i + 1] > 200 && px.bytes[i + 2] < 40) { other += 1 }
                }
            }
            #expect(other == 0, "t=\(t)")
        }
    }

    @Test func aHookTooTallForItsCardFailsClearly() throws {
        var config = try Self.config()
        config.videos![0].hook = String(repeating: "word ", count: 40)
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        #expect {
            _ = try VideoFrame.style(
                kind: .promo, size: .init(width: 1080, height: 1920), config: config, appearance: "dark",
                video: video, stage: stage, icon: nil, preset: .kinetic, timeline: timeline)
        } throws: { error in
            guard case .videoRenderFailed(_, let why) = error as? AppShotError else { return false }
            return why.contains("leaves no room")
        }
    }

    @Test func studioTitlesTakeNoAccentColour() throws {
        var config = try Self.config()
        config.themes["dark"]!.accent = "#FF0000"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        func reds(_ preset: MotionPreset) throws -> Int {
            let style = try VideoFrame.style(
                kind: .promo, size: .init(width: 540, height: 540), config: config, appearance: "dark",
                video: video, stage: stage, icon: nil, preset: preset, timeline: timeline)
            let card = Config.Card(title: "Plain *accent* title", subtitle: nil, icon: nil, cta: nil)
            let canvas = try #require(VideoCanvas(width: 540, height: 540))
            for line in try VideoFrame.cardText(card, style: style) {
                canvas.text(line.line, x: line.x, baseline: line.baseline)
            }
            let image = try #require(canvas.makeImage())
            let px = try #require(Image.pixels(image))
            return stride(from: 0, to: px.bytes.count, by: 4).filter {
                px.bytes[$0 + 3] > 200 && px.bytes[$0] > 200 && px.bytes[$0 + 1] < 60 && px.bytes[$0 + 2] < 60
            }.count
        }
        #expect(try reds(.kinetic) > 0)
        #expect(try reds(.studio) == 0)
    }

    @Test func aPreviewWindowIsAtRestFromFrameZero() throws {
        for preset in MotionPreset.all {
            let (style, timeline) = try Self.styled(
                .preview, .init(width: 1920, height: 1080), preset: preset)
            let frame = try VideoFrame.render(stage: Self.green(), t: 0, timeline: timeline, style: style)
            let r = style.stageRect
            let px = try Self.pixel(frame, Int(r.midX), Int(r.midY))
            #expect(px[0] < 40 && px[1] > 200 && px[2] < 40, "\(preset.name)")
            let p = style.camera.placement(at: 0)
            #expect(abs(p.rect.minY - r.minY) < 1 && p.alpha == 1, "\(preset.name)")
        }
    }

    @Test func aFrameIsAFunctionOfItsTime() throws {
        let (style, timeline) = try Self.styled(.promo, .init(width: 320, height: 320))
        let a = try VideoFrame.render(stage: Self.green(), t: 3.3, timeline: timeline, style: style)
        let b = try VideoFrame.render(stage: Self.green(), t: 3.3, timeline: timeline, style: style)
        #expect(Image.pngData(a) == Image.pngData(b))
    }

    @Test func theScrimContrastsWithTheCaption() throws {
        let config = try Self.config()
        func luma(_ hex: String) -> Double {
            let c = Image.color(hex: hex)!.components!
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        for (name, theme) in config.themes {
            let gap = abs(luma(VideoFrame.scrim(theme)) - luma(theme.title))
            #expect(gap > 0.4, "\(name)")
        }
    }

    @Test func aHookTooLongForTheCanvasFailsClearly() throws {
        var config = try Self.config()
        config.videos![0].hook = String(repeating: "word ", count: 60)
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        #expect {
            _ = try VideoFrame.style(
                kind: .promo, size: .init(width: 320, height: 200), config: config, appearance: "dark",
                video: video, stage: stage, icon: nil, preset: .kinetic, timeline: timeline)
        } throws: { error in
            guard case .videoRenderFailed(_, let why) = error as? AppShotError else { return false }
            return why.contains("leaves no room")
        }
    }
}
