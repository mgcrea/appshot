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
    private var _pictures = PictureCounter()
    private var _maxGap = 0.0
    private var stopError: (any Error)?

    var frames: Int { lock.withLock { _frames } }
    /// The frames written that differ from the one before: what actually moved.
    /// ScreenCaptureKit sends a complete frame whenever anything on the display changes,
    /// outside the filter too, so on a Mac in use a still window arrives as a steady run
    /// of identical pictures, and `frames` counts the Mac's activity rather than the app's.
    var pictures: Int { lock.withLock { _pictures.count } }
    var maxGap: Double { lock.withLock { _maxGap } }

    /// The presentation time of the first frame written, on the host clock SCStream
    /// stamps its samples with. The master's t = 0.
    var origin: CMTime? { lock.withLock { firstPTS } }

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            let reason = writer.error.map { "\($0)" } ?? "writer did not start"
            throw AppShotError.recordFailed(video: "", reason: reason)
        }
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
        let picture = CMSampleBufferGetImageBuffer(sample).map(Self.fingerprint)
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
            _pictures.note(picture)
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
    struct PictureCounter {
        private var last: UInt64?
        private(set) var count = 0

        mutating func note(_ fingerprint: UInt64?) {
            if fingerprint == nil || fingerprint != last { count += 1 }
            last = fingerprint
        }
    }

    /// Pixels apart, both ways, that `fingerprint` reads: an eighth of the rows and an
    /// eighth of each row, about 0.3M of a 6K display's 20M, so a 60 fps stream stays
    /// cheap. A change smaller than this in both directions can be missed.
    static let fingerprintStride = 8

    /// An FNV-1a hash of a sparse grid of a BGRA buffer's pixels. Equal pictures give
    /// equal hashes; a change on the grid gives a different one.
    static func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return hash }
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
