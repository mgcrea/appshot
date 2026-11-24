# `appshot symbols` — layered SVGs in, checked `.symbolset`s out

Verified against appshot 0.35.0. Check `appshot symbols <command> --help` for the version in
front of you; flags change.

```bash
appshot symbols build --from design/glyphs --out App/Assets.xcassets/Glyphs
appshot symbols check --from design/glyphs --out App/Assets.xcassets/Glyphs
appshot symbols sheet --from design/glyphs --out "$SCRATCH/glyphs.html"
```

`--out` may be left out of `build` and `check` when `symbols.json` gives `"out"`, a path read
against the sources folder (so it means the same from any working directory); a flag always
beats the file.

## The source format

One SVG per glyph, `<name>.svg`, in one folder (subfolders are not read). The asset name is
`symbols.json`'s `prefix` followed by the file name: lower-case letters and digits separated by
single dots, dashes or underscores (`feature.extrude`), so it works in `Image(_:)` and
`NSImage(named:)`.

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <g id="wash"><polygon points="…"/></g>
  <g id="outline" fill="none" stroke="currentColor" stroke-linejoin="round">
    <path d="…"/>
  </g>
  <g id="touch">
    <circle cx="82" cy="82" r="14" data-knockout="true"/>
  </g>
</svg>
```

- **`viewBox="0 0 100 100"`**, always: the box is the cap-height square, its bottom on the
  baseline. Drawing past it is expected (see Overhang below).
- **Three groups by `id`**: `outline` (required), `touch`, `wash`. Each becomes one layer;
  palette order is outline, touch, wash. Shapes outside the three groups are refused.
- **Elements**: `path`, `line`, `polyline`, `polygon`, `rect` (with `rx`/`ry`), `circle`,
  `ellipse`, inside any nesting of `<g>`. `title`, `desc`, `metadata` and namespaced elements
  are ignored; `defs` passes, but what it holds is read like anything else (a gradient or a
  clip path inside it is refused).
- **Attributes**: `transform` (`matrix`, `translate`, `scale`, `rotate`, `skewX`, `skewY`),
  `fill`, `stroke`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-dasharray`,
  `data-knockout`, as attributes or inherited from groups and the root (Figma writes
  `fill="none"` on the root; that passes down).
- **Paint means on or off only.** Any `fill` or `stroke` other than `none` turns it on; the
  colour is ignored, since the group decides the layer. `url(…)` paint is refused. As in SVG,
  a closed shape is filled unless `fill="none"`; `line` and `polyline` are not.
- **Strokes**: without `stroke-width`, an element takes the family's `strokeWidth`. An explicit
  `stroke-width` and dash lengths are in the element's user space, so they scale with its
  transform; under a skew or an uneven scale they are refused (a CoreGraphics outline cannot
  draw an anisotropic stroke).
- **Values are checked too**: a shape missing a coordinate it needs, a zero width or radius,
  a number that is not one, or an attribute value outside its list is refused with the file,
  the line, and what to give (`a.svg:3: <circle> has no r; give it one, in box units.`).
- **`data-knockout="true"`** on a touch element cuts the outline under it, grown by half the
  family stroke, round-joined. Unmarked is flush.
- **Anything else is refused by name**, with the file and line: text, gradients, filters,
  `use`, clip paths, masks, unknown attributes. Nothing is dropped silently.

## `symbols.json`

Beside the SVGs. Every key is optional; no file means every default.

```json
{
  "strokeWidth": 8,
  "sideBearing": 4,
  "prefix": "feature.",
  "out": "../../Maquette/Assets.xcassets/Glyphs",
  "companions": ["cube", "square.and.pencil", "trash"],
  "variants": [
    { "name": "selected", "colors": ["accent", "primary", "#0000001A"], "tile": "#007AFF40" },
    { "name": "refused", "colors": ["#FF3B30", "#FF3B30", "#FF3B3040"] }
  ],
  "references": ["../../.idea/design/glyphs/references/fusion-extrude.png"]
}
```

| key | default | meaning |
|---|---|---|
| `strokeWidth` | 8 | the Regular stroke, in box units; also sets the knockout gap |
| `sideBearing` | 4 | room left and right of the outlined bounds, in box units, inside the margin guides |
| `prefix` | `""` | prepended to each file name to make its asset name |
| `out` | none | the asset folder, relative to this folder |
| `companions` | `[]` | stock SF Symbols drawn below the family on the sheet |
| `variants` | `[]` | extra sheet columns: three colours in palette order, each `#RRGGBB`, `#RRGGBBAA`, `"primary"` or `"accent"`, and an optional `tile` background |
| `references` | `[]` | images for the HTML page only, relative to this folder; may lie outside the repo |

Only `strokeWidth`, `sideBearing` and `prefix` bear on the drawing, so only they are in each
asset's fingerprint: adding a companion or a variant does not make every asset stale.

## `build`

```
appshot symbols build --from <folder> [--out <folder>]
```

For each SVG: read, outline, place, and write `<name>.symbolset/` with its `Contents.json` and
a Regular-M template. Every source is read before anything is written, so one bad source
refuses the whole build and leaves the assets and the lock as they were.

- **Placement**: the box's bottom on Regular-M's baseline and its top on the cap line (cap
  height 70.459 at point size 100); the margin guides from the outlined bounds plus
  `sideBearing`.
- **Stacking**: wash, then outline, then touch; a marked touch cuts the outline (geometry, not
  `-sfsymbols-clear-behind`, so every mode and the sheet see the same shapes). The wash is
  never cut.
- **Classes**: each layer's path is `monochrome-N hierarchical-N:<role>`, N its index in
  drawing order; the role is `primary` for the outline, `secondary` for the touch, `tertiary`
  for the wash, and the palette's colours follow the roles. Monochrome gives the wash
  `opacity:0.0`, so it drops out.
- **Overhang**: a warning, on stderr, naming the glyph and the side, when the outlined glyph
  runs more than 50 box units past the box. Stock-matching families overhang about 30, so the
  warning means a drawing at the wrong scale, not a big one.
- **Idempotent on one Mac**: the same sources give the same bytes (coordinates to two
  decimals); an unchanged asset is reported unchanged and not rewritten. Not promised across
  macOS versions, since the outlining is CoreGraphics's.
- **The lock**, `symbols.lock.json`, is written beside the sources, not in the asset catalogue
  (Xcode's asset editor rewrites what it touches). For each asset: a fingerprint of its SVG and
  the drawing settings, and a hash of the template written; appshot's geometry version; and
  `out`, the asset folder it was built into, written as `symbols.json`'s `out` would be
  (relative to the sources folder). **Commit it.**
- **One folder per family**: the lock ties the sources to that `out`, so a build into another
  folder is refused, naming the one it was built for: pass that `--out`, or, to move the
  family, delete the lock (and the old folder's `.symbolset`s) and build again. A lock from
  before 0.35.0 without `out` builds as before, and the build records it.
- **No sources, no build**: a folder with no SVG is refused (`no glyph sources in <folder>`),
  rather than removing every set the lock lists; so is a `--from` that is not a folder.
- **Ownership**: `build` removes only `.symbolset`s the lock lists whose source is gone. It
  refuses to write over a set the lock does not list, unless the set already holds exactly
  what it would write (a first build, or a lost lock). Hand-made sets in the same folder are
  left alone.

Output: `✓ wrote <name>.symbolset` for each written, `✓ removed <name>.symbolset, its source is
gone`, then `N unchanged, in <out>`.

## `check`

```
appshot symbols check --from <folder> [--out <folder>] [--no-actool]
appshot symbols check --out <folder>
```

**With `--from`**, it compares every asset with its source and the lock, and never rebuilds
to compare, so that part gives the same answer on any Mac. Then it compiles the folder with
`actool`, as Xcode would. **With `--out` alone**, the folder is hand-made (drawn in the SF
Symbols app): `actool` must accept it, and every symbol must load and draw something at 16
points in monochrome, hierarchical and palette.

A check that checks nothing fails: `no glyph sources in <folder>`, or `no symbols found in
<folder>`. `--no-actool` needs `--from`. `actool` comes with Xcode, not the Command Line Tools,
and is bounded at 120 s.

Exit 0 prints `✓ <out>: N symbol(s) match their sources, and actool accepts them` (with
`(actool skipped)` under `--no-actool`), or, in hand-made mode, `✓ <out>: N symbol(s) compile
and draw in all three modes`. Otherwise
exit 1, one `✗` line per finding:

| finding | means | do |
|---|---|---|
| `the source or its settings changed since it was built` | the SVG, `strokeWidth`, `sideBearing` or `prefix` changed | `appshot symbols build`, commit the assets and the lock |
| `its template was edited by hand` | the `.symbolset`'s SVG no longer matches its hash | edit the source instead; `build` writes over the edit |
| `the source has no asset, or the lock does not list it` | a new SVG, never built, or a lost lock | `build` |
| `the lock lists this asset but its source … is gone` | a source deleted or renamed | `build` removes the asset, or restore the source |
| `built with geometry version N, and this appshot draws version M` | appshot changed what it writes | `build`, then re-run the sheet review: the shapes moved |
| `The lock ties these glyphs to <A>, not to <B>` | `--out` is not the folder the lock was built for; nothing else is reported | check `--out <A>`, or move the family: delete the lock and the old sets, then `build` |
| a source's own error (`<file>:<line>: … cannot go in a symbol`) | outside the subset | redraw that element with the subset |
| `actool refused the symbols:` | Xcode's compiler rejects the folder | fix the symbol it names; a newer Xcode refusing what an older took is a real finding |
| `<name> draws nothing at 16 points in <mode>` | hand-made mode: an empty layer for that mode | give the layer that mode shows a shape |

The `actool` part depends on the installed Xcode; the drift part does not. `check` cannot see
a generator that changed without its SVGs: guard the generator separately (run it into a
scratch folder and diff).

## `sheet`

```
appshot symbols sheet --from <folder> --out <file.png|file.html>
appshot symbols sheet --assets <folder> [--from <folder>] --out <file.png|file.html>
```

With `--from` alone, the glyphs are built into a scratch folder, without reading or writing
the lock or touching the asset folder, and that is drawn: the review of glyphs not yet built
into the app. With `--assets`, that folder is drawn instead, as built (a hand-made one, say);
an empty or missing one is refused. Either way it compiles with `actool` into a scratch
bundle and draws each symbol as AppKit loads it from there. `--from` supplies `symbols.json`
(companions, variants, references); without it there are none. The extension of `--out`
picks the output, and anything else is refused:

- **`.html`**: the review page, the sheet plus the reference images. Publish it as a private
  artifact; never commit it. It prints `holds N reference image(s); do not commit it`. A
  missing reference is refused before anything is compiled.
- **`.png`**: the sheet alone, at 2×. May be committed, but its bytes follow the Mac's accent
  colour.

Layout: one row per symbol, then the companions below a rule; a light half and a dark half,
each with these columns:

| column | what |
|---|---|
| monochrome 13, 16, 20, 28 | `labelColor` with its alpha, as macOS draws a template; no wash |
| hier. 20 | hierarchical |
| palette 13, 16, 20, 28 | `labelColor`, the accent, `labelColor` at 18 % of its own alpha (as `.primary.opacity(0.18)`) |
| pink 20 | palette with a non-blue accent |
| each variant, 20 | the variant's colours on its tile |
| label 13 | the glyph beside text, for the baseline and the height |

## Wiring it into an app

- Point `--out` at a folder inside the app's asset catalogue (`Assets.xcassets/Glyphs`); Xcode
  picks up the `.symbolset`s with no project change.
- Load by asset name: `Image("feature.extrude")`, `Label("Extrude", image: "feature.extrude")`,
  `NSImage(named: "feature.extrude")`. Never `systemName:`.
- Add `appshot symbols check --from design/glyphs --out <asset folder>` to the repo's test
  target (a Makefile line); `--out` may be left off when `symbols.json` gives `"out"`, and
  without either it stops with "--out is required". The source compare renders nothing and is
  quick; the `actool` half that runs by default takes seconds and needs Xcode. On a machine
  without Xcode, such as a CI runner, add `--no-actool`.
