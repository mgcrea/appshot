# iOS specifics

**`appshot` drives iOS itself.** Set `"platform": "ios"` in the config, declare a
`devices[]` entry per store canvas, and `appshot capture` boots a simulator, stages each
screen by launch argument and photographs it — the same staged-relaunch model as macOS,
sharing the same settle engine, gate and compositor. You do not need an XCUITest for
screens reachable from a cold launch, and you do not need fastlane.

```jsonc
{
  "platform": "ios",
  "devices": [
    { "id": "iphone", "simulator": "iPhone 17 Pro Max",
      "output": { "width": 1320, "height": 2868 } },
    { "id": "ipad", "simulator": "iPad Pro 13-inch (M5)",
      "output": { "width": 2064, "height": 2752 }, "screens": ["home"] }
  ]
}
```

The device is a **directory level** — `source/iphone/home~dark.png` — never a third `~`
field, so everything downstream keys off `<id>~<appearance>` exactly as it does on Mac.

The driver already pins what follows: the status bar (9:41, full bars, charged), the
appearance via `simctl ui`, Dynamic Type, and it captures with `--mask=alpha` so the
capture carries the device's real rounded corners. The rest of this file is what you
still need to know — including three hazards that are measured, not folklore.

`appshot extract` remains the route for screens only reachable by in-session navigation.

## Four measured hazards

**The first run on a fresh simulator is an outlier.** iOS shows first-run system
banners on a newly created device; one measured run baked a "Ready for Apple
Intelligence" notification into a capture — 7.7% of the canvas. Runs 2 and 3 were then
byte-identical to each other. **Never accept goldens from the first run on a new
device.** Capture once, discard, then accept.

This inverts the usual advice about `simctl erase`, and the conclusion is stronger than
it first looks: erasing returns the device to *exactly* the state that shows those
banners, so **`--erase` must not live in your default capture target.** Putting it there
does not buy determinism every run, it reproduces the first run every run — and the
banner lands on whichever screens happen to fall inside its window, which moves. A
permanent `--erase` is a permanently flaky gate. Make it an opt-in variable
(`make screenshots-ios-capture IOS_ERASE=--erase`), use it when device state is suspect
or the devices are new, and **throw that run away**.

**The iPad status bar carries a live date that cannot be pinned.** `--time` sets the
clock, not the date, and the date is present inside real apps — not just SpringBoard.
The ISO form is worse: it only parses with fractional seconds
(`2026-01-09T09:41:00.000Z`), shifts the clock by the *host* timezone so goldens differ
per machine, and still leaves the date live. At 0.0484% of an iPad canvas a date change
sits **under** the 0.1% tolerance — so it never fails outright; it spends half the drift
budget every day. Give that device an `ignore` rect over the status bar:

```jsonc
{ "id": "ipad", "ignore": [{ "x": 0, "y": 0, "width": 600, "height": 70 }] }
```

Keep that rect **tight**, and check it rather than eyeballing it: `check` prints the
ignored area as a fraction of the canvas on every run. A rect blind to 1% of the picture
to hide a change measured at 0.05% is twenty times the drift budget you are protecting,
and everything inside it — a real regression included — is invisible for good. Read the
number the gate reports back; if it is much larger than the thing being masked, shrink it.

**A simctl frame costs ~0.4s, against ~90ms for ScreenCaptureKit.** The poll, not the
settle floor, is what an iOS run spends — measured at 65% of a 3.6s/shot run. Read
`--timings` before reaching for `--settle`.

**The picture can be the home screen, and before 0.16.1 the run still succeeded.** A
simulator's display always shows *something*, so the driver's only evidence the app is
up is that the screen changed. When the previous screen's app is still animating out,
the frame taken "before launch" is that outgoing app, and SpringBoard appearing a moment
later is a change: the app counted as appeared, the frame poll settled on the home screen,
and the capture exited 0. Measured on an iPad run: `notebook~light` was the springboard,
with the developer's own installed apps in the picture. The gate rejects it (99.8% drift),
but only a gate against real goldens does, and a first run, or an `accept` right after,
has nothing to reject it with.

0.16.1 records the home screen once per device and appearance, with the app terminated,
and a shot that still matches it at the shutter fails with `app_left_the_screen` instead
of writing a file. On an older binary, look at every iOS capture before an `accept`,
because the home screen is still, correctly sized and plausible. If `app_left_the_screen`
recurs on one screen, the app is crashing or exiting there: read the device log, don't
raise a timeout.

## When the simulator cannot render the app: `"hardware"`

A Metal 4 renderer compiles to nothing in the iOS Simulator (its SDK ships the MTL4
headers as stubs), so an app like that shows a placeholder on every simulator capture,
and a pipeline built on simctl produces a full, correctly sized set of placeholders.
**Check this before building an iOS pipeline:** grep the app for
`targetEnvironment(simulator)` and launch one staged screen on a simulator by hand.
The tell in a run is the ready file never arriving, which is one more reason to keep
`--ready-file` on: without it, placeholder screens that differ only by a toolbar label
pass the duplicate check.

The fix is a connected device in place of the simulator, one per `devices[]` entry:

```jsonc
{ "id": "iphone", "hardware": "Olivier's iPhone",
  "output": { "width": 1320, "height": 2868 } }
```

`--app` becomes the signed `Debug-iphoneos` build. A config that mixes simulator and
hardware entries needs one run per build (`--device`). The app owes four things a
simulator would have pinned from outside, all keyed on `-ScreenshotTarget hardware`
behind the demo flag:

- **Hide the status bar.** Its clock and battery are live and cannot be overridden.
- **Apply `-ScreenshotAppearance` itself**, with `.preferredColorScheme` on the root
  view or `overrideUserInterfaceStyle`. There is no `simctl ui` for a device. A run
  whose light and dark captures of a screen match fails, because otherwise every dark
  golden is a light one under the wrong name.
- **Expand the tilde in `-ScreenshotReadyFile`.** devicectl never reports the
  container's absolute path, so appshot passes `~/tmp/appshot-ready-<uuid>`.
  `(path as NSString).expandingTildeInPath` leaves the Mac and simulator drivers'
  absolute paths alone, so one line serves all three.
- **Lock the orientation**, or hold the device the canvas's way up. A frame follows how
  the device is physically held (a phone flat on a desk is landscape) and a mismatch
  fails the shot rather than being rotated.

And the device must be unlocked and awake, with **nothing live in the Dynamic Island**.
appshot takes two frames before the first shot and refuses to start if the island's
span moves. It looks nowhere else: an untouched Home Screen changed over its icon grid
between two frames, and its clock ticked over between two others, and neither is ever in
a capture. The measured case was
music playing: the Dynamic Island's waveform moved 0.017% of the screen, just over the
stillness tolerance, so the poll ran 25 frames and settled on a lucky one with the
waveform baked in. It is the first-run-banner hazard's cousin: ambient device state,
not the app, and a gate cannot tell them apart.

Costs, measured on an iPhone 17 Pro Max: ~0.8s a frame, ~0.5s from launch to the ready
signal through devicectl, ~7s a shot. Two runs came back byte-identical on 5 shots of 6.
Do not poll the ready file through DeviceFS (CoreDevice's mount of the containers under
~/Library/Developer/CoreDevice/DeviceFS): it serves a cached view, and a marker never
appeared there within 8s, six shots out of six.

The app locks the orientation itself for a phone canvas. The Filiation fix was an
`UIApplicationDelegate` returning `.portrait` from `supportedInterfaceOrientationsFor`
under the demo flag. That method **replaces** Info.plist's list rather than narrowing it,
so outside a capture it must return exactly the plist's orientations. Frames are opaque (the compositor rounds them) and 16-bit (written
at 8). A run takes the phone over the way a focused Mac run takes the Mac, so say so
before starting one.

## Under the hood

Two facts worth knowing if you are debugging the driver:

- `simctl boot` returns in ~0.7s but the device is not installable for ~29s. `bootstatus
  -b` is what turns that race into a wait.
- `simctl io … screenshot -` **does not write to stdout** despite `--help` saying so — it
  creates a file named `-`. Frames go through a temp file.

iOS is easier than macOS in one way (no window-server games, no focus fight) and harder
in another: the **status bar** and the **device matrix**.

## The status bar is the whole game

Apple's own marketing uses 9:41, full signal, full battery. A real simulator shows the host clock, a partial battery, and possibly a carrier string — and the clock changes between captures, which alone defeats a golden-image check.

Override it before launching, per booted device:

```bash
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
```

Clear it afterward with `xcrun simctl status_bar "$UDID" clear`.

The override persists for the boot session, so apply it after `simctl boot` and before the test runs. It is silently ignored on a device that is not booted.

## Determinism knobs

```bash
xcrun simctl erase "$UDID"                        # blank slate: no prior state, no permissions
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b                # wait until actually ready
xcrun simctl ui "$UDID" appearance dark           # or light
xcrun simctl ui "$UDID" content_size medium       # pin Dynamic Type
```

`erase` is the strongest determinism lever available: it removes the app's prior container, so no leftover onboarding state, no granted permissions, no stale defaults, and it clears the simulator's own slow-animations setting. When you run it, run it once per device, not per screen.

**But do not run it every time** — see the first-run hazard above, which is the reason most pipelines are right to skip it. It is a repair tool, not a default. Its usual justification is weaker than it sounds under `appshot` anyway: the driver captures into its own devices (`appshot-iphone`, `appshot-ipad`) rather than any simulator you use by hand, so the only state accumulating between runs is your app's.

`bootstatus -b` matters because `boot` returns before the device can accept an install. Without it you get intermittent "Unable to launch" failures that look like flakes but are a race.

## Device matrix

Drive the same test across devices rather than writing per-device tests:

```bash
for DEVICE in "iPhone 17 Pro Max" "iPhone 17" "iPad Pro 13-inch (M4)"; do
  xcodebuild test \
    -scheme MyApp \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -only-testing:MyAppUITests/ScreenshotTests
done
```

The App Store derives most sizes from the largest iPhone and largest iPad, so two devices usually suffice — see [appstore.md](appstore.md). Capturing every device is a waste of minutes.

Name outputs with the device so the compositor can route them: `<screen>~<appearance>~<device>.png`.

## Appearance, without simctl

If you'd rather not shell out per device, override in-app from the same demo launch argument you already use, or set the trait at the window level. Driving it through `simctl ui` has the advantage of also affecting system UI (the keyboard, share sheets) — which does show up in screenshots.

## Capturing

```swift
let shot = XCUIScreen.main.screenshot()        // whole screen, includes status bar
let attachment = XCTAttachment(screenshot: shot)
attachment.name = "\(screen)~\(appearance)~\(device)"
attachment.lifetime = .keepAlways
add(attachment)
```

Prefer `XCUIScreen.main.screenshot()` over `app.screenshot()` when you want the (overridden) status bar in frame, which the store expects. Use `app.windows.firstMatch.screenshot()` if you specifically want to exclude it.

There is no ScreenCaptureKit here and none is needed — the simulator renders opaquely and the device frame is added later by the compositor.

That opacity has a consequence worth planning for. A compositor written for macOS probably rounds only the *shadow*, because a macOS capture already carries its own rounded alpha. An iOS capture is a hard rectangle, so the same code yields a square screenshot on a rounded shadow. On the iOS path, mask the image or use a bezel frame — see [appstore.md](appstore.md).

## Porting a macOS pipeline to iOS

The **fixture layer ports unchanged**: the demo flag, the in-memory store, the bundled JSON, relative `offsetDays`, and the entitlement override are all platform-neutral. Share them.

So does the **launch-argument contract**. `simctl launch` passes everything after the bundle id as argv, which lands in `NSArgumentDomain` exactly as `open --args` does — so `-ScreenshotMode`, `-ScreenshotStage` and `-ScreenshotAppearance` work on iOS with no new code.

The **capture layer does not port at all**, but `appshot` owns that half now: `ScreenCaptureKit`, `CGWindowListCopyWindowInfo`, `NSWorkspace` PID scoping and window pinning are all inside the tool. In *your app*, wrap any `NSApplication` window-pinning or self-activation code in `#if os(macOS)`, or the shared target stops building for iOS. iOS needs neither: there is no window to pin (the screen is the frame) and no focus to win.

The **navigation route does not port either**. A macOS route leans on menu shortcuts (`⌘N`, `⌘,`) and a separate Settings *window*; an iPhone has a tab bar and a nav stack. Expect to write a second route. This is the strongest argument for putting `accessibilityIdentifier`s on everything first: the identifiers are the only part of the two tests that can be shared.

Finally, the screen *set* usually differs — a desktop-only feature has no iPhone screenshot — so `screens[]` needs a per-platform list rather than one shared array.

### What a staged Mac pipeline gets wrong on iOS

The staging itself ports — the launch-argument contract is identical — but *what the app
does with it* is not, and the four below all fail the same way: a valid, correctly sized,
good-looking capture of the wrong thing. Every one of them was found by the duplicate
check (`capture --config`), not by looking.

**A screen the Mac reaches for free may need a navigation push.** On macOS a
three-column `NavigationSplitView` shows the detail column for every stage, so selecting
a row is something the app does once at launch and no stage has to ask for. On a
compact layout that same selection **is** the push — which is why apps deliberately
suppress it (auto-selecting would re-navigate on every back swipe). The screens that
live *inside* the detail column then never open, and the stages that were supposed to
reach them all photograph the list instead, identically.

**`horizontalSizeClass` is not a device check inside a split view.** It reports the
enclosing *column's* width, so it reads `.compact` in a sidebar or content column on a
13" iPad. Any staging guarded on `horizontalSizeClass == .regular` therefore stages an
iPad as a phone, and the symptom is an iPad set that fails exactly like the iPhone set
for a completely different reason. Ask `UIDevice.current.userInterfaceIdiom` when you
mean the device.

**On iPad the sheet is right and the backdrop is wrong.** This is the inverse of the
macOS *sheet trap*: there you photograph the bare sheet and lose the window; here the
split view keeps its columns on screen, so whatever is behind the sheet is *in the
picture* — dimmed, but perfectly legible. A Mac pipeline never sees this because its
auto-select fills the detail column unconditionally. One measured run shipped eight iPad
shots over a "No Bucket Selected" empty state. **Stage the backdrop, not just the sheet.**

**A preselection that fills a pane on macOS may present a sheet on iOS.** The same
`selection = [key]` that populates a side-by-side preview pane on the Mac drives a modal
preview on a phone — which then covers the screen the stage was actually for. Preselect
per stage on iOS, not unconditionally.

The pattern under all four: **macOS stages by setting state in a layout where everything
is already visible; iOS stages by navigating.** Assume every Mac stage that "just worked"
needs to be asked for again, and let the duplicate check tell you which.

## fastlane snapshot

Many iOS teams already use `fastlane snapshot`. It handles the device matrix, locales, and status bar for you, and writes into `screenshots/`.

If a project already has a `Snapfile`, **align with it rather than replacing it**. The invariants in the main skill still apply — snapshot does not give you determinism (you still need seeded fixtures and relative dates), does not give you a regression gate, and its `setupSnapshot(app)` still requires you to pass your own demo launch arguments.

Where snapshot fits:

```swift
override func setUp() {
    let app = XCUIApplication()
    setupSnapshot(app)
    app.launchArguments += ["-AppDemoMode", "YES"]
    app.launch()
}
// ...
snapshot("01-home")
```

Keep the golden-image gate (`appshot check`, and `appshot selftest` to prove it works) on top of snapshot's output; it is orthogonal and snapshot has no equivalent.

## Simulator gotchas

- **Keyboard.** The software keyboard may or may not appear depending on whether a hardware keyboard is "connected". It changes layout. Toggle it deterministically (`Hardware ▸ Keyboard ▸ Connect Hardware Keyboard` maps to `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`).
- **First launch permission dialogs** (notifications, tracking) will sit in front of your screenshot. Either pre-grant with `simctl privacy`, or stub the request behind the demo flag.
- **Scroll position** is not restored deterministically after `erase`; scroll explicitly to the top before capturing a list.
- **Slow animations** (`⌘T` in the simulator) is a per-simulator UI setting that persists and will wreck timing. `erase` clears it.
