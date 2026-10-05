import AVFoundation
import ScreenCaptureKit

/// SCStream frames → an HEVC-with-alpha `.mov`, kept as the master.
///
/// HEVC with alpha rather than ProRes 4444: the same transparency at roughly a
/// hundredth of the size, hardware-encoded. A 24s Retina take in ProRes 4444 runs to
/// several gigabytes.
///
/// Also the stream's delegate: without one, a stream the system stops mid-take (display
/// sleep, a replayd restart, permission revoked) just goes quiet, and the take would
/// "succeed" with a master frozen from that point on.
///
/// `@unchecked Sendable` because SCStream calls it on its own queue while the recorder
/// reads it from the task; every mutable field is behind `lock`.
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var closed = false
    private var _frames = 0
    /// Only clips count pictures: takes never read them, so they never pay for the hash.
    private let countsPictures: Bool
    private var _pictures: PictureCounter?
    private var _maxGap = 0.0
    private var stopError: (any Error)?

    var frames: Int { lock.withLock { _frames } }
    /// The frames written that differ from the one before, nil unless counting pictures:
    /// what actually moved. ScreenCaptureKit sends a complete frame whenever anything on
    /// the display changes, outside the filter too, so on a Mac in use a still window
    /// arrives as a steady run of identical pictures, and `frames` counts the Mac's
    /// activity rather than the app's.
    var pictures: PictureCounter? { lock.withLock { _pictures } }
    var maxGap: Double { lock.withLock { _maxGap } }

    /// The presentation time of the first frame written, on the host clock SCStream
    /// stamps its samples with. The master's t = 0.
    var origin: CMTime? { lock.withLock { firstPTS } }

    init(url: URL, width: Int, height: Int, countsPictures: Bool = false) throws {
        self.countsPictures = countsPictures
        _pictures = countsPictures ? PictureCounter() : nil
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Checked first: AVAssetWriterInput raises an Objective-C exception on settings
        // the writer refuses, which Swift cannot catch, so `record` would crash.
        let tagged = Self.outputSettings(width: width, height: height)
        let untagged = Self.outputSettings(width: width, height: height, tagged: false)
        let settings: [String: Any]
        if writer.canApply(outputSettings: tagged, forMediaType: .video) {
            settings = tagged
            streamColorSpace = Self.colorSpace
        } else if writer.canApply(outputSettings: untagged, forMediaType: .video) {
            settings = untagged
            streamColorSpace = nil
        } else {
            throw AppShotError.recordFailed(
                video: "", reason: "the writer refuses HEVC with alpha at \(width)x\(height)")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            let reason = writer.error.map { "\($0)" } ?? "writer did not start"
            throw AppShotError.recordFailed(video: "", reason: reason)
        }
    }

    /// The colour space the movie is tagged with, and so the one ScreenCaptureKit must send
    /// frames in. sRGB because compose draws in sRGB, and the stills land there too:
    /// ScreenCaptureKit makes the same conversion from the display's profile that drawing
    /// a still's PNG makes.
    static var colorSpace: CFString { CGColorSpace.sRGB }

    /// What to ask ScreenCaptureKit for: `colorSpace` when the movie is tagged with it, nil
    /// (the display's own space) when the writer refused the tags and the movie is
    /// untagged. Untagged, it is read as BT.709 either way, and display-space frames are
    /// what takes always held, so the fallback is the old tone exactly rather than a new
    /// wrong one.
    let streamColorSpace: CFString?

    /// The writer's settings. The colour tags say what `colorSpace` holds: BT.709
    /// primaries (sRGB's), the sRGB transfer function, and the BT.709 Y'CbCr matrix.
    /// AVFoundation, and so `RecordedMaster`, guesses BT.709 throughout for an untagged
    /// movie: measured, a dark grey of 50 came back as 57 and saturated colours washed out.
    ///
    /// `kCVImageBufferTransferFunction_sRGB` rather than `AVVideoTransferFunction_IEC_sRGB`:
    /// the same string, but the AVFoundation name needs macOS 15, and the writer may refuse
    /// the value before it. `init` then falls back to `tagged: false`, the settings every
    /// master had before the tags: the old, lighter tone, never a crash.
    static func outputSettings(width: Int, height: Int, tagged: Bool = true) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if tagged {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        return settings
    }

    /// Returns the first complete frame's time once it is written, or nil if none
    /// arrives within `timeout`: a filter matching no window streams nothing, and
    /// waiting on it forever would hang the run instead of failing it.
    func waitForFirstFrame(timeout: Double) async throws -> CMTime? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let origin { return origin }
            try await Task.sleep(for: .milliseconds(2))
        }
        return origin
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType)
    {
        guard type == .screen, sample.isValid, Self.isComplete(sample) else { return }
        // Read before the lock: it is the one slow step here.
        let picture = countsPictures ? CMSampleBufferGetImageBuffer(sample).flatMap(Self.fingerprint) : nil
        let pts = sample.presentationTimeStamp
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if firstPTS == nil {
            firstPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        if let last = lastPTS { _maxGap = max(_maxGap, (pts - last).seconds) }
        lastPTS = pts
        if input.isReadyForMoreMediaData, input.append(sample) {
            _frames += 1
            if let first = firstPTS { _pictures?.note(picture, at: (pts - first).seconds) }
        }
    }

    func finish() async throws {
        let started = lock.withLock {
            closed = true
            input.markAsFinished()
            return firstPTS != nil
        }
        guard started else {
            writer.cancelWriting()
            throw AppShotError.recordFailed(video: "", reason: "master: no frame was recorded")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AppShotError.recordFailed(
                video: "", reason: "master: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
    }

    /// The failure path: stop accepting frames and drop what was written.
    func cancel() {
        lock.withLock {
            closed = true
            if writer.status == .writing { writer.cancelWriting() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopped(with: error)
    }

    /// What the delegate callback records; separate so a test can drive it without a stream.
    func stopped(with error: any Error) {
        lock.withLock { stopError = error }
    }

    /// Throws once the system has stopped the stream, so the take fails at once rather
    /// than recording nothing until its duration runs out.
    func throwIfStopped(video: String) throws {
        guard let error = lock.withLock({ stopError }) else { return }
        throw AppShotError.recordFailed(
            video: video,
            reason: "ScreenCaptureKit stopped the stream mid-take: \(Recorder.describe(error))")
    }

    /// Counts a run of frames as pictures: a frame is a new picture when its fingerprint
    /// differs from the one before. A frame with no fingerprint counts as new, so a
    /// picture that could not be read never hides motion.
    struct PictureCounter: Sendable {
        private var last: UInt64?
        private var lastAt: Double?
        private var gap = 0.0
        private(set) var count = 0

        /// `t` in seconds on the take's clock, t = 0 at the first frame.
        mutating func note(_ fingerprint: UInt64?, at t: Double) {
            let new = fingerprint == nil || fingerprint != last
            last = fingerprint
            guard new else { return }
            count += 1
            if let lastAt { gap = max(gap, t - lastAt) }
            lastAt = t
        }

        /// The longest time between new pictures, the stretch from the last one to `end`
        /// included: a stage that never moved shows its whole length.
        func maxGap(until end: Double) -> Double {
            max(gap, end - (lastAt ?? 0))
        }
    }

    /// Pixels apart, both ways, that `fingerprint` reads: an eighth of the rows and an
    /// eighth of each row, about 0.3M of a 6K display's 20M, so a 60 fps stream stays
    /// cheap. A change smaller than this in both directions can be missed.
    static let fingerprintStride = 8

    /// An FNV-1a hash of a sparse grid of a BGRA buffer's pixels. Equal pictures give
    /// equal hashes; a change on the grid gives a different one. Nil when the pixels
    /// cannot be read, which the counter takes as a new picture.
    static func fingerprint(_ buffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = min(CVPixelBufferGetWidth(buffer), bytesPerRow / 4)
        for y in stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: fingerprintStride) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in stride(from: 0, to: width, by: fingerprintStride) {
                hash = (hash ^ UInt64(row[x])) &* 0x100_0000_01b3
            }
        }
        return hash
    }

    /// SCStream also delivers idle and blank frames; only complete ones are pictures.
    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
