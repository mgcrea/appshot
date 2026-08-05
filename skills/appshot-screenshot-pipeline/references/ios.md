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

## Three measured hazards

**The first run on a fresh simulator is an outlier.** iOS shows first-run system
banners on a newly created device; one measured run baked a "Ready for Apple
Intelligence" notification into a capture — 7.7% of the canvas. Runs 2 and 3 were then
byte-identical to each other. **Never accept goldens from the first run on a new
device.** Capture once, discard, then accept. Note this inverts the usual advice about
`simctl erase`: erasing returns the device to exactly the state that shows those banners.

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

**A simctl frame costs ~0.4s, against ~90ms for ScreenCaptureKit.** The poll, not the
settle floor, is what an iOS run spends — measured at 65% of a 3.6s/shot run. Read
`--timings` before reaching for `--settle`.

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

`erase` is the strongest determinism lever available and the one most pipelines skip. It removes the app's prior container, so no leftover onboarding state, no granted permissions, no stale defaults. It is slow; do it once per device per run, not per screen.

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
