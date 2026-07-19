import Foundation
import Testing

@testable import AppShotKit
@testable import appshot

/// The report exists to be *acted on* — it tells you which knob to reach for — so a
/// wrong conclusion is worse than no report. Producing a real `Capture.Timings`
/// needs a permission grant and exclusive control of the pointer, so without these
/// the formatting and every one of those conclusions would ship unexecuted.
struct TimingReportTests {
    static func shot(
        _ name: String = "main",
        launch: Double = 0, window: Double = 0, floor: Double = 0, poll: Double = 0,
        frames: Int = 3, encode: Double = 0, teardown: Double = 0
    ) -> Capture.Shot {
        Capture.Shot(
            name: name,
            appearance: "dark",
            url: URL(fileURLWithPath: "/tmp/\(name)~dark.png"),
            size: Config.Size(width: 100, height: 100),
            settled: true,
            timings: Capture.Timings(
                launch: launch, window: window, floor: floor, poll: poll, frames: frames,
                encode: encode, teardown: teardown))
    }

    @Test("no shots means no report, not a table of zeroes")
    func emptyRun() {
        #expect(Pipeline.timingReport([], settle: 1.0).isEmpty)
    }

    @Test("every phase appears, with the run's totals")
    func rendersEveryPhase() {
        let report = Pipeline.timingReport(
            [Self.shot(launch: 0.5, window: 0.25, floor: 1.0, poll: 0.5, teardown: 0.25)],
            settle: 1.0)
        let text = report.joined(separator: "\n")

        for phase in ["launch", "window", "floor", "poll", "encode", "teardown"] {
            #expect(text.contains(phase), "missing phase: \(phase)")
        }
        #expect(text.contains("1 shot(s), 2.5s total, 2.50s/shot"))
        #expect(text.contains("frames      3 median"))
    }

    /// Columns stay aligned or the table is unreadable, and the padding is exactly
    /// what the %s that used to do it got wrong.
    @Test("phase rows are aligned")
    func rowsAlign() {
        let report = Pipeline.timingReport([Self.shot(floor: 1.0)], settle: 1.0)
        let rows = report.filter { $0.hasSuffix("%") }

        #expect(rows.count == 6)
        #expect(Set(rows.map(\.count)).count == 1, "rows: \(rows)")
        // The header is built from the same widths, so it must land on them too.
        let header = report.first { $0.contains("median") }
        #expect(header?.count == rows.first?.count, "header: \(header ?? "nil")")
    }

    @Test("a window still on arrival points at the floor")
    func minimumFramesBlamesTheFloor() {
        let report = Pipeline.timingReport(
            [Self.shot(floor: 2.5, frames: Capture.pollMatches + 1)], settle: 2.5)
        #expect(report.contains { $0.contains("already still on arrival") })
        #expect(report.contains { $0.contains("2.5s floor") })
    }

    /// The opposite conclusion: the poll is doing the work, so the floor is not the
    /// thing to cut. Both must never fire at once.
    @Test("a dominant poll points away from the floor")
    func dominantPollBlamesTheFrameCost() {
        let report = Pipeline.timingReport([Self.shot(floor: 0.1, poll: 5.0, frames: 20)], settle: 0.1)
        #expect(report.contains { $0.contains("poll dominates") })
        #expect(!report.contains { $0.contains("already still on arrival") })
    }

    /// The finding that would invalidate the whole 0.2.0 premise: if launching and
    /// killing the app is most of the run, the settle was never worth tuning.
    @Test("launch and teardown overhead is called out")
    func overheadIsCalledOut() {
        let report = Pipeline.timingReport(
            [Self.shot(launch: 2.0, window: 1.0, floor: 0.5, frames: 3, teardown: 1.5)],
            settle: 0.5)
        #expect(report.contains { $0.contains("launching and killing the app") })
        #expect(report.contains { $0.contains("90%") })
    }
}
