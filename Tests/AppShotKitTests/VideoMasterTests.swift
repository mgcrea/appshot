import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoMasterTests {
    static func solid(_ w: Int, _ h: Int, gray: Double, to url: URL) throws {
        let ctx = try #require(Image.context(width: w, height: h))
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        try Image.write(try #require(ctx.makeImage()), to: url)
    }

    static func dir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "master-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func video() throws -> Config.Video {
        try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "duration": 4, "outputs": { "promo": [[100, 100]] },
                   "beats": [{ "at": 0, "screen": "browser" }, { "at": 2, "screen": "paywall" }] }]
                """
        ).video("v")
    }

    @Test func crossfadesBetweenStills() throws {
        let dir = try Self.dir()
        try Self.solid(100, 50, gray: 0, to: dir.appending(path: "browser~dark.png"))
        try Self.solid(100, 50, gray: 1, to: dir.appending(path: "paywall~dark.png"))
        var master = try StillsMaster(video: Self.video(), sourceDir: dir, appearance: "dark")
        #expect(master.stageSize == CGSize(width: 100, height: 50))
        let px = { (img: CGImage) in Image.pixels(img)!.bytes[(25 * 100 + 50) * 4] }
        #expect(px(try master.frame(at: 1)) == 0)
        let mid = px(try master.frame(at: 2.25))
        #expect(mid > 100 && mid < 160)
        #expect(px(try master.frame(at: 3)) == 255)
    }

    @Test func differentSizedStillsAreCenteredNotStretched() throws {
        let dir = try Self.dir()
        try Self.solid(100, 50, gray: 1, to: dir.appending(path: "browser~dark.png"))
        try Self.solid(60, 30, gray: 1, to: dir.appending(path: "paywall~dark.png"))
        var master = try StillsMaster(video: Self.video(), sourceDir: dir, appearance: "dark")
        let frame = try master.frame(at: 3)
        let px = Image.pixels(frame)!
        // Outside the centered 60x30 the canvas is transparent.
        #expect(px.bytes[(2 * 100 + 2) * 4 + 3] == 0)
        #expect(px.bytes[(25 * 100 + 50) * 4 + 3] == 255)
    }

    @Test func missingStillNamesTheFile() throws {
        let dir = try Self.dir()
        #expect {
            _ = try StillsMaster(video: Self.video(), sourceDir: dir, appearance: "dark")
        } throws: { error in
            guard case .missingCaptures(let names, _) = error as? AppShotError else { return false }
            return names.contains("browser~dark.png")
        }
    }

    @Test func unreadableMasterThrowsNamingTheVideo() throws {
        let url = try Self.dir().appending(path: "m.mov")
        try Data("not a movie".utf8).write(to: url)
        let track = VideoTrack(
            video: "v", appearance: "dark", duration: 1, stage: [0, 0, 8, 8],
            cues: [], targets: [], frames: 30, maxFrameGap: 0)
        #expect {
            _ = try RecordedMaster(url: url, track: track)
        } throws: { error in
            guard case .videoRenderFailed(let video, _) = error as? AppShotError else { return false }
            return video == "v"
        }
    }

    // HEVC-with-alpha is lossy: 255 written reads back as ~253, hence `>= 250`.
    @Test(
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "no hardware HEVC encoder on CI runners"))
    func recordedMasterKeepsAlphaAndCrops() async throws {
        let url = try Self.dir().appending(path: "m.mov")
        try await Self.writeAlphaMovie(url, width: 64, height: 64)
        // y-down crop: rows 8..<40. The movie is opaque in y-down rows 0..<24 only, so the
        // crop's top 16 rows are opaque and its bottom 16 are clear. minY (8) differs from
        // height - maxY (24), so a wrong y-down to y-up conversion lands on other rows.
        let track = VideoTrack(
            video: "v", appearance: "dark", duration: 1, stage: [16, 8, 32, 32],
            cues: [], targets: [], frames: 30, maxFrameGap: 0)
        let master = try RecordedMaster(url: url, track: track)
        let frame = try master.frame(at: 0.5)
        #expect(frame.width == 32 && frame.height == 32)
        let px = try #require(Image.pixels(frame))
        let top = px.bytes[(4 * 32 + 16) * 4 + 3]
        let bottom = px.bytes[(28 * 32 + 16) * 4 + 3]
        #expect(top >= 250)
        #expect(bottom <= 5)
    }

    @Test(
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "no hardware HEVC encoder on CI runners"))
    func truncatedMasterThrowsInsteadOfReturningFrames() async throws {
        let url = try Self.dir().appending(path: "m.mov")
        try await Self.writeAlphaMovie(url, width: 64, height: 64)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 3).write(to: url)
        let track = VideoTrack(
            video: "v", appearance: "dark", duration: 1, stage: [0, 0, 64, 64],
            cues: [], targets: [], frames: 30, maxFrameGap: 0)
        // A cut-off movie has lost its index, so it can fail at init or mid-walk; either
        // must be a videoRenderFailed rather than a frame.
        #expect {
            let master = try RecordedMaster(url: url, track: track)
            for i in 0..<30 { _ = try master.frame(at: Double(i) / 30) }
        } throws: { error in
            guard case .videoRenderFailed(let video, _) = error as? AppShotError else { return false }
            return video == "v"
        }
    }

    /// The index is intact but 40-90% of the sample bytes are noise, so the movie opens and
    /// then fails mid-walk: the reader goes to `.failed`, which `copyNextSampleBuffer` reports
    /// as nil, exactly like end of stream. Observed: "Cannot Decode" around 1.03 s.
    @Test(
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "no hardware HEVC encoder on CI runners"))
    func corruptedSamplesFailMidStream() async throws {
        let url = try Self.dir().appending(path: "m.mov")
        try await Self.writeAlphaMovie(url, width: 64, height: 64, frames: 90)
        var data = try Data(contentsOf: url)
        let tag = try #require(data.range(of: Data("mdat".utf8)))
        let boxSize = data[(tag.lowerBound - 4)..<tag.lowerBound].reduce(0) { $0 << 8 | Int($1) }
        let start = tag.upperBound
        let size = boxSize - 8
        var seed: UInt64 = 42
        for i in (start + size * 4 / 10)..<(start + size * 9 / 10) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        try data.write(to: url)
        let track = VideoTrack(
            video: "v", appearance: "dark", duration: 3, stage: [0, 0, 64, 64],
            cues: [], targets: [], frames: 90, maxFrameGap: 0)
        let master = try RecordedMaster(url: url, track: track)
        #expect {
            for i in 0..<90 { _ = try master.frame(at: Double(i) / 30) }
        } throws: { error in
            guard case .videoRenderFailed(let video, let reason) = error as? AppShotError else {
                return false
            }
            return video == "v" && reason.contains("decoding the master failed")
        }
    }

    /// A 1s HEVC-with-alpha movie: transparent, with an opaque 32x32 block spanning x 16..<48
    /// and, in y-down terms, rows 0..<24 (the top of the frame).
    static func writeAlphaMovie(_ url: URL, width: Int, height: Int, frames: Int = 30) async throws {
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
        let ctx = try #require(Image.context(width: width, height: height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        // Image.context is y-up: y 40..<64 is the top 24 rows of the image.
        ctx.fill(CGRect(x: 16, y: height - 24, width: 32, height: 24))
        let image = try #require(ctx.makeImage())
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pool = try #require(adaptor.pixelBufferPool)
            let pb = try VideoWriter.pixelBuffer(image, pool: pool)
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    /// A stills video over three captures: `browser` bare, then `paywall` and `organize`
    /// each presenting a sheet at `sheet`.
    static func sheets(_ dir: URL, sheet: [Int] = [20, 10, 60, 30]) throws -> Config.Video {
        let json = ConfigTests.json.replacingOccurrences(
            of: "\"screens\": [",
            with: """
                "videos": [{ "id": "v", "duration": 6, "outputs": { "promo": [[100, 100]] },
                  "beats": [{ "at": 0, "screen": "browser" },
                            { "at": 2, "screen": "paywall", "present": \(sheet) },
                            { "at": 4, "screen": "organize", "present": \(sheet) }] }],
                "screens": [{ "id": "organize", "title": "Organize" },
                """)
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8)).video("v")
    }

    /// A 100x50 capture: `base` grey, with `inside` filling the y-down rect `r`.
    static func capture(_ base: Double, inside: CGColor? = nil, r: CGRect, to url: URL) throws {
        let ctx = try #require(Image.context(width: 100, height: 50))
        ctx.setFillColor(CGColor(gray: base, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        if let inside {
            ctx.setFillColor(inside)
            ctx.fill(CGRect(x: r.minX, y: 50 - r.maxY, width: r.width, height: r.height))
        }
        try Image.write(try #require(ctx.makeImage()), to: url)
    }

    @Test func aPresentedSheetSpringsUpOverTheWindow() throws {
        let dir = try Self.dir()
        let r = CGRect(x: 20, y: 10, width: 60, height: 30)
        try Self.capture(0, r: r, to: dir.appending(path: "browser~dark.png"))
        try Self.capture(
            0, inside: CGColor(gray: 1, alpha: 1), r: r, to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(0, r: r, to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        let px = { (img: CGImage, x: Int, y: Int) in Image.pixels(img)!.bytes[(y * 100 + x) * 4] }
        // Mid-spring the sheet is still smaller than its rect: its left edge shows the window,
        // while its middle is already mostly the sheet. A crossfade would fail the second.
        let mid = try master.frame(at: 2.15)
        #expect(px(mid, 20, 25) < 128)
        #expect(px(mid, 50, 25) > 150)
        // At the start of the present the rect still shows the bare window.
        #expect(px(try master.frame(at: 2.0), 50, 25) < 30)
        #expect(px(try master.frame(at: 3.5), 21, 25) == 255)
    }

    @Test func swappingSheetsNeverShowsBothAtOnce() throws {
        let dir = try Self.dir()
        let r = CGRect(x: 20, y: 10, width: 60, height: 30)
        // Black everywhere else, so only the sheets carry red or blue.
        try Self.capture(0, r: r, to: dir.appending(path: "browser~dark.png"))
        try Self.capture(
            0, inside: CGColor(red: 1, green: 0, blue: 0, alpha: 1), r: r,
            to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(
            0, inside: CGColor(red: 0, green: 0, blue: 1, alpha: 1), r: r,
            to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        for i in 0..<30 {
            let frame = try master.frame(at: 4 + Double(i) / 30)
            let px = try #require(Image.pixels(frame))
            for y in 10..<40 {
                for x in 20..<80 {
                    let o = (y * 100 + x) * 4
                    #expect(
                        !(px.bytes[o] > 90 && px.bytes[o + 2] > 90), "t=\(4 + Double(i) / 30) at \(x),\(y)")
                }
            }
        }
        let settled = try #require(Image.pixels(try master.frame(at: 5.5)))
        #expect(settled.bytes[(25 * 100 + 50) * 4 + 2] > 200)
    }

    @Test func presentIsInStagePixelsOnTheCenteredCanvas() throws {
        let dir = try Self.dir()
        try Self.capture(0, r: .zero, to: dir.appending(path: "browser~dark.png"))
        // A 60x30 capture is centered on the 100x50 canvas, at (20, 10).
        let small = try #require(Image.context(width: 60, height: 30))
        small.setFillColor(CGColor(gray: 1, alpha: 1))
        small.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        try Image.write(try #require(small.makeImage()), to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(0, r: .zero, to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        // Mid-present the sheet is drawn from the centered canvas at the config's rect: white
        // just inside its left edge, the black window just outside it.
        let mid = try #require(Image.pixels(try master.frame(at: 2.3)))
        #expect(mid.bytes[(25 * 100 + 25) * 4] == 255)
        #expect(mid.bytes[(25 * 100 + 17) * 4] == 0)
    }

    @Test func aSheetSettlesIntoTheCaptureWithoutAPop() throws {
        let dir = try Self.dir()
        let r = CGRect(x: 20, y: 10, width: 60, height: 30)
        try Self.capture(0, r: r, to: dir.appending(path: "browser~dark.png"))
        try Self.capture(
            0.3, inside: CGColor(gray: 1, alpha: 1), r: r, to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(0, r: r, to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(video: Self.sheets(dir), sourceDir: dir, appearance: "dark")
        // The kinetic present lasts max(0.6, 0.45 * 1.6) = 0.72 s from the beat at 2.
        let before = try #require(Image.pixels(try master.frame(at: 2.72 - 1.0 / 30)))
        let after = try #require(Image.pixels(try master.frame(at: 2.72)))
        #expect(before.bytes.count == after.bytes.count)
        let worst = zip(before.bytes, after.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "the last drawn frame differs from the capture by \(worst)")
    }

    @Test func aSheetRectPastTheCaptureEdgeIsNotStretched() throws {
        let dir = try Self.dir()
        try Self.capture(0, r: .zero, to: dir.appending(path: "browser~dark.png"))
        // Within the 100 px stage the sheet has x 60..100: white then blue from x 80.
        let ctx = try #require(Image.context(width: 100, height: 50))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 0, width: 20, height: 50))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 80, y: 0, width: 20, height: 50))
        try Image.write(try #require(ctx.makeImage()), to: dir.appending(path: "paywall~dark.png"))
        try Self.capture(0, r: .zero, to: dir.appending(path: "organize~dark.png"))
        var master = try StillsMaster(
            video: Self.sheets(dir, sheet: [60, 10, 60, 30]), sourceDir: dir, appearance: "dark")
        // Late in the spring the scale is near 1: the blue starts near x 80, not stretched to 90.
        let frame = try #require(Image.pixels(try master.frame(at: 2.5)))
        let at = { (x: Int) in (r: frame.bytes[(25 * 100 + x) * 4], b: frame.bytes[(25 * 100 + x) * 4 + 2]) }
        #expect(at(70).r > 200)
        #expect(at(85).r < 60 && at(85).b > 200)
    }
}
