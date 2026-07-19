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
