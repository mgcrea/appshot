# `appshot symbols` and the `appshot-symbols` skill — design

Approved by Olivier on 2026-11-24, in the Maquette session that redesigned its timeline.

## 1. Intent

The fleet's apps need glyphs of their own: Maquette's features (Extrude, Fillet, Revolve…),
Calque's drawing tools, four apps' menu-bar icons (Bastion, Armada, Almanac, Cupertino, each
an `.imageset` made by hand), Canopy's and Almanac's glyph views. Nothing in the fleet ships a
custom SF Symbol yet. Calque's rail (`ToolIcon`) and Maquette's (`SketchToolGlyph`) both
fake two tones by laying accent dots over stock symbols, and Maquette's file is a copy of
Calque's.

`appshot icon` already splits app icons in two: the mark is the project's own design, and
the tool does the mechanical part (the grid, the slots, the manifest) and refuses to guess at
the design. Glyphs want the same split:

- **`appshot symbols`**: layered drawings in, valid `.symbolset`s out, checked, with a
  contact sheet rendered by the OS itself.
- **The `appshot-symbols` skill**: when to draw a custom symbol at all, the fleet's two-tone
  rule, how to set up a family's drawing grid, the SF Symbols template's traps, and the review
  that comes before anything is wired into an app.

Maquette's feature glyphs are the pilot and the first user
(`~/Projects/apps/maquette/docs/specs/2026-11-24-feature-glyphs-and-timeline-design.md`);
Calque's rail is the second.

## 2. Goals, non-goals, anti-goals

Goals:
- A repo keeps simple layered SVGs (or a generator that writes them) as the source of truth;
  `.symbolset`s are build output, regenerated, never edited by hand.
- What comes out works where SF Symbols work: `Image(_:)`, `Label(_:image:)`,
  `NSImage(named:)` in an `NSMenu`, toolbars, palette, hierarchical and monochrome rendering.
- The contact sheet shows what macOS draws, not what a guess at it draws.
- A CI-friendly `check` that fails when an asset drifted from its source.

Non-goals:
- Drawing the glyphs. As with `appshot icon`, what is in the mark is per project.
- Multicolour rendering, variable values (`variableValue`), animation presets, iOS-only
  concerns. Later, if an app needs them.
- Replacing the SF Symbols app for a designer who draws in it; `check` still works on a
  hand-made `.symbolset` (§4.3).

Anti-goals:
- A symbol that Xcode accepts but renders wrong (clipped, misaligned with text, the wrong
  layer tinted): the template's margins and baselines are exactly where custom symbols
  usually fail, and the tool exists to get them right every time.
- A sheet that renders the source SVG instead of the compiled symbol, and so hides those
  failures.

## 3. The source format

One SVG per glyph, `<name>.svg`, on a square design box (`viewBox="0 0 100 100"`; the box is
the symbol's cap-height square, see §4.1):

- Three groups by id, each optional except `outline`: `outline` (layer 1, foreground),
  `touch` (the accent), `wash` (low-opacity fill). Their order in the palette is
  primary = outline, secondary = touch, tertiary = wash, so an app sets
  `.foregroundStyle(.primary, .tint, .primary.opacity(x))`. Hierarchical rendering gives the
  same three their usual primary, secondary and tertiary opacities.
- Inside a group: `path`, `line`, `polyline`, `polygon`, `rect`, `circle`, `ellipse`, with
  `transform`s, `stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-dasharray`
  and `fill`. Anything else (text, gradients, filters, `use`, clip paths, masks) is refused
  by name, with the file and the element, not dropped.
- Strokes are drawn as strokes. The tool outlines them (`CGPath.copy(strokingWithWidth:…)`,
  dashes by `copy(dashingWithPhase:lengths:)` first), because a symbol template holds filled
  paths only.
- **Knockout, per element**: an element of `touch` marked `data-knockout="true"` cuts the
  outline away under it (§4.1, Stacking); one not marked is drawn flush over the outline. A
  badge or an arrow is marked; a touch that is a face of the drawn solid (a fillet's rounded
  edge, a chamfer's bevel, an extrude's top) is not, since a gap there would break the
  silhouette where the face meets its edges. Unmarked is the default, and the sheet is where
  each choice is judged.
- A `symbols.json` beside the SVGs names the family's settings: the stroke width at Regular
  (default: SF's Regular stroke for the box), the asset folder to write into, a prefix for
  asset names if any, the stock symbols the family sits with, the sheet's variant columns
  (each a name, the three palette colours and a tile background, e.g. Maquette's "selected"
  and "refused"), and the reference images the sheet places beside the glyphs, by paths that
  may lie outside the repo.
- A lock file, `symbols.lock.json`, beside the sources, written by `build` and committed: for
  each asset it wrote, its name, a fingerprint of its source SVG and of the `symbols.json`
  settings that bear on it, appshot's geometry version, and a hash of the template SVG it
  wrote. It lives with the sources and not in the asset catalogue, so Xcode's asset editor,
  which rewrites a `Contents.json` it touches, never drops it.

## 4. The command

### 4.1 `appshot symbols build --from design/glyphs --out App/Assets.xcassets/Glyphs`

For each SVG: parse the subset, outline, and write `<name>.symbolset/` with its
`Contents.json` and a template SVG in the current template format (template writer version
as the SF Symbols app's own templates carry it; copies of those ship in
`/Applications/SF Symbols.app/Contents/Resources/*.svg`, which are the reference for the
format: the `Notes` group, the guides, the `Symbols` group, the class names
`monochrome-N`, `hierarchical-N:primary|secondary|tertiary`).

- **Placement**: the design box is mapped to the template's cap-height and baseline guides
  for the Regular-M slot, so a glyph sits on the text baseline as a letter does and is as tall
  as a capital, the way SF Symbols align in a `Label`. The margins left and right come from
  the outlined paths' bounds, as the template's left and right margin guides want.
- **Weights**: milestone 1 writes Regular-M only, which Xcode accepts and uses at every
  weight and scale. Tried with `actool` on 2026-11-24 (the builder check): a template holding
  Regular-M alone compiles once its left and right margin guides are named
  `left-margin-Regular-M` and `right-margin-Regular-M` and the S margin guides are gone; all six
  baseline and cap-line guides (Baseline-S/M/L, Capline-S/M/L) stay, or `actool` refuses the
  file, naming the first one missing. Regular-S alone is refused ("must have a glyph for
  Regular weight Medium size"). Of the template's `Notes` group only its `template-version`
  text ("Template v.4.0") is required, and it is: without it the file compiles but is read as
  an older template, whose monochrome ignores a class's `opacity` and draws the wash solid
  black. No `multicolor-N` classes are needed. The Resources
  templates hold the three S masters only, so they are the reference for the file's
  structure, not for which slots to write. The later milestone writes Ultralight-S, Regular-S
  and Black-S, the three interpolation masters, by outlining the same geometry at three stroke
  widths, and still writes Regular-M; it ships only if the three outlines interpolate (same
  path structure), which the build checks and refuses otherwise. Unclear before trying; it
  may be dropped.
- **Overhang**: the 100 by 100 box is the reference square, cap height above the baseline,
  not a limit. A drawing may run past it, outlined stroke included, as stock symbols run below
  the baseline and above the cap line (`cube`, `circle`); the build places what overhangs
  where the box puts it and the margins come from the outlined bounds. It warns, naming the
  glyph, past 50 box units on any side, a drawing then likely on the wrong scale. Not 20 %:
  a glyph that only fills the box renders at 13 points where `cube` renders at 17 under the
  same configuration, since stock symbols overhang the cap-height box by about 30 units, so a
  family meant to sit beside them overhangs about as much, and only a larger overhang points
  to a wrong scale. The
  family's grid in the repo decides how far its glyphs reach; Maquette's matches `cube`'s.
- **Stacking**: wash, then outline, then touch. Where a touch element marked for knockout (§3)
  lies over the outline it cuts the outline away, with a gap of half the stroke width round the touch, as SF Symbols' own
  badges are cut out of what they sit on: in hierarchical rendering the touch is drawn at
  secondary opacity, and over a full outline it would read as the outline. Done as
  geometry (the outline's fill minus the touch's outline grown by the gap, both as
  `CGPath`s, `CGPath.subtracting(_:)`), not `-sfsymbols-clear-behind`, so the sheet and every
  rendering mode see the same shapes.
- **Layers**: each group's outlined paths become one layer, classed for monochrome and
  hierarchical; `wash` is classed as tertiary and, in monochrome, omitted
  (`-sfsymbols-clear-behind` is not used: the wash is under the outline, not cut out of it).
- **Idempotence**: on one Mac, the same sources give byte-identical output (coordinates
  rounded to two decimals). Not promised across macOS versions or machines, since the
  outlining is CoreGraphics's: so `check` compares fingerprints, not a rebuild (§4.3).
- **The geometry version**: an integer in appshot, raised by any release that changes what
  `build` writes for the same source (outlining, rounding, placement, knockout, the template
  format). The lock records it, so a release that changes the geometry marks every asset
  stale, while a release that does not leaves them alone.
- It writes the lock (§3), deletes the `.symbolset`s in `--out` the lock lists whose source is
  gone, and leaves any other asset alone.

### 4.2 `appshot symbols sheet --from … --assets … --out sheet.png|.html`

Compiles the asset folder with `xcrun actool` into a scratch bundle, loads each symbol with
`NSImage(symbolName:bundle:variableValue:)`, and draws it with `NSImage.SymbolConfiguration`
in palette, hierarchical and monochrome, at 13 (body text), 16, 20 and 28 points, light and
dark, with an accent other than blue in one column, beside the stock symbols the family is
meant to sit with (listed in `symbols.json`), and in each variant column `symbols.json`
names (a selected tile's swapped tones, a refused glyph's red). Each glyph also sits in a
`Label`-like row with text, so the baseline and height read against a word. Two outputs:

- the review page (`.html`), with the reference images beside the glyphs, which the skill
  publishes as a private artifact and which is never committed: references are often other
  vendors' icons (Fusion's, for Maquette);
- the PNG (`.png`), without the references, which a repo may commit.

### 4.3 `appshot symbols check --from … --out …`

Exits non-zero when a source's fingerprint no longer matches its asset's marker (the source
or its settings changed, the asset is stale), when an asset's template no longer matches the
hash in its marker (edited by hand), when a source has no asset or an asset of appshot's has
no source, when the lock's geometry version is older than appshot's, when a source falls
outside the subset, and when `actool` rejects the folder.

It never regenerates to compare, so its source-and-lock part gives the same answer on any Mac
and any macOS; whether a rebuild is byte-identical on one Mac is appshot's own test, not
`check`'s. Its `actool` part depends on the Xcode installed, and a newer Xcode may refuse what
an older one took: that is a real finding, reported as `actool`'s, apart from the drift
findings; `--no-actool` skips it where Xcode is absent.

`check` compares SVGs with assets. A repo whose SVGs come from a generator commits the SVGs
and guards the generator itself (Maquette's `make glyphs-check` runs it into a scratch folder
and diffs); `check` cannot see a generator that changed without its SVGs.

With `--out` alone (no sources)
it checks a hand-made `.symbolset` folder: `actool` accepts it, every symbol loads, and each
renders non-empty in all three modes. Fast enough for a `make test` (no rendering in the
source-compare path).

## 5. The skill: `skills/appshot-symbols/`

Beside `appshot-app-icon`, symlinked into `~/.claude/skills` the same way. Triggers: a custom
icon or glyph for a command, tool, feature or menu-bar item; "SF Symbols", "custom symbol",
`.symbolset`, "two-tone icon"; icons that look foreign beside system symbols; `appshot
symbols`. Not for app icons (appshot-app-icon, app-icon-exploration).

It holds:
1. **Which glyph to use**: a stock symbol when one says it; a stock symbol with a touch
   (Calque's and Maquette's rails) when the gesture's point is what matters; a custom symbol
   when no stock symbol draws the thing (a fillet, a boss, a beam).
2. **The fleet's two-tone rule**: the drawing in the foreground, the faces in a light wash, the
   touch (what the command makes, picks or removes) in the app's accent, never a fixed colour;
   on a selected tile the two swap. Every glyph must still read in monochrome.
3. **A family's grid**: one basis (flat, or isometric for 3D apps, 30° axes), one stroke width,
   shared proportions, badges in the bottom trailing corner, written once in a generator so
   the family stays one family; Maquette's `design/glyphs/` is the worked example once it
   exists.
4. **The traps**, as learnt on the pilot: template margins and baselines, outlined strokes,
   palette layer order, `NSImage(named:)` vs `NSImage(systemSymbolName:)`, toolbar items
   showing titles, the menu's template rendering, what monochrome drops, which touches are
   knocked out and which are drawn flush, dashes and thin arrows that close up once outlined.
5. **The review**: the sheet before anything is wired in, published as a private artifact,
   the person approving it, judged first at the floor (13 points, monochrome, no wash: how a
   menu draws a symbol), where families fail, and only then at tile sizes in palette; then the check by eye in the running app, light and dark, with a
   non-blue accent.
6. The command's reference (`references/appshot-symbols.md`).

The shared Swift view that draws both kinds of glyph (a custom symbol or a stock one with its
touch) with the selected swap belongs in swift-support-kit once Calque and Maquette both use
it; not in this spec.

## 6. Milestones

1. **Build, check, sheet at Regular-M**, the skill's first version: what Maquette's cycle 1
   needs. Released as an appshot minor version.
2. Maquette's glyphs through it, the skill's traps section rewritten from what that taught.
3. Three-weight masters, if they interpolate.
4. Calque's rail as the second user; the support-kit view.

## 7. Approaches considered

1. **A subcommand of appshot plus a skill (chosen)**: appshot already parses SVG for icons,
   ships skills beside its commands, and holds the "mechanics, not design" line; a Swift
   command can use CoreGraphics to outline strokes and AppKit to render what the OS renders.
2. Scripts in a skill only (Python, no package): no tests worth the name, and outlining
   strokes and rendering compiled symbols both want CoreGraphics and AppKit anyway.
3. Drawing each symbol in the SF Symbols app by hand: right for a one-off, but a family of a
   dozen drawn by hand drifts, and nothing checks it.

## 8. Left to the builder

- The SVG parsing approach (a small parser over `XMLParser` for the subset is expected;
  no new dependency without a reason).
- The sheet's exact layout.
- Whether `sheet` renders HTML by embedding PNGs or by SVG.
