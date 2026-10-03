import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct VideoWriterTests {
    @Test func writesH264WithASilentStereoTrack() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "w-\(UUID()).mp4")
        let writer = try VideoWriter(url: url, size: .init(width: 64, height: 48))
        let ctx = try #require(Image.context(width: 64, height: 48))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(ctx.makeImage())
        for _ in 0..<30 { try writer.append(image) }
        let done = try await writer.finish()
        #expect(done == url)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".partial"))

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.05)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 64, height: 48))
        #expect(abs(try await video.load(.nominalFrameRate) - 30) < 0.5)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mSampleRate == 48_000)
    }
}
