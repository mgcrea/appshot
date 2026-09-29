import Foundation
import Testing

@testable import AppShotKit

/// The `--no-activate` guard's decisions, over window-list fixtures.
///
/// The live half cannot run here — it needs a window server and an app misbehaving on
/// it, which is what `make bench-no-activate` provides. What can run here is every call
/// the guard makes about *whose doing* a change was, which is where a guard like this
/// goes wrong: failing a run because the person pressed ⌘Q is how it gets turned off.
struct ForegroundGuardTests {
    typealias Entry = ForegroundGuard.Entry
    typealias Sample = ForegroundGuard.Sample

    static let app: pid_t = 500
    static let editor: pid_t = 100
    static let browser: pid_t = 200
    static let finder: pid_t = 300

    static func window(_ pid: pid_t, layer: Int = 0) -> Entry {
        let owner =
            switch pid {
            case app: "AppShotFixture"
            case editor: "Code"
            case browser: "Safari"
            case finder: "Finder"
            default: "pid \(pid)"
            }
        return Entry(pid: pid, layer: layer, owner: owner)
    }

    /// Feed `samples` to a monitor tracking the launched app, and return its verdict.
    static func verdict(_ samples: [Sample], trackAfter: Int = 0) -> ForegroundGuard.Violation? {
        var monitor = ForegroundGuard.Monitor()
        for (i, sample) in samples.enumerated() {
            if i == trackAfter { monitor.track(app) }
            monitor.observe(sample)
        }
        return monitor.verdict
    }

    // MARK: - Z-order

    @Test("a launched window ahead of the front app's is raised above it")
    func raisedAbove() {
        let windows = [Self.window(Self.app), Self.window(Self.editor), Self.window(Self.browser)]
        #expect(
            ForegroundGuard.isRaisedAbove(launched: Self.app, front: Self.editor, windows: windows))
    }

    /// Where a well-behaved background launch lands: behind the app being used, and
    /// possibly ahead of every other app, which is nobody's business.
    @Test("behind the front app's first window is fine, whatever it is ahead of")
    func behindTheFrontApp() {
        let windows = [
            Self.window(Self.editor), Self.window(Self.app), Self.window(Self.browser),
            Self.window(Self.editor),
        ]
        #expect(
            !ForegroundGuard.isRaisedAbove(launched: Self.app, front: Self.editor, windows: windows))
    }

    /// Menu-bar strips and deliberately floating panels live on other layers.
    @Test("windows on other layers are not compared")
    func otherLayers() {
        let windows = [
            Self.window(Self.app, layer: 24), Self.window(Self.app, layer: 3),
            Self.window(Self.editor), Self.window(Self.app),
        ]
        #expect(
            !ForegroundGuard.isRaisedAbove(launched: Self.app, front: Self.editor, windows: windows))
    }

    /// Nothing to be above. The frontmost check still covers activation here.
    @Test("no verdict when the front app has no normal window on screen")
    func frontAppWithoutWindows() {
        let windows = [Self.window(Self.app), Self.window(Self.finder, layer: 25)]
        #expect(
            !ForegroundGuard.isRaisedAbove(launched: Self.app, front: Self.finder, windows: windows))
    }

    @Test("the launched app being the front app is the other check's business")
    func frontIsLaunched() {
        let windows = [Self.window(Self.app), Self.window(Self.editor)]
        #expect(
            !ForegroundGuard.isRaisedAbove(launched: Self.app, front: Self.app, windows: windows))
    }

    // MARK: - Monitor: raised

    @Test("a window held above the front app fails, naming that app")
    func raisedPersists() {
        let above = Sample(
            frontmost: Self.editor, windows: [Self.window(Self.app), Self.window(Self.editor)])
        let verdict = Self.verdict([
            Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)]), above, above,
        ])
        #expect(verdict == .raisedAbove(frontApp: "Code"))
    }

    /// The two reads are a moment apart, so a person switching apps can pair the new
    /// window order with the old front app for one sample.
    @Test("one sample above the front app is not enough")
    func raisedBlip() {
        let editor = [Self.window(Self.editor), Self.window(Self.app), Self.window(Self.browser)]
        let blip = [Self.window(Self.browser), Self.window(Self.app), Self.window(Self.editor)]
        let verdict = Self.verdict([
            Sample(frontmost: Self.editor, windows: editor),
            Sample(frontmost: Self.editor, windows: blip),
            Sample(frontmost: Self.browser, windows: blip),
        ])
        #expect(verdict == nil)
    }

    @Test("a well-behaved run, the person switching apps throughout, passes")
    func wellBehaved() {
        let verdict = Self.verdict([
            Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)]),
            Sample(
                frontmost: Self.editor,
                windows: [Self.window(Self.editor), Self.window(Self.app)]),
            Sample(
                frontmost: Self.browser,
                windows: [Self.window(Self.browser), Self.window(Self.editor), Self.window(Self.app)]),
            Sample(
                frontmost: Self.editor,
                windows: [Self.window(Self.editor), Self.window(Self.browser), Self.window(Self.app)]),
        ])
        #expect(verdict == nil)
    }

    // MARK: - Monitor: took the foreground

    @Test("the app making itself frontmost fails")
    func tookForeground() {
        let verdict = Self.verdict([
            Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)]),
            Sample(
                frontmost: Self.app,
                windows: [Self.window(Self.app), Self.window(Self.editor)]),
            Sample(
                frontmost: Self.app,
                windows: [Self.window(Self.app), Self.window(Self.editor)]),
        ])
        #expect(verdict == .tookForeground)
    }

    /// Activating raises the app's windows, and if the front-app read lags the window
    /// list the raise is seen first. The activation is the cause and the fix.
    @Test("taking the front outranks the raise it causes")
    func tookOutranksRaised() {
        let raised = [Self.window(Self.app), Self.window(Self.editor)]
        let verdict = Self.verdict([
            Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)]),
            Sample(frontmost: Self.editor, windows: raised),
            Sample(frontmost: Self.editor, windows: raised),
            Sample(frontmost: Self.app, windows: raised),
        ])
        #expect(verdict == .tookForeground)
    }

    /// It became active, which is the thing it must not do; that nobody was covered does
    /// not survive the person opening a window.
    @Test("taking the front from an app with no windows still fails")
    func tookForegroundFromNothing() {
        let verdict = Self.verdict([
            Sample(frontmost: Self.finder, windows: []),
            Sample(frontmost: Self.app, windows: [Self.window(Self.app)]),
        ])
        #expect(verdict == .tookForeground)
    }

    /// Activation in the first instant, before `open` has produced a pid to track, is
    /// still attributed: the samples taken meanwhile say who held the front.
    @Test("a takeover right after launch is attributed to the front app before it")
    func tookForegroundBeforeTracking() {
        let verdict = Self.verdict(
            [
                Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)]),
                Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)]),
                Sample(
                    frontmost: Self.app,
                    windows: [Self.window(Self.app), Self.window(Self.editor)]),
            ], trackAfter: 2)
        #expect(verdict == .tookForeground)
    }

    /// ⌘Q or ⌘H on the front app, or another project's run tearing its app down: macOS
    /// hands the front to whatever is next in line, and a window parked just behind the
    /// front app's is exactly that.
    @Test("the front handed over by an app that quit or hid is not a takeover")
    func handoff() {
        let verdict = Self.verdict([
            Sample(
                frontmost: Self.editor,
                windows: [Self.window(Self.editor), Self.window(Self.app)]),
            Sample(frontmost: Self.editor, windows: [Self.window(Self.app)]),
            Sample(frontmost: Self.app, windows: [Self.window(Self.app)]),
        ])
        #expect(verdict == nil)
    }

    /// The window server drops the windows and the front app moves in either order, and
    /// a quitting app can take a moment to close them.
    @Test("windows closing just after the front moved is still a handoff")
    func lateHandoff() {
        let both = [Self.window(Self.app), Self.window(Self.editor)]
        let verdict = Self.verdict([
            Sample(frontmost: Self.editor, windows: [Self.window(Self.editor), Self.window(Self.app)]),
            Sample(frontmost: Self.app, windows: both),
            Sample(frontmost: Self.app, windows: both),
            Sample(frontmost: Self.app, windows: [Self.window(Self.app)]),
        ])
        #expect(verdict == nil)
    }

    /// The handoff excuse is for windows that go *as* the front moves. The editor hidden
    /// long after the app took the front says nothing about how it was taken.
    @Test("the holder hiding long after the takeover does not excuse it")
    func hiddenLongAfter() {
        let both = [Self.window(Self.app), Self.window(Self.editor)]
        var samples = [
            Sample(frontmost: Self.editor, windows: [Self.window(Self.editor)])
        ]
        samples += Array(
            repeating: Sample(frontmost: Self.app, windows: both),
            count: ForegroundGuard.Monitor.handoffSamples + 2)
        samples.append(Sample(frontmost: Self.app, windows: [Self.window(Self.app)]))
        #expect(Self.verdict(samples) == .tookForeground)
    }

    @Test("samples before a pid is tracked never fail on their own")
    func untracked() {
        var monitor = ForegroundGuard.Monitor()
        let raised = Sample(
            frontmost: Self.editor, windows: [Self.window(Self.app), Self.window(Self.editor)])
        monitor.observe(raised)
        monitor.observe(raised)
        monitor.observe(raised)
        #expect(monitor.verdict == nil)
    }

    // MARK: - Errors

    /// `make bench-no-activate` matches each failure on a phrase of its message. This
    /// pins the phrase to the case, and the case to its slug, so the live proof and the
    /// `kind` a caller branches on cannot drift apart.
    @Test("each violation reports its own slug, with the phrase the bench matches")
    func slugs() {
        let took = ForegroundGuard.Violation.tookForeground.error(screen: "main~dark")
        #expect(took.slug == "took_foreground")
        #expect(took.description.hasPrefix("main~dark: the app made itself frontmost"))
        #expect(took.description.contains("-ScreenshotActivation"))

        let raised = ForegroundGuard.Violation.raisedAbove(frontApp: "Code")
            .error(screen: "main~dark")
        #expect(raised.slug == "raised_above_front_app")
        #expect(raised.description.hasPrefix("main~dark: a window was ordered above Code's"))
        #expect(raised.description.contains("orderFrontRegardless()"))
    }
}
