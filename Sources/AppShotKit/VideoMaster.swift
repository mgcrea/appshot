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
    private let keys: [(time: Double, image: CGImage, present: CGRect?)]
    private let sheet: Spring

    public init(
        video: Config.Video, sourceDir: URL, appearance: String,
        sheet: Spring = MotionPreset.kinetic.sheet
    ) throws {
        self.sheet = sheet
        let cuts = video.beats.compactMap { beat in
            beat.screen.map {
                (beat.at, $0, beat.present.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) })
            }
        }
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
            return (cut.0, centered, cut.2)
        }
    }

    public mutating func frame(at t: Double) throws -> CGImage {
        let index = keys.lastIndex { $0.time <= t } ?? 0
        let current = keys[index]
        guard index > 0 else { return current.image }
        let previous = keys[index - 1]
        let q = t - current.time
        guard let sheetRect = current.present else { return crossfade(previous.image, current.image, q) }

        let swap = previous.present != nil
        let duration = max(0.6, sheet.response * 1.6) + (swap ? 0.2 : 0)
        guard q < duration,
            let canvas = VideoCanvas(width: Int(stageSize.width), height: Int(stageSize.height))
        else { return current.image }
        let full = CGRect(origin: .zero, size: stageSize)
        var presentAge = q
        if let old = previous.present {
            // A crossfade between two sheets double-exposes their text. Instead the old
            // sheet drops away over the bare window, then the new one comes up.
            guard let bare = keys[..<index].last(where: { $0.present == nil }) else {
                return crossfade(previous.image, current.image, q / duration * Self.crossfade)
            }
            canvas.image(current.image, in: full)
            canvas.ctx.saveGState()
            canvas.ctx.clip(to: sheetRect)
            canvas.image(bare.image, in: full)
            canvas.ctx.restoreGState()
            let d = Ease.smooth(q / 0.2)
            drawSheet(canvas, previous.image, old, scale: 1 - 0.05 * d, alpha: 1 - d)
            presentAge = q - 0.16
        } else {
            // Present: the window behind dims in, the sheet springs up from 90%.
            canvas.image(previous.image, in: full)
            canvas.ctx.saveGState()
            let outside = CGMutablePath()
            outside.addRect(full)
            outside.addRect(sheetRect)
            canvas.ctx.addPath(outside)
            canvas.ctx.clip(using: .evenOdd)
            canvas.image(current.image, in: full, alpha: Ease.smooth(q / 0.35))
            canvas.ctx.restoreGState()
        }
        if presentAge > 0 {
            drawSheet(
                canvas, current.image, sheetRect, scale: 0.9 + 0.1 * sheet.value(presentAge),
                alpha: Ease.clamp01(presentAge / 0.2))
        }
        return canvas.makeImage() ?? current.image
    }

    private func crossfade(_ from: CGImage, _ to: CGImage, _ q: Double) -> CGImage {
        let p = q / Self.crossfade
        guard p < 1, let ctx = Image.context(width: Int(stageSize.width), height: Int(stageSize.height))
        else {
            return to
        }
        let full = CGRect(origin: .zero, size: stageSize)
        ctx.draw(from, in: full)
        ctx.setAlpha(Ease.smooth(p))
        ctx.draw(to, in: full)
        return ctx.makeImage() ?? to
    }

    /// The region `rect` of `image`, drawn at `scale` of its size about its center.
    private func drawSheet(
        _ canvas: VideoCanvas, _ image: CGImage, _ rect: CGRect, scale: Double, alpha: Double
    ) {
        guard alpha > 0.001, let crop = image.cropping(to: rect) else { return }
        let dest = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
        // CGPath traps on a corner radius over half a side.
        let radius = min(26 * scale, dest.width / 2, dest.height / 2)
        let rounded = CGPath(roundedRect: dest, cornerWidth: radius, cornerHeight: radius, transform: nil)
        canvas.ctx.saveGState()
        canvas.ctx.setShadow(
            offset: CGSize(width: 0, height: -20), blur: 60, color: CGColor(gray: 0, alpha: 0.5 * alpha))
        canvas.ctx.addPath(rounded)
        canvas.ctx.setFillColor(CGColor(gray: 0.12, alpha: alpha))
        canvas.ctx.fillPath()
        canvas.ctx.restoreGState()
        canvas.ctx.saveGState()
        canvas.ctx.addPath(rounded)
        canvas.ctx.clip()
        canvas.image(crop, in: dest, alpha: alpha)
        canvas.ctx.restoreGState()
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
    private let video: String
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
        video = track.video
        crop = CGRect(x: track.stage[0], y: track.stage[1], width: track.stage[2], height: track.stage[3])
        stageSize = crop.size
    }

    public func frame(at t: Double) throws -> CGImage {
        while true {
            guard let sample = pending ?? output.copyNextSampleBuffer() else {
                // nil is both end of stream and a failed reader; only the status tells them apart.
                // Returning the stale frame on a failure would render a frozen video with no error.
                if reader.status == .failed {
                    let cause = reader.error?.localizedDescription ?? "unknown error"
                    throw AppShotError.videoRenderFailed(
                        video: video, reason: "decoding the master failed at \(t)s: \(cause)")
                }
                break
            }
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
            throw AppShotError.videoRenderFailed(video: video, reason: "the master has no frame at \(t)s")
        }
        return current
    }
}
