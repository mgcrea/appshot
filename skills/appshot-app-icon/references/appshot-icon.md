# `appshot icon` — generating an icon from one mark

`appshot icon build` renders a macOS app icon from a single piece of artwork. It owns the
mechanical half — the grid, exact pixel sizes, the manifest — which is identical for every
project, so it does not belong in a per-project script.

Notes below verified against appshot 0.9.0. Check `appshot icon build --help` for the version in
front of you; flags change.

```
--from <path>              the artwork: .svg, .pdf or bitmap. Aspect-fitted and centred.
--out <path>               the .appiconset or .icon directory — the extension picks the format
--plate <#RRGGBB>          plate colour behind the mark. Omit for artwork carrying its own.
--plate-gradient <a,b,…>   gradient plate stops; overrides --plate
--plate-angle <deg>        gradient angle, clockwise, y-down (default 45)
--tint <#RRGGBB>           fill the mark's shape with this colour instead of its own
--mark-fraction <f>        fraction of the canvas the mark spans (default 0.46875)
```

`appshot icon check --out <path>` audits either format, and `doctor --app-icon <path>` folds it
into the rest. Worth wiring into a release checklist — an `.appiconset` declaring ten slots while
holding no images builds and runs, and only the store objects.

## The `--out` extension picks the format

There is no `--format` flag. The path already says which one it is, and a flag that could
disagree with it is how a full-bleed layer ends up inside an `.appiconset`.

| | `.appiconset` | `.icon` |
|---|---|---|
| images | ten slots, 16–1024px | one 1024px layer |
| plate | 824pt rounded square on a 1024 canvas | square, edge to edge |
| corners | transparent | **opaque** |
| use when | supporting macOS 15 or earlier | deploying to macOS 26+ |

A `.icon` build takes the same flags; only the output differs:

```bash
appshot icon build --from design/mark-on-dark.svg \
    --plate-gradient '#7c7a72,#403e39' --plate-angle 71 \
    --mark-fraction 0.708 --out App/App.icon
```

That writes `App.icon/icon.json` and `App.icon/Assets/1024.png`, then audits what it wrote: the
manifest names a layer, the layer is 1024×1024 square, and every one of its pixels is opaque.
That last check is the migration guard — `.appiconset` artwork dropped into a `.icon` is a valid
PNG at the right size, and opacity is the only thing that tells them apart.

**Both formats print the composed-plate fraction**, which is the number worth reading:

```
mark spans 70.8% of the composed plate (peers sit at 70–80%)
```

### Migrating an existing icon

1. Multiply `--mark-fraction` by 1024/824 — see the denominator section below. `0.57` → `0.708`.
2. Point `--out` at a `.icon` path **inside the target's folder group**. In an Xcode 16+ project
   using `PBXFileSystemSynchronizedRootGroup`, a bundle left beside the `.xcodeproj` is not in
   the target at all: it compiles to nothing and the app falls back to the generic icon, which
   is easy to mistake for a broken icon rather than a missing one.
3. Set `ASSETCATALOG_COMPILER_APPICON_NAME` to the bundle's base name (`App.icon` → `App`).
4. Rebuild, `lsregister -f`, then render and measure against peers.
5. Delete the `.appiconset` only once that measurement is in.

## Two ways to drive it

### Composed: bare mark + plate flags

The tool draws the plate on Apple's 824-on-1024 grid and centres the mark on it.

```bash
appshot icon build --from design/mark-on-dark.svg --plate '#0b0b0c' \
    --mark-fraction 0.62 --out App/Assets.xcassets/AppIcon.appiconset
```

This yields a **100px transparent margin** on every side — the pre-macOS-26 convention. Correct
for apps still supporting macOS 15 and earlier.

### Full-bleed: pre-plated artwork at fraction 1.0

To emit artwork that reaches every edge, hand appshot art that already carries its plate, omit
the plate flags, and set the fraction to 1.0:

```bash
appshot icon build --from design/icon-ink.svg --mark-fraction 1.0 \
    --out App/Assets.xcassets/AppIcon.appiconset
```

Verified: opaque bounding box `(0, 0, 1024, 1024)`. A 1024-square source aspect-fits into
`1.0 × 1024`, so appshot only rasterises the slots — it composes nothing. Anything below 1.0
reintroduces a margin.

This shifts responsibility: the plate's colour and **corner radius now live in your artwork**, not
in a flag. Scale the radius when you scale the plate — going from an 824 plate with `rx="185"` to
a 1024 plate means `rx = 185 × 1024/824 ≈ 230`.

## The `--mark-fraction` denominator trap

`--mark-fraction` is a fraction of the **1024 canvas**, but the visible plate is only 824 of it.
So the number understates how large the mark looks:

```
plate fraction = mark-fraction × 1024 / 824 = mark-fraction × 1.243
```

The default `0.46875` (480/1024) is therefore **58% of the plate**, against a 70–80% target band.
This is the most common reason an appshot-generated icon reads timid. Useful values:

| `--mark-fraction` | % of the 824 plate |
|---|---|
| 0.46875 (default) | 58% |
| 0.56 | 70% |
| 0.62 | 77% |
| 0.68 | 85% |

With full-bleed artwork the denominator problem disappears — plate and canvas are the same thing —
but the *artwork* must then place the glyph at the target fraction itself.

## Computing glyph coordinates

When artwork is a hand-written SVG rather than a composed mark, derive the coordinates rather than
eyeballing them; a wrong transcription is invisible until someone measures. For a mark of size
`SRC_W × SRC_H` aspect-fitted to fraction `F` of a 1024 canvas and centred:

```python
S     = F * 1024
scale = S / SRC_W                    # if SRC_W > SRC_H (width-limited)
rh    = SRC_H * scale
left  = (1024 - S) / 2
top   = (1024 - rh) / 2
# a rect (x, y, w, h) in mark space becomes:
X, Y, W, H = left + x*scale, top + y*scale, w*scale, h*scale
```

Sanity-check the result against the tool's own output by measuring both. If they disagree, the
model is wrong, not the tool.

## Keeping artwork and tool in agreement

If the project also hand-maintains 1024 SVGs that *duplicate* what appshot computes, they will
drift — nothing checks them. Two stable arrangements:

- **Artwork is the input** (full-bleed, fraction 1.0). The SVG is authoritative; appshot only
  resizes. Preferred, because there is one geometry.
- **Tool is the input** (bare mark + plate flags). Then no plated SVG should exist at all; derive
  web assets from the generated PNGs instead.

The unstable arrangement is both at once. If a project generates its bare marks from a script
holding the canonical geometry, having that same script emit the plated icons closes the gap
permanently.
