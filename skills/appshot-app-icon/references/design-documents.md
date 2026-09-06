# Reading the icon's real settings out of the design document

An icon that was drawn in Pixelmator, Sketch or Figma and exported to PNG has two
descriptions: the export, and the document that produced it. **Measuring the export answers
a different question than reading the document.** A raster tells you what a pixel ended up
being; it cannot tell you what that pixel *is*, and every effect it carries has already been
flattened into its neighbours.

So when a project needs its icon rebuilt — migrating to `.icon`, recovering a lost vector,
matching artwork nobody has the source for — look for the document first. `assets/read-pxd.py`
does it for Pixelmator:

```bash
python3 ${CLAUDE_SKILL_DIR}/assets/read-pxd.py MyIcon.pxd            # layers, fonts, styles, gradients
python3 ${CLAUDE_SKILL_DIR}/assets/read-pxd.py MyIcon.pxd --flags    # the same, as appshot flags to paste
```

## What measuring gets wrong

Not hypothetical. On the document this script was written against, careful measurement —
fitting profiles, solving for alpha, cross-checking against a reconstructed plate — got three
things wrong, and **not one of them looked wrong on screen**:

| measured | actual, per the document |
|---|---|
| long shadow stepping `(24, 27)` | three copies at **exactly 315°**, distances 64/128/192 |
| a warm `#EDAA70` band read as a feathered edge | the plate's own `#F6821E`, cast as an **inner shadow** at 0.70 |
| glyph tracking `0.014em` | **0** — an inner shadow had eaten ~10px off the bottom of the white, and a shorter box reads as a wider face |

The third is the instructive one, and it generalises: **an effect that erodes an edge
corrupts every measurement taken from that edge.** Fitting a font by its white pixels'
aspect ratio is sound reasoning applied to a box that the artwork itself had already moved.

Exporting the document to SVG does not rescue this. The export bakes effects into paths or
into a filter approximation, and the parameters — the thing you actually want — are gone.

## The format

Verified against Pixelmator Pro 4.0 documents. A `.pxd` is a **zip**, and the interesting
member is a **SQLite database**:

```
MyIcon.pxd                      zip archive
  metadata.info                 SQLite
    document_info(key, value)   canvas size, guides, slices
    document_layers             id, identifier, parent_identifier, index_at_parent, type
    layer_info(layer_id, key, value)
                                name, position, size, scale, transform,
                                styles-data, text-stringData, shape-shapeData
  data/…                        pixel tiles, one blob per raster layer
  QuickLook/                    preview
```

`type` in `document_layers` is 2 = text, 3 = shape, 4 = group.

Most values are wrapped in a small container: the 4-byte magic `4-tP`, a 4-byte type tag, a
little-endian `uint32` length, then the payload. Two details that will bite:

- **Numbers inside are big-endian doubles**, unlike the little-endian length in front of them.
- **Strings carry their own `uint32` count** and are padded to a multiple of four, so the
  payload is not the string.

`styles-data` is plain JSON and needs no unwrapping beyond the container.

## The styles

`styles-data` holds one array per effect group, and **`"E": 1` means enabled** — a document
usually carries disabled styles that are not in the artwork, so filter on it or you will
reproduce effects nobody can see.

### Hidden layers are the trap, and `E` will not save you

Enabled is not visible. **A layer renders only if bit `0x1` of its `flags` word is set on the
layer *and on every ancestor*** — checking the layer alone is not enough, because what hides
a draft is usually its group.

This is not a corner case. Icon documents get made by duplicating the last one, so they carry
whole hidden groups holding the *previous product's* artwork, styles still enabled and
indistinguishable from the real thing. One of the two documents this was written against has
a hidden group whose layers are literally named `R2` — a different app — carrying a full set
of inner shadows in that app's accent colour. Read naively, a tool emits those, and the
result is plausible: five well-formed effects, in a colour that is nearly right.

`read-pxd.py` resolves the whole ancestor chain and skips what the document hides;
`--include-hidden` shows them if you want to see what a file is dragging around.

| key | meaning | fields |
|---|---|---|
| `S` | drop shadow | `a` angle (radians), `d` distance, `b` blur, `o` opacity, `c` colour |
| `i` | inner shadow | same |
| `f` | fill | `c`, or `g` for a gradient with `gSP`/`gEP` endpoints |
| `s` | stroke | as fill, plus `W` width |

Angles are radians: `4.712389` is 270°, `5.497787` is 315°.

A text layer's font is buried further: `text-stringData` is JSON wrapping a base64
`NSKeyedArchiver` plist of the `NSAttributedString`. Inside, `font-style-data` reads
`[1,{"b":1,"n":"SFProRounded-Regular","s":1024}]` — and **`b` selects the Bold face**, it is
not a synthetic embolden, so match against the real Bold cut rather than hunting for outset
metrics that do not exist. Tracking is the sibling `character-spacing` attribute.

## Converting to appshot

Two conversions, both easy to forget, both silent:

1. **Canvas.** Distances and blurs are in the document's own pixels; appshot's are per 1024.
   Scale by `1024 / canvas_width` — a 2048 document halves.
2. **Blur.** appshot's `blur` is the Gaussian standard deviation, SVG's `stdDeviation`. A
   design tool's blur slider quotes roughly **2σ**, so halve it again.

`--flags` does both. Sanity-check the result by rebuilding and diffing against the export;
the numbers being right does not prove you read the units right.

## Locating the artwork on the plate

The document gives you the effects; it will not hand you the mark's box on a 1024 plate as
directly, because layer `position` and `size` are in document space and sit under a stack of
group transforms. There is a shortcut that avoids all of it, and it is more robust than
measuring the glyph:

**Take the box from the union of mark plus long shadow.** A long shadow only travels one
way — down-right, typically — so the union's top-left corner *is* the mark's own, and its
bottom-right is the mark's plus the largest shadow offset, which the document states exactly.
Subtract it. That route never touches an edge an inner shadow has eroded, which is precisely
where measuring the mark directly goes wrong.

## Other tools

The principle carries even though the file formats do not:

- **Sketch** — a zip of JSON. `document.json` and `pages/*.json`; layer styles are readable
  without any decoding.
- **Figma** — no local document; use the REST API's node `effects` array, which names
  `DROP_SHADOW` / `INNER_SHADOW` with radius, offset and colour.
- **Photoshop** — layer effects live in the `lfx2` descriptor of the PSD's layer records.
  Harder; `psd-tools` in Python reads them.
- **Affinity** — closed binary, no practical reader. Export a layered TIFF or re-derive.

Whatever the source, the rule is the same: read the parameters, convert the units once, and
verify by rebuilding rather than by trusting the arithmetic.
