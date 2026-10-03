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

    // Uncomment with `writeAlphaMovie` once Task 6 adds `VideoWriter.pixelBuffer(_:pool:)`.
    // HEVC-with-alpha is lossy: 255 written reads back as ~253, hence `>= 250`.
    //
    // @Test(
    //     .disabled(
    //         if: ProcessInfo.processInfo.environment["CI"] != nil,
    //         "no hardware HEVC encoder on CI runners"))
    // func recordedMasterKeepsAlphaAndCrops() async throws {
    //     let url = try Self.dir().appending(path: "m.mov")
    //     try await Self.writeAlphaMovie(url, width: 64, height: 64)
    //     let track = VideoTrack(
    //         video: "v", appearance: "dark", duration: 1, stage: [16, 16, 32, 32],
    //         beats: [], targets: [], frames: 30, maxFrameGap: 0)
    //     var master = try RecordedMaster(url: url, track: track)
    //     let frame = try master.frame(at: 0.5)
    //     #expect(frame.width == 32 && frame.height == 32)
    //     #expect(Image.pixels(frame)!.bytes[(16 * 32 + 16) * 4 + 3] >= 250)
    // }
    //
    // /// A 1s HEVC-with-alpha movie: transparent, with an opaque 32x32 square in the middle.
    // static func writeAlphaMovie(_ url: URL, width: Int, height: Int) async throws {
    //     let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    //     let input = AVAssetWriterInput(
    //         mediaType: .video,
    //         outputSettings: [
    //             AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width,
    //             AVVideoHeightKey: height,
    //         ])
    //     let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    //         assetWriterInput: input,
    //         sourcePixelBufferAttributes: [
    //             kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    //             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    //         ])
    //     writer.add(input)
    //     writer.startWriting()
    //     writer.startSession(atSourceTime: .zero)
    //     let ctx = try #require(Image.context(width: width, height: height))
    //     ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    //     ctx.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
    //     let image = try #require(ctx.makeImage())
    //     for i in 0..<30 {
    //         while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
    //         let pb = try VideoWriter.pixelBuffer(image, pool: try #require(adaptor.pixelBufferPool))
    //         adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
    //     }
    //     input.markAsFinished()
    //     await writer.finishWriting()
    // }
}
