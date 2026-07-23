# Flake catalog

Symptom → cause → fix. When a screenshot pipeline misbehaves intermittently, the cause is almost always in here. Each entry explains *why*, because the same root cause resurfaces in new disguises.

## Contents

- [Wrong window captured](#wrong-window-captured)
- [Opaque black or desktop-colored corners](#opaque-black-or-desktop-colored-corners)
- [A tooltip or hover highlight in the image](#a-tooltip-or-hover-highlight-in-the-image)
- [Element found, click does nothing](#element-found-click-does-nothing)
- [Ambiguous element match](#ambiguous-element-match)
- [Every query times out](#every-query-times-out)
- [Relaunching per screen hangs or hits a stale window](#relaunching-per-screen-hangs-or-hits-a-stale-window)
- [The gate fails on some runs and passes on others](#the-gate-fails-on-some-runs-and-passes-on-others)
- [Image differs run to run by a few pixels](#image-differs-run-to-run-by-a-few-pixels)
- [Dates drift](#dates-drift)
- [Window size changes between runs](#window-size-changes-between-runs)
- [The run is green but the images are last week's](#the-run-is-green-but-the-images-are-last-weeks)
- [A crash poisons every subsequent run](#a-crash-poisons-every-subsequent-run)
- [The app dies during a screenshot run, in the pinning code](#the-app-dies-during-a-screenshot-run-in-the-pinning-code)
- [One screenshot in the set is a different size](#one-screenshot-in-the-set-is-a-different-size)
- [Nothing written / no screenshots found](#nothing-written--no-screenshots-found)
- ["another capture run is in progress"](#another-capture-run-is-in-progress)
- [The goldens changed and nobody ran `accept`](#the-goldens-changed-and-nobody-ran-accept)
- ["the app never signalled ready"](#the-app-never-signalled-ready)
- [Passes locally, fails in CI](#passes-locally-fails-in-ci)
- [Breaks the moment you localize](#breaks-the-moment-you-localize)
- [Text looks soft in the final store asset](#text-looks-soft-in-the-final-store-asset)
- [A stray tab bar appears on some runs](#a-stray-tab-bar-appears-on-some-runs)
- [The capture is the bare sheet, not the app window](#the-capture-is-the-bare-sheet-not-the-app-window)
- [The *next* run fails with "timed out while enabling automation mode"](#the-next-run-fails-with-timed-out-while-enabling-automation-mode)
- [Paid features look locked (or unlocked) depending on the machine](#paid-features-look-locked-or-unlocked-depending-on-the-machine)
- [Extracted files have UUIDs in their names](#extracted-files-have-uuids-in-their-names)
- [The gate passes a capture that lost its transparency](#the-gate-passes-a-capture-that-lost-its-transparency)
- [Every golden is a 131-byte file named .png](#every-golden-is-a-131-byte-file-named-png)
- [An iOS golden drifts on every run after the first](#an-ios-golden-drifts-on-every-run-after-the-first)
- [An iPad golden drifts slowly, or fails only sometimes](#an-ipad-golden-drifts-slowly-or-fails-only-sometimes)
- [An iOS run is slow, and raising --settle makes it worse](#an-ios-run-is-slow-and-raising---settle-makes-it-worse)

---

## Wrong window captured

**Symptom.** The screenshot shows real data, a different window, or an app you weren't testing.

**Cause.** The capture selects windows by bundle identifier or process name. The developer's own copy of the app is already running with the same bundle id — a near-certainty, since they build and run it constantly.

**Fix.** Snapshot the set of running PIDs for that bundle id *before* `app.launch()`, then take the one that appears after. Scope every subsequent `CGWindowListCopyWindowInfo` lookup to that PID.

```swift
let preexisting = devPulsePIDs()
app.launch()
testAppPID = resolveTestAppPID(excluding: preexisting)   // poll; launch isn't instant
```

This also explains a puzzling variant: it works in CI (clean machine, one instance) and fails only on the developer's laptop.

---

## Opaque black or desktop-colored corners

**Symptom.** macOS window corners are square-ish, filled with black or whatever was behind the window, instead of transparent.

**Cause.** `XCUIScreenshot` composites what is on screen, including the pixels *behind* the window's rounded corners. There is no alpha.

**Fix.** Capture with ScreenCaptureKit and a transparent background — see [macos.md](macos.md). Build an `SCContentFilter` containing the target window **plus any window layered in front of it** (a sheet), but nothing behind it, so the base window's corners stay clear.

Hold the background `CGColor` in a stored property: `SCStreamConfiguration.backgroundColor` is `unowned(unsafe)` and will dangle if you pass a temporary.

Requires Screen Recording permission for the **test runner**, not the app. Preflight it and fail loudly in CI rather than silently falling back.

---

## A tooltip or hover highlight in the image

**Symptom.** A stray tooltip, or one row highlighted, in an otherwise clean shot.

**Cause.** The pointer keeps whatever position the last interaction left it in. If that lands on a row with a `.help` tooltip or a hover effect, it renders into the capture.

**Fix.** Park the cursor in an inert corner before every capture, then let the hover-out animation finish.

```swift
window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.99)).hover()
```

Pick a corner that is genuinely inert for *your* layout — the bottom-left of a sidebar may still be a row.

---

## Element found, click does nothing

**Symptom.** `element.exists` is true, `.click()` returns, and nothing happened. Usually on a freshly-opened window (Settings, a new sheet).

**Cause.** The first click on a window that has just become key is frequently swallowed while the window finishes taking focus.

**Fix.** Retry until the *consequence* of the click is observable. Never retry blindly on a fixed count without checking an outcome.

```swift
var rendered = false
for _ in 0..<3 {
    tab.click()
    if endpointLabel.waitForExistence(timeout: 5) { rendered = true; break }
}
XCTAssertTrue(rendered, "MCP pane never rendered")
```

---

## Ambiguous element match

**Symptom.** The test clicks the right label but the wrong thing happens, or matches shuffle when unrelated UI changes.

**Cause.** The same string appears in more than one pane. `app.staticTexts["Harbor"]` matches the sidebar row and the detail heading and a feed row.

**Fix, in order of preference.**
1. Give the element a stable `accessibilityIdentifier` and query that. Immune to layout *and* to localization.
2. Scope by container: `app.outlines.staticTexts["Harbor"]`, `app.tables.staticTexts[...]`.
3. Last resort: `.firstMatch` with a documented assumption about z-order.

SwiftUI's `List` maps to an outline *or* a table depending on style and platform, so a robust helper tries both and falls back:

```swift
firstExisting([app.outlines.staticTexts[label].firstMatch,
               app.tables.staticTexts[label].firstMatch], timeout: 5)
    ?? app.staticTexts[label].firstMatch
```

---

## Every query times out

**Symptom.** The first `waitForExistence` burns its full timeout and fails, even though the app is clearly on screen.

**Cause.** Under `xcodebuild test` the app launches *behind* the test runner. Its window is never key, and accessibility queries spin in a retry loop against a non-frontmost window.

**Fix.** Have the **app raise itself**. `app.activate()` from the test is unreliable; the same calls made from inside the app, on its own main thread, work:

```swift
// Root view's .task — behind the demo flag. NOT init / didFinishLaunching:
// before a window exists these calls do nothing, which is how people conclude
// macOS forbids it and reach for a shell driver they didn't need.
NSApplication.shared.activate(ignoringOtherApps: true)
for window in NSApplication.shared.windows {
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}
```

Who calls it is the whole thing: the test process cannot raise the app, the app can. Once it's frontmost, queries resolve and `typeKey` lands.

**If it still won't come forward**, the app can't self-activate for some reason of its own, and the shell driver is the right answer — see the next entry.

---

## macOS: the app never takes focus, and keystrokes go nowhere

**Symptom.** The UI test runs, the app launches and is visible, but it never comes to the front. Every `typeKey` appears to do nothing: menu shortcuts don't fire, navigation never advances, and the run ends having captured nothing (or the same screen N times).

**Cause.** Under `xcodebuild test` the app is launched by the test runner, and recent macOS will not let it become the active application. This is not a race you can win with more retries. All of these can silently fail to raise it:

- `XCUIApplication.activate()`
- `NSApplication.shared.activate(ignoringOtherApps: true)`
- `window.makeKeyAndOrderFront(nil)` / `window.orderFrontRegardless()`
- calling any of the above repeatedly, or from `.task` instead of an `NSViewRepresentable`

And `typeKey` delivers to whichever app is *frontmost* — so if the app never activates, keyboard-driven navigation is not merely flaky, it is inert. Worse, the keystrokes land somewhere else.

Before spending an afternoon on this, note it is **not app-specific**: if one of your apps can't take focus under `xcodebuild test`, the others won't either. Verify on a second app before assuming you've misconfigured the first.

**Fix — stop needing focus.** Launching through LaunchServices (`open`) *does* activate the app; that path isn't blocked. So don't navigate with keystrokes at all: make every screen reachable **directly from a launch argument**, and relaunch per screen.

```bash
open -n MyApp.app --args -ScreenshotMode YES -ScreenshotStage settings -ScreenshotAppearance dark
```

Then resolve the window by the PID you launched and capture it. `appshot capture` is a working driver.

This inverts one of the usual rules: relaunch-per-screen is normally the flaky choice ("Relaunching per screen hangs or hits a stale window", above). That warning assumes a working automation session. Here there isn't one — a few seconds per launch buys a driver that actually runs, and it removes the test runner, its sandbox, and the whole `XCTAttachment` → `xcresult` extraction dance along with it.

The cost is a real requirement on the app: it must be able to open *directly* onto any screen, including ones normally reached through a context menu or a multi-step flow. In practice that means a `stage` enum and a bit of view code that presents the right sheet on launch. That is the whole trick, and it is worth it.

---

## Relaunching per screen hangs or hits a stale window

**Symptom.** The first screen captures fine; later ones time out or photograph the *previous* screen — a shot arrives correctly named and containing the wrong thing.

**Cause.** Depends on the platform, and the two have opposite fixes. Read this before "fixing" a macOS driver into an iOS one.

**iOS / XCUITest.** Rapidly terminating and relaunching the same bundle under one automation session leaves the new window not reliably registered with that session. **Fix:** launch **once per appearance/locale** and navigate between screens in-session. Terminate only at the end of the pass.

This is a property of the **XCUITest automation session**, not of iOS. `appshot`'s staged iOS driver relaunches per screen through `simctl launch --terminate-running-process` with no automation session involved, and that is its normal, working mode — do not "fix" it into an in-session navigator on the strength of this entry.

**macOS / launch-arg driver.** Relaunching per screen is the whole design here, so it is not the bug. (If you chose this driver because you believed the app couldn't take focus, re-read the focus entry — it can, if it activates itself. But a *working* shell driver is a fine thing to keep.) The stale window comes from process bookkeeping instead, and there are two distinct bugs:

1. **The previous instance is still dying.** You `kill` it and move straight on, but SIGTERM is asynchronous. Its window is still on screen when the next screen launches. `pgrep` lists PIDs ascending, so the corpse is found *first* — and it is not in your "pre-existing" set either, so a driver that only snapshots pre-existing PIDs once, at startup, happily accepts it as "the app I just launched" and photographs it. This ships a correctly-named file containing the previous screen. It is not theoretical: it shipped a paywall shot named `help~light`.

   **Fix, both halves — one is not enough:**
   - Re-snapshot the running PIDs *immediately before each launch*, and take the PID that is not in that snapshot. Scoping against a startup-only snapshot does not exclude the corpse.
   - **Block until the previous instance is really gone** before launching the next. `wait` cannot do this — the app is a child of LaunchServices, not of your shell, so `wait` fails instantly. Poll `kill -0`, and escalate to `kill -9` if it ignores SIGTERM.

2. **The window frame leaks forward.** macOS state restoration reapplies the frame saved by the *previous* staged launch, and it wins the race against the app's own pinning. Harmless while every screen is the same size; the moment one differs, the next launch inherits it and a whole pass captures at the wrong size. **Fix:** `-ApplePersistenceIgnoreState YES` at launch *and* `window.isRestorable = false` before sizing.

---

## The gate fails on some runs and passes on others

**Symptom.** `appshot check` fails maybe one run in three, on the same screen or two, with no code change between runs. Re-run it and it goes green. Everyone learns to re-run it.

**First, get a rate.** Intermittency is the one failure mode you cannot debug from a single observation, and the instinct — stare at the one failing image — tells you nothing about whether your fix worked. Capture and gate the whole set N times and count:

```sh
for i in $(seq 1 6); do
  appshot capture --app "$APP" --out "/tmp/run-$i" --config "$CFG" \
    --screens $SCREENS --extra-args="$DEMO_ARGS" >/dev/null 2>&1
  appshot check --source "/tmp/run-$i" --golden "$GOLDEN" --config "$CFG" \
    >/dev/null 2>&1 && echo "run $i: PASS" || echo "run $i: FAIL"
done
```

Six runs distinguishes "always" from "sometimes". Twelve clean runs after a fix, against a rate that was one in three, is about a 1-in-125 coincidence — enough to believe it. Fewer than six proves very little, and one proves nothing at all: a 33% flake passes twice in a row nearly half the time.

**Then ask whether it is drift or a coin flip.** The failure percentage tells you, and this is the fastest branch in the whole diagnosis:

- **A percentage that varies run to run** — 0.14%, then 0.3%, then 0.11% — is *drift*. Anti-aliasing, a clock, an animation caught at different phases. Look at timing and tolerance.
- **The same percentage every time** — 0.727%, exactly, on every failure — is *bistable*. The app renders one of exactly two states and timing only selects which. `shasum` the failing captures from different runs to confirm: byte-identical files across runs are conclusive. No amount of settle will fix this, because neither state is unfinished. Look for something the app decides nondeterministically.

The distinction matters because the two point in opposite directions, and "the screenshot is flaky" pulls everyone toward the timing explanation by default.

**Read the magnitude too, not just the picture.** The amplified diff is bad at conveying scale — a lit-up sidebar and lit-up rows look much the same whether a colour changed or the whole layout moved — so let the number tell you which:

- **Well under 1%** is a *state* difference. Something small is drawn differently: a selection colour, a focus ring, a badge, a caret. The layout is intact.
- **Double digits** is a *structural* difference — content shifted, so everything below the shift disagrees with the golden even though it is pixel-perfect in itself. A stray tab bar pushing content down ~50px scores ~26%. So does a changed window size, an inserted banner, a collapsed sidebar.

To confirm a shift rather than a repaint, compare a thin band across the top of both images: identical means the difference starts lower down, different means the whole frame moved.

**Two screens failing does not mean one bug.** This is the trap the magnitude reading exists to catch. A run where one screen fails at 0.727% and another at 26% has *two unrelated flakes* — a bistable state and a layout shift — and fixing the first leaves the second firing at its own rate. Because both diffs are dominated by the same lit-up regions, the natural reading is "same bug, two screens", and then a fix that measurably works on one screen looks like it fixed everything. Check the percentages per screen before concluding you are chasing one thing, and measure the rate *per screen* when they differ.

**Common bistable causes**, in rough order of likelihood:

1. **Which view holds first responder.** A `List(selection:)` row draws in the accent colour while focused and grey when not; a focused text field shows a caret that blinks. Most apps never assign focus deliberately, so AppKit decides, and the driver's re-activation immediately before the shot is exactly the moment it decides. See *the first-responder trap* in SKILL.md — this is the one that keeps showing up, because nothing in an app's code looks wrong.
2. **A hover or selection state left by the pointer.** Park the cursor off the window.
3. **A race between two things that populate the same view** — a cached value painting before a fetched one, or two async loads finishing in either order.
4. **A collection rendered from an unordered source.** A `Set` or a dictionary iterated without a sort will hold its order within a process and change between them.

**Fix.** Make the app decide the same way every time, in demo mode, rather than making the capture wait longer. For focus specifically, clear first responder on every `NSWindow.didBecomeKeyNotification` — every time, not once at launch, since the driver re-activates before each shot — with one `DispatchQueue.main.async` hop so SwiftUI's own assignment doesn't immediately overwrite it:

```swift
// Demo mode only. Unfocused is the state the goldens already hold, and it keeps
// a blinking caret out of the captures as well.
window.makeFirstResponder(nil)
token = NotificationCenter.default.addObserver(
    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
) { [weak window] _ in
    DispatchQueue.main.async { window?.makeFirstResponder(nil) }
}
```

Then re-measure the rate. A fix you cannot show moving the number is a guess.

**Why the frame poll won't save you here.** Waiting for the window to hold still is the right default for half-drawn content, but both states of a bistable pair are perfectly still — the poll settles on either without complaint. Only the golden gate ever notices, which is precisely what it is for.

---

## Image differs run to run by a few pixels

**Symptom.** The golden check fails, but the images look identical.

**Cause.** Anti-aliasing, subpixel text positioning, shadow dithering, and animation easing all introduce tiny nondeterminism. Exact equality is not achievable.

**Fix.** Tolerate a small fraction of changed pixels (`appshot check --tolerance`, default 0.1%) rather than demanding zero. Note this tolerance cannot see a *categorical* change that is small in area — see the alpha trap in SKILL.md. Also reduce the noise at the source:

- Disable window animations for the run: launch with `-NSAutomaticWindowAnimationsEnabled NO`.
- Let async content (markdown, images, charts) finish rendering — wait on the content, then a short settle.
- Capture at a fixed backing scale; do not let the run migrate between a Retina and non-Retina display.

If a diff exceeds tolerance and the visual diff shows a real change, that's the gate doing its job — update the golden deliberately.

---

## Dates drift

**Symptom.** Screenshots said "2 days ago" in March; in September they say "6 months ago", or a "Recent" section is empty.

**Cause.** Absolute timestamps in the fixture.

**Fix.** Store offsets and resolve them against launch time.

```json
{ "version": "v2.13.0", "offsetDays": 2 }
```
```swift
let date = now.addingTimeInterval(-dto.offsetDays * 86_400)
```

Make `now` injectable so unit tests can pin it. The same reasoning applies to anything relative: unread counts, "new" badges, streaks.

**But check what the UI actually renders first — the fix above breaks the golden gate if it renders the date absolutely.** The advice assumes a *relative* label ("2 days ago"), which is stable no matter when you run. If the view formats the same timestamp as **an absolute date and time** ("Jul 10, 2026 at 17:47"), then an offset from `now` makes the rendered string change with the hour the capture happened to run, and the gate fails for whoever next runs it at a different time of day.

That flake is nasty out of proportion to its size: the drifting text is a few small glyphs, so it lands *near* the tolerance — some screens trip and others don't, on the same run. It reads like a real regression in one screen rather than a clock, and people go looking for a UI change that never happened. (Observed: one appearance of a screen failed at 0.194% while the other passed under 0.1%.)

Determine which you have, then:

- **Relative label** → offsets from launch, as above.
- **Absolute date/time** → the fixture cannot be both fresh and deterministic. Pick determinism: pin a fixed anchor and offset from *that*, so the rendered text is identical on every run. Bump the anchor when you refresh the store images.

```swift
// Not Date() — see above.
static let fixtureAnchor = Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 12, hour: 17, minute: 47)
)!
func daysAgo(_ days: Double) -> Date { fixtureAnchor.addingTimeInterval(-days * 86_400) }
```

A gate that cries wolf gets ignored, and then it protects nothing — which is why determinism beats freshness here.

---

## Window size changes between runs

**Symptom.** Captures differ in dimensions; the compositor letterboxes or crops.

**Cause.** The app restores its last-used window frame from `NSUserDefaults` / state restoration.

**Fix.** In demo mode, pin the content size explicitly and center the window. Choose a size whose `@2x` backing equals your target asset resolution (e.g. 1280×800 pt → 2560×1600 px), so the compositor never rescales.

```swift
for window in NSApplication.shared.windows {
    window.setContentSize(NSSize(width: 1280, height: 800))
    window.center()
}
```

This loop at startup fixes run-to-run drift but **not** the next entry — it only reaches windows that already exist.

---

## One screenshot in the set is a different size

**Symptom.** Nine captures are 2560×1600 and the tenth — nearly always Settings, or some other secondary window — is 1800×1496. The compositor scales it to fit, so it ships as a visibly smaller, differently-proportioned window than the rest of the set. Nothing errors.

**Cause.** Pinning ran once, at startup, over `NSApplication.shared.windows`. A window opened later by `⌘,` did not exist then and was never pinned, so it captured at whatever size it liked.

**Fix, in two layers — the first alone is not enough:**

1. **Pin on window appearance**, via `NSWindow.didBecomeKeyNotification`, not a one-shot startup loop. Skip `window.isSheet` — sheets are windows too, and forcing a main-window size on them wrecks their layout.
2. **Fix the SwiftUI frame as well.** `setContentSize` loses to SwiftUI's own content clamp: on a `Settings` scene it takes the height and silently drops the width, so you get a correctly-tall, wrongly-narrow window that *looks* like the pinner worked. And the window is the content **plus its chrome** — a `TabView`'s tab bar is ~88pt, so a content height equal to your target overshoots the window by that much. Use a fixed height of `target − 88`, not a `minHeight` (a minimum lets the tallest tab grow the window back).

Catch it with one command — an odd one out is this bug:

```bash
for f in Screenshots/source/*.png; do
  sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{printf "%s ", $2}'; echo "$f"
done | sort | uniq -c -w12
```

**The gate catches this in one direction only.** If the goldens hold the correct size, a later run that drifts fails with "the window is no longer pinned to a deterministic size". But if the wrong size was baselined — the usual case, because the bug is there from the first capture — it matches its own golden run after run, forever. That is why the `sips` sweep above is a review habit and not a fallback.

---

## Renamed screens leave ghosts

**Symptom.** `Screenshots/source/` contains `briefing~dark.png` long after the screen was renamed to `list`, and nobody can say whether it still ships.

**Cause.** The capture step copies new PNGs *into* the output directory without clearing it, and the runner's temp dir is never erased either. Deletions never propagate.

**Fix.** Wipe the output directory at the start of the capture step. If the compositor iterates a `screens[]` config it will ignore the orphan — but a compositor that globs the directory will happily ship it.

---

## The run is green but the images are last week's

**Symptom.** `** TEST SUCCEEDED **`, the extraction step reports screenshots copied, and everything downstream is happy — but the PNGs are unchanged from a previous run. A screen you deleted is still there; a screen you added is missing.

**Cause.** The test never ran, and nobody noticed, because **a run that executes zero tests still exits zero.** The extraction step then copies whatever was already sitting in the runner's output directory and calls it fresh.

The usual reason it executed nothing is the scheme. If the screenshot test is in the scheme's `<SkippedTests>` (or its testable is `skipped="YES"`), then `-only-testing:MyUITests/MyScreenshotTests` **cannot bring it back**. xcodebuild prints, with no hint of a problem:

```
Test Suite 'Selected tests' passed
	 Executed 0 tests, with 0 failures
** TEST SUCCEEDED **
```

**Fix, two halves:**

1. **Split by scheme, not by flag.** A `<SkippedTests>` entry in the default scheme keeps `⌘U` and `xcodebuild test` clean; a *dedicated* scheme containing only the screenshot class is what the capture target runs. The two settings do not compose, and no command-line flag escapes a scheme-level skip.
2. **Make an empty capture loud.** `rm -rf` the runner's output directory before the run, then assert files exist afterwards. An empty directory turns a silent stale copy into an error.

Grep any suspicious run for `Executed 0 tests` — it is the tell, and it's easy to miss in xcodebuild's noise.

---

## A crash poisons every subsequent run

**Symptom.** After one crashed run, later runs capture a full-screen image of the developer's desktop instead of the app — and queries time out with "the app is clearly running".

**Cause.** macOS state restoration. After an unclean exit it greets the *next* launch with a modal alert — **"The last time you opened X, it unexpectedly quit while reopening windows. Reopen?"** — which sits in front of the app. The main window never appears, `waitForExistence` burns its timeout, and a capture that falls back to `XCUIScreenshot` photographs the whole screen: your editor, your browser, your Slack.

**Fix.** Launch with `-ApplePersistenceIgnoreState YES` (and `window.isRestorable = false`). Clear an existing one with `rm -rf ~/Library/"Saved Application State"/<bundle-id>.savedState`.

Treat this as a correctness issue, not a cosmetic one: the fallback path publishes the developer's screen contents into an image the pipeline is about to composite and upload.

---

## The app dies during a screenshot run, in the pinning code

**Symptom.** `<app> crashed in <external symbol>` partway through, usually right after adding window-pinning.

**Cause.** The pinning observer is hooked to `NSWindow.didUpdateNotification`. That fires continuously, and calling `makeKeyAndOrderFront` / `orderFrontRegardless` from inside it re-enters the notification, which recurses until the stack blows.

**Fix.** Observe `NSWindow.didBecomeKeyNotification` instead — a window you care about always becomes key when it opens, so it's sufficient — and don't re-order the window from inside the handler (it's already frontmost; that's why the notification fired). Resize only.

Then clear the saved state it left behind, or the *next* run hits the entry above.

---

## Nothing written / no screenshots found

**Symptom.** The test passes, the extraction step finds no PNGs.

**Cause.** The UI-test runner is sandboxed. It cannot write into your repository. Writes to a repo path either fail or land somewhere unexpected.

**Fix.** Attach images to the test result (`XCTAttachment`, `lifetime = .keepAlways`) and export them with `appshot extract --xcresult`. If the pipeline instead writes to the runner's temp dir and scrapes `~/Library/Containers/*xctrunner*`, that works locally — but `xcresulttool` is the path that also survives CI.

A subtle one: if `xcodebuild` is given `-derivedDataPath`, the `.xcresult` lives under it, not in the default DerivedData. Locate the bundle rather than assuming.

---

## "another capture run is in progress"

**Symptom.** A capture exits immediately with `Error: another capture run is in progress (pid 10994)`. Nothing in this repo is running one.

**Cause.** The capture lock is machine-wide, not per project — and correctly so: there is exactly one active application per Mac, so two runs photographing at the same moment steal focus from each other and each captures the other's windows. The holder is usually a *different repository*, which is why the pid looks like nobody's.

**Fix.** Pass `--wait` and the run queues behind the other one instead of failing; `--wait-timeout` bounds it. On a current `appshot` the error already names the holder — app, pid, working directory, how long it has been going — so there is nothing left to work out with `ps`. If the message is a bare pid, the binary predates that and wants reinstalling.

Only the shutter is exclusive, so the two runs genuinely overlap: launching, waiting for the window and the settle floor all proceed concurrently, and `--timings` reports a `lock` phase so contention reads as contention rather than as a mysteriously slow poll.

If nothing at all is running, look for a lock left by a killed process: `/tmp/appshot-capture.lock/info.json` names its holder, and a lock whose pid is gone is cleared automatically on the next attempt.

---

## The goldens changed and nobody ran `accept`

**Symptom.** `git status` shows every golden modified — and sometimes a couple of new ones — with no `accept` in anyone's shell history. Reverting makes it go away, and you learn nothing.

**Cause.** Three things produce exactly this signature, and from the outside they are indistinguishable: an `appshot accept` from a second terminal (often another project's agent), a `git lfs pull`, or a branch switch. Only the first is a problem.

**Fix.** Seal the goldens: `appshot seal --golden Screenshots/golden`, and commit `manifest.json` with them. From then on `check` verifies a sha256 per golden before comparing anything, and the three cases separate cleanly — the manifest travels with the images, so a pull or a checkout still agrees with them, while an out-of-band write fails loudly and names each file, the time it changed, and the accept it disagrees with (user, host, pid, cwd, argv).

Two related guards come with it: `check` re-reads the golden directory at the end of its own run and withholds the verdict if it moved mid-comparison, and `accept` stages its copies before deleting anything, so a failure partway through can no longer destroy a baseline it has not replaced yet.

---

## "the app never signalled ready"

**Symptom.** A capture run with `--ready-file` fails with `the app never signalled ready within 8.0s`, naming a path nothing was written to.

**Cause.** One of two things, and the error cannot tell them apart: the app does not read `-ScreenshotReadyFile` yet, or that screen genuinely never finished loading.

**Fix.** Check the app side first — it is one line, and it belongs at the moment the content actually exists, not when the window appears:

```swift
if let path = UserDefaults.standard.string(forKey: "ScreenshotReadyFile") {
    FileManager.default.createFile(atPath: path, contents: nil)
}
```

If the app does write it, the screen is the problem: run without `--ready-file` and look at what gets captured, because a skeleton row or an empty state is what the signal is correctly refusing to call ready. Raising `--settle-max` only buys more waiting.

This fails rather than falling back to a fixed settle on purpose. Silently reverting to the guess would leave you with a capture whose readiness nobody checked, which is the state `--ready-file` was reached for to escape.

---

## Fails only when the developer is using the machine

**Symptom.** Intermittent failures on a laptop; the same commit passes on a quiet machine or overnight.

**Cause.** The run needs the keyboard and the frontmost window. A click, a `⌘Tab`, or a notification banner steals focus mid-run, so `typeKey` goes to the wrong app or a capture photographs a banner.

**Fix.** This is environmental, not a code bug — resist "fixing" it with longer sleeps. Move the run off the working desktop: a macOS VM, a second login session, or a dedicated runner (see the main skill's CI section). Until then, treat a failure that nobody can reproduce on an idle machine as noise, and say so rather than chasing it.

---

## Passes locally, fails in CI

Common causes, in the order worth checking:

1. **No GUI session.** XCUITest needs a window server. A plain SSH shell or a headless container cannot run it. Use a macOS VM, a second login session, or a dedicated runner.
2. **No Screen Recording permission** → silent fallback to opaque-corner capture. Preflight and gate on `STRICT_CAPTURE=1`.
3. **Only one app instance in CI** masks a PID-scoping bug that only bites locally (see the first entry — the polarity is inverted).
4. **Different display scale** → different image dimensions.
5. **Parallel testing** → two runs fighting for focus. Disable it: `-parallel-testing-enabled NO`.

---

## Breaks the moment you localize

**Symptom.** Adding a second language turns every query red.

**Cause.** Queries key off displayed text.

**Fix.** Set `accessibilityIdentifier` on everything the test touches. Identifiers are not localized and not user-visible, which is exactly what you want. Then drive the locale from launch arguments and loop:

```swift
app.launchArguments += ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
```

Name outputs `<screen>~<appearance>~<locale>.png`. Do this *before* you have twenty screens; retrofitting identifiers is tedious.

---

## Text looks soft in the final store asset

**Symptom.** The raw capture is crisp; the composited store image is slightly blurry.

**Cause.** The image was resampled twice — captured, scaled once, then scaled again during compositing. Or the raw capture was at 1x and upscaled.

**Fix.** Always composite from the original capture. Size the window so its `@2x` capture matches the target asset's pixel dimensions, so the compositor places it 1:1 with no resampling at all.

---

## The golden gate reports "not a PNG" for a file that is a valid PNG

**Symptom.** The regression gate throws on a capture that `file` and every image viewer agree is a perfectly good PNG. Or, worse, the gate never fires at all and you assume it's passing.

**Cause.** A stdlib-only gate (no Pillow) naturally shells out to macOS's `sips` to decode, and the obvious way to get bytes back is `sips -s format png in.png --out /dev/stdout`. That cannot work: `sips` renders to a temp file and **renames** it into place, and rename onto `/dev/stdout` fails. It then prints its error message *to stdout* — so the caller reads `Error: Cannot rename temporary file…` where it expected a PNG header, and reports "not a PNG".

**Fix.** Give `sips` a real file to write, then read it back:

```python
with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "n.png"
    r = subprocess.run(["sips", "-s", "format", "png", str(path), "--out", str(out)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0 or not out.exists():
        raise ValueError(f"{path}: sips could not decode it ({r.stderr.decode().strip()})")
    raw = out.read_bytes()
```

**Why it hides for so long.** `--update` only *copies* files — it never decodes anything. So a gate whose decoder is completely broken installs cleanly, blesses a baseline, and reports success. The decode path first runs on the first real comparison, which may be weeks later. After wiring up any gate, prove it both ways before trusting it: it must pass on unchanged captures **and** fail on a deliberately altered one. A gate that has only ever been observed passing has not been observed at all.

---

## A stray tab bar appears on some runs

**Symptom.** The same screen has a macOS tab bar across the top on one run and not the next. The golden gate flags it as a huge diff (30%+) between two runs with no code change — or, worse, it is *consistently* there and the gate never says anything, because it matches its own golden every time.

**Cause.** The system-wide "prefer tabs when opening documents" setting (`AppleWindowTabbingMode = always`, System Settings → Desktop & Dock). macOS attaches a tab bar to the window, and whether it wins the race with the app's own window setup is timing-dependent.

**Why it is nastier than it looks.** It is *the developer's machine configuration* leaking into the App Store listing. Every capture on a Mac with that preference is at risk, and nothing in the repo records it.

**Fix.** Pin it per launch, so the capture never depends on how the capturing Mac is configured:

```
-AppleWindowTabbingMode manual
```

`appshot` passes this on every launch. If you see a tab bar in an existing pipeline's goldens, that pipeline is not passing it.

---

## The capture is the bare sheet, not the app window

**Symptom.** Screens that present a sheet (a paywall, a confirm dialog, an import panel) come out as a floating dialog on a transparent background, at the sheet's own size — while the rest of the set is full-window. Or: three of your seven captures have a different pixel size from the other four.

**Cause.** The driver takes "the frontmost window". A sheet **is a window**, and it sits in front of its parent, so it wins.

**Why the shot is wrong.** The picture that screen is meant to show is the app window *with the sheet presented on it* — dimmed backdrop, the app visible behind, the sheet reading as a card. The bare sheet shows none of that context.

**Fix.** Build the capture around the **largest** normal window (layer 0, above a minimum size) and include everything in front of it. `appshot` does this. A stage that genuinely wants to photograph a secondary window should hide the main one (`window.orderOut(nil)`) so its window is the only candidate — which is a deliberate, visible choice rather than an accident of z-order.

Related: ScreenCaptureKit resolves a sheet's material properly, where `screencapture -l` can flatten it into the backdrop and lose the card entirely.

---

## The *next* run fails with "timed out while enabling automation mode"

**Symptom.** A UI test — possibly in a *different project* — suddenly refuses to start. `xcodebuild` reports `The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)`

**Cause.** A previous capture run **leaked an app instance**. If the driver fails before it has resolved the launched app's pid, a teardown deferred on that pid has nothing to kill, so the app keeps running — with its screenshot launch arguments, holding focus and automation state — and wedges `testmanagerd` for everything that comes after.

**Fix.** Two parts:

1. In the driver, kill anything **not in the pre-existing pid set** on the way out, however you leave — success, failure, or a failure so early there is no pid yet. `appshot` does.
2. To recover a wedged machine: `pkill -f MyApp` for the strays, then `sudo pkill -9 testmanagerd` (it is root-owned and launchd restarts it), or just log out and back in.

The lesson generalises: a screenshot driver launches processes it does not own, and *anything* it leaks becomes someone else's inexplicable bug later.

---

## Paid features look locked (or unlocked) depending on the machine

**Symptom.** The store screenshots look right on your laptop and wrong on a colleague's, or wrong in CI — padlock icons appear on toolbars and tabs, or a paywall doesn't appear where it should.

**Cause.** A demo flag you *don't pass* does not default to off. It falls back to **whatever is persisted in the capturing Mac's `UserDefaults`**. If you rely on `-isProUnlocked YES` but never actually pass it, the entitlement comes from ambient machine state — and it will look correct on any machine where you once unlocked the app.

**Why it hides.** It is invisible on the machine that has always taken the screenshots. It surfaces on the first clean machine — which may be the CI runner you set up months later, or nowhere at all until a reviewer asks why your listing shows padlocks.

**Fix.** Pass every flag the screens depend on, explicitly, in `DEMO_ARGS`. Then audit by grepping for who *passes* each key, not who reads it. A flag that is read but never passed is worse than no flag: the screen silently falls back to its default and looks plausible.

---

## Extracted files have UUIDs in their names

**Symptom.** After extracting from an `.xcresult`, the files are called `main~dark_0_8C756F5A-DC9C-44CF-84CB-908C5F65E2BC.png`, and the gate reports every screen as missing (or as a "new screen, no golden").

**Cause.** XCTest splices an occurrence index and a UUID into an attachment's stored filename, so the same name can be attached more than once. The attachment's **name** is what you set in the test, and it is the filename the rest of the pipeline keys on.

**Fix.** Strip the trailing `_<index>_<UUID>` and restore the name. `appshot extract` does.

**Worth noticing:** the *set* check is what caught this. A count check would have said "2 files extracted, fine".

---

## The gate passes a capture that lost its transparency

**Symptom.** Nothing. That is the problem. The compositor starts producing store images with opaque black or desktop-coloured window corners, and the golden gate reports a clean match.

**Cause — two of them, stacked.** First, many gates flatten RGBA over black before comparing, discarding alpha by design. Fix that and it *still* passes, which is the interesting part: the transparent corners are only **~0.056%** of a 2880×1800 capture, while the changed-pixel tolerance is **0.1%**. A **total** alpha wipe scores under tolerance. Measured against a real 14-image golden set, it passed on 12 of them.

**Fix.** Alpha loss is **categorical, not gradual drift**. It needs its own check, outside the fractional tolerance: if the golden has transparent pixels and the candidate has none, fail — and say why (the capture almost certainly fell back to an opaque-corner path). `appshot` does this, and `appshot selftest` proves it by wiping the alpha on a real golden and asserting the gate fails *for that reason*.

**The general lesson, which recurs:** when a property is binary and small in area, a fractional tolerance can never see it. Ask of any gate: *what change would this be structurally unable to detect?*


---

## Every golden is a 131-byte file named .png

**Symptom.** One of: the gate reports "could not decode golden.png"; the compositor fails
on a file that plainly exists; or — the dangerous one — **the gate passes every screenshot
without decoding a single image.**

**Cause.** The goldens are stored in Git LFS, and this clone has not run `git lfs pull`.
What you have are pointer files: 131 bytes of text, still named `.png`.

```
version https://git-lfs.github.com/spec/v1
oid sha256:a61a02d85c73ab0c1fd7ebcd00d590e8aab5277fed9ae0c8e373cf8ca4061f4a
size 421729
```

**Why it can pass the gate.** Every check that only asks *does the file exist* walks
straight past a pointer. And a gate with a hash fast path is worse than that: two pointers
for the same object are **byte-identical**, so the fast path short-circuits and calls it a
clean match. The gate then reports "✓ 16 screenshots match" having decoded none of them.

**Fix.** `git lfs pull`. And in the tooling, reject pointers *up front* — before the hash
comparison, not at decode time. `appshot` does, and names the cause.

**Recognise the shape.** This is the same failure as the alpha trap: a check that is
structurally unable to see the thing it is checking. When you add a fast path, ask what it
now makes invisible.

---

## An iOS golden drifts on every run after the first

**Symptom.** You capture, `accept`, and from then on `check` fails — often by a large,
*stable* margin (7.7% in the measured case). Re-capturing does not help. Two later runs
compared against each other are byte-identical.

**Cause.** The goldens were accepted from the **first run on a freshly created
simulator**, and that run is the outlier. A new device shows first-run system furniture:
in the measured case a "Ready for Apple Intelligence" notification banner sat across the
top of the capture and `accept` blessed it as the baseline. Everything afterwards
correctly disagrees with it.

**Fix.** Discard the first run on a new device, then capture and accept. If the banner is
already in your baseline, delete the goldens for that device and re-accept from a warm
run.

**The trap inside the fix:** `--erase` (and `simctl erase`) returns the device to exactly
the state that shows those banners, so "erase every run for determinism" *reintroduces*
this. Erase to reset a polluted device, not as routine hygiene. There is no simctl switch
that disables system notifications — `simctl ui` has no focus or do-not-disturb option —
so this is a discipline, not a setting.

**Note what saved you:** the golden gate. A 7.7% failure is it working. But it can only
catch this once a good golden exists, which is precisely what the first run does not
produce.

---

## An iPad golden drifts slowly, or fails only sometimes

**Symptom.** iPad captures gate more tightly than iPhone ones and eventually fail for no
reason anyone changed. The diff is a thin bright band across the top-left.

**Cause.** The iPad status bar shows a **live date** — "Thu Jul 23" — and
`simctl status_bar --time` cannot pin it. It sets the clock only, and the date is present
inside real apps, not just SpringBoard.

Do not reach for the ISO form to fix this. It is accepted only with fractional seconds
(`2026-01-09T09:41:00.000Z`), it shifts the rendered clock by the **host timezone** — so
two machines produce different goldens — and it *still* leaves the date live.

**Why it is worse than a plain failure.** Measured on an iPad Pro 13", a date change moves
**0.0484%** of the canvas, against a 0.1% tolerance. So it does not fail; it silently
spends half the drift budget every day, and tips over only when combined with a real
change.

**Fix.** Give that device an ignore rect over the status bar:

```jsonc
{ "id": "ipad", "ignore": [{ "x": 0, "y": 0, "width": 600, "height": 70 }] }
```

`check` then reports how many pixels it excluded, every run — an ignore list is the one
setting that makes the gate weaker, so it is never silent.

---

## An iOS run is slow, and raising --settle makes it worse

**Symptom.** Each shot costs seconds and `--timings` shows a large `poll` share.

**Cause.** A `simctl io screenshot` frame costs **~0.4s**, against ~90ms for
ScreenCaptureKit on macOS. The quiescence poll needs at least three frames, so the *frame
cost*, not the settle floor, is what an iOS run spends — measured at 65% of a 3.57s/shot
run.

**Fix.** Nothing to tune with `--settle`; lowering it saves the floor only, and raising it
adds to an already-dominant poll. Read the frame count in `--timings` first: if it is at
the minimum, the floor is the whole cost and can come down. `appshot` prints this
conclusion itself rather than making you derive it.
