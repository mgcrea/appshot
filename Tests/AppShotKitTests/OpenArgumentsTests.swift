import Foundation
import Testing

@testable import AppShotKit

/// What a staged launch hands the app.
///
/// These are a contract with code in other repositories: an app reads each of these keys
/// by name, and a key that silently stops arriving degrades the capture rather than
/// failing it. `-ScreenshotActivation` is the sharpest case — an app that no longer hears
/// `none` goes back to taking the screen from whoever is using the Mac.
struct OpenArgumentsTests {

    private func arguments(
        noActivate: Bool = false,
        foregroundLaunch: Bool = false,
        display: UInt32? = nil,
        readyFile: URL? = nil,
        extraArgs: [String] = []
    ) -> [String] {
        let options = Capture.Options(
            app: URL(fileURLWithPath: "/tmp/My.app"),
            outDir: URL(fileURLWithPath: "/tmp/out"),
            screens: [],
            extraArgs: extraArgs,
            foregroundLaunch: foregroundLaunch,
            noActivate: noActivate)
        return Capture.openArguments(
            screen: Capture.Screen(name: "main", stage: "browser"), appearance: "dark",
            readyFile: readyFile, display: display, options: options)
    }

    /// The value after `key`, or nil when the key is absent.
    private func value(of key: String, in args: [String]) -> String? {
        guard let i = args.lastIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @Test func noActivate_tellsTheAppNotToActivate() {
        #expect(value(of: "-ScreenshotActivation", in: arguments(noActivate: true)) == "none")
    }

    @Test func aFocusedRun_tellsTheAppToActivate() {
        #expect(value(of: "-ScreenshotActivation", in: arguments()) == "focused")
    }

    /// Launched frontmost, so the app activating itself is harmless — and a project that
    /// switches CAPTURE_FOCUS to it must not have to touch the app.
    @Test func foregroundLaunch_isAFocusedRun() {
        #expect(
            value(of: "-ScreenshotActivation", in: arguments(foregroundLaunch: true))
                == "focused")
    }

    @Test func stageAndAppearance_arrive() {
        let args = arguments()
        #expect(value(of: "-ScreenshotStage", in: args) == "browser")
        #expect(value(of: "-ScreenshotAppearance", in: args) == "dark")
    }

    @Test func displayAndReadyFile_arriveOnlyWhenGiven() {
        let bare = arguments()
        #expect(value(of: "-ScreenshotDisplay", in: bare) == nil)
        #expect(value(of: "-ScreenshotReadyFile", in: bare) == nil)

        let given = arguments(display: 7, readyFile: URL(fileURLWithPath: "/tmp/ready"))
        #expect(value(of: "-ScreenshotDisplay", in: given) == "7")
        #expect(value(of: "-ScreenshotReadyFile", in: given) == "/tmp/ready")
    }

    @Test func backgroundLaunch_isTheDefault() {
        #expect(arguments().first == "-gn")
        #expect(arguments(foregroundLaunch: true).first == "-n")
    }

    /// NSArgumentDomain keeps the last occurrence, so the project's own value must come
    /// after appshot's.
    @Test func extraArgs_comeLastSoTheyWin() {
        let args = arguments(extraArgs: ["-AppleWindowTabbingMode", "always"])
        #expect(value(of: "-AppleWindowTabbingMode", in: args) == "always")
        #expect(Array(args.suffix(2)) == ["-AppleWindowTabbingMode", "always"])
    }
}
