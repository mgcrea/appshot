import Foundation
import Testing

@testable import AppShotKit

/// The simulator turn's argv and runner text, asserted as values: running either needs a
/// booted simulator and a working Xcode.
struct SimulatorTurnTests {
    static let udid = "246D0326-FC34-4885-A0CF-D93432A08EEC"

    // MARK: - Orientation

    @Test func aWideCanvasIsLandscapeAndATallOnePortrait() {
        #expect(SimulatorTurn.Orientation(Config.Size(width: 2752, height: 2064)) == .landscape)
        #expect(SimulatorTurn.Orientation(Config.Size(width: 2064, height: 2752)) == .portrait)
        #expect(SimulatorTurn.Orientation(Config.Size(width: 2868, height: 1320)) == .landscape)
    }

    /// A simulator boots in portrait, so a square canvas never costs a turn.
    @Test func aSquareCanvasIsPortrait() {
        #expect(SimulatorTurn.Orientation(Config.Size(width: 1000, height: 1000)) == .portrait)
    }

    // MARK: - Commands

    /// One test method per orientation, named in full: without `-only-testing` both run,
    /// in whatever order, and the device ends up whichever way the last one turned it.
    @Test func aTurnRunsOnlyTheTestForItsOrientation() {
        let argv = SimulatorTurn.Command.turn(
            xctestrun: "/c/r.xctestrun", udid: Self.udid, to: .landscape
        ).argv

        #expect(argv.contains("-only-testing:AppShotTurner/TurnTests/testLandscape"))
        #expect(!argv.contains { $0.hasSuffix("testPortrait") })
        #expect(argv.contains("id=\(Self.udid)"))
        #expect(argv.contains("test-without-building"))
    }

    /// XCTest waits ten minutes on a refused UI-testing action unless told otherwise.
    @Test func aTurnThatCannotHappenGivesUpWithinAMinute() {
        let argv = SimulatorTurn.Command.turn(
            xctestrun: "/c/r.xctestrun", udid: Self.udid, to: .portrait
        ).argv

        let allowance = argv.firstIndex(of: "-maximum-test-execution-time-allowance")
        #expect(allowance.map { argv[$0 + 1] } == "60")
        #expect(argv.contains("-test-timeouts-enabled"))
    }

    /// Generic, so one build serves every simulator and runtime on the Mac.
    @Test func theRunnerIsBuiltForAnySimulator() {
        let argv = SimulatorTurn.Command.build(project: "/c/P.xcodeproj", derivedData: "/c/b")
            .argv

        #expect(argv.contains("build-for-testing"))
        #expect(argv.contains("generic/platform=iOS Simulator"))
        #expect(argv.contains("AppShotTurner"))
    }

    // MARK: - The runner

    /// The names `-only-testing` asks for are the names the test source declares.
    @Test func theTestsTheTurnAsksForExist() {
        #expect(SimulatorTurn.testSource.contains("class TurnTests: XCTestCase"))
        #expect(SimulatorTurn.testSource.contains("func testLandscape()"))
        #expect(SimulatorTurn.testSource.contains("func testPortrait()"))
    }

    /// `XCUIDevice` refuses to turn anything from a unit-test bundle. Measured.
    @Test func theRunnerIsAUITestingBundleWithNoAppToTest() {
        #expect(
            SimulatorTurn.projectFile.contains(
                "productType = \"com.apple.product-type.bundle.ui-testing\""))
        #expect(!SimulatorTurn.projectFile.contains("TEST_TARGET_NAME"))
        #expect(SimulatorTurn.projectFile.contains("path = AppShotTurner;"))
        #expect(SimulatorTurn.schemeFile.contains("BlueprintName = \"AppShotTurner\""))
    }

    /// A bundle built by one Xcode is not one another can run, and a build of an older
    /// runner text must not be found by a newer appshot.
    @Test func theCacheIsKeyedByXcodeAndRunnerVersion() {
        let directory = SimulatorTurn.cacheDirectory(xcodeBuild: "27A5218c")
        #expect(directory.lastPathComponent == "27A5218c")
        #expect(
            directory.deletingLastPathComponent().lastPathComponent
                == "turner-v\(SimulatorTurn.runnerVersion)")
        #expect(directory.path.contains("/Library/Caches/appshot/"))
    }

    @Test func theProjectIsWrittenWhereTheBuildLooks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "appshot-turner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SimulatorTurn.write(project: directory)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: directory.appending(path: "AppShotTurner/TurnTests.swift").path))
        #expect(
            fm.fileExists(
                atPath: directory.appending(path: "AppShotTurner.xcodeproj/project.pbxproj").path))
        #expect(
            fm.fileExists(
                atPath: directory.appending(
                    path: "AppShotTurner.xcodeproj/xcshareddata/xcschemes/AppShotTurner.xcscheme"
                ).path))
    }

    /// xcodebuild's `[MT]` diagnostics say nothing about why a turn failed, and crowd out
    /// the lines that do.
    @Test func aFailureSummaryDropsXcodebuildsOwnChatter() {
        let output = """
            2026-10-31 08:52:59.715 xcodebuild[1:2] [MT] IDESchemeActionSDKRecord: noise
            Testing started
            error: Failed to set device orientation
            """
        let summary = SimulatorTurn.summary(output, status: 65)
        #expect(!summary.contains("[MT]"))
        #expect(summary.contains("Failed to set device orientation"))
        #expect(SimulatorTurn.summary("", status: 65) == "exit 65")
    }
}
