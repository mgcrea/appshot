import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct RecorderTests {
    static func video() throws -> Config.Video {
        try VideoConfigTests.config(
            videos: """
                [{ "id": "v", "stage": "video", "duration": 4, "outputs": { "promo": [[100, 100]] },
                   "beats": [{ "at": 0, "caption": "a" }, { "at": 1, "cue": "pointer.click", "args": { "target": "row-2" } },
                             { "at": 2, "cue": "fixture.flash" }] }]
                """
        ).video("v")
    }

    @Test func onlyBeatsWithACueBecomeLines() throws {
        let lines = Recorder.cueLines(for: try Self.video())
        #expect(lines.map(\.seq) == [0, 1])
        #expect(lines.map(\.beat) == [1, 2])
        #expect(lines[0].line.args["target"] == .string("row-2"))
    }

    @Test func lateAckWarnsThenFails() throws {
        let lines = Recorder.cueLines(for: try Self.video())
        let warnings = try Recorder.judge(sent: [0: 1], acked: [0: 1.1], now: 1.2, lines: lines, video: "v")
        #expect(warnings.count == 1)
        #expect(throws: AppShotError.self) {
            try Recorder.judge(sent: [0: 1], acked: [0: 1.3], now: 1.4, lines: lines, video: "v")
        }
    }

    @Test func missingAckFailsAfterTheTimeout() throws {
        let lines = Recorder.cueLines(for: try Self.video())
        _ = try Recorder.judge(sent: [0: 1], acked: [:], now: 1.9, lines: lines, video: "v")
        #expect {
            try Recorder.judge(sent: [0: 1], acked: [:], now: 2.01, lines: lines, video: "v")
        } throws: { error in
            guard case .cueFailed(_, let seq, let cue, _) = error as? AppShotError else { return false }
            return seq == 0 && cue == "pointer.click"
        }
    }

    @Test func stageCropIsTheWindowUnionInDisplayPixels() {
        let crop = Recorder.stageCrop(
            windows: [
                CGRect(x: 110, y: 60, width: 100, height: 50), CGRect(x: 150, y: 80, width: 100, height: 50),
            ],
            display: CGRect(x: 100, y: 50, width: 1000, height: 800), scale: 2)
        #expect(crop == [20, 20, 280, 140])
    }

    @Test func aWindowScreenCaptureKitDoesNotListYetIsLeftForTheNextCheck() throws {
        let ids = try Recorder.recordable(appWindows: [1, 2], listed: [1, 7], video: "v")
        // Not [1, 2]: the next check must still see a difference, and retry.
        #expect(ids == [1])
        #expect(try Recorder.recordable(appWindows: [1, 2], listed: [1, 2, 7], video: "v") == [1, 2])
        #expect {
            try Recorder.recordable(appWindows: [1, 2], listed: [7], video: "v")
        } throws: { error in
            guard case .recordFailed(let video, let reason) = error as? AppShotError else { return false }
            return video == "v" && reason.contains("none of the app's")
        }
    }

    /// The app does not exist and the lock root is fresh: only a check made before both
    /// can answer `invalidVideo` for the second video.
    @Test func aVideoWithoutAStageFailsBeforeLaunchingAnything() async throws {
        let config = try VideoConfigTests.config(
            videos: """
                [{ "id": "ok", "stage": "video", "duration": 4, "outputs": { "promo": [[100, 100]] }, "beats": [] },
                 { "id": "bare", "duration": 4, "outputs": { "promo": [[100, 100]] }, "beats": [] }]
                """)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rec-\(UUID())")
        let options = Recorder.Options(
            capture: Capture.Options(
                app: root.appending(path: "Missing.app"), outDir: root.appending(path: "out"), screens: [],
                appearances: ["dark"], lockRoot: root.appending(path: "lock"), noActivate: true),
            videos: config.videos ?? [])
        await #expect {
            _ = try await Recorder.run(options)
        } throws: { error in
            guard case .invalidVideo(let id, let reason) = error as? AppShotError else { return false }
            return id == "bare" && reason.contains("stage")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Every error out of a take is an AppShotError

    static func sckError(_ code: Int, _ text: String) -> NSError {
        NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: code,
            userInfo: [NSLocalizedDescriptionKey: text])
    }

    @Test func foreignErrorsBecomeRecordFailedNamingTheVideo() throws {
        let mapped = Recorder.takeError(Self.sckError(-3815, "stream stopped"), video: "v")
        guard case .recordFailed(let video, let reason) = mapped else {
            Issue.record("expected recordFailed, got \(mapped)")
            return
        }
        #expect(video == "v")
        #expect(reason.contains("stream stopped"))
        #expect(reason.contains("-3815"))
    }

    @Test func appShotErrorsKeepTheirCaseAndGainAMissingVideo() {
        let unnamed = Recorder.takeError(AppShotError.recordFailed(video: "", reason: "x"), video: "v")
        guard case .recordFailed(let video, let reason) = unnamed else {
            Issue.record("expected recordFailed, got \(unnamed)")
            return
        }
        #expect(video == "v" && reason == "x")

        let cue = Recorder.takeError(
            AppShotError.cueFailed(video: "w", seq: 3, cue: "c", reason: "r"), video: "v")
        guard case .cueFailed(let named, let seq, let name, _) = cue else {
            Issue.record("expected cueFailed, got \(cue)")
            return
        }
        #expect(named == "w" && seq == 3 && name == "c")
    }

    @Test func aScreenCaptureKitCallThatNeverAnswersFailsTheTake() async {
        await #expect {
            try await Recorder.bounded(video: "v", "starting the stream", timeout: .milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
            }
        } throws: { error in
            guard case .recordFailed(let video, let reason) = error as? AppShotError else { return false }
            return video == "v" && reason.contains("starting the stream") && reason.contains("replayd")
        }
    }

    @Test func aScreenCaptureKitErrorIsWrappedNamingTheStep() async {
        await #expect {
            try await Recorder.bounded(video: "v", "stopping the stream", timeout: .seconds(5)) {
                throw Self.sckError(-3808, "already stopped")
            }
        } throws: { error in
            guard case .recordFailed(let video, let reason) = error as? AppShotError else { return false }
            return video == "v" && reason.contains("stopping the stream")
                && reason.contains("already stopped")
        }
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "needs a hardware HEVC encoder"))
    func aStreamTheSystemStoppedFailsTheTake() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "stop-\(UUID()).mov.partial")
        let recorder = try StreamRecorder(url: url, width: 64, height: 64)
        defer {
            recorder.cancel()
            try? FileManager.default.removeItem(at: url)
        }
        try recorder.throwIfStopped(video: "v")
        recorder.stopped(with: Self.sckError(-3821, "the display went to sleep"))
        #expect {
            try recorder.throwIfStopped(video: "v")
        } throws: { error in
            guard case .recordFailed(let video, let reason) = error as? AppShotError else { return false }
            return video == "v" && reason.contains("the display went to sleep")
        }
    }

    /// `record` films a Mac window; an iOS config is pointed at the stills path instead
    /// of launching an app it cannot film.
    @Test func recordRefusesAnIOSConfig() throws {
        let ios = try VideoConfigTests.ios(
            videos: #"[{ "id": "v", "duration": 15, "outputs": { "preview": true }, "beats": [] }]"#)
        #expect {
            try Recorder.requireMac(ios)
        } throws: { error in
            guard case .invalidVideo(let id, let reason) = error as? AppShotError else { return false }
            return id == "v" && reason.contains("--from-stills")
        }
        try Recorder.requireMac(try VideoConfigTests.config(videos: VideoConfigTests.valid))
    }
}
