---
name: appshot-app-icon
description: Author, resize, fix or audit the app icon for an Xcode app (macOS, iOS) — the artwork itself, its `.appiconset` or Icon Composer `.icon` bundle, and the favicon/OG/touch-icon variants a marketing site renders from the same source. Use this skill whenever the user says their icon looks small, cramped, oversized, off-centre, blurry, or "not like other apps"; asks about icon padding, margins, the safe area, the squircle, corner radius, or full-bleed artwork; mentions Icon Composer, a `.icon` bundle, `icon.json`, `AppIcon.appiconset`, `actool`, `iconutil`, `.icns`, or `appshot icon build`; or wants to adopt the macOS 26 / Tahoe icon system, add dark/tinted/clear variants, or migrate a legacy icon set. Reach for it especially when the complaint is comparative ("smaller than the other icons in my Dock") — the usual diagnosis is wrong, and the measurement that settles it is here. Also use it when an icon change has to reach a website's favicon, apple-touch-icon or OG card from the same artwork, when the same geometry has been hand-copied into several SVGs and drifted, or when a store upload is rejected with a missing-icon error like 90236.
---

# Apple app icons

Icon work goes wrong in a specific way: the artwork looks fine in isolation, and wrong next to
its neighbours. Every judgement here is *comparative*, and the platform sits between your file
and what the user sees — masking it, scaling it, adding a shadow. So the rule that matters most:

**Never reason about what the OS renders. Measure it.** The pipeline from PNG to Dock is not
the identity function, and on macOS 26 it changed in a way that inverts the obvious diagnosis.
`assets/render-icon.swift` asks macOS for the composed icon of any bundle; `assets/measure-icon.py`
turns that into numbers. Use both before proposing a fix and again after applying one.

## Start by measuring, not by looking

When someone says "my icon looks small", there are two very different causes and they need
opposite fixes:

1. **The plate is small in the canvas** — the artwork carries a transparent margin.
2. **The glyph is small in the plate** — the artwork fills the canvas, but the logo inside it
   is timid.

These are indistinguishable by eye and trivial to tell apart by measurement. Run:

```bash
swiftc -O assets/render-icon.swift -o /tmp/render-icon
/tmp/render-icon /Applications/YourApp.app /System/Applications/Notes.app \
                 /System/Applications/Music.app /System/Applications/Podcasts.app
python3 assets/measure-icon.py rendered_*.png
```

Include three or four peers you consider well-drawn. The script reports, per icon, the opaque
plate size and the glyph extent as a fraction of the plate. Compare rows, not absolutes.

## The macOS 26 grid change

This is the fact that makes the obvious diagnosis wrong, so internalise it before touching artwork.

**Before macOS 26**, an app icon was authored as an 824×824 rounded square centred in a 1024×1024
canvas. The 100px gutter was real: macOS asked artwork to carry room for its own drop shadow, and
drawing edge-to-edge produced an icon visibly larger than its neighbours.

**From macOS 26 (Tahoe)**, the system masks every icon to its own squircle and draws the shadow
itself. The gutter is dead space. But — and this is the part that surprises people — macOS
*normalises legacy artwork anyway*. A 824-inset icon and a full-bleed icon render at **the same
size in the Dock**. Verified by measurement on 26.6: an app shipping the old inset grid rendered
its plate at exactly the same pixel size as Notes, Music, Podcasts, Terminal, App Store and
Reminders, and full-bleeding the source changed that number not at all.

Two consequences worth stating plainly, because they cut against intuition:

- **Removing the margin will not make the icon bigger in the Dock.** If someone's complaint is
  "smaller than other apps", the margin is almost certainly not the cause. Measure the glyph
  ratio instead.
- **Full-bleed authoring is still correct**, just for other reasons: it is what Icon Composer
  requires, it is what the file *looks* like when inspected, and it is what web and store
  contexts render without a system mask to save them. Do it — just don't promise a size change.

Deployment target decides how much this matters. Check it before advising:

```bash
grep -n "MACOSX_DEPLOYMENT_TARGET\|IPHONEOS_DEPLOYMENT_TARGET" *.xcodeproj/project.pbxproj | sort -u
```

An app targeting 26 and nothing older can go full-bleed and adopt `.icon` freely. An app still
supporting 15 or earlier renders unmasked on those systems, where a full-bleed square really does
look oversized and unrounded — there, keep a rounded plate rather than a square one.

## Glyph-to-plate ratio is usually the real answer

When an icon reads small next to its peers, this is almost always why. Measured on macOS 26.6,
as a fraction of plate width:

| icon | glyph width | note |
|---|---|---|
| Music, Podcasts, Notes, Terminal | ≥80% | content runs to or past the measurement window |
| App Store, Reminders | ≥80% wide, ~72% tall | |
| a well-drawn third-party icon | ~72% × 77% | |
| the icon that prompted this skill | **58% × 36%** | reads as an island in a large field |

Treat **70–80% of plate width** as the target band for a centred glyph. Below ~65% the icon
starts looking timid; past ~85% the outer elements crowd the squircle's corner curve, which is
tighter than the plate's own corners.

Height is not symmetric with width. A wide, short mark (a waveform, a wordmark) will land far
below 70% vertically and that is fine — fit is driven by the constraining axis. Do not inflate a
short mark to hit a vertical number; you will overshoot horizontally.

**Watch for compounding shrink factors.** A glyph can be small for more than one reason at once,
and fixing only the outer one leaves it small. Two common ones:

- A tool's "mark fraction" parameter is often a fraction of the **canvas**, while the plate is
  only ~80% of the canvas. A 0.47 canvas fraction is a 58% *plate* fraction — the same number
  reads very differently depending on the denominator.
- The mark's own artboard often carries slack. A mark drawn in a 52×40 box that only inks
  `y=4..36` wastes 20% of its fitted height before anything else happens.

Multiply them out before choosing a new value, and verify by measurement rather than arithmetic.

## Choosing the icon format

| situation | use |
|---|---|
| deployment target is macOS 26+ / iOS 26+ | Icon Composer `.icon` — the supported path; gets light/dark/tinted/clear for free |
| must support older OS versions | `.appiconset` (PNG slots) |
| migrating, want one step at a time | `.appiconset` full-bleed first, `.icon` after |

`.appiconset` still works on 26 — it is not deprecated out from under you — so a full-bleed
`.appiconset` is a legitimate resting point, not merely a waypoint.

**`appshot icon build` writes either one**, picked by the `--out` extension, and audits what it
wrote. So the choice above is a one-flag difference rather than a different pipeline. The one
thing a migration must not carry across is `--mark-fraction`: it is measured against the canvas,
and the canvas *is* the plate in a `.icon` while being 1024/824 of it in an `.appiconset` — so
the same number shrinks the mark by a quarter. Multiply by 1024/824 ≈ 1.243, and read the
composed-plate figure the command prints instead of re-deriving it.

For the `.icon` format — the verified `icon.json` schema, layer requirements, `actool`
invocation, Xcode wiring, and why the emitted `.icns` looks truncated — read
`references/icon-composer.md`. For driving appshot, read `references/appshot-icon.md`.

For generating an `.appiconset` from one mark with `appshot`, including the flag combination that
produces full-bleed output, read `references/appshot-icon.md`.

## The duplicated-geometry trap

Icon artwork has a strong tendency to exist in N places: a design SVG, a second treatment SVG, a
website's hand-written favicon, a script that crops one into another. Each copy hardcodes the same
coordinates. Nothing checks they agree, so they drift silently — and the drift is invisible
because each file looks self-consistent.

Before changing any icon geometry, find every copy:

```bash
grep -rn 'viewBox\|width="1024"\|rx="' --include=*.svg . | grep -v node_modules
grep -rn '824\|1024' --include=*.mjs --include=*.js --include=*.py scripts/ 2>/dev/null
```

Then either update all of them in the same change, or better, propose collapsing them to one
generated source. When a file becomes a *build input* (a tool reads it to produce the icon set),
duplication stops being untidy and becomes a correctness bug — say so, because that argument
usually lands where "this is duplicated" does not.

**A crop that strips a margin is the classic casualty.** Sites often re-cut an icon's viewBox to
remove the macOS gutter before rasterising a favicon. Against full-bleed artwork that same crop
shaves the plate's own edges off. Any time you full-bleed a source, search for crops keyed to the
old geometry.

## Derived variants

One source, several contexts, and the masking rules differ:

- **favicon** — crop nothing if the source is full-bleed. Keep the rounded plate; browsers do not
  mask. Check it at actual size, magnified, not just scaled down.
- **apple-touch-icon** — iOS applies its own mask. Feed it a **square** plate (radius 0) so the
  system's rounding is the only rounding. A rounded source gets double-rounded and leaves a
  visible sliver at each corner. Prefer squaring the plate over flattening onto a flat background
  colour: flattening fills the corners with one colour and breaks a gradient that should run into
  all four.
- **OG / social card** — composited at small size on a light page; the glyph ratio matters more
  here than anywhere.

## Verification checklist

Before calling an icon change done:

- [ ] **Rebuild.** The icon is compiled into the bundle; the old one renders until you do.
- [ ] **Re-render and re-measure** against the same peers as the baseline. State the before/after
      numbers rather than "looks better".
- [ ] **Check the file itself** — opaque bounding box, and the corner and edge-midpoint pixels.
      Edges opaque + corners transparent means a rounded full-bleed plate; both opaque means square.
- [ ] **All slots present.** An `.appiconset` whose `Contents.json` declares ten slots while
      holding no images builds, runs, and shows a blank icon nobody notices — until the store
      rejects the upload with *"Missing required icon"* (error 90236).
- [ ] **Small sizes still read.** Magnify the 16px and 32px renderings; bars and fine detail merge
      first.
- [ ] **Every derived copy regenerated** and any stale crop removed.

macOS caches icons aggressively. If a rebuilt bundle still renders the old icon, re-register it:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /path/to/App.app
```

Note that `NSWorkspace.icon(forFile:)` returns a *generic* icon for bundles LaunchServices will
not resolve — unsigned stubs, or bundles outside a known location. A suspiciously non-square
result (e.g. a portrait aspect) means you measured the generic document icon, not the app's.
Test against real built bundles.
