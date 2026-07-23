# iOS specifics

iOS is easier than macOS in one way (no window-server games — `XCUIScreenshot` is fine, there are no transparent corners) and harder in another: the **status bar** and the **device matrix**.

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

The **capture layer does not port at all**. `ScreenCaptureKit`, `CGWindowListCopyWindowInfo`, `NSWorkspace` PID scoping, and any `NSApplication` window pinning are AppKit. Wrap them in `#if os(macOS)` — including the pinning code inside the app, or the shared target stops building for iOS.

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
