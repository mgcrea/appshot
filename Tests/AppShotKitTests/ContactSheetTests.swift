import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

struct ContactSheetTests {
    @Test func laysCellsOutInAGrid() throws {
        let ctx = try #require(Image.context(width: 320, height: 200))
        let image = try #require(ctx.makeImage())
        let cells = (0..<4).map { ContactSheet.Cell(time: Double($0), label: "beat \($0)", image: image) }
        let sheet = try ContactSheet.render(cells, columns: 3, cellWidth: 160)
        #expect(sheet.width == 480)
        // Two rows of a 100px thumbnail plus a 40px label band.
        #expect(sheet.height == 2 * (100 + 40))
    }

    @Test func picksASettledFrameAfterEachBeatAndMidCaption() throws {
        let video = try VideoTimelineTests.video(#"[{"at":0,"caption":"a","until":4},{"at":6,"cue":"x"}]"#)
        let timeline = try VideoTimelineTests.timeline(video)
        #expect(ContactSheet.times(for: timeline, beats: [0, 6]) == [0.8, 2, 6.8])
    }
}
