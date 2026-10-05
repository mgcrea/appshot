import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct ClipsMasterTests {
    /// A clip `seconds` long at 30 fps, opaque, each frame filled with `gray(t)`, and its
    /// sidecar. Shared with the compose tests.
    static func writeClip(
        dir: URL, screen: String, appearance: String = "dark", width: Int = 100, height: Int = 50,
        seconds: Double, frames: Int? = nil, lightsPatch: ClipInfo.LightsPatch? = nil,
        gray: (Double) -> Double
    ) async throws {
        let url = ClipInfo.movieURL(in: dir, screen: screen, appearance: appearance)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let count = Int((seconds * 30).rounded())
        for i in 0..<count {
            let ctx = try #require(Image.context(width: width, height: height))
            ctx.setFillColor(
                CGColor(
                    srgbRed: gray(Double(i) / 30), green: gray(Double(i) / 30), blue: gray(Double(i) / 30),
                    alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(ctx.makeImage())
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pool = try #require(adaptor.pixelBufferPool)
            adaptor.append(
                try VideoWriter.pixelBuffer(image, pool: pool),
                withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try ClipInfo(
            screen: screen, stage: screen, appearance: appearance, length: seconds,
            crop: [0, 0, Double(width), Double(height)], lightsPatch: lightsPatch,
            frames: frames ?? count, maxFrameGap: 1.0 / 30, appshotVersion: "test",
            recordedAt: "2026-10-05T12:00:00Z"
        ).write(to: ClipInfo.url(in: dir, screen: screen, appearance: appearance))
    }

    static func video(duration: Double = 6, _ cuts: [(Double, String)]) throws -> Config.Video {
        try ClipPlanTests.video("v", duration: duration, cuts: cuts)
    }

    /// The level the first screen's ramp clip shows `t` seconds in, read from a master of its own.
    /// Decoding shifts gray levels a little, so frames are compared with this rather than with
    /// the level the ramp was written at.
    static func reference(dir: URL, screen: String, at t: Double) throws -> Int {
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(
                video: try video([(0, screen)]), appearance: "dark", clipsDir: dir, stillsDir: nil),
            video: "v")
        return level(try master.frame(at: t))
    }

    /// The level of a ramp clip: gray = t / seconds.
    static func level(_ image: CGImage) -> Int { Int(Image.pixels(image)!.at(50, 25)) }

    @Test func playsEachClipFromItsOwnStart() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 4) { $0 / 4 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 4) { $0 / 4 }
        let video = try Self.video([(0, "browser"), (2, "paywall")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        var master = try ClipsMaster(segments: segments, video: "v")
        // 1 s into browser: a quarter up the ramp.
        let quarter = try Self.reference(dir: dir, screen: "browser", at: 1)
        #expect(quarter > 40 && quarter < 120)
        #expect(abs(Self.level(try master.frame(at: 1)) - quarter) <= 4)
        // 3 s into the video is 1 s into paywall, past the crossfade.
        #expect(abs(Self.level(try master.frame(at: 3)) - quarter) <= 4)
    }

    @Test func aScreenNamedTwiceRestartsItsClip() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { $0 / 3 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 3) { _ in 0 }
        let video = try Self.video([(0, "browser"), (2, "paywall"), (4, "browser")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        var master = try ClipsMaster(segments: segments, video: "v")
        _ = try master.frame(at: 1.5)
        _ = try master.frame(at: 3)
        // 0.75 s into the second browser segment, not 4.75 s into the clip.
        let expected = try Self.reference(dir: dir, screen: "browser", at: 0.75)
        #expect(abs(Self.level(try master.frame(at: 4.75)) - expected) <= 4)
    }

    @Test func crossfadesFromAClipIntoAStill() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { _ in 0 }
        try VideoMasterTests.solid(100, 50, gray: 1, to: stills.appending(path: "paywall~dark.png"))
        let video = try Self.video(duration: 4, [(0, "browser"), (2, "paywall")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        #expect(segments.map(\.isClip) == [true, false])
        var master = try ClipsMaster(segments: segments, video: "v")
        #expect(Self.level(try master.frame(at: 1)) <= 8)
        let mid = Self.level(try master.frame(at: 2.25))
        #expect(mid > 100 && mid < 160)
        #expect(Self.level(try master.frame(at: 3)) == 255)
    }

    @Test func clipsAndStillsOfDifferentSizesAreCenteredOnTheLargest() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", width: 100, height: 50, seconds: 3) { _ in 1 }
        try VideoMasterTests.solid(60, 30, gray: 1, to: stills.appending(path: "paywall~dark.png"))
        let video = try Self.video(duration: 4, [(0, "browser"), (2, "paywall")])
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(
                video: video, appearance: "dark", clipsDir: dir, stillsDir: stills),
            video: "v")
        #expect(master.stageSize == CGSize(width: 100, height: 50))
        _ = try master.frame(at: 1)
        let px = try #require(Image.pixels(try master.frame(at: 3)))
        #expect(px.at(2, 2, 3) == 0)
        #expect(px.at(50, 25, 3) == 255)
    }

    @Test func neverHoldsMoreThanTwoDecoders() async throws {
        let dir = try VideoMasterTests.dir()
        for screen in ["browser", "paywall", "organize"] {
            try await Self.writeClip(dir: dir, screen: screen, seconds: 3) { _ in 0.5 }
        }
        let video = try Self.video([(0, "browser"), (2, "paywall"), (4, "organize")])
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(
                video: video, appearance: "dark", clipsDir: dir, stillsDir: nil),
            video: "v")
        var most = 0
        for i in 0..<180 {
            _ = try master.frame(at: Double(i) / 30)
            most = max(most, master.openDecoders)
        }
        #expect(most == 2)
        #expect(master.openDecoders == 1)
    }

    @Test func rendersTheSameFramesTwice() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { $0 / 3 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 3) { 1 - $0 / 3 }
        let video = try Self.video(duration: 4, [(0, "browser"), (2, "paywall")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        var a = try ClipsMaster(segments: segments, video: "v")
        var b = try ClipsMaster(segments: segments, video: "v")
        for t in stride(from: 0.0, to: 4, by: 0.3) {
            #expect(Image.pixels(try a.frame(at: t))!.bytes == Image.pixels(try b.frame(at: t))!.bytes)
        }
    }

    @Test func aScreenWithNeitherClipNorStillNamesBothPaths() throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        let video = try Self.video([(0, "browser")])
        #expect {
            _ = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        } throws: { error in
            guard case .invalidVideo(let id, let reason)? = error as? AppShotError else { return false }
            return id == "v" && reason.contains("browser~dark.mov") && reason.contains("browser~dark.png")
        }
    }

    @Test func aFirstCutAfterZeroFailsLikeStills() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 3) { _ in 0 }
        let video = try Self.video([(1, "browser")])
        #expect {
            _ = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("a beat at 0 that names a screen")
        }
    }

    @Test func resolvesEachAppearanceOnItsOwn() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", appearance: "dark", seconds: 7) { _ in 0 }
        try VideoMasterTests.solid(100, 50, gray: 1, to: stills.appending(path: "browser~light.png"))
        let video = try Self.video([(0, "browser")])
        let dark = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        let light = try ClipsMaster.segments(
            video: video, appearance: "light", clipsDir: dir, stillsDir: stills)
        #expect(dark.map(\.isClip) == [true])
        #expect(light.map(\.isClip) == [false])
        #expect(light.map(\.name) == ["browser~light"])
    }

    /// A 20x10 patch, white over black, so a patch drawn upside down shows.
    static func writePatch(screen: String, in dir: URL) throws {
        let ctx = try #require(Image.context(width: 20, height: 10))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 5))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 5, width: 20, height: 5))
        try Image.write(
            try #require(ctx.makeImage()),
            to: ClipInfo.lightsPatchURL(in: dir, screen: screen, appearance: "dark"))
    }

    @Test func pastesTheLightsPatchOverEveryFrameAtItsRect() async throws {
        let dir = try VideoMasterTests.dir()
        let plain = try VideoMasterTests.dir()
        try await Self.writeClip(
            dir: dir, screen: "browser", seconds: 3,
            lightsPatch: .init(rect: [10, 5, 20, 10], recolored: false)
        ) { $0 / 3 }
        try Self.writePatch(screen: "browser", in: dir)
        try await Self.writeClip(dir: plain, screen: "browser", seconds: 3) { $0 / 3 }
        let video = try Self.video(duration: 2.5, [(0, "browser")])
        var master = try ClipsMaster(
            segments: try ClipsMaster.segments(
                video: video, appearance: "dark", clipsDir: dir, stillsDir: nil),
            video: "v")
        var reference = try ClipsMaster(
            segments: try ClipsMaster.segments(
                video: video, appearance: "dark", clipsDir: plain, stillsDir: nil),
            video: "v")
        var levels: [UInt8] = []
        for t in [0.2, 1.4, 2.3] {
            let px = try #require(Image.pixels(try master.frame(at: t)))
            let ref = try #require(Image.pixels(try reference.frame(at: t)))
            levels.append(ref.at(50, 25))
            // Inside, top-left origin: the white half on top, the black half below.
            #expect(px.at(15, 6) == 255 && px.at(29, 7) == 255)
            #expect(px.at(15, 13) == 0 && px.at(10, 14) == 0)
            // Outside, the clip's own frame, moving.
            for (x, y) in [(9, 6), (30, 6), (15, 4), (15, 15), (15, 40), (50, 25)] {
                #expect(px.at(x, y) == ref.at(x, y), "(\(x), \(y)) at \(t)")
            }
        }
        #expect(levels[0] < levels[1] && levels[1] < levels[2])
    }

    @Test func aClipWhoseLightsPatchIsMissingFailsNamingIt() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(
            dir: dir, screen: "browser", seconds: 3,
            lightsPatch: .init(rect: [10, 5, 20, 10], recolored: true)
        ) { _ in 0.5 }
        let video = try Self.video(duration: 2, [(0, "browser")])
        #expect {
            _ = try ClipsMaster.segments(video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        } throws: { error in
            guard case .invalidVideo(let id, let reason)? = error as? AppShotError else { return false }
            return id == "v" && reason.contains("browser~dark.lights.png") && reason.contains("re-record")
        }
    }

    @Test func aClipShorterThanItsHoldFailsNamingTheScreenAndTheFix() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 2) { _ in 0 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 5) { _ in 0 }
        // browser is held 3 s, so it needs 3.5 s with the crossfade, and has 2.
        let video = try Self.video([(0, "browser"), (3, "paywall")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect {
            try ClipsMaster.check(video: video, segments: segments)
        } throws: { error in
            guard let error = error as? AppShotError,
                case .clipTooShort("v", "browser~dark", "browser", 2, 3.5) = error
            else { return false }
            return error.slug == "clip_too_short"
                && error.description.contains("appshot record --clips --screens browser")
        }
    }

    @Test func presentIsRefusedInAClipsRender() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7) { _ in 0 }
        var video = try Self.video([(0, "browser")])
        video.beats[0].present = [0, 0, 10, 10]
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect {
            try ClipsMaster.check(video: video, segments: segments)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("beat 0") && reason.contains("--from-stills")
        }
    }

    @Test func aCueIsRefusedInAClipsRender() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7) { _ in 0 }
        var video = try Self.video([(0, "browser")])
        video.beats.append(.init(at: 1, cue: "pointer.click"))
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect {
            try ClipsMaster.check(video: video, segments: segments)
        } throws: { error in
            guard case .invalidVideo(_, let reason)? = error as? AppShotError else { return false }
            return reason.contains("beat 1 has a cue") && reason.contains("clips have no cue channel")
        }
    }

    @Test func warnsWhenAClipNeverMoved() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7, frames: 2) { _ in 0 }
        let video = try Self.video([(0, "browser")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        let warnings = ClipsMaster.warnings(for: segments, stillsDir: nil)
        #expect(warnings.map(\.kind) == ["clipNeverMoved"])
        #expect(warnings[0].message.contains("browser~dark has 2 frames in 7.0s"))
        #expect(warnings[0].message.contains("-ScreenshotClip"))
    }

    @Test func warnsWhenAClipAndItsStillDifferInSize() async throws {
        let dir = try VideoMasterTests.dir()
        let stills = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", width: 100, height: 50, seconds: 7) { _ in 0 }
        try VideoMasterTests.solid(96, 50, gray: 1, to: stills.appending(path: "browser~dark.png"))
        let video = try Self.video([(0, "browser")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: stills)
        #expect(
            ClipsMaster.warnings(for: segments, stillsDir: stills).map(\.kind) == ["clipStillSizeMismatch"])
        // Within 2 px is the same size.
        try VideoMasterTests.solid(98, 50, gray: 1, to: stills.appending(path: "browser~dark.png"))
        #expect(ClipsMaster.warnings(for: segments, stillsDir: stills).isEmpty)
    }

    @Test func aClipUsedTwiceWarnsOnce() async throws {
        let dir = try VideoMasterTests.dir()
        try await Self.writeClip(dir: dir, screen: "browser", seconds: 7, frames: 1) { _ in 0 }
        try await Self.writeClip(dir: dir, screen: "paywall", seconds: 7) { _ in 0 }
        let video = try Self.video([(0, "browser"), (2, "paywall"), (4, "browser")])
        let segments = try ClipsMaster.segments(
            video: video, appearance: "dark", clipsDir: dir, stillsDir: nil)
        #expect(ClipsMaster.warnings(for: segments, stillsDir: nil).count == 1)
    }
}
