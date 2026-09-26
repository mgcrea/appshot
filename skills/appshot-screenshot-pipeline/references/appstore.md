# Store dimensions and compositing

## Verify the spec before you build to it

Apple changes required screenshot sizes as devices ship, and App Store Connect rejects an image that is off by a single pixel. The numbers below are the long-stable ones, but **treat App Store Connect's own upload UI as authoritative** — it names the exact accepted dimensions per display class, and it is the thing that will reject you.

Practical consequence: make the output size a value in a config file, not a constant in the compositor.

## Mac

The Mac App Store takes 16:10, in any one of:

| Dimensions | Notes |
|---|---|
| 1280 × 800 | 1x |
| 1440 × 900 | 1x |
| 2560 × 1600 | **2x of 1280×800 — use this** |
| 2880 × 1800 | 2x of 1440×900 |

Pick 2560×1600 as the canvas.

The crispness trick is to size the app window so that its @2x capture lands **1:1 in the box the compositor will place it in** — not so that it equals the whole canvas. Those are the same number only when the composite has no margins and no caption, which is never. Work backwards:

```
canvas 2560×1600
  − horizontal margins (2 × 160)          → content box 2240 wide
  − caption block (textTop + text height) → content box ~1150 tall
⇒ place the window at ≤ 2240×1150 px ⇒ capture the window at ≤ 1120×575 pt @2x
```

Size the window to that, and the compositor resamples nothing. Size it to 1280×800 pt and the compositor must shrink a 2560-px image into a 2240-px box — one downscale. That is *acceptable* (a single high-quality Lanczos pass is nearly invisible); two are not. Know which you are doing rather than assuming 1:1.

If measuring the content box is impractical, capture large and downscale once. The rule that actually matters is the next section's: never resample twice.

## iOS

Apple derives smaller sizes from the largest, so you generally need only the biggest iPhone and the biggest iPad:

| Class | Portrait | Typical device |
|---|---|---|
| iPhone 6.9" | 1290 × 2796 or 1320 × 2868 | iPhone Pro Max |
| iPhone 6.5" | 1242 × 2688 or 1284 × 2778 | older Pro Max |
| iPad 13" | 2064 × 2752 or 2048 × 2732 | iPad Pro |

Landscape is the transpose. A simulator screenshot of the right device is already the right pixel size — which is why the iOS path needs no scaling either, provided you screenshot the full screen.

## Compositing

Raw window captures are not marketing assets. A store image is: a branded background, a headline, a subtitle, and the capture with a shadow and rounded corners.

**Use the tool.** `appshot compose appstore` does exactly this, driven by [`assets/screenshots.config.json`](../assets/screenshots.config.json). Per `screen × appearance` it loads `<id>~<appearance>.png`, draws the gradient, lays out the caption with real font metrics, shadows and places the capture, and writes an exact-size PNG:

```bash
appshot compose appstore --config Screenshots/screenshots.config.json \
  --source Screenshots/source --out Screenshots/appstore
```

It needs nothing but the binary — Swift and CoreGraphics, one package dependency, no Node and no Python. (It once needed `sharp`; that pipeline is what `appshot` replaced, and any repo still carrying it should be migrated rather than patched.) It refuses an output size the store won't accept, fails on a missing capture, and preflights the font — the three ways this step ships something broken without telling you.

On an **iOS** config it composes once per `devices[]` entry, into `<out>/<device-id>/`, because each device has its own canvas — iPhone 6.9" is 1320×2868 and iPad 13" is 2064×2752, and one config cannot carry both in a single `output`.

**Keep it data-driven.** Captions and colors change often, and by non-engineers; the layout engine changes rarely. Everything a marketer touches lives in the config; nothing they touch is code.

**Choice of tool.** Use `appshot`. If you find a repo with its own compositor — `sharp`, `Pillow`, ImageMagick — that is a fork carrying the known bugs in the main skill, not a local preference to respect. What to reject outright is "just resize the raw capture": that yields soft text and a bare screenshot with no branding.

## Choosing the background

`themes.<appearance>.background` is a linear gradient in sRGB: an `angle` and a list of `stops`. There is nothing else. It has no radial, no noise and no per-screen override. `compose family` reads the same block, and so does `appshot icon build --plate-angle`, because the icon plate is drawn by the same function.

### The angle is not CSS

**Degrees clockwise from east, y down, taken literally.** The vector `(cos θ, sin θ)` points from offset 0 toward offset 1, so offset 0 sits on the side the angle points *away* from:

| `angle` | offset 0 lands at | offset 1 lands at | the same ramp in CSS |
|---|---|---|---|
| 0 | left edge | right edge | `90deg` |
| 45 | top-left corner | bottom-right corner | `135deg` |
| 90 | top edge | bottom edge | `180deg` |
| 135–160 | top-right corner | bottom-left corner | `225deg`–`250deg` |
| 270 | bottom edge | top edge | `0deg` |

Between the rows, any angle that is not a multiple of 90 still puts offset 0 exactly on a corner: the top-left for 0–90, top-right for 90–180, bottom-right for 180–270, and bottom-left for 270–360. The angle only tilts the bands. So `70` is lit from the top-left corner, with bands that run almost level.

Two conversions, and they are all you need:

- **From CSS** `linear-gradient(Adeg, …)`: `angle = A − 90` (mod 360). A site hero at `160deg` is `70` here. Copied verbatim as `160` it runs from the top-right corner to the bottom-left, which does not match the hero.
- **From an SVG** `linearGradient` with `gradientUnits="userSpaceOnUse"`: `angle = atan2(y2 − y1, x2 − x1)`. An icon plate from `(0,0)` to `(1024,1024)` is `45`.

To mirror left and right (lit from the top-left instead of the top-right), use `180 − θ`. The template's `145` puts its lightest stop in the **top-right** corner, opposite an icon plate at `45`. Pick the side on purpose.

**Do not correct for the aspect ratio.** The ramp is stretched along its axis until it reaches the canvas's extreme corners, so `45` goes exactly corner to corner on a 16:10 Mac canvas and on a tall iPhone one alike. Offset `0.5` is always the canvas centre. At `90` and `270` the offsets are fractions of the height, and at `0` and `180` fractions of the width.

The JS compositor appshot replaced skewed its angle by the canvas aspect, so `145` measured about 135° on its output. Re-render an angle from that era before trusting it. Separately, `appshot icon build`'s `--mark-shadow` angles use a different convention (counter-clockwise, y up). Never carry an angle between the two.

### Where the colours come from

**From the icon or the site, not a new palette.** A store image in colours the site does not use reads as a different product. Take the stops off the icon's plate (`design/*.svg`, `design/colors.json`, `AccentColor.colorset`) or the site's tokens, and say which in a `//themes` note beside them. A note that names its source is what lets the next person check it. Copying the template's warm neutrals is not a choice. They are placeholders.

**Only the uploaded appearance gets judged.** If App Store Connect holds only the `~dark` set, tune the dark half and give the light half whatever ink reads on it.

### Two checks before shipping a ground

**Does the shadow still separate the window?** On a dark app over a dark ground it may not (see [the bezel](#the-bezel-when-shadow-cannot-define-an-edge)). Measure it: compose once as configured and once with `layout.shadow.opacity` set to `0`, then take the largest per-pixel difference. At `5/255` or under, the shadow is rendering and doing nothing. A ground that moved it to `30/255` fixed one measured case outright. There are two fixes. You can change the ground (lift it, or give it a hue the window does not have), or add `layout.bezel`. Either is compose-only: no re-capture, no re-accept.

**Does the ground compete with the accent?** A ground in the same hue family as the app's tinted controls swallows them. A warm amber ramp behind amber-accented UI hid the primary buttons in one measured case, and the fix was a neutral slate that left the accent the only colour in the frame. When the UI already carries the brand colour, the ground does not have to.

### A pattern worth knowing: the floor

For a dark app, a ground that is dark at the top (where the caption sits) with a warm band only along the bottom reads as a horizon and keeps the type on plain ink:

```json
"background": {
  "angle": 270,
  "stops": [
    { "offset": 0, "color": "#7A2F1C" },
    { "offset": 0.24, "color": "#241A1A" },
    { "offset": 0.6, "color": "#101215" },
    { "offset": 1, "color": "#0B0C0F" }
  ]
}
```

At `270`, offset 0 is the bottom edge. The `0.24` stop is what keeps the warmth a floor instead of a wash. Keep the floor colour at the depth of the icon's darkest tone rather than lifting it toward the accent: it shares the band the window's drop shadow falls in, and a bright floor makes the shadow read as dirt.

## The font falls back silently, and you find out on the store

A renderer that substitutes a missing family **never errors** — it picks the nearest match and carries on. `SF Pro Display` is the natural choice for an Apple-platform app and is *not* part of a stock macOS install; it ships in [Apple's SF font pack](https://developer.apple.com/fonts/). So the images render beautifully on the machine of whoever set the pipeline up, and in Helvetica on everyone else's — including CI.

This is the single strongest argument for `appshot` over a hand-rolled compositor: it is built on CoreText, which can be made to *decline* a font, and it refuses to compose at all if the first family in the stack does not resolve. The librsvg/fontconfig stack it replaced could only substitute one and warn.

Check, once, rather than trusting the render:

```bash
appshot doctor --config Screenshots/screenshots.config.json   # names the resolved family
```

(`fc-match "SF Pro Display:bold"` is the fontconfig equivalent, and is what you want when auditing a pipeline that still rasterizes through librsvg.) A substitution is invisible in code review, invisible in the config, and obvious only if you happen to know what the typeface should look like.

## The marketing site is a second consumer of the same captures

Most of these apps have a website showing the same screens. It is nearly always fed by
hand — someone `cp`s a few PNGs in at release time — which is why the site's screenshots
are reliably the most stale images the project owns, and why they are the ones still
showing the developer's real data long after the store set was fixed.

Give it a second generator over the *same* `screens[]` array
(`appshot compose website`). The site wants the **bare
app UI** — no gradient, no baked-in caption — because it supplies its own headline and copy
around the image. So: same captures, same config, different rendering.

```bash
appshot compose website --config Screenshots/screenshots.config.json \
  --source Screenshots/source --out ../site/src/assets/screenshots
```

Three things worth copying:

- **Opt in per screen.** A screen is exported only if its config entry declares a `website`
  basename. A paywall belongs on the store listing and not on your own pricing page, and
  "no key" says that more clearly than a second list would.
- **Emit only the appearance the site actually uses.** Two sibling projects copy in `~light`
  variants that no component ever imports — megabytes of PNGs that have sat unreferenced for
  months. Check for `prefers-color-scheme` / a `dark:` class on the image before assuming the
  site needs both.
- **Wipe the output directory first.** With static imports (Astro, Vite), deleting a renamed
  screen's old file turns a silent staleness bug into a dangling import that fails the build.
  That is the behaviour you want.

**Don't number the website files.** See below — the reason the store needs a prefix does not
apply to a site, and doing it anyway is how you get two orderings that drift.

## Store order belongs in the config, never in the filenames

Tempting: name the captures `1_connection.png`, `2_preview.png`, so they sort correctly. Don't.

App Store Connect orders uploads by filename, so the *composite* does need a numeric prefix — the compositor stamps `01-`, `02-` from the position in `screens[]`. If the capture is numbered too, you get `01-1_connection.png`, and worse, the two numbering schemes drift the moment someone reorders the listing: move the catalog screen to slot 3 and it becomes `03-8_catalog.png`.

Store order is a marketing decision that changes independently of the app. Keep it in exactly one place — `screens[]` — and let the raw captures be named for *what they are* (`connection`, `preview`, `catalog`). Reordering the listing is then a config edit, not a file rename plus a golden re-bless.

## Rounding the corners: a macOS/iOS asymmetry that bites

A macOS ScreenCaptureKit capture *already has* transparent rounded corners. So a compositor built for macOS often applies `cornerRadius` only to the **shadow**, and the window looks correctly rounded purely because its own alpha says so.

An iOS screenshot from `XCUIScreenshot` — or from a real device — is a hard rectangle. Feed it to that same compositor and you get a square image sitting on a rounded shadow, visibly wrong. Recognise the shape of this in someone else's pipeline: if you cannot find code that masks the screenshot, it is relying on macOS alpha.

`appshot` closes it from both ends:

- **The staged iOS driver captures with `--mask=alpha`**, so a simulator capture arrives carrying the *device's own* rounded-corner alpha — measured at 0.878% of an iPhone canvas, 0.064% of an iPad's. Nothing needs masking, and the categorical alpha check keeps working on iOS for free.
- **The compositor masks an opaque capture** to `layout.cornerRadius` when the config is iOS, which covers the `extract` route and real-device screenshots. On a *Mac* config an opaque capture is not a shape problem but a permission one, so it warns instead: that is what a capture looks like when Screen Recording was not granted.

Note the iPad figure. At 0.064% its transparent corners sit *below* the 0.1% drift tolerance — the same trap the alpha check exists for on macOS (0.056% there). A fractional tolerance can never see a property that is binary and small in area, which is why alpha loss gets its own categorical check instead of being folded into the pixel diff.

## The bezel: when `shadow` cannot define an edge

`layout.shadow` is what separates the device from the gradient. On a dark app over a dark background it separates nothing — measured on an RXd composite, the pixel immediately outside the window read `(18,15,13)` against a background of `(19,16,14)`. One unit. The setting is configured, it renders, and it does nothing: exactly the silent degradation that never gets noticed, because the image still looks plausible on its own.

`layout.bezel` is the fix — `width`, `color`, and an optional `highlight` rim on the outermost pixels. It is off unless set.

Turning it on does **not** touch the gate. The goldens are raw captures and `check` compares captures; the bezel is applied in `compose`, which is downstream of both. So a bezel is one of the few visual changes you can make without a re-accept — recompose, look at the result, and revert the config line if you don't like it. Nothing to bless either way.

**Reach for a drawn bezel, not a device-frame PNG**, and know why before someone asks for the PNG:

- **Assets.** appshot ships no binary resources. A device frame means artwork per device kept in step with Apple's hardware cadence forever — a config naming `iPhone 17 Pro Max` names something else in a year, and a frame that has not kept up is wrong in a way nothing checks.
- **Licence.** Apple Design Resources bezels are licensed for marketing your own app. Bundling them into a tool other projects install is a different act from using one in your own listing.
- **Alignment.** The aperture has to agree with the capture's own alpha corners to the pixel — and on iOS the capture already carries the device's real squircle. Disagree by two and you get a seam, or a double-rounded corner, on the part of the image people look at closely.
- **Legibility.** The window is *width*-bound in a typical layout, so every pixel of frame comes straight out of app UI on a thumbnail that is already small. Measured on RXd's 6.9" canvas: a 1020px window in a 1020px box, with 117px of vertical slack going unused. A 14px drawn ring cost 32px of screen; a photographic frame would have cost roughly 70.

The drawn ring is derived, not described: the capture's own alpha silhouette dilated outward by a disc — the Minkowski sum of the screen outline with that disc, which is precisely what a physical frame is. So it fits a squircle, a circular corner and a Mac window's corners identically, with no per-device radius to configure and get wrong. An opaque capture has no silhouette, so it falls back to the rounded rect the compositor is about to clip it into.

One layout rule makes it safe: the window shrinks by `2 * width` first, so the ring's outer edge lands on `margin`. A frame grown outward from an already-placed window walks past the edge the config says the device stops at — silently, because a composite is only ever looked at, never measured.

## Three invariants for the compositor

**Composite from raw, always.** Never feed the compositor an image it (or anything else) has already scaled. Two resamples visibly soften text.

**Fail on a missing input.** If `screens[]` names `settings` and `settings~dark.png` doesn't exist, stop with an error naming the file. Silently emitting five of six store images is how a release goes out with a gap.

**Never `fit: "fill"`.** It distorts anything whose aspect ratio differs from the target box. It appears to work while every source is the same size, then silently stretches the day a portrait iOS capture arrives. Use `fit: "contain"` (or `inside`) and let a mismatch show up as letterboxing you can see.

## Localized store assets

There are two different things people mean by this, and only one of them exists.

**Localized captions over shared captures** — the common case, and what `appshot` does. The app's UI is one language (or its screens are language-neutral), and only the marketing copy changes. Declare the axis, then key each screen's copy by locale:

```json
{
  "locales": ["fr-FR", "en-US"],
  "screens": [
    { "id": "map", "captions": {
        "fr-FR": { "title": "La carte", "subtitle": "Tout le relief." },
        "en-US": { "title": "The map",  "subtitle": "All the terrain." } } }
  ]
}
```

One capture in, one composite set per locale out, into `appstore/<locale>/` — and `appstore/fr-FR/iphone/01-map~dark.png` on iOS, where the locale is the outer level. `--locale fr-FR` narrows a run and leaves the other languages untouched on disk.

Three properties worth knowing, each a decision rather than an accident:

- **A locale is a directory, not a third `~` field.** `compose appstore` wipes the directory it writes into, so locales sharing one would mean `--locale fr-FR` destroying a finished set for a language the run was explicitly told not to touch. Note this is a *different* reason from the one that makes `devices[]` a directory — that one is about `<id>~<appearance>` demangling, which a locale never touches. Same conclusion, different argument; don't collapse them.
- **There is no fallback to a plain `title`.** A screen carries one caption or one per locale, never both, and both mistakes are rejected when the config is read. A fallback means two places to look for the string that actually rendered, and its failure mode is a French listing shipping English copy — plausible, publishable, wrong.
- **The gate never sees a locale.** Captures are locale-independent, so `check`, `accept`, `seal` and `selftest` take no `--locale` — and neither does `compose website`, which bakes in no caption to vary. They *reject* the flag rather than accepting and ignoring it. All five do take `--device`, so the absence reads as an oversight; it isn't.

Design against the longest locale: German and French run 30–40% longer than English. The caption block pushes the window down, so the same capture composes at a *smaller scale* in the longer language — and an overflow is a hard failure in that locale alone. If the headline fits there, it fits everywhere.

Adding `locales[]` to a project that already composed flat strands the old `appstore/*.png` in the root, where a localized run will never overwrite or mention it again. `appshot` warns; it does not delete.

**Localized UI** — where the app itself is translated, so the pixels differ per language — is a **capture** axis, not a caption one. It would touch the drivers, the golden directories, `accept`, `seal` and `selftest`. `appshot` does not have it. In particular, do not reach for `<screen>~<appearance>~<locale>.png`: that filename shape does not exist, and adding it would break the `<id>~<appearance>` parsing that `Gate`, `Compose` and `Extractor` all share.
