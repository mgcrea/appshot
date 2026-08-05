# Changelog

All notable changes to appshot are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Note for anyone upgrading: a release that changes composed output is called out
under **Changed** with a **re-check your goldens** warning. Those are the ones
that drift every consuming project's baseline at once, and the cost shows up as
a red `appshot check` with no obvious cause.

## [Unreleased]

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
