import AVFoundation
import CoreGraphics
import Foundation

/// H.264 at 30 fps plus a silent stereo AAC track.
///
/// The silent track is there because Apple's preview spec lists stereo audio and says
/// every track must be enabled; carrying one costs nothing and takes the question off
/// the table. Promos get it too, so the two outputs differ only in what they show.
///
/// Audio is appended alongside video rather than all at the end: AVAssetWriter
/// interleaves its inputs, and an input that falls far behind makes the other one stop
/// accepting data — a stall, not an error.
public final class VideoWriter {
    public static let fps: Int32 = 30
    static let sampleRate = 48_000

    private let url: URL
    private let partial: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let format: CMAudioFormatDescription
    private var frame: Int64 = 0
    private var audioFrames: Int64 = 0

    public init(url: URL, size: Config.Size, bitRate: Int = 10_000_000) throws {
        self.url = url
        partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)

        video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264High40,
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: Int(Self.fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(Self.fps),
                ],
            ])
        audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ])
        writer.add(video)
        writer.add(audio)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard let description, writer.startWriting() else {
            let cause = writer.error.map { "\($0)" } ?? "writer did not start"
            throw AppShotError.videoRenderFailed(video: url.lastPathComponent, reason: cause)
        }
        format = description
        writer.startSession(atSourceTime: .zero)
    }

    public func append(_ image: CGImage) throws {
        try waitFor(video)
        guard let pool = adaptor.pixelBufferPool else { throw failure("no pixel buffer pool") }
        let buffer = try Self.pixelBuffer(image, pool: pool)
        let time = CMTime(value: frame, timescale: Self.fps)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw failure("frame \(frame) was refused")
        }
        frame += 1
        try appendSilence(upTo: Double(frame) / Double(Self.fps))
    }

    public func finish() async throws -> URL {
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw failure("finish: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    public static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else {
            throw AppShotError.videoRenderFailed(video: "", reason: "no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info: UInt32 =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { throw AppShotError.videoRenderFailed(video: "", reason: "no pixel buffer context") }
        let full = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        ctx.clear(full)
        ctx.draw(image, in: full)
        return buffer
    }

    private func appendSilence(upTo seconds: Double) throws {
        let target = Int64(seconds * Double(Self.sampleRate))
        while audioFrames < target {
            let count = Int(min(1024, target - audioFrames))
            try waitFor(audio)
            let bytes = count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw failure("no audio block") }
            CMBlockBufferFillDataBytes(
                with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: audioFrames, timescale: CMTimeScale(Self.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, audio.append(sample) else { throw failure("silence was refused") }
            audioFrames += Int64(count)
        }
    }

    /// The inputs are not real-time, so readiness comes back quickly; ten seconds
    /// without it is a stuck writer, and a hang is worse than an error.
    private func waitFor(_ input: AVAssetWriterInput) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else { throw failure("encoder stalled") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func failure(_ why: String) -> AppShotError {
        .videoRenderFailed(video: url.lastPathComponent, reason: why)
    }
}
