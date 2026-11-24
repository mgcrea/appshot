---
name: appshot-symbols
description: Design, build, review and wire in custom SF Symbols for a Mac or iOS app, from layered SVG glyphs, with `appshot symbols build|check|sheet`. Use this skill whenever someone wants a custom icon or glyph for a command, a tool, a feature, a toolbar button, a sidebar row or a menu-bar item; mentions SF Symbols, a custom symbol, a `.symbolset`, a symbol template, `symbols.json`, `symbols.lock.json`, palette or hierarchical rendering, or a "two-tone icon"; says the app's icons look foreign, clip-art-like, too small or misaligned beside the system's symbols or the text of a label; wants a family of glyphs drawn by a generator (`design/glyphs/`); or is faking two tones by laying dots over stock symbols. Reach for it before drawing anything, since the first question is whether a stock symbol already says it, and before wiring a glyph in, since the sheet review comes first. Not for app icons, which belong to appshot-app-icon and app-icon-exploration.
---

# Custom SF Symbols

A custom symbol goes wrong where nobody looks at it: beside the system's own symbols, at the
size a menu draws it, in the mode that drops a layer. In isolation, at 64 points, in colour,
every glyph looks fine. So the rule that matters most:

**Judge a glyph only as macOS draws it, beside the symbols it will sit with, and first at the
floor: 13 points, monochrome, no wash.** `appshot symbols sheet` compiles the assets with
`actool` and draws what AppKit draws, never the source SVG, because the margins, baselines and
layer classes are where custom symbols fail, and a picture of the source hides all three.

The tool does the mechanical half: outlining strokes, placing the box on the baseline and cap
line, classing layers, the lock, the check. What is *in* the glyph is the project's, as the
mark is for `appshot icon`. The command's flags, the source format and every message are in
`references/appshot-symbols.md`.

## 1. Which glyph to use

Decide this before drawing anything; most commands never need a custom symbol.

- **A stock symbol** when one says it. Search the SF Symbols app by meaning, not by name.
- **A stock symbol with a touch** when the point is the gesture: the tool rails in Calque
  (`ToolIcon`) and Maquette (`SketchToolGlyph`) lay an accent mark over a stock symbol to say
  what the tool makes. That is cheaper than a family and stays native.
- **A custom symbol** when no stock symbol draws the thing at all: a fillet, a boss, a
  revolve, a beam, an app's own menu-bar mark. Then it is a family, not a one-off (§3).

## 2. The fleet's two-tone rule

Every glyph has up to three layers, and each has one job:

- **outline**, the drawing, in the foreground (`.primary`);
- **wash**, the faces, the foreground at low opacity, so a solid reads as a solid;
- **touch**, what the command makes, picks or removes, in the app's accent (`.tint`), never a
  fixed colour.

On a **selected** tile the two swap: the outline goes to the accent and the touch to the
foreground, so the touch does not sink into the tile's accent fill.

**Every glyph must still read in monochrome**, where outline and touch take one colour and the
wash is dropped. That is how a menu, a disabled button and a template image draw it. A glyph
whose meaning lives in the wash, or in the touch's colour alone, fails there.

In SwiftUI the palette order is fixed by the build: primary is the outline, secondary the
touch, tertiary the wash.

```swift
Image("feature.extrude")
    .symbolRenderingMode(.palette)
    .foregroundStyle(.primary, .tint, .primary.opacity(0.18))
```

0.18 is the wash the sheet's palette columns draw, so what was approved is what ships. Put
that in one small view so the three colours are set in one place (Maquette's spec plans a
`FeatureGlyph` that takes a tone: normal, selected, refused).

## 3. A family's grid

A family is one drawing system, written once:

- **one basis**: flat, or isometric for a 3D app (30° axes, as `cube` is);
- **one stroke width**, `symbols.json`'s `strokeWidth`, which every element without its own
  uses;
- **shared proportions**: the same solid, the same cap height, the same badge size;
- **badges in the bottom trailing corner**, as SF Symbols' own `.badge.plus` sit;
- **written in a generator** (a `gen.py` beside the SVGs) that draws every glyph from the
  shared basis, so a new glyph joins the family instead of drifting from it. Commit the
  generator, the SVGs it writes, `symbols.json` and `symbols.lock.json`.

Maquette's `design/glyphs/` is the worked example once it lands (its spec is
`docs/specs/2026-11-24-feature-glyphs-and-timeline-design.md` in that repo). A generator
the tool cannot see needs its own guard: run it into a scratch folder and diff the SVGs
(Maquette's spec plans a `make glyphs-check` for it), since `appshot symbols check` compares SVGs with assets and
nothing more.

**Draw past the box.** The 100 box is the cap-height square, a reference, not a limit. A glyph
that only fills it renders at about 13 points where `cube` renders at 17 under the same
configuration, because stock symbols overhang the cap-height box by some 30 units. A family
meant to sit beside them overhangs as much. Set the scale by putting a companion on the sheet,
not by arithmetic.

## 4. The traps

What the pilot taught. Most are silent: the asset compiles and draws, just wrong.

- **The template's guides.** `actool` wants a Regular-M glyph (Regular-S alone is refused),
  all six baseline and cap-line guides, margin guides named `left-margin-Regular-M` and
  `right-margin-Regular-M`, and the Notes group's "Template v.4.0" text, without which
  monochrome ignores the wash's opacity and draws it solid black. `build` writes all of it; a
  template copied from elsewhere and edited by hand is where these go missing.
- **One weight.** Only Regular-M is written, and Xcode draws it at every weight and scale: a
  glyph beside bold text does not get bolder. Pick the stroke for Regular.
- **Strokes are outlined.** A template holds filled paths only, so `build` turns every stroke
  into its outline. A path is filled by default, as in SVG: a stroked shape needs
  `fill="none"` or it is filled as well. An explicit `stroke-width` scales with the element's
  transform, and is refused under a skew or an uneven scale.
- **Dashes and thin arrows close up** once outlined at the family's stroke: a dash gap or an
  arrowhead narrower than the stroke fills in. Look at them at 13 points.
- **Layers by group, not by colour.** The group (`outline`, `touch`, `wash`) decides the layer;
  colours in the SVG are ignored. Palette order is outline, touch, wash.
- **Knockout, per element.** A touch marked `data-knockout="true"` cuts the outline away under
  it, with a gap of half the stroke; an unmarked one is drawn flush. Mark badges and arrows,
  which sit *on* the drawing. Leave flush the touches that are a face of the solid (a fillet's
  rounded edge, a chamfer's bevel, an extrude's top): a gap there breaks the silhouette. In
  hierarchical rendering an unmarked touch over the outline reads as the outline.
- **What monochrome drops**: the wash, always. Judge every glyph without it.
- **Loading.** A custom symbol is an asset: `Image("feature.extrude")`,
  `Label("Extrude", image: "feature.extrude")`, `NSImage(named: "feature.extrude")`.
  `Image(systemName:)` and `NSImage(systemSymbolName:)` look only in the system's symbols and
  return nothing for it.
- **Menus draw a template.** An `NSMenu` item draws the symbol in monochrome in the menu's text
  colour, at the menu's text size: the floor the sheet's 13-point monochrome column shows.
- **Toolbar items with titles** show the glyph over its label, at toolbar size; check the glyph
  there beside the stock items, not only on the sheet.
- **The sheet's PNG follows the Mac's accent colour**: two Macs write different bytes. A repo
  that commits the PNG regenerates it on one Mac, or does not commit it.

Milestone 2 (Maquette's glyphs through the tool) rewrites this list from what it teaches.

## 5. The review

Nothing is wired into an app before the sheet is approved.

1. Build, then draw the sheet:

   ```bash
   appshot symbols build --from <glyphs> --out <asset folder>
   appshot symbols sheet --from <glyphs> --assets <asset folder> --out <scratchpad>/glyphs.html
   ```

   `--out` may be left off `build` when `symbols.json` gives `"out"`. Keep `--from` on the
   sheet: it is what brings `symbols.json`'s companions, variant columns and references, and
   without it the sheet has none of them.
2. **Publish the HTML page as a private artifact** and give the person the link. It holds the
   reference images `symbols.json` lists, often another vendor's icons, so it is never
   committed and never made public; the `.png` (without references) may be committed.
3. **The person approves it.** Read it with them in this order:
   - the floor first: the 13-point monochrome column, light and dark. Can each glyph be told
     from every other, and from its companions, with no wash and no colour? Families fail here;
   - the `label` column: does the glyph sit on the baseline and stand as tall as the word?
   - then the tile sizes in palette, the non-blue (pink) accent, and each variant column
     (selected, refused).
4. Only then wire it in, and check it by eye in the running app: light and dark, with a
   non-blue accent (System Settings › Appearance), in the menu, the toolbar and the tile.
5. Put `appshot symbols check --from <glyphs> --out <asset folder>` in the repo's tests, so
   an asset never drifts from its source (`--out` may be left off when `symbols.json` gives
   `"out"`; without either, check stops with "--out is required").
