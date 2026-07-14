import Foundation

/// Every failure the library can produce. The CLI turns these into exit codes and
/// messages; the library itself never prints and never exits.
public enum AppShotError: Error, CustomStringConvertible {
    case invalidConfig(URL, String)
    case invalidOutputSize(String, allowed: [String])
    case missingTheme(String)
    case missingCaptures([String], dir: URL)
    case duplicateCaptures([Gate.Duplicate])
    case noCaptures(URL)
    case noGoldens(URL)
    case fontNotResolved(requested: String, got: String)
    case noRoomForScreenshot(screen: String, textBottom: Int, canvasHeight: Int)
    case imageDecodeFailed(URL)
    case gitLFSPointer(URL)
    case imageEncodeFailed(URL)
    case captureFailed(screen: String, reason: String)
    case appNotFound(URL)
    case appNeverStarted(screen: String)
    case windowNeverAppeared(screen: String)
    case wouldNotComeToFront(pid: Int32, screen: String)
    case screenRecordingDenied
    case captureLockHeld(by: String)
    case extractFailed(String)

    public var description: String {
        switch self {
        case .invalidConfig(let url, let why):
            return "invalid config \(url.path): \(why)"

        case .invalidOutputSize(let size, let allowed):
            return """
                output is \(size), which App Store Connect will reject.
                Use one of: \(allowed.joined(separator: ", "))
                """

        case .missingTheme(let appearance):
            return "no theme for appearance \"\(appearance)\""

        case .missingCaptures(let names, let dir):
            return """
                \(names.count) capture(s) missing from \(dir.path):
                \(names.map { "   • \($0)" }.joined(separator: "\n"))

                The config expects these; the run did not produce them. Re-capture — a \
                partial set must not travel further down the pipeline.
                """

        case .duplicateCaptures(let duplicates):
            return """
                refusing to accept — \(duplicates.count) set(s) of captures are the same image:
                \(duplicates.map { "   • \($0.reason)" }.joined(separator: "\n"))

                Accepting these would make the duplicate the baseline, and a baseline that \
                disagrees with nothing can never be caught again. Fix the staging and \
                re-capture.
                """

        case .noCaptures(let dir):
            return "no PNGs in \(dir.path) — did capture run?"

        case .noGoldens(let dir):
            return """
                no goldens at \(dir.path).
                Seed them with:  appshot accept
                """

        case .fontNotResolved(let requested, let got):
            return """
                the caption font "\(requested)" is not installed — it resolved to "\(got)".
                Store captions would silently ship in the wrong typeface.
                Install it (SF Pro is a free download from developer.apple.com/fonts)
                or change `fontFamily` in the config to one that is present.
                """

        case .noRoomForScreenshot(let screen, let textBottom, let height):
            return """
                \(screen): no room left for the screenshot — the text block ends at \
                \(textBottom)px of a \(height)px canvas.
                Shorten the caption, or reduce layout.textTop / layout.margin.
                """

        case .imageDecodeFailed(let url):
            return "could not decode \(url.lastPathComponent)"

        case .gitLFSPointer(let url):
            return """
                \(url.lastPathComponent) is a Git LFS pointer, not an image — this clone \
                has not fetched the real bytes.

                    git lfs pull

                Everything that only checks the file exists will walk straight past these: \
                they are 131 bytes of text, still named .png.
                """

        case .imageEncodeFailed(let url):
            return "could not write \(url.path)"

        case .captureFailed(let screen, let reason):
            return "\(screen): capture failed — \(reason)"

        case .appNotFound(let url):
            return "no app bundle at \(url.path) (build it first)"

        case .appNeverStarted(let screen):
            return "\(screen): the app never started"

        case .windowNeverAppeared(let screen):
            return "\(screen): the window never appeared"

        case .wouldNotComeToFront(let pid, let screen):
            return """
                \(screen): pid \(pid) would not come to the front — something else is \
                stealing activation.
                Capturing now would bake an inactive title bar (grey traffic lights, \
                dimmed toolbar) into the image, which looks plausible and is wrong.
                """

        case .screenRecordingDenied:
            return """
                Screen Recording permission is not granted.
                Without it captures fall back to opaque window corners, which the \
                compositor depends on being transparent.
                Grant it in System Settings → Privacy & Security → Screen Recording.
                """

        case .captureLockHeld(let holder):
            return """
                another capture run is in progress (pid \(holder)).
                Activation is global — two runs would steal focus from each other and \
                photograph the wrong windows.
                """

        case .extractFailed(let why):
            return "could not extract attachments: \(why)"
        }
    }
}
