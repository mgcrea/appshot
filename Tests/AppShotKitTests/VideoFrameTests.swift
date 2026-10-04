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

        // The hook is drawn: with no window and no caption yet, whatever differs from the
        // bare background in the centre of the frame is the hook's text.
        let canvas = try #require(VideoCanvas(width: 320, height: 320))
        VideoFrame.drawBackground(canvas, t: 0.5, style: style)
        let bare = try #require(canvas.makeImage())
        let a = try #require(Image.pixels(frame))
        let b = try #require(Image.pixels(bare))
        var changed = 0
        for y in 100..<220 {
            for x in 0..<320 {
                let i = (y * 320 + x) * 4
                if abs(Int(a.bytes[i]) - Int(b.bytes[i])) > 60 { changed += 1 }
            }
        }
        #expect(changed > 50)
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

    /// A white stage with a red block at `red`, and a video that spotlights or pops it.
    static func emphasis(
        _ key: String, rect: [Double], preset: MotionPreset,
        size: Config.Size = .init(width: 640, height: 640),
        paint: (CGContext) -> Void = { _ in }
    ) throws -> (VideoFrame.Style, VideoTimeline, CGImage) {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 10, "outputs": { "promo": [[\(size.width), \(size.height)]] },
                   "beats": [{ "at": 1, "\(key)": { "rect": \(rect), "until": 8 } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: .promo, size: size, config: config, appearance: "dark", video: video, stage: stage,
            icon: nil,
            preset: preset, timeline: timeline)
        let ctx = try #require(Image.context(width: 800, height: 500))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // y-up context: flip the y-down rect.
        ctx.fill(CGRect(x: rect[0], y: 500 - rect[1] - rect[3], width: rect[2], height: rect[3]))
        paint(ctx)
        return (style, timeline, try #require(ctx.makeImage()))
    }

    @Test func aSpotlightDimsEverythingButItsRegion() throws {
        let (style, timeline, stage) = try Self.emphasis(
            "spotlight", rect: [300, 200, 200, 100], preset: .studio)
        let t = 4.0
        let frame = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        let placed = style.camera.placement(at: t)
        let outside = placed.map(CGPoint(x: 100, y: 100))
        let inside = placed.map(CGPoint(x: 310, y: 250))
        let o = try Self.pixel(frame, Int(outside.x), Int(outside.y))
        let i = try Self.pixel(frame, Int(inside.x), Int(inside.y))
        #expect(o[1] < 200)  // white stage, dimmed
        #expect(i[0] > 200)  // red block, not dimmed
    }

    @Test func aPopLiftsAnEnlargedCopyOfItsRegion() throws {
        let (style, timeline, stage) = try Self.emphasis("pop", rect: [300, 200, 200, 100], preset: .kinetic)
        let t = 4.0
        let frame = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        let base = style.camera.placement(at: t).map(CGRect(x: 300, y: 200, width: 200, height: 100))
        let lift = style.minDim * 0.012
        // Just right of the region itself, but inside its 1.32x copy.
        let p = try Self.pixel(frame, Int(base.maxX + base.width * 0.08), Int(base.midY - lift))
        #expect(p[0] > 180 && p[1] < 80)
    }

    @Test func aPopPastTheStageEdgeDrawsOnlyWhatExists() throws {
        // Only [700, 400, 100, 100] of this region exists. Its left half is red and its right
        // half blue, so a clipped crop stretched over the full 300x200 rect lands elsewhere.
        let (style, timeline, stage) = try Self.emphasis(
            "pop", rect: [700, 400, 300, 200], preset: .kinetic
        ) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 700, y: 0, width: 50, height: 500))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 750, y: 0, width: 50, height: 500))
        }
        for t in stride(from: 0.5, through: 9.5, by: 0.5) {
            _ = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        }
        let t = 4.0
        let frame = try VideoFrame.render(stage: stage, t: t, timeline: timeline, style: style)
        // Where the lifted copy of the existing 100x100 part belongs: grown about its centre,
        // clamped inside the canvas, lifted a little.
        let base = style.camera.placement(at: t).map(CGRect(x: 700, y: 400, width: 100, height: 100))
        let W = Double(style.size.width)
        var dest = base.insetBy(dx: -base.width * 0.16, dy: -base.height * 0.16)
        dest.origin.x = min(max(dest.minX, W * 0.03), W * 0.97 - dest.width)
        dest.origin.y -= style.minDim * 0.012
        let y = Int(dest.midY)
        let left = try Self.pixel(frame, Int(dest.minX + dest.width * 0.25), y)
        let right = try Self.pixel(frame, Int(dest.minX + dest.width * 0.75), y)
        #expect(left[0] > 200 && left[2] < 60)  // red half
        #expect(right[2] > 200 && right[0] < 60)  // blue half
        // Below the copy there is only the canvas: nothing was stretched down there.
        let below = try Self.pixel(
            frame, Int(dest.minX + dest.width * 0.75), Int(dest.maxY + dest.height * 0.15))
        #expect(!(below[2] > 200 && below[0] < 60) && !(below[0] > 200 && below[2] < 60))
    }

    @Test func thePointerIsDrawnOnItsPoint() throws {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 6, "motion": "studio", "outputs": { "promo": [[640, 640]] },
                   "beats": [{ "at": 1, "pointer": { "point": [400, 250] } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 640, height: 640), config: config, appearance: "dark",
            video: video,
            stage: stage, icon: nil, preset: .studio, timeline: timeline)
        let frame = try VideoFrame.render(stage: Self.stage(), t: 2, timeline: timeline, style: style)
        let placed = style.camera.placement(at: 2)
        let tip = placed.map(CGPoint(x: 400, y: 250))
        let size = style.minDim * 0.03 * placed.zoom.squareRoot()
        let inArrow = try Self.pixel(frame, Int(tip.x + size * 0.12), Int(tip.y + size * 0.6))
        #expect(inArrow[0] < 60)  // the arrow's black fill on a white stage
    }

    @Test func fastMovesAreBlurredAndStillFramesAreNot() throws {
        var config = try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 6, "outputs": { "promo": [[320, 320]] },
                   "beats": [{ "at": 1, "focus": { "rect": [0, 0, 100, 60] } }] }]
                """)
        config.fontFamily = "Helvetica"
        let video = try config.video("v")
        let stage = CGSize(width: 800, height: 500)
        let track = VideoTrack.stills(video: video, appearance: "dark", stageSize: stage)
        let timeline = try VideoTimeline(video: video, track: track)
        var preset = MotionPreset.kinetic
        preset.drift = 0
        let style = try VideoFrame.style(
            kind: .promo, size: .init(width: 320, height: 320), config: config, appearance: "dark",
            video: video,
            stage: stage, icon: nil, preset: preset, timeline: timeline)
        let image = try Self.stage()
        let moving = 1.15
        #expect(
            Image.pngData(try VideoFrame.render(stage: image, t: moving, timeline: timeline, style: style))
                != Image.pngData(
                    try VideoFrame.layers(stage: image, t: moving, timeline: timeline, style: style)))
        let still = 5.5
        #expect(
            Image.pngData(try VideoFrame.render(stage: image, t: still, timeline: timeline, style: style))
                == Image.pngData(
                    try VideoFrame.layers(stage: image, t: still, timeline: timeline, style: style)))
    }
}
