import Foundation
import Testing

@testable import AppShotKit

/// `Capture.run` itself is untestable in CI — it needs a real .app, Screen Recording
/// permission and exclusive control of the pointer. What *is* testable is the spec
/// parsing in front of it, which is where a typo turns into a 90-second run that
/// captures the wrong thing.
struct CaptureScreenSpecTests {
    @Test("a bare name stages itself and takes the default settle")
    func bareName() throws {
        let screen = try Capture.Screen(spec: "export")
        #expect(screen.name == "export")
        #expect(screen.stage == "export")
        #expect(screen.settle == nil)
    }

    @Test("name:stage keeps the settle defaulted")
    func namedStage() throws {
        let screen = try Capture.Screen(spec: "export:export-pane")
        #expect(screen.name == "export")
        #expect(screen.stage == "export-pane")
        #expect(screen.settle == nil)
    }

    @Test("a third field is that screen's settle")
    func perScreenSettle() throws {
        let screen = try Capture.Screen(spec: "export:export-pane:6.5")
        #expect(screen.name == "export")
        #expect(screen.stage == "export-pane")
        #expect(screen.settle == 6.5)
    }

    /// The whole point of the empty middle: asking for a settle must not force you to
    /// restate a stage that already defaults correctly.
    @Test("an empty stage still means stage == name")
    func emptyStageWithSettle() throws {
        let screen = try Capture.Screen(spec: "export::6")
        #expect(screen.stage == "export")
        #expect(screen.settle == 6)
    }

    @Test("zero is a settle, not a missing one")
    func zeroSettle() throws {
        #expect(try Capture.Screen(spec: "export::0").settle == 0)
    }

    /// Silently ignoring these is the failure mode worth avoiding: `export:pane:six`
    /// would capture at the default settle and look like it worked.
    @Test(
        "a non-numeric or negative settle is rejected",
        arguments: [
            "export:pane:six", "export:pane:", "export:pane:-1", "export:pane:2s", ":pane:2", "",
        ])
    func rejected(spec: String) {
        #expect(throws: AppShotError.self) {
            try Capture.Screen(spec: spec)
        }
    }
}
