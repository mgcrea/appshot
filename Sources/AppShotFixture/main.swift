import AppKit

/// A stand-in app for measuring and testing the capture driver.
///
/// The capture path has no end-to-end coverage: `Capture.run` needs a real `.app`,
/// Screen Recording permission and exclusive control of the pointer, so the unit
/// tests inject synthetic frames and never touch a window server. That leaves the
/// settle defaults tuned by reasoning alone.
///
/// This app closes that gap by being deliberately hard to photograph in the three
/// ways real apps are:
///
///   instant      content on the first frame — the floor is pure overhead
///   late         a *still* empty state for 3s, then the real content. The trap the
///                frame poll cannot see: quiescence says settled, and it is wrong
///   restless     never stops moving — must ride --settle-max and report `!`
///   slow-window  no window for 2s — exercises waitForWindow, not the settle
///
/// `make bench` captures all four and prints where the time went.
enum Stage: String {
    case instant, late, restless, slowWindow = "slow-window"

    /// Seconds before the window exists at all.
    var windowDelay: Double { self == .slowWindow ? 2.0 : 0 }
    /// Seconds of still-but-unfinished content before the real thing appears.
    var contentDelay: Double { self == .late ? 3.0 : 0 }
    var animates: Bool { self == .restless }
}

final class ContentView: NSView {
    var loaded = false
    var phase = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // A header, always present. Stands in for the chrome that renders instantly
        // in any real app — without it a "loading" capture would be almost empty,
        // which is not the case worth simulating.
        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 64).fill()

        guard loaded else {
            // The skeleton. Perfectly still, and *not* the finished screen — this is
            // exactly what a frame poll alone would happily photograph.
            NSColor.tertiaryLabelColor.setFill()
            for row in 0..<3 {
                NSRect(x: 32, y: 104 + Double(row) * 44, width: 240, height: 20).fill()
            }
            return
        }

        NSColor.labelColor.setFill()
        for row in 0..<6 {
            let width = 420 - Double(row % 3) * 60
            NSRect(x: 32, y: 104 + Double(row) * 44, width: width, height: 20).fill()
        }

        if phase > 0 {
            // Big enough to clear the stability tolerance by orders of magnitude: at
            // ~0.01% of a 1600x1040 capture the threshold is ~170 pixels, and this is
            // 40,000 of them. A poll must never call this window still.
            NSColor.systemOrange.setFill()
            NSRect(x: 560, y: 120 + Double(phase % 3) * 60, width: 100, height: 100).fill()
        }
    }
}

/// `Timer` bodies are `@Sendable` but always fire on the main run loop, so the
/// isolation is real and `assumeIsolated` is stating it rather than dodging it.
@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let stage: Stage
    var window: NSWindow?
    var view: ContentView?

    init(stage: Stage) {
        self.stage = stage
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if stage.windowDelay > 0 {
            Timer.scheduledTimer(withTimeInterval: stage.windowDelay, repeats: false) { _ in
                MainActor.assumeIsolated { self.makeWindow() }
            }
        } else {
            makeWindow()
        }
    }

    func makeWindow() {
        let view = ContentView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        view.loaded = stage.contentDelay == 0

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "appshot fixture — \(stage.rawValue)"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.view = view

        if stage.contentDelay > 0 {
            Timer.scheduledTimer(withTimeInterval: stage.contentDelay, repeats: false) { _ in
                MainActor.assumeIsolated {
                    view.loaded = true
                    view.needsDisplay = true
                }
            }
        }
        if stage.animates {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    view.phase += 1
                    view.needsDisplay = true
                }
            }
        }
    }
}

let defaults = UserDefaults.standard
let stage = Stage(rawValue: defaults.string(forKey: "ScreenshotStage") ?? "instant") ?? .instant

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Same knob the real apps read, so the fixture exercises the appearance argument
// rather than only the stage one.
app.appearance = NSAppearance(
    named: defaults.string(forKey: "ScreenshotAppearance") == "light" ? .aqua : .darkAqua)

let delegate = Delegate(stage: stage)
app.delegate = delegate
app.run()
