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
