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
}
