# appshot

[![CI](https://github.com/mgcrea/appshot/actions/workflows/ci.yml/badge.svg)](https://github.com/mgcrea/appshot/actions/workflows/ci.yml)

App Store screenshot pipeline for Mac apps: capture, gate, compose.

`appshot` launches your app once per screen, photographs the window with its
transparency intact, fails the build if the result drifted from an accepted
baseline, and frames the captures into App Store visuals and marketing-site
images.

## Why

This replaces a JavaScript/librsvg pipeline that *guessed* at text. It estimated
advances with `approxCharWidth = fontSize * 0.52`, so captions wrapped in the
wrong place, and when a font was not installed the renderer silently substituted
another one — the composite looked fine until it was next to the real thing.

CoreText knows real glyph advances, and more importantly it can be made to
*refuse* an uninstalled font instead of substituting. `Text.font` throws
`fontNotResolved` rather than quietly rendering the wrong typeface.

Three shipping apps drive it: **swift-d1**, **swift-r2** and **silhouette**. All
three run identical code from `source/<id>~<appearance>.png` onwards.

## Requirements

- **macOS 14+** — the real floor is `SCScreenshotManager.captureImage`.
- **Swift 6.0 toolchain**.
- **Xcode** only if you use `appshot extract`, which shells out to
  `xcrun xcresulttool`.

## Install

### From a release

Each tagged release carries a universal (arm64 + x86_64) binary:

```sh
VERSION=v0.1.0
curl -fsSL -O "https://github.com/mgcrea/appshot/releases/download/$VERSION/appshot-$VERSION-macos-universal.tar.gz"
curl -fsSL -O "https://github.com/mgcrea/appshot/releases/download/$VERSION/appshot-$VERSION-macos-universal.tar.gz.sha256"
shasum -c "appshot-$VERSION-macos-universal.tar.gz.sha256"

tar -xzf "appshot-$VERSION-macos-universal.tar.gz"
# The binary is ad-hoc signed, not notarized, so Gatekeeper quarantines it on
# download. Clear the flag, or macOS refuses to run it.
xattr -d com.apple.quarantine "appshot-$VERSION-macos-universal/appshot"
install -m 0755 "appshot-$VERSION-macos-universal/appshot" ~/.local/bin/appshot
```

### From source

```sh
make install          # builds release, installs into $PREFIX/bin (PREFIX ?= ~/.local)
make uninstall
```

Or by hand:

```sh
swift build -c release
cp .build/release/appshot /usr/local/bin/
```

Building from source sidesteps the quarantine step entirely, which is why it
stays the primary path for the projects that drive this.

## Screen Recording permission

`appshot capture` will not work without it, and the failure is quiet rather than
loud: captures come back without their transparent rounded corners.

Grant it to **the terminal running `appshot`** — System Settings → Privacy &
Security → Screen Recording. Nothing is granted to the app being captured. If
you run captures from an IDE's integrated terminal, that IDE is the thing that
needs the permission.

`appshot doctor` checks this, along with the other things that fail silently
(missing font, invalid config, wrong output size).

One more thing worth knowing before you start a run: **capture takes over the
pointer and the active app** at the moment of each shot. Don't use the machine
while it runs — a stray click lands in a screenshot. Two projects can run at once
(only the shutter is exclusive), but they still take turns with the screen.

## The pipeline

**Capture** relaunches your app once per screen, staged onto that screen by a
launch argument, and photographs its window into `<id>~<appearance>.png`. The
window is matched strictly by pid — never by name, which would happily return
the developer's own running copy of the app, with their real data in it. That is
the single most common way a private bucket name ends up in a store screenshot.

**Gate** diffs the captures against goldens you have accepted. Beyond pixel
drift it catches two failures the diff alone cannot: *duplicates*, which are the
tell that a staging argument did nothing, and *missing screens*, which only the
config knows should have existed.

**Compose** frames the captures onto gradient backgrounds with real typeset
captions for the App Store, and emits bare, downscaled captures for the
marketing site.

## Quick start

```sh
# 1. Capture. --config checks --screens against the config's screens[].id BEFORE
#    launching anything, so a typo costs a second instead of 90 seconds.
#
#    --extra-args needs the `=`: the value starts with `-`, and without the `=`
#    ArgumentParser reads it as appshot's own flags.
#
#    A screen is name[:stage[:settle]]. `export::6` stages as `export` (empty
#    middle) but waits at least 6s, for data that lands later than the floor.
appshot capture \
  --app "build/MyApp.app" \
  --out "screenshots/source" \
  --config "screenshots/screenshots.config.json" \
  --screens main models export::6 \
  --appearances light dark \
  --extra-args="-ScreenshotMode YES -isProUnlocked YES" \
  --settle 0.3

# 2. Gate against the accepted baseline.
appshot check \
  --source screenshots/source \
  --golden screenshots/golden \
  --config screenshots/screenshots.config.json

# 3. Compose both sets.
appshot compose both \
  --config screenshots/screenshots.config.json \
  --source screenshots/source \
  --out screenshots/appstore \
  --website-out ../site/src/assets/screenshots \
  --appearance light
```

Or the whole chain in one command:

```sh
appshot run --app build/MyApp.app --screens main models export \
  --extra-args="-ScreenshotMode YES"
```

Note that `run` stops at a failed gate — composing after a failed gate would
ship the very drift the gate just caught.

## Commands

| Command | What it does | Key options |
| --- | --- | --- |
| `run` | The whole chain: capture → gate → compose. | `--app`, `--screens`, `--extra-args`, `--settle`, `--settle-max`, `--wait`, `--ready-file`, `--appstore-out`, `--website-out`, `--tolerance`, `--appearance`, `--max-width` |
| `capture` | Launch the app staged onto each screen and photograph its window. | `--app`, `--out`, `--screens`, `--appearances`, `--extra-args`, `--settle`, `--settle-max`, `--wait`, `--ready-file`, `--config` |
| `extract` | Export screenshot attachments from an `.xcresult` bundle. | `--xcresult`, `--out`, `--config` |
| `check` | Fail if the captures drifted from the goldens. | `--source`, `--golden`, `--diff`, `--tolerance`, `--config`, `--json`, `--require-manifest` |
| `accept` | Accept the current captures as the new goldens. | `--source`, `--golden`, `--prune` |
| `seal` | Record what the goldens are, so a later change to them is visible. | `--golden` |
| `selftest` | Prove the golden gate actually fails when it should. | `--golden` |
| `compose appstore` | Compose framed + captioned App Store visuals. | `--config`, `--source`, `--out` |
| `compose website` | Emit bare app captures for the marketing site. | `--config`, `--source`, `--out`, `--appearance`, `--max-width` |
| `compose both` | Compose the App Store set, and the website set if `--website-out` is given. | all of the above |
| `doctor` | Check the things that fail silently: font, permission, config. | `--config` |

`extract` exists for projects whose captures come from an XCUITest rather than
the staged shell driver: the test runner is sandboxed out of the repo, so each
capture travels as an `XCTAttachment` named `<screen>~<appearance>.png`.

## The golden-gate workflow

`check` compares against goldens under version control. When it fails, the
question is always **drift or regression** — did the UI legitimately change, or
did something break?

```sh
appshot check --source screenshots/source --golden screenshots/golden \
  --config screenshots/screenshots.config.json   # writes diffs on failure
open screenshots/diff                            # look at them
appshot accept --source screenshots/source --golden screenshots/golden
```

Accept deliberately, never reflexively. Two rules the tool enforces for you:

- **`accept` refuses when a golden has no candidate.** The capture may have
  stopped early, and silently dropping that golden would erase a screen from
  your baseline. Pass `--prune` only when the screen was removed on purpose.
- **A duplicate report is a staging failure, not a visual change.** Two
  near-identical captures mean a stage argument did nothing. Accepting it buries
  a broken capture in the baseline, so `check` says so explicitly before it
  offers `accept`.

`selftest` synthesizes mutants and proves the gate rejects them — so a green
`check` means something rather than merely being green:

```sh
appshot selftest --golden screenshots/golden
```

### Sealed goldens

`accept` writes `golden/manifest.json`: the sha256 of every golden it installed,
plus who accepted them, from where, and with what arguments. `check` verifies it
before comparing anything, and refuses to compare against a baseline that no
longer matches.

Commit it alongside the goldens. That is what makes the distinction work:

| What happened | What `check` does |
| --- | --- |
| `git lfs pull`, branch switch, fresh clone | Nothing. The manifest travels with the goldens, so their contents still agree. |
| An `accept` in another terminal | The manifest is rewritten too, and names the run that did it — pid, cwd, argv. |
| Anything else that edited the bytes | Hard failure, naming each file and when it changed. |

Goldens that predate the manifest keep working; `check` warns once and carries on.
Adopt them with one command, and use `--require-manifest` in CI to make an unsealed
baseline fatal:

```sh
appshot seal --golden screenshots/golden
appshot check --source screenshots/source --golden screenshots/golden --require-manifest
```

`check` also snapshots the golden directory at the start of the comparison and
re-reads it at the end. A `check` racing an `accept` in another terminal is
describing a directory that no longer exists, so it withholds the verdict instead
of reporting one that is right about as often as not.

### Driving the gate from a script

`check --json` reports the verdict as one document on stdout — never prose on one
run and JSON on the next, including for failures that happen *before* the
comparison. Exit codes are unchanged.

```sh
appshot check --source screenshots/source --golden screenshots/golden --json | jq
```

```jsonc
{
  "schema": 1, "passed": false, "tolerance": 0.001, "matched": 16, "sealed": true,
  "source": "screenshots/source", "golden": "screenshots/golden",
  "screens": {
    "browser~dark.png":  { "status": "match" },
    "preview~light.png": { "status": "pixel_drift", "pixelDiffPercent": 0.412,
                           "diffPath": "screenshots/diff/preview~light.png" }
  },
  "duplicates": [],
  "error": null   // or { "kind": "golden_drift", "message": "…" }
}
```

`status` is `match` or a failure kind: `pixel_drift`, `size_changed`,
`alpha_lost`, `alpha_drift`, `new_screen`, `missing_capture`. Match on those, not
on the prose — the sentences are written for a person and will keep being
reworded.

## Configuration

`screenshots/screenshots.config.json` (override with `--config`):

```jsonc
{
  // Must be one of the sizes App Store Connect accepts (four Mac sizes,
  // plus iPhone/iPad in both orientations). It rejects anything else without
  // naming the offending file, so appshot fails here instead.
  "output": { "width": 2880, "height": 1800 },

  // Every appearance listed here needs a matching key in "themes" below.
  "appearances": ["light", "dark"],

  // A CSS-style stack. The FIRST family must be installed — appshot refuses to
  // substitute rather than silently rendering the wrong typeface.
  "fontFamily": "'SF Pro Display', -apple-system, 'Helvetica Neue', Helvetica, sans-serif",

  "layout": {
    "margin": 140,
    "textTop": 120,
    "titleFontSize": 100,
    "titleWeight": 700,
    "titleLineHeight": 1.12,
    "subtitleFontSize": 46,
    "subtitleWeight": 500,
    "textGap": 28,
    "screenshotGap": 72,
    "cornerRadius": 28,
    // blur is an SVG feGaussianBlur stdDeviation (sigma), NOT a
    // CoreGraphics setShadow(blur:) value, which is roughly 2x.
    "shadow": { "blur": 48, "opacity": 0.3, "dy": 24 },
    // Warn (don't fail) past this many wrapped title lines. Default 2.
    "maxTitleLines": 2
  },

  "themes": {
    "light": {
      // Degrees, clockwise, screen space. See the note below if you are
      // porting a config from the old JS pipeline.
      "background": {
        "angle": 145,
        "stops": [
          { "offset": 0, "color": "#F7F8FA" },
          { "offset": 1, "color": "#E2E5EA" }
        ]
      },
      "title": "#0E1116",
      "subtitle": "#5B6472"
    },
    "dark": { "...": "same shape" }
  },

  // Array order IS the App Store order: it stamps the 01-, 02- prefix onto the
  // composites, because App Store Connect sorts uploads by filename. The raw
  // captures stay unnumbered, so reordering the listing never renames an image.
  "screens": [
    {
      "id": "main",              // matches <id>~<appearance>.png in the capture dir
      "website": "main",         // basename emitted for the marketing site
      "title": "Pixel-perfect cutouts, on your Mac",
      "subtitle": "Free to download · pay once for Pro."
    },
    {
      // No "website" key ⇒ store-only. This is how a paywall screen stays off
      // the pricing page.
      "id": "pricing",
      "title": "One purchase. No subscription."
    }
  ]
}
```

Two notes:

- Unknown keys are ignored, so a `"//"`-prefixed or `"_screens"` entry works as
  a comment for free. (The example above is annotated JSONC for readability —
  the real file is plain JSON.)
- **`background.angle` changed meaning.** The JS original fed it to an SVG
  `gradientTransform="rotate(A .5 .5)"` in objectBoundingBox units, which the
  renderer then skewed by the canvas aspect ratio: `angle: 145` measured about
  135° on the actual output. Here the angle means what it says, so a config
  carried over verbatim renders a slightly different — and now predictable —
  gradient than its old composites.

## Gotchas

**Window sizes must be stable *and* intentional.** The gate will never catch a
wrong-but-stable size: it matches its own golden run after run, forever. After a
capture, `appshot` prints a window-size summary — expect one group per intended
window size. An unexplained extra group is the bug.

**The settle is a floor, not the whole wait.** After it, `appshot` polls frames
until the window holds still — two consecutive matching captures — and the frame
that proves it is the screenshot. So a static pane finishes fast while a slow one
waits as long as it needs, up to `--settle-max` (8s). Measured on a 16-shot run of
a real app: 1.85s per shot, of which the floor is 17% and the poll 55%.

**But a floor is still required**, which is why `--settle` did not go to zero:
quiescence cannot tell *finished* from *hasn't started*. An empty state, a
skeleton row and a spinner-free loading pane are all perfectly still, and a poll
alone would photograph one and call it settled. If a screen's data lands later
than the floor, give that screen its own: `export::6` (empty stage ⇒ stage is
still `export`). Raising the global `--settle` instead taxes every launch — at 16
shots, +0.5s is +8s.

**The gate can catch what the poll cannot.** A window can be perfectly still and
still be wrong — a focus or selection state that landed differently, an empty
state that has not filled in. The frame poll sees stillness, not correctness, so
a screen that renders two discrete states will settle happily on either and gate
flakily afterwards. If one screen fails intermittently with the *same* pixel
percentage each time, that is the signature: two states, not drift. Look for
something non-deterministic in the app, not a settle to raise.

**Two projects can capture at once — but they take turns at the shutter.** Only
the exclusive part of a shot is locked: parking the pointer, activating the app,
and the frame poll. Launching, waiting for the window and the settle floor all
overlap with another project's run, so a machine-wide lock costs seconds per shot
instead of minutes per run. When it is held, the error names the run that has it
— app, pid, working directory, how long it has been going — and `--wait` blocks
until it clears instead of failing:

```sh
appshot capture --app build/MyApp.app --screens home --wait --wait-timeout 600
```

The lock cannot go away entirely. ScreenCaptureKit is not the constraint — it
captures by window id regardless of z-order — but macOS renders a non-frontmost
window with grey traffic lights and a dimmed toolbar, and there is exactly one
active application per Mac. A capture taken without activating looks plausible
and is wrong, which is why `wouldNotComeToFront` is fatal rather than a warning.
`appshot doctor` reports whether the lock is currently held. `--foreground-launch`
restores the old behaviour — an activating launch and one lock for the whole run —
for an app whose window never appears when launched in the background.

**`--ready-file` replaces the settle guess with a signal.** The floor exists only
because the poll sees *stillness*, not *readiness*. An app that can say when its
data has landed removes the guesswork: appshot passes a path as a launch argument
and waits for the app to create it, then skips the floor entirely.

```sh
appshot capture --app build/MyApp.app --screens report --ready-file
```

```swift
// In the app, at the moment the content it is being photographed for exists:
if let path = UserDefaults.standard.string(forKey: "ScreenshotReadyFile") {
    FileManager.default.createFile(atPath: path, contents: nil)
}
```

The path is inside the app's sandbox container when it has one, so a sandboxed app
can write it. A screen's own settle (`export::6`) is still honoured; the global
`--settle` is what the signal replaces. If the signal never comes, the run fails
rather than quietly falling back to the guess it was reached for to escape.

**A capture marked `!` never held still.** It rode `--settle-max` out and was
photographed mid-change, so it will match its golden on some runs and not others.
That reads as a flaky gate; the cause is usually a spinner outliving its data, a
live clock, or an animation the capture flags don't suppress.

## Development

```sh
make build     # swift build -c release
make test      # swift test
make bench     # capture the fixture app and report where the time goes
make clean
```

`AppShotKit` returns values and never prints or exits; the `appshot` target is a
thin CLI over it. That is what lets the gate and the compositor be tested as
plain functions over synthesized images, with no GUI and no permissions — which
in turn is what lets CI run them.

### Measuring the capture loop

The settle defaults were reasoned from the shape of the capture loop rather than
measured against a real app, and there are two ways that reasoning could be
wrong: the frame poll might cost more than the sleep it replaced, and per-shot
launch/teardown might dominate both — in which case the settle was never worth
tuning. `--timings` answers that, on any app:

```sh
appshot capture --app build/MyApp.app --screens main export --timings
```

```
Timing — 16 shot(s), 29.6s total, 1.85s/shot:
  phase       median     worst   share
  launch       0.05s     0.10s      3%
  window       0.33s     0.39s     18%
  floor        0.31s     0.32s     17%
  poll         1.07s     1.46s     55%
  encode       0.03s     0.03s      1%
  teardown     0.10s     0.11s      6%
  frames      4 median, 5 worst
```

Read the frame count first. At the minimum (3) the window was already still when
the poll started, so the floor is the entire cost and `--settle` can come down.
At the ceiling, the window never held still — see the `!` gotcha above.

`make bench` runs this against a fixture app in this repo whose stages are
deliberately awkward to photograph: `instant` draws immediately, `late` shows a
*still* skeleton for 3s before the real content, `restless` never stops moving,
and `slow-window` has no window for 2s. `late` is the interesting one — it is the
case a frame poll cannot see, and the reason `--settle` still has a floor.

Neither `--timings` nor `make bench` can run in CI: capture needs Screen
Recording permission and exclusive control of the pointer.

Formatting is enforced in CI:

```sh
swift format lint --strict --recursive Sources Tests
swift format --in-place --recursive Sources Tests
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Releases that change composed output are
called out with a **re-check your goldens** warning — those are the ones that
drift every consuming project's baseline at once.

## License

[MIT](LICENSE) © Olivier Louvignes
