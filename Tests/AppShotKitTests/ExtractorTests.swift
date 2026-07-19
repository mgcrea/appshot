import Foundation
import Testing

@testable import AppShotKit

struct ExtractorTests {
    /// XCTest splices an occurrence index and a UUID in before the extension, so the
    /// name the test chose — which is the filename the rest of the pipeline keys on —
    /// has to be put back.
    @Test func stripsXCTestsAttachmentMangling() {
        #expect(
            Extractor.demangle("main~dark_0_8C756F5A-DC9C-44CF-84CB-908C5F65E2BC.png")
                == "main~dark.png")
        #expect(
            Extractor.demangle("settings-pro~light_12_00F40861-78EA-4A4B-BF92-CB90EC4FB702.png")
                == "settings-pro~light.png")
    }

    /// An already-clean name must survive untouched, and so must anything that merely
    /// resembles the pattern.
    @Test func leavesUnmangledNamesAlone() {
        #expect(Extractor.demangle("main~dark.png") == "main~dark.png")
        #expect(Extractor.demangle("readiness~light.png") == "readiness~light.png")
        // Underscores and digits in the stem are not the mangling suffix.
        #expect(Extractor.demangle("my_screen_2.png") == "my_screen_2.png")
    }
}
