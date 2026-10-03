import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// A source of stage frames, in stage pixels. The renderer never knows which kind it has.
public protocol VideoMaster {
    var stageSize: CGSize { get }
    mutating func frame(at t: Double) throws -> CGImage
}

/// A stand-in recording built from existing captures: each beat that names a `screen`
/// cuts to it with a crossfade.
///
/// Captures of different sizes are centered on one canvas the size of the largest,
/// never stretched: a stretched window is a lie about the app, and it is the kind a
/// reviewer only notices after it ships.
public struct StillsMaster: VideoMaster {
    public static let crossfade = 0.5

    public let stageSize: CGSize
    private let keys: [(time: Double, image: CGImage)]

    public init(video: Config.Video, sourceDir: URL, appearance: String) throws {
        let cuts = video.beats.compactMap { beat in beat.screen.map { (beat.at, $0) } }
        guard let first = cuts.first, first.0 == 0 else {
            throw AppShotError.invalidVideo(
                id: video.id, reason: "--from-stills needs a beat at 0 that names a screen")
        }
        let names = cuts.map { "\($0.1)~\(appearance).png" }
        let missing = Set(names).filter {
            !FileManager.default.fileExists(atPath: sourceDir.appending(path: $0).path)
        }
        guard missing.isEmpty else { throw AppShotError.missingCaptures(missing.sorted(), dir: sourceDir) }

        let images = try names.map { try Image.load(sourceDir.appending(path: $0)) }
        let w = images.map(\.width).max() ?? 0
        let h = images.map(\.height).max() ?? 0
        stageSize = CGSize(width: w, height: h)
        keys = try zip(cuts, images).map { cut, image in
            guard let ctx = Image.context(width: w, height: h) else {
                throw AppShotError.videoRenderFailed(video: video.id, reason: "no bitmap context")
            }
            let x: Int = (w - image.width) / 2
            let y: Int = (h - image.height) / 2
            ctx.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
            guard let centered = ctx.makeImage() else {
                throw AppShotError.videoRenderFailed(video: video.id, reason: "could not center \(cut.1)")
            }
            return (cut.0, centered)
        }
    }

    public mutating func frame(at t: Double) throws -> CGImage {
        let index = keys.lastIndex { $0.time <= t } ?? 0
        let p = (t - keys[index].time) / Self.crossfade
        guard index > 0, p < 1 else { return keys[index].image }
        guard let ctx = Image.context(width: Int(stageSize.width), height: Int(stageSize.height)) else {
            return keys[index].image
        }
        let full = CGRect(origin: .zero, size: stageSize)
        ctx.draw(keys[index - 1].image, in: full)
        ctx.setAlpha(VideoTimeline.ease(p))
        ctx.draw(keys[index].image, in: full)
        return ctx.makeImage() ?? keys[index].image
    }
}

/// The recording, decoded in order and cropped to the track's stage.
///
/// Sequential only: `frame(at:)` must be asked for non-decreasing times, which is how
/// the renderer walks a video. Seeking an HEVC stream per frame would cost a decode
/// from the last keyframe every time.
public final class RecordedMaster: VideoMaster {
    public let stageSize: CGSize
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let crop: CGRect
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var origin: CMTime?
    private var current: CGImage?
    private var pending: CMSampleBuffer?

    public init(url: URL, track: VideoTrack) throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw AppShotError.videoRenderFailed(
                video: track.video, reason: "\(url.lastPathComponent) has no video track")
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AppShotError.videoRenderFailed(
                video: track.video, reason: "cannot read \(url.lastPathComponent)")
        }
        crop = CGRect(x: track.stage[0], y: track.stage[1], width: track.stage[2], height: track.stage[3])
        stageSize = crop.size
    }

    public func frame(at t: Double) throws -> CGImage {
        while true {
            guard let sample = pending ?? output.copyNextSampleBuffer() else { break }
            pending = nil
            let pts = sample.presentationTimeStamp
            if origin == nil { origin = pts }
            guard (pts - (origin ?? pts)).seconds <= t + 0.0005 else {
                pending = sample
                break
            }
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                let ci = CIImage(cvPixelBuffer: pb)
                // CIImage is y-up; the crop is y-down.
                let rect = CGRect(
                    x: crop.minX, y: ci.extent.height - crop.maxY, width: crop.width, height: crop.height)
                current = context.createCGImage(
                    ci, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
        guard let current else {
            throw AppShotError.videoRenderFailed(video: "", reason: "the master has no frame at \(t)s")
        }
        return current
    }
}
