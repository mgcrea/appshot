# Changelog

All notable changes to appshot are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Note for anyone upgrading: a release that changes composed output is called out
under **Changed** with a **re-check your goldens** warning. Those are the ones
that drift every consuming project's baseline at once, and the cost shows up as
a red `appshot check` with no obvious cause.

## [Unreleased]

Nothing yet.

## [0.16.0] - 2026-09-26

### Added

- **`compose family` handles a second app language.** `"locales": [{ "id": "fr-FR",
  "language": "fr" }]` pairs each caption locale with the app language its captures were
  taken in, read from `<platform>/source/<language>/` on every device and written to
  `<out>/<id>/`. Composites carry `captions` per locale, with the per-platform config's
  rule: every locale or none, and no fallback to a plain `title`. The capture-time check
  runs per language, since each is its own capture run. Found on the first localized
  project to try it, where the French and English demo sets show different routes: a
  crossed pair would have shown two apps under one caption. A 0.15.0 binary ignores
  `locales`, so a localized family config needs 0.16.0.

## [0.15.0] - 2026-09-26

### Added

- **`appshot compose family`: one app on several platforms, in one image.** For a
  target that ships on Mac and iOS, a Mac window with an iPhone standing in front of it
  (`continuity`), or two or three devices side by side (`split`), from the captures both
  pipelines already took. It captures nothing and keeps no goldens. The config,
  `Screenshots/family.config.json`, reuses the per-platform `themes`, `layout` and
  `bezel`; devices are named by their directories (`macos`, `ios/iphone`). Shadows
  follow each device's own silhouette, so the phone's shadow falls on the Mac window
  with the phone's corners. `"store": "mac"` checks an image for the Mac listing (a Mac
  store size, the Mac window as the subject) and every family image is written with no
  alpha channel. The run prints when each platform was captured and warns when the two
  are more than a day apart, since two halves from either side of a redesign compose
  into a picture of two different apps; `--max-skew` makes that fatal. The skill's
  Makefile gains a `screenshots-family` target. Nothing changes for existing configs.

## [0.14.0] - 2026-09-25

### Added

- **Capture on a real iPhone or iPad: `"hardware": "<name or UDID>"` on a `devices[]`
  entry, instead of `"simulator"`.** For apps the simulator cannot render, such as a
  Metal 4 canvas, which the Simulator SDK compiles to stubs. The same staged relaunch,
  settle, gate and compositor, driven through `devicectl`; `--app` is the signed
  `iphoneos` build. What a simulator pins from outside, the app now does under
  `-ScreenshotTarget hardware` (hide the status bar, apply `-ScreenshotAppearance`,
  expand the tilde in the `~/tmp/…` ready file), and each gap fails the run instead of
  shipping: identical light and dark captures, a capture whose orientation disagrees
  with the canvas (the rejected frame is kept for a look), and a Dynamic Island that is
  moving before the first shot (a music live activity, measured). `doctor` checks the device is paired and
  in Developer Mode. Nothing changes for simulator or Mac configs.

## [0.13.0] - 2026-09-24

### Added

- **`"chrome": "none"` on a `screens[]` entry exempts that one screen from
  `--recolor-traffic-lights`.** For a stage that photographs a borderless window, such as
  a menu bar panel's content hosted for the capture. Until now the flag failed that
  shot, since there are no buttons to find, and the only way out was to drop the flag
  for the whole app. The exemption is per screen and config-only (a `--screens` spec
  cannot carry it), so every screen that does not declare it still fails loudly when
  its buttons are missing. Captured output is unchanged for every existing config.

### Fixed

- **iOS: "the app never appeared" while the app was on screen, and settles that fired
  mid-transition.** Every simulator frame is written to one scratch path, and a loaded
  image was decoded lazily from that file, so the frame taken before launch could decode
  as the app's own screen, and the settle poll could compare a frame with itself. Images
  are now read and decoded when loaded. An iOS run that settled early before this may
  have accepted a mid-transition golden (a sheet's home indicator missing, glass controls
  half drawn): **re-check your iOS goldens.**

## [0.12.0] - 2026-09-24

### Added

- **`capture --recolor-traffic-lights` repaints `--no-activate`'s grey window buttons.**
  An unattended run never takes the screen, and until now the price was a title bar with
  three grey dots, since macOS greys the close, minimise and zoom buttons whenever the app
  is not frontmost and nothing inside the app can change that. The buttons are found by
  measurement (three equal discs on one row at an even pitch, in the window's top-left
  corner, including over a glass title bar) and redrawn in their active colours for the
  title bar's appearance. A shot where they cannot be found, or are half grey and half
  coloured, fails instead of shipping half-painted; buttons that are already coloured are
  left alone. The sidebar and toolbar keep their inactive tone. Off by default. Turning it
  on changes captured pixels, so **re-accept your goldens** in the same change.
- **`capture` tells the app which activation mode it is in: `-ScreenshotActivation
  none|focused`.** A staged app on macOS 14+ has to activate itself once for a focused
  run, since a CLI that is not frontmost cannot raise an app that has never been active.
  Under `--no-activate` the same call takes the screen from whoever is working, on every
  launch, which is the one thing that mode exists to prevent. Nothing distinguished the two
  modes before, so an app had to pick one behaviour and was wrong for the other.
  `--foreground-launch` passes `focused`. Existing apps are unaffected until they read it.

## [0.11.1] - 2026-09-17

### Fixed

- **`capture --partial` on iOS deleted the screens it didn't name.** The simulator
  driver accepted `--partial` but still wiped the whole capture directory before every
  run, so a partial iOS capture wrote the screens it was given and destroyed the rest.
  The macOS driver always got this right; the simulator driver now matches it.

### Changed

- **The `--screens`/config mismatch error now names `--partial`.** When every screen
  the config declares but the run didn't capture is the whole complaint, the error now
  says so — `appshot capture --partial` rewrites only the named screens instead of
  refusing a deliberate subset. An unknown screen name still gets no hint, since that
  is a typo to fix, not a flag to reach for.

## [0.11.0] - 2026-09-16

### Added

- **`capture --no-activate`: photograph the window without ever taking the screen.**
  Until now a run activated the app at each shutter and warped the pointer to the corner
  first, because an inactive macOS window renders grey traffic lights and a dimmed toolbar.
  That cost is paid by whoever is at the machine: the run takes the screen, their stray
  click can fail it, and on a Mac somebody is actually working at, `would not come to the
  front` fires on a random shot no matter how long the settle is.

  ScreenCaptureKit never needed the window frontmost — an occluded window captures its own
  content. `--no-activate` skips the activation, both frontmost assertions and the cursor
  parking, and a run becomes invisible to the person at the keyboard. `--foreground-launch`
  and the capture lock stop mattering in this mode, because nothing contends for focus.

  The app has to meet it halfway, behind its demo flag: force SwiftUI's
  `controlActiveState` to `.key`, and hold off App Nap with `ProcessInfo.beginActivity` so a
  backgrounded window is not throttled into being photographed half-drawn. Measured against
  a focused capture of the same screen: 97.5% of pixels differ with nothing forced, 21.5%
  with `controlActiveState` forced. The residue is chrome the process cannot reach — the
  traffic lights follow app-level activation rather than the window's key state, so an
  `NSWindow` subclass overriding `isKeyWindow` does nothing, and the sidebar's uniform
  ~11/255 lift is not `NSVisualEffectView.state` either. Both were tried.

  **Goldens must come from one mode or the other.** The gate compares like with like, so an
  unfocused capture against a focused golden fails on chrome nobody changed. Existing
  projects are unaffected: the default is still focused.

- **`capture --capture-display main|secondary|builtin|external`.** Stopping a run taking the
  keyboard is only half of not being disruptive — the window is still *drawn*, over whatever
  the person is reading. This parks it on a display they are not using, which on a laptop
  plus a monitor is free. appshot resolves the choice and passes `-ScreenshotDisplay
  <CGDirectDisplayID>`; an app that ignores the argument is unaffected, and moving another
  process's window directly would need an Accessibility grant, which is a worse trade than
  one launch argument.

  It declines to move at all when the named display is absent, when the choice would land
  back on the display in use, or when the target's backing scale differs — that last guard
  matters, because a 1x display beside a 2x one halves every captured dimension and fails
  the gate on every screen at once for a reason nothing in the output explains.

### Fixed

- **The frame poll no longer settles on a window that has not drawn yet.** Stillness was
  standing in for readiness, and a launched-but-empty window is perfectly still, so the
  shutter could fire on a blank frame. Cadence shipped four byte-identical black iPhone
  captures this way. A frame now also has to carry content: on real captures a blank
  window runs 0.36-0.54% off its dominant colour and every drawn screen 36-71%, and the
  floor sits at 2%. A window that never draws ends at the ceiling with `settled: false`
  instead of passing as done.

- **"No goldens" no longer tells you to run `accept` over an iOS baseline.** A Mac-shaped
  command (`selftest`, or `check` without `--config`) pointed at an iOS golden tree found
  nothing at the top level and suggested seeding it with `appshot accept`, which would
  overwrite real, reviewed goldens sitting one level down under `devices[]`. It now names
  those subdirectories and points at `--config`. A genuinely empty directory still gets
  the `accept` suggestion.

## [0.10.0] - 2026-08-07

### Added

- **`capture` stamps `source/run.json`, and `check --max-source-age` can gate on it.**
  `check` compares whatever is sitting in `source/` against the goldens — it has never had
  any way to know whether those captures came from *this* run, and when the answer is no,
  the failure is silent and green. Measured: a project's build broke, so `capture` never
  ran; `check` compared twenty PNGs left over from a run **fifteen days earlier** against
  the goldens they were accepted from and reported `✓ 20 screenshot(s) match their
  goldens`, exit 0.

  `run.json` records when the captures were taken, by what argv, from which app bundle,
  and `check` now reports its age on **both** the pass and the fail path — a pass is
  exactly when nobody looks closer. `--max-source-age <seconds>` turns that into a hard
  failure, for CI, where the captures should always be minutes old and anything else means
  the pipeline is broken. Off by default: "capture, review, check tomorrow" is a real
  workflow, and a tool that broke it would be switched off. A source directory captured
  before this existed simply has nothing to say and still gates normally; `check --json`
  carries it as `capturedBy`.

- **`check` locates a drift, not just its size.** A `pixel_drift` failure now carries a
  bounding box of the pixels that breached the noise floor, the densest rows, and — when
  most of the canvas moved by the same small amount — a call-out that the change is a
  uniform tonal shift rather than an edit. Printed before the diff path, and carried in
  `check --json` as each screen's `drift`.

  A percentage alone only says a screen changed; the diff PNG is amplified 12x, which
  makes a uniform two-unit shift look exactly like a content change. Measured case: 74%
  of one capture differed by exactly 3 while only 0.27% breached the floor — "everything
  changed" in the diff image and "almost nothing changed" in the percentage. Both
  properties fall out of the loop `check` already runs over every pixel, so this costs
  nothing extra to compute.

- **`icon build --mark-shadow` and `--mark-inner-shadow`** — drop and inner shadows on the
  mark, applied identically to every rendering. Both are repeatable and take named fields:

      --mark-shadow 'angle=315,distance=32,blur=0,opacity=0.22'
      --mark-inner-shadow 'angle=270,distance=6.5,blur=5,opacity=0.7,color=#F6821E'

  This closes a hole whose only symptom was two files disagreeing. Marks are rasterised
  through `NSImage`, whose SVG support has **no filter support at all**, so a `<filter>`
  authored in a mark renders in a browser and is silently discarded in the app icon — the
  website and the Dock then show different artwork from one source file, which is the
  drift `--out something.svg` exists to remove, reintroduced one layer down. Rather than
  grow a browser-grade SVG engine, appshot now takes the effects as parameters: it
  composites them into the `.appiconset` slots and the `.icon` mark layer, and emits them
  as real `<filter>` elements into the SVG, where browsers do the same arithmetic. A mark
  that still carries its own `<filter>` now gets a warning instead of silence.

  Inner shadows are why this cannot be left to the caller. A drop shadow can be faked with
  a second copy of the artwork; an inner shadow is bounded by the mark's own alpha, so
  nothing drawn in the mark stands in for it — and it is what gives a flat letterform
  depth.

  Three details worth knowing. `distance` and `blur` are **canvas pixels on a 1024
  canvas** and scale with the output, so one spec serves the 16pt slot and the 1024pt
  layer; in output pixels they would swamp the small slots. `blur` is the Gaussian
  **standard deviation** — SVG's `stdDeviation` — which is roughly half what a design
  tool's blur slider shows, and is spelled that way so one number means the same thing in
  the filter and in the raster. And `angle` points at **where the shading lands** for both
  kinds, matching a design tool's inspector, which an inner shadow honours by displacing
  its silhouette the opposite way; copied literally as a sign, every inner shadow would
  light the icon from the wrong side.

- **`icon build --out something.svg`** — the plated icon as vector, for the half of an
  icon that never reaches Xcode. A marketing site wants the same artwork as a favicon, an
  `apple-touch-icon`, an OG card and usually a press-kit download; rasterising those from
  a 1024 PNG loses the two that should stay vector, so the site grows a hand-written SVG
  transcribing the same geometry, and it drifts from the app's icon the first time either
  moves. Emitting it from the same command removes the transcription rather than asking
  someone to keep it in step.

  Same mark, same plate and the same placement arithmetic as the raster formats — the
  placement comes from one function and the gradient axis from one projection — so an SVG
  favicon cannot sit a few pixels off from the icon it is meant to be. Two deliberate
  differences. It **keeps** its corner radius, because nothing masks an SVG on a web page:
  `--corner-radius` defaults to Apple's own proportion carried onto a full-bleed canvas
  (185 on 824, rescaled to 1024 ≈ 230), and `--corner-radius 0` gives the square plate an
  `apple-touch-icon` needs, since iOS masks that one itself and a rounded source gets
  rounded twice. And the mark must be SVG: embedding a bitmap would produce a file that is
  vector only in its extension.

### Changed

- **A `.icon` with a plate is now written as two layers**, `plate.png` with `mark.png`
  above it, instead of one flattened bitmap. A flat bitmap gets a single specular sweep
  across the whole icon — the system cannot light a mark it cannot tell apart from its
  plate — and separating them is the entire reason the format exists. `--flatten` keeps
  the 0.9.0 output. Artwork with no plate has nothing to split and is unchanged.

  This changes what `icon build --out X.icon` writes: `Assets/1024.png` becomes
  `Assets/mark.png` + `Assets/plate.png`. Delete the old layer when you re-run, or the
  bundle keeps a file nothing references.

### Fixed

- **`icon check` held the wrong layer to the opacity rule.** `layers` in `icon.json` runs
  **front to back**, so the base is the *last* entry, not the first. The audit required
  the first — which on a multi-layer bundle demanded that the topmost mark be fully
  opaque, while exempting the plate underneath that actually has to be. Single-layer
  bundles were unaffected, which is why it went unnoticed.

  The ordering is not a reading of the schema — it was confirmed by rendering. An opaque
  full-bleed plate listed first paints over everything above it, and the icon compiles,
  installs and renders as a bare plate with the mark nowhere.

## [0.9.0] - 2026-08-06

### Added

- **Icon Composer `.icon` bundles.** `icon build` now writes either format, and the
  `--out` extension picks which: `.appiconset` keeps the ten-slot 824-on-1024 grid,
  `.icon` writes `icon.json` plus a single square, fully opaque 1024px layer. `icon
  check` and `doctor` audit both.

  The extension decides rather than a `--format` flag, because the two formats want
  **opposite** artwork and a flag could disagree with the path it is writing to. An
  `.appiconset` carries its own rounded plate and its own margin — nothing masks it on
  the systems that format exists to serve. A `.icon` layer is square and opaque to all
  four edges, because the system applies the squircle, the shadow and the material
  itself. A radius copied across is masked a second time and leaves a sliver of nothing
  at each corner: it renders, so nothing objects, and it is only visible next to
  another icon.

  That is what the `.icon` audit is for. Nothing rejects a malformed one the way App
  Store Connect rejects a hollow `.appiconset` (error 90236), so the check reads the
  properties the format requires: the manifest names a layer, the layer is on disk at
  1024×1024, and its every pixel is opaque. Counted in full rather than sampled at the
  corners — the count is what tells a stray antialiased edge from a carried-over corner
  radius, and the message says which one it found. Layers above the base are exempt;
  those are meant to carry alpha.

  **Migrating multiplies `--mark-fraction` by 1024/824 ≈ 1.243** — `0.57` becomes
  `0.708`. The flag is a fraction of the canvas in both formats, but the canvas is only
  the plate in one of them: an `.appiconset` plate is 824 of its 1024 canvas and renders
  1:1, while a `.icon` layer *is* the plate and the system scales it down to the same
  824. Carrying the old number across shrinks the mark by a quarter, which reads as a
  timid glyph rather than as a bug. `icon build` now prints what the fraction lands at
  on the composed plate — `mark spans 70.8% of the composed plate (peers sit at 70–80%)`
  — on every run, for both formats, so the comparable number is stated instead of
  re-derived.

- **Localized captions.** A top-level `"locales": ["fr-FR", "en-US"]` declares the axis,
  and each screen carries a `captions` block keyed by locale instead of a plain `title`.
  `compose appstore` then emits one full set per locale into `appstore/<locale>/`, and
  `--locale fr-FR` narrows a run to one of them. `run` and `compose both` take it too.

  This is the `appearances` / `themes` shape the config already used for its other
  fan-out-with-data axis: an ordered array declares, a keyed object supplies, and a gap
  between them is a hard failure. Declaring the axis rather than inferring it from the
  union of `captions` keys is what makes a typo name itself — mistyping `en-US` as
  `en-UK` is one error pointing at the offending key, instead of inventing a locale and
  reporting every other screen as incomplete.

  **There is no fallback to the plain `title`.** A screen carries either one caption or
  one per locale, never both, and both cases are rejected at decode. A fallback would
  mean two places to look for the string that actually rendered, and its failure mode is
  a French listing shipping English copy — plausible, publishable, and wrong.

  A locale is a *directory* rather than a third `~` field, but for different reasons than
  a device is, and the difference is worth knowing before anyone collapses the two.
  `Device`'s reasons — that a third field would break `<id>~<appearance>` demangling, and
  that one config cannot hold two canvas sizes — do not transfer: a locale never appears
  in a capture filename and needs no canvas. What decides it is that `compose appstore`
  wipes the directory it writes into, so locales sharing one directory would mean
  `--locale fr-FR` destroying a finished set for a locale the run was told not to touch.
  Outermost, so `appstore/fr-FR/` mirrors the whole appstore tree; on iOS that reads
  `appstore/fr-FR/iphone/01-home~dark.png`.

- **A warning when a pre-locale composite set is stranded in the output root.** Adding
  `locales[]` to a project that already composed flat leaves last release's
  `appstore/01-*.png` beside the new `appstore/<locale>/` directories — complete,
  correct-looking, and never overwritten again, because a localized run only ever wipes
  inside a locale directory. appshot now says so. It warns rather than deletes: that is
  your output directory, and appshot removes only what it is about to rewrite.

- **`capture --partial`, for iterating on one screen.** `--config` cross-checks
  `--screens` against `screens[].id`, and both halves of that check used to be fatal.
  The half that catches a typo stays on always — a mistyped screen name does not error
  on its own, it stages the app's default screen and writes it under the name that was
  asked for, which is the duplicate-capture failure wearing a different hat. `--partial`
  withholds only the other half, "every declared screen must be captured" — without it, a
  design loop recapturing ten shots to look at one is a loop nobody runs. A run whose
  output is going to be gated must still be complete, and `check --config` still enforces
  that regardless of how the captures were taken.
  `--partial` also stops `capture` from wiping the rest of `--out` before it starts: that
  wipe is right for a complete run, but under a subset run it silently deleted every
  screen the run was not taking, and the loss surfaced only at the next `check` — long
  after the run that caused it. A subset run now owns only the screens it names.

### Changed

- `doctor --appiconset` is now spelled `doctor --app-icon`, since it takes either an
  `.appiconset` or a `.icon`. The old name still works as an alias — it is what every
  existing caller spells, and there is nothing to gain from breaking them.

- `Config.Screen.title` is now `String?` (AppShotKit API), since a localized screen
  carries its copy in `captions` instead. `Compose.appStore` gains a **required**
  `locale:` parameter with no default — a defaulted one would let a new call site compose
  the unlocalized captions on a localized config and emit a full, plausible store set in
  the wrong language, with nothing to catch it.

  **No need to re-check your goldens.** The gate compares raw captures and a caption is
  applied downstream of them, exactly like the bezel in 0.7.0. An existing config decodes
  unchanged, resolves to a single unnamed locale, and writes byte-identical composites to
  byte-identical paths.

- `check`, `accept`, `seal`, `selftest` and `compose website` deliberately take **no**
  `--locale`, and reject it rather than accepting and ignoring it. The first four compare
  raw captures, which are the same images in every language; the last bakes in no caption
  to vary, so per-locale output would be byte-identical files in two directories.

- `--foreground-launch`'s help said it was "only for an app whose window never appears when
  launched in the background". That undersold it: it is also the answer when *something else
  on the machine* competes for focus — an editor, a browser, or the terminal an agent is
  driving the run from — which otherwise surfaces as `would not come to the front` on a
  random shot. Measured on a contended Mac: 2 of 3 runs failed without it, 3 of 3 passed
  with it. The help now says so, and names the concurrency it costs.

### Known limitation

- `doctor`'s font check catches a family that is not installed, but not one that lacks
  glyphs for a locale's script: CoreText falls back per glyph during typesetting, so a
  CJK caption can ship in a substituted typeface with a green `doctor`. Latin locales are
  unaffected. A per-locale `fontFamily` override is the natural fix if this ever bites.

## [0.8.0] - 2026-08-05

### Added

- **`appshot icon` builds a macOS `.appiconset` from one mark.** `icon build --from
  <svg|pdf|png> --out <path>.appiconset` renders all ten slots at exact pixel sizes and
  writes `Contents.json`. `--plate` puts a flat colour behind the mark,
  `--plate-gradient a,b` with `--plate-angle` a ramp — the same angle convention as the
  compositor's background, since both now share one gradient implementation and an icon
  and its store visuals should not disagree about what 45° means. `--tint` fills the
  mark's shape with a single colour, for artwork authored with `currentColor`, which
  renders black on its own.

  It does the mechanical half deliberately, and not the design half: what is *in* the
  mark stays per-project, because a tool that generated one would be guessing. The plate
  sits on Apple's grid — an 824pt rounded square on a 1024pt canvas, radius 185 — because
  on macOS that margin is part of the artwork rather than something the system masks, and
  a full-bleed icon renders visibly larger than every neighbour in the Dock.

  Vector input goes through `NSImage`, which reads SVG where `CGImageSource` has no
  support for it at all, and every slot is rendered at its final size rather than
  downsampled from one master, so a mark stays sharp at 16pt.

- **`appshot icon check` fails on an incomplete icon set, and `doctor --appiconset` folds
  the same audit into the rest.** An `.appiconset` whose `Contents.json` declares every
  slot while the directory holds no images builds fine, runs fine, shows a blank icon
  nobody looks at, and is rejected only at upload with *"Missing required icon … 512pt x
  512pt @2x" (90236)*. That is a full archive, export and transfer to learn something
  readable from disk in milliseconds, which is the same reason the font check exists.

  The audit keys on each slot's size and scale rather than on its filename: `filename` is
  optional in `Contents.json`, an entry without one is exactly how a hollow set is
  spelled, and keying on filenames both reported every slot twice — missing *and*
  undeclared — and would have failed any project that names its images something other
  than Xcode's default.

  It also catches a Git LFS pointer sitting where a PNG should be, and anything else
  present but undecodable, instead of skipping the slot silently: a repo that
  LFS-tracks its icon assets has a 130-byte text file at the right name and the right
  `Contents.json` entry on any clone that hasn't run `git lfs pull`, and `Image.size`
  returns nil for it — the same blank-icon failure the audit exists to catch, just
  one step earlier.

## [0.7.1] - 2026-08-05

### Fixed

- **`--extra-args` can now express a value containing a space.** It was tokenized with
  `split(separator: " ")`, so `-AppleHighlightColor "0.65 0.79 0.94 Blue"` arrived as
  four separate arguments and `-AppleLanguages "(en, fr)"` as two. The launch then
  quietly took something else, and the only symptom was a capture that rendered
  differently on a different Mac — which is the class of bug `--extra-args` exists to
  prevent, since the arguments worth pinning are precisely the ambient macOS defaults
  that decide how the app draws.

  Splitting is now quote-aware (`LaunchArguments.split`): single and double quotes
  group rather than delimit, backslash escapes, a backslash stays literal inside
  single quotes, and an unterminated quote runs to the end of the string — all as in
  `sh`. Arguments with no quoting tokenize exactly as before, so no existing
  invocation changes meaning and no golden moves.

## [0.7.0] - 2026-08-04

### Added

- **`layout.bezel` — a drawn device edge.** Absent ⇒ no bezel, so every existing
  config composes as it did. Compose-only, so it does not touch the gate: the goldens
  are raw captures and the bezel is applied downstream of them, which makes it one of
  the few visual changes that needs no re-accept.
  It exists because `shadow` cannot separate a dark app from a dark gradient:
  measured on an RXd composite, the pixel immediately outside the window read
  (18,15,13) against a background of (19,16,14) — one unit, from the setting whose
  entire job is that edge.
  Deliberately not a photographic device frame. That would mean an artwork asset per
  device kept in step with Apple's hardware cadence, a redistribution licence for
  images appshot does not own, and a screen aperture that has to agree with the
  capture's own alpha corners to the pixel or show a seam — and it would cost real
  legibility, since the window is *width*-bound in a typical layout and every pixel
  of frame comes straight out of rendered app UI.
  The ring is instead the capture's own alpha silhouette dilated by a disc: the screen
  outline offset outward everywhere by the same amount, which is what a physical frame
  is. It fits an iPhone squircle, an iPad's circular corner and a Mac window's corners
  identically, with no radius to configure per device and no fixed-aperture artwork to
  fall out of alignment with. An opaque capture, having no silhouette to dilate, falls
  back to the rounded rect the compositor is about to clip it into.
  Keys: `width`, `color`, an optional `highlight` rim on the outermost pixels and its
  `highlightWidth` (default `width / 4`, clamped into `1...width`). The window shrinks
  by `2 * width`, so the ring's outer edge respects `margin` instead of eating into
  it — a frame growing outward from an already-placed window would walk past the edge
  the config says the device stops at, and nothing downstream would notice.
  `validate()` rejects a non-positive width, an unparseable colour or highlight, and a
  bezel too wide for its margin — per device, and through per-device layout overrides.
  A bezel is drawn rather than checked against anything, so every other way of getting
  it wrong renders quietly and ships.
- **`--ready-file` now works on the iOS simulator driver.** It matters more there than
  on macOS: a React Native or Flutter launch still loading its bundle is perfectly
  still, so the frame-settle poll happily settles on the blank frame and calls it a
  screenshot. The marker lives inside the app's own sandboxed data container, located
  via `simctl get_app_container ... data` — the simulator's container is a real host
  directory, so appshot can poll a path from outside that the sandboxed app also sees.
  With a ready signal the settle floor drops to 0: the app has stated its data is on
  screen, which is strictly more than a sleep can know.

### Changed

- **With a bezel set, the shadow sits under the whole device**, expanded by the ring
  width, rather than under the screen with a ring of unshadowed frame around it. No
  effect on a config without a bezel.

### Fixed

- **`selftest`'s ignore-rect mutants no longer wipe corner alpha.** The mutant painted
  its change into a band anchored at the top-left — exactly where a rounded capture's
  transparent corner lives — and was forcing that pixel's alpha to 255 along with the
  colour. Alpha is checked categorically, outside the ignore list by design, so the
  mutant failed for a reason that had nothing to do with the property under test:
  "change inside an ignored region" declared the gate untrustworthy on every project
  whose captures are rounded. It now leaves alpha alone and only changes colour.

## [0.6.0] - 2026-07-23

iOS and iPadOS, through a staged simulator driver. Nothing here changes composed
output for an existing Mac project — **no need to re-check your goldens.**

### Added

- **`"platform": "ios"` and `devices[]`.** An iOS config names one simulator per store
  canvas, and each device gets its own directory level under `source/`, `golden/` and
  `appstore/` (`source/iphone/main~dark.png`). The device is a *directory*, never a
  third `~` field, so the `<id>~<appearance>` contract the gate, the compositor and
  `extract` all key off is untouched — and one config could not carry two canvas sizes
  any other way, iPhone 6.9" being 1320x2868 and iPad 13" 2064x2752.
  A device may override `layout` and ship a subset of `screens[]`; a config with no
  `devices[]` keeps the flat directories it has always had.
- **The simulator driver.** Boot → status-bar override → install → `simctl launch` with
  `-ScreenshotStage` per screen → screenshot → terminate. The same staged-relaunch model
  as macOS, and the same settle engine: `Capture.settledImage` was already generic over
  its frame source, so the floor, the quiescence poll and the `Timings` breakdown are
  shared code reaching the same verdicts. The app-side demo harness is identical on both
  platforms — arguments after the bundle id land in `NSArgumentDomain` exactly as
  `open --args` does.
  It captures with `--mask=alpha`, which yields the device's real rounded-corner alpha
  (measured: 0.878% of an iPhone canvas, 0.064% of an iPad's), so the compositor and the
  categorical alpha check work on iOS unchanged.
- **`--device`** to run one entry of `devices[]`, and **`--erase`** to `simctl erase`
  before booting.
- **Gate ignore regions** — `ignore: [{x, y, width, height}]` per device. `check` reports
  how many pixels each capture excluded and what fraction of the canvas that is, every
  run: an ignore list is the one setting that makes the gate *weaker*, and a weakening
  nobody can see is how "ignore the status bar" becomes "ignore the top third". Excluded
  pixels leave the denominator as well as the numerator, and are marked in blue in the
  diff image.
- **`appshot selftest` gained two ignore-rect mutants** — a change inside an ignored
  region must pass, one outside must still fail. The second is the one that matters:
  without it, a rect that swallowed the whole canvas would look correct.

### Changed

- **`doctor` is platform-aware.** An iOS project is no longer failed for missing Screen
  Recording permission, which its driver never uses; instead it checks that simctl works
  and that every `devices[]` entry resolves to an installed device type and runtime. It
  also stops claiming an output size is "a valid Mac App Store size" when the config is
  iOS — the check and its own report used to disagree.
- **`validate()` checks sizes against the config's platform**, not the union of both. A
  Mac config carrying an iPhone canvas used to pass here and be rejected by App Store
  Connect, which does not name the offending file.
- **`compose` masks an opaque capture on iOS** to `layout.cornerRadius`. Previously only
  the shadow was rounded, relying on the capture's own alpha — feed that path an
  XCUIScreenshot and you get a square image on a rounded shadow. On Mac an opaque capture
  now *warns* instead: there it means Screen Recording was not granted, and compose is the
  last place to catch it.
- **`selftest` reports three outcomes rather than two.** The alpha mutant cannot be posed
  against a golden set with no transparency — setting alpha to 255 on an opaque image is a
  no-op — so it is reported as `⊘ skipped` with its reason instead of as a wrong verdict.
  It was a false alarm on every iOS project whose captures came from an XCUITest.
- **`check --json` gained `device`, `ignoredPixels` and `ignoredFraction`.** A
  multi-device run emits one document per device, one per line — a JSON stream, which
  `jq` reads natively. A Mac run's document is unchanged apart from the new keys, and
  `device` is null there. Existing fields keep their meaning, so `schema` stays 1.

### Fixed

- **`accept`, `seal` and `selftest` now fan out over `devices[]`** like every other
  leg, given `--config`. They were the three commands that take no config of their
  own, so on an iOS project they looked for PNGs directly in `source/`, found only
  device directories, and failed — leaving the documented golden-gate workflow
  broken for iOS unless you passed per-device paths by hand.
- **"no PNGs in …" now says when the captures are one directory down.** That error
  asked "did capture run?" about a capture that had run perfectly well and written
  into `source/iphone/`. It now names the device directories it found and what to do
  about them.

## [0.5.0] - 2026-07-23

Driving appshot unsupervised, from one of several terminals. Everything here comes
from a session that had to `ps aux | grep appshot` to find out whose run held the
lock, hand-write a polling loop to wait it out, grep `✗` out of prose to decide
pass/fail, and revert 18 silently-modified goldens without ever learning what wrote
them.

### Added

- **`--wait` / `--wait-timeout` on `capture` and `run`.** Blocks until a concurrent
  capture run releases the lock instead of failing. The lock now records who holds
  it — app, pid, working directory, when it started, argv — so a collision reports
  `another capture run is in progress: D1Explorer (pid 10994), started 2m14s ago in
  ~/Projects/D1Explorer` rather than a bare pid. `appshot doctor` reports lock state.
- **Sealed goldens.** `accept` writes `golden/manifest.json`: a sha256 per golden,
  plus who accepted them, from where, and with what arguments (last 10 accepts kept).
  `check` verifies it before comparing and fails hard on any file that changed, was
  added, or vanished — naming each one, with the accept it disagrees with. Commit it
  with the goldens: it travels with them, so a `git lfs pull`, a branch switch or a
  fresh clone is *not* mistaken for someone rewriting the baseline, while an edit
  made outside `accept` cannot be missed. `appshot seal` adopts goldens that predate
  it, and `--require-manifest` makes an unsealed baseline fatal for CI.
- **A mid-run guard on the golden directory.** `check` snapshots it at the start and
  re-reads it at the end; a `check` racing an `accept` in another terminal withholds
  its verdict instead of reporting one about a directory that no longer exists.
- **`check --json`.** One document on stdout — `{status, pixelDiffPercent, diffPath}`
  per screen, plus `duplicates` and `sealed` — including for failures that happen
  before the comparison, so a caller never gets prose on one run and JSON on the
  next. `status` is a stable slug (`pixel_drift`, `size_changed`, `alpha_lost`,
  `alpha_drift`, `new_screen`, `missing_capture`), not a sentence to match on.
  Exit codes are unchanged.
- **`--ready-file`.** The app says when its screen is genuinely ready, instead of
  everyone padding `--settle` defensively. appshot passes a path as a launch
  argument (`-ScreenshotReadyFile`, renameable with `--ready-arg`), waits for the app
  to create it, and then skips the settle floor entirely — the floor exists only
  because the frame poll sees stillness, not readiness. The path lands inside the
  app's sandbox container when it has one. A signal that never comes fails the run
  rather than reverting to the guess. A screen's own settle (`export::6`) is still
  honoured.
- A `lock` and a `ready` phase in `--timings`, so contention and readiness show up as
  themselves rather than as an inexplicably slow poll.

### Changed

- **The capture lock now covers the shutter, not the whole run.** It is taken
  immediately before parking the pointer and released after the frame poll — roughly
  1.5s of a 90s run. Launching, waiting for the window, the settle floor, PNG
  encoding and teardown all overlap with other projects' runs, which is what
  multi-project, multi-terminal use actually looks like. The app is launched with
  `open -gn` (no activation) and fronted deliberately inside the lock, so no run can
  steal focus from another one's shutter. `--foreground-launch` restores the previous
  behaviour for an app whose window never appears from a background launch.
- **`accept` is crash-safe.** It copies the new set into a staging directory first and
  only then replaces the old goldens. It previously deleted all of them before
  writing the first byte of the new ones; in a project whose goldens are not
  committed, one failed copy left nothing to recover from.

### Fixed

- **A live capture lock could be stolen.** `acquire` treated an unreadable holder as
  license to delete the lock and take it, and the holder wrote its pid *after*
  creating the lock directory — so a second process arriving inside that window
  destroyed a live lock and both runs proceeded, fighting over the pointer. A lock
  with no readable holder is now re-polled through a grace window, and only debris
  that survives it is cleared.
- `--wait` no longer overshoots its timeout by a whole retry interval.

## [0.4.0] - 2026-07-19

The settle defaults, retuned against measurements from a real app instead of
reasoning about the capture loop.

### Changed

- **`--settle` now defaults to 0.3s, down from 1.0s.** Measured, not reasoned: on a
  16-shot run of a real app (D1Explorer) a 1.0s floor left every window already
  still on arrival — the frame poll never waited for anything — while at 0.2s the
  poll started doing real work (3 frames median rising to 4) and the captures still
  matched goldens accepted under the old fixed 2.5s sleep. 0.3s keeps a margin over
  the value proven to work. The run went 40.6s → 29.6s. Still not zero: the poll
  cannot tell a finished window from a still-but-unloaded one.
- **Waiting for the window is 5x finer-grained** (250ms → 50ms polls). That phase
  was 21% of a measured run, most of it granularity rather than the window being
  slow. Unlike the frame poll it only detects existence, so there is no stillness
  guarantee to trade away. Waiting for the pid went 200ms → 100ms; it forks `pgrep`
  per poll, so the granularity is paid in process spawns.
- `--settle-max` and the 250ms frame-poll interval are unchanged. Dropping the
  interval to 150ms would save ~0.2s/shot but cut proven stillness from 500ms to
  300ms, and restoring the guarantee with a third match costs an extra frame that
  gives the saving straight back — so the cheaper poll is only available by
  weakening what it proves.

## [0.3.0] - 2026-07-19

Measurement for the settle defaults 0.2.0 shipped, which were reasoned from the
capture loop rather than observed.

### Added

- **`--timings`** reports where each shot's time went — launch, window, floor,
  poll, encode, teardown — as medians with worst cases and shares of the run,
  plus the frame count the poll used. The 0.2.0 settle defaults were reasoned
  from the capture loop's shape rather than measured; this is what measures them.
  Read the frame count first: at the minimum the floor is the entire cost, at the
  ceiling the window never held still.
- **`make bench`** captures a fixture app built from this repo, whose stages are
  deliberately awkward to photograph: `instant`, `late` (a *still* skeleton for 3s
  before the real content — the case a frame poll cannot see), `restless` (never
  settles) and `slow-window`. Neither this nor `--timings` can run in CI, which
  needs Screen Recording permission and the pointer.

## [0.2.0] - 2026-07-19

How long to wait before photographing a window, which until now was one number
sized for the slowest screen and paid by every launch.

### Added

- **Per-screen settle.** `--screens` now takes `name[:stage[:settle]]`, so the one
  screen that renders an async result can wait longer without every other launch
  paying for it — `--screens main export::6` settles 6s on `export` and `--settle`
  everywhere else. An empty stage keeps the default (stage == name). `--settle` is
  now the default rather than the only value.
- **Frame-poll settle.** After the floor, capture now polls frames and waits until
  the window holds still — two consecutive matching captures — instead of trusting
  a fixed sleep. The frame that proves it is the screenshot, so nothing is
  re-captured. Bounded by the new `--settle-max` (default 8s). A capture that never
  held still is marked `!` and reported: it was photographed mid-change and will
  gate flakily.

### Changed

- **`--settle` now defaults to 1.0s, down from 2.5s.** It is a floor before the
  frame poll rather than the entire wait, so it no longer has to be sized for the
  slowest screen. A screen whose data lands later than the floor needs its own
  settle (`export::6`) — the poll cannot distinguish a finished window from one
  that has not started, since an empty state is perfectly still.
- A malformed `--screens` entry (`export:pane:six`, an empty name) is now an error
  before anything launches, instead of being read as a stage name.

## [0.1.0] - 2026-07-19

First tagged release. Extracted from the three apps that drive it — swift-d1,
swift-r2 and silhouette — which had been running it from a local clone on
`$PATH` with no version to pin against.

### Added

- **`capture`** — relaunches the app once per screen, staged by a launch
  argument, and photographs its window with transparency intact. Matches the
  window strictly by pid, never by name, so it cannot photograph the
  developer's own running copy of the app with their real data in it.
- **`check`** — gates the captures against accepted goldens. Beyond pixel
  drift it catches two failures a diff alone cannot: near-identical captures,
  which are the tell that a staging argument did nothing, and screens missing
  from the set, which only the config knows should have existed.
- **`accept`** — promotes captures to goldens, refusing when a golden has no
  candidate unless `--prune`, so a capture that stopped early cannot silently
  erase a screen from the baseline.
- **`selftest`** — synthesizes mutants and proves the gate rejects them, so a
  green `check` means something.
- **`compose appstore` / `website` / `both`** — frames captures onto gradient
  backgrounds with real CoreText-typeset captions for the App Store, and emits
  bare downscaled captures for a marketing site. `website` renders one or more
  appearances.
- **`run`** — the whole chain, stopping at a failed gate rather than composing
  the drift it just caught.
- **`extract`** — pulls screenshot attachments out of an `.xcresult`, for
  projects capturing from an XCUITest rather than the staged shell driver.
- **`doctor`** — checks the things that fail silently: missing font, missing
  Screen Recording permission, invalid config or output size.
- **iOS store sizes** alongside the four Mac ones, in both orientations.
- **`--version`**, which also gives `make install` something real to print.

### Changed

- **Captions are typeset, not estimated.** The JavaScript/librsvg pipeline this
  replaces guessed advances with `approxCharWidth = fontSize * 0.52` and
  silently substituted a missing font. CoreText knows real advances, and
  `Text.font` now throws `fontNotResolved` rather than rendering the wrong
  typeface.
- **`background.angle` means what it says. Re-check your goldens.** The JS
  original fed the angle to an SVG `gradientTransform` in objectBoundingBox
  units, which the renderer then skewed by the canvas aspect ratio: `angle: 145`
  measured about 135° on the actual output. A config carried over verbatim
  renders a slightly different — and now predictable — gradient than its old
  composites.

### Fixed

- Capture photographs the app window rather than a bare sheet, with window
  tabbing pinned so a stray tab bar cannot appear mid-run.
- XCTest attachment names are de-mangled on extract, and a launched app is
  never leaked when a capture fails.
- Git LFS pointers are rejected before the hash fast path rather than at decode
  time, so a golden stored as a pointer fails loudly instead of comparing equal
  to itself.
- `run` assigns every option on the commands it drives. The pipeline now runs
  through plain functions over option structs with no default parameter values,
  so a newly added knob is a compile error at every construction site instead of
  a trap 90 seconds into a capture.
