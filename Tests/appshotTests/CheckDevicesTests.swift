import ArgumentParser
import Foundation
import Testing

@testable import AppShotKit
@testable import appshot

/// `check` on a config with a device axis compares every device and combines the verdicts,
/// so one device's failure cannot hide another's regressions.
struct CheckDevicesTests {
    static let config = """
        {
          "platform": "ios",
          "appearances": ["dark"],
          "fontFamily": "Helvetica",
          "layout": {
            "margin": 140, "textTop": 120, "titleFontSize": 100, "titleWeight": 700,
            "titleLineHeight": 1.12, "subtitleFontSize": 46, "subtitleWeight": 500,
            "textGap": 28, "screenshotGap": 72, "cornerRadius": 28,
            "shadow": { "blur": 48, "opacity": 0.3, "dy": 24 }
          },
          "themes": {
            "dark": {
              "background": { "angle": 145, "stops": [
                { "offset": 0, "color": "#000000" }, { "offset": 1, "color": "#111111" }] },
              "title": "#FFFFFF", "subtitle": "#AAAAAA"
            }
          },
          "screens": [{ "id": "home", "title": "Home" }],
          "devices": [
            { "id": "iphone", "simulator": "iPhone 17 Pro Max",
              "output": { "width": 1320, "height": 2868 } },
            { "id": "ipad", "simulator": "iPad Pro 13-inch (M5)",
              "output": { "width": 2064, "height": 2752 } }
          ]
        }
        """

    /// The iPhone has no captures at all; the iPad has one that drifted from its golden.
    static func fixture() throws -> (root: URL, config: URL, paths: Pipeline.PathValues) {
        let dirs = try CheckReportTests.dirs()
        let configURL = dirs.root.appending(path: "screenshots.config.json")
        try Data(Self.config.utf8).write(to: configURL)
        for slug in ["iphone", "ipad"] {
            try FileManager.default.createDirectory(
                at: dirs.cand.appending(path: slug), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: dirs.gold.appending(path: slug), withIntermediateDirectories: true)
        }
        try CheckReportTests.write("home~dark.png", in: dirs.gold.appending(path: "iphone"), shade: 90)
        try CheckReportTests.write("home~dark.png", in: dirs.gold.appending(path: "ipad"), shade: 90)
        try CheckReportTests.write("home~dark.png", in: dirs.cand.appending(path: "ipad"), shade: 200)
        let paths = Pipeline.PathValues(
            source: dirs.cand.path, golden: dirs.gold.path,
            diff: dirs.root.appending(path: "diff").path)
        return (dirs.root, configURL, paths)
    }

    static func options(
        _ fixture: (root: URL, config: URL, paths: Pipeline.PathValues), device: String? = nil
    ) -> Pipeline.CheckOptions {
        Pipeline.CheckOptions(
            paths: fixture.paths, tolerance: Gate.defaultTolerance, config: fixture.config.path,
            json: false, requireManifest: false, maxSourceAge: nil, device: device)
    }

    @Test("a device that throws does not stop the next one being compared")
    func aFailingDeviceDoesNotStopTheNext() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: ExitCode.self) { try Pipeline.check(Self.options(fixture)) }
        // The iPad's drift diff exists only if the iPad was compared after the iPhone threw.
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "diff/ipad/home~dark.png").path))
    }

    /// The gate reads each device's run record from that device's directory, so an iOS
    /// capture has to stamp each one, or `--max-source-age` can never pass and the
    /// staleness notices never print. The root record stays, for the family skew check.
    @Test("an iOS capture stamps each device directory and the root")
    func eachDeviceDirectoryCarriesItsRunRecord() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Both devices clean, so only the age check can fail.
        try CheckReportTests.write(
            "home~dark.png", in: fixture.root.appending(path: "source/iphone"), shade: 90)
        try CheckReportTests.write(
            "home~dark.png", in: fixture.root.appending(path: "source/ipad"), shade: 90)
        let source = URL(fileURLWithPath: fixture.paths.source)

        Pipeline.recordRuns(
            [
                (source.appending(path: "iphone"), [TimingReportTests.shot("home")]),
                (source.appending(path: "ipad"), [TimingReportTests.shot("home")]),
            ],
            appPath: nil, out: source.path)

        #expect(CaptureRun.read(from: source) != nil)
        var options = Self.options(fixture)
        options = Pipeline.CheckOptions(
            paths: options.paths, tolerance: options.tolerance, config: options.config,
            json: false, requireManifest: false, maxSourceAge: 3600, device: nil)
        try Pipeline.check(options)
    }

    /// One device in text mode keeps the error the top level renders, `Error: ` and all.
    @Test("a single device still throws its own error")
    func aSingleDeviceStillThrowsItsError() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: AppShotError.self) {
            try Pipeline.check(Self.options(fixture, device: "iphone"))
        }
    }
}
