# macOS specifics

## Why not `XCUIScreenshot`

`XCUIScreenshot` composites the screen. A macOS window has rounded corners with real alpha, and behind them is the desktop — so the capture bakes desktop pixels (or black) into the corners. On a store page against a colored background, that reads as a rendering bug.

ScreenCaptureKit can capture a specific window list with a transparent background, preserving the corner alpha. It costs Screen Recording permission for the test runner.

## Capturing a window with true alpha

The shape of it (full working version in [`assets/ScreenshotHarness.swift`](../assets/ScreenshotHarness.swift)):

```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let scWindows = content.windows.filter { ids.contains($0.windowID) }
let display = content.displays.first { $0.frame.intersects(base.bounds) } ?? content.displays.first!

let config = SCStreamConfiguration()
config.showsCursor = false
config.backgroundColor = clearColor                 // stored property — see below
config.sourceRect = base.bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
config.width  = Int((base.bounds.width  * scale).rounded())
config.height = Int((base.bounds.height * scale).rounded())

let filter = SCContentFilter(display: display, including: scWindows)
return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
```

Four things go wrong here:

**`backgroundColor` is `unowned(unsafe)`.** Pass a temporary `CGColor` and you get garbage or a crash. Hold it in a stored property on the test case.

**`sourceRect` is display-relative.** Window bounds are global. On a multi-display setup, subtract the display origin or you capture the wrong region.

**Which windows to include.** Include the base window *and any window in front of it that overlaps it* — a sheet must appear in the shot. Exclude everything behind, or the transparent corners fill with the window underneath. Selecting by z-order:

```swift
let ids = Set(windows[...baseIndex]
    .filter { !$0.bounds.intersection(base.bounds).isNull }
    .map(\.id))
```
(`windows` is front-to-back from `CGWindowListCopyWindowInfo`, so `[...baseIndex]` is "base and everything in front".)

**Which window is the base.** Don't assume `windows.first`. Pick the one with the greatest area of overlap with the `XCUIElement.frame` you're trying to photograph. This is what makes a Settings window capture work: query for a window containing a known element (`app.windows.containing(.staticText, identifier: "Endpoint")`) and let overlap resolve the rest.

`CGWindowListCopyWindowInfo` still exists and is fine for z-order and window ids — only the *image-producing* `CGWindowListCreateImage` variants were deprecated in favor of ScreenCaptureKit.

## Permission

Screen Recording must be granted to the **test runner** (`…UITests-Runner.app`), not to your app. It is granted once per runner binary; changing the bundle id resets it.

Preflight so failure is legible:

```swift
guard CGPreflightScreenCaptureAccess() else {
    if ProcessInfo.processInfo.environment["STRICT_CAPTURE"] == "1" {
        XCTFail("Screen Recording not granted to the test runner")
    }
    // else: fall back to XCUIScreenshot, but print a loud warning
}
```

Silently falling back is how opaque corners reach the App Store. In CI, fail.

## Focus — the fact that decides the architecture

Start here.

Under `xcodebuild test` the app launches behind the runner, and **the test process cannot raise it**. `XCUIApplication.activate()` from the test does not reliably make it the active application. That matters more than it sounds, because `typeKey` delivers to whichever app is frontmost: if the app never activates, keyboard-driven navigation is not flaky — it is **inert**, and the run captures nothing while reporting success.

**But the app can raise itself.** This is the distinction that gets missed, and it reopens XCUITest as a macOS driver:

```swift
// From the ROOT VIEW's .task — behind the demo flag.
NSApplication.shared.activate(ignoringOtherApps: true)
for window in NSApplication.shared.windows {
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}
```

The same calls that fail from the test process succeed from inside the app, on its own main thread, once a window exists. Timing is the trap: from `init` or `applicationDidFinishLaunching` there is no window yet, the calls are wasted, and you conclude — wrongly — that macOS forbids it.

Once the app is frontmost by its own doing, an ordinary XCUITest drives it: `typeKey` lands, menu shortcuts work, `waitForExistence` resolves, and you navigate in-session with one launch per appearance. Verified on macOS 26 / Xcode 26 against a SwiftUI app driving five screens by menu shortcut.

**Confirm rather than believe.** Capture two screens that should differ and hash them:

```bash
md5 -q Screenshots/source/*.png | sort | uniq -c | sort -rn | head
```

Duplicate hashes = the keystrokes went nowhere and you photographed one screen repeatedly. Distinct = focus is real.

If your app can't self-activate — or you'd rather not put demo-mode activation in it, or your screens are easier to *stage* than to navigate to — use the shell driver instead. It is not a consolation prize; it never touches the accessibility tree, so a redesign cannot break it. The trade table is in [SKILL.md](../SKILL.md#which-driver).

### The shell driver

`open` (LaunchServices) starts the app for real, so drive it from a shell script rather than a UI test:

1. Make every screen reachable **directly from a launch argument** (`-ScreenshotStage <name>`).
2. `open -gn MyApp.app --args -ScreenshotMode YES -ScreenshotStage settings -ScreenshotAppearance dark`
3. Resolve the window by **the PID you launched** — never the bundle id or app name, which happily return the developer's own running copy with their real data in it.
4. `screencapture -o -x -l <windowID> out.png`
5. Kill it, next screen.

`appshot capture` implements this. It also removes the test runner, its sandbox, and the `XCTAttachment` → `xcresult` extraction step — the PNGs land straight on disk.

`-g` is deliberate: it launches the app **without** activating it, and `appshot` fronts it later, immediately before the frame poll. Without `-g`, `open` yanks focus the moment it runs, so a second project's launch lands in the middle of the first one's shutter — which is why the machine-wide lock used to have to cover a whole run instead of a second per shot. Front the window yourself, once, when you are about to photograph it; an inactive window renders grey traffic lights and a dimmed toolbar, and that is not a shot you can ship.

### Telling appshot the screen is ready

The frame poll sees **stillness, not readiness**. An empty state, a skeleton row, and a pane whose async data has not arrived are all perfectly still — the poll will photograph one and call it settled, which is the entire reason `--settle` has a floor at all. Padding that floor defensively is a guess, and it stays a guess.

An app can say so instead. With `appshot capture --ready-file`, appshot passes a path and waits for the app to create it:

```swift
// At the moment the content this screen is being photographed for actually exists —
// after the data lands and the redraw is queued, not when the window appears.
if let path = UserDefaults.standard.string(forKey: "ScreenshotReadyFile") {
    FileManager.default.createFile(atPath: path, contents: nil)
}
```

That is the whole app-side change. The path is inside the app's sandbox container when it has one, so a sandboxed app can write it; the floor is then skipped entirely, and a signal that never arrives fails the run rather than silently reverting to the guess.

The price is that the app must open *directly* onto any screen, including ones normally behind a context menu. That's a `stage` enum plus a little view code that presents the right sheet on launch. It is the whole trick, and it's the part worth investing in.

`screencapture -o -x -l`:
- `-l` captures that window alone. SwiftUI sheets are drawn into the parent window, so they come along — which is what you want.
- `-o` omits the drop-shadow while **keeping the window's own rounded-corner alpha** (verify with `sips -g hasAlpha`).
- The cursor is not captured, but park it anyway (`appshot` warps it to the corner before every shot) — otherwise a hover highlight or tooltip is baked into the frame.

Screen Recording is needed by the **terminal running the script**, not by the app and not by a test runner.

## Pinning the window

Regardless of driver, pin the size in demo mode. Choose a size whose @2x backing is exactly your target asset resolution so the compositor never rescales.

A one-shot loop over `NSApplication.shared.windows` at startup is the obvious implementation and it is **not enough** — it only reaches windows that exist at that moment, so a Settings window opened later by `⌘,` captures at its own natural size. That is the classic "one screenshot in the set is mysteriously smaller" bug. Pin on window *appearance* instead:

```swift
@MainActor
enum DemoWindowPinner {
    static let contentSize = NSSize(width: 1280, height: 800)   // → 2560×1600 @2x

    static func start() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        // didBecomeKey, NOT didUpdate. didUpdate fires continuously, and ordering
        // a window front from inside it re-enters the notification until the app
        // dies by recursion.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { resize(w) }
        }
        NSApplication.shared.windows.forEach { resize($0); $0.orderFrontRegardless() }
    }

    static func resize(_ window: NSWindow) {
        // Sheets are NSWindows too. Forcing a main-window size on them wrecks
        // their layout — and they're captured on top of the parent anyway.
        guard !window.isSheet, window.styleMask.contains(.titled) else { return }
        guard window.contentRect(forFrameRect: window.frame).size != contentSize else { return }
        window.setContentSize(contentSize)
        window.center()
    }
}
```

`setContentSize` also defeats state restoration, which would otherwise reuse the developer's last window frame.

### AppKit cannot out-resize a SwiftUI clamp

`setContentSize` loses to SwiftUI's own sizing. A `Settings` scene is sized to its content, so the pinner takes the *height* and silently loses the *width* — you get a correctly-tall, wrongly-narrow capture and it looks like the pinner ran. Fix the frame in the view as well:

```swift
TabView { … }
    .frame(width: DemoSeed.isEnabled ? DemoWindowPinner.contentSize.width : 600)
    // The WINDOW is the content plus its chrome. A TabView's tab bar is ~88pt,
    // so a content height of `target` overshoots the window by that much.
    .frame(height: DemoSeed.isEnabled ? DemoWindowPinner.contentSize.height - 88 : nil)
```

Use a *fixed* height, not `minHeight` — a minimum lets the tallest tab's intrinsic content grow the window right back. Nothing enforces the chrome offset at compile time; the golden gate is what catches it, because the capture stops matching its dimensions.

### State restoration will ambush you after a crash

Launch with `-ApplePersistenceIgnoreState YES`. If the app ever crashes mid-run, macOS greets the *next* launch with a modal **"The last time you opened X, it unexpectedly quit while reopening windows. Reopen?"** alert. It sits on top of the app, the main window never appears, every query times out, and the capture falls back to a full-screen shot of the developer's desktop — a wrong image *and* a privacy leak. The flag suppresses it, and turns a one-off crash into a one-off crash instead of a poisoned run.

## Windows that aren't the main window

**Settings** (`⌘,`) is a separate window. Open it, click into the tab you want, retry the first click, then resolve the window by an element unique to that pane:

```swift
let settings = app.windows.containing(.staticText, identifier: "Endpoint").firstMatch
await save(settings.exists ? settings : app.windows.firstMatch, name: "settings", ...)
```

**Sheets** are child windows layered in front. They are captured automatically by the "include windows in front" rule above — you photograph the *parent* window and the sheet comes along, which is what you want (a sheet floating on nothing looks wrong).

Dismiss with Escape and give it time to animate out before the next capture.

## Reducing animation noise

Launch with `-NSAutomaticWindowAnimationsEnabled NO` to suppress window open/close animations. Sheet and view transitions inside SwiftUI still animate; wait on content, then `settle()` briefly.

## Keyboard navigation

Menu commands are the most reliable way to move between screens in-session, because they don't depend on hit-testing a moving target:

```swift
app.typeKey("n", modifierFlags: .command)                 // New / Add
app.typeKey("h", modifierFlags: [.command, .shift])       // Go Home
app.typeKey(.escape, modifierFlags: [])                   // dismiss sheet
app.typeKey("w", modifierFlags: .command)                 // close window
```

Having a "return to a known state" shortcut (Go Home) is what makes a single-launch, multi-screen route practical. If the app lacks one, adding it is usually easier than fighting the navigation.
