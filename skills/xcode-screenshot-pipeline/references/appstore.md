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
appshot compose appstore --config screenshots/screenshots.config.json \
  --source Screenshots/source --out Screenshots/appstore
```

It needs nothing but the binary — Swift and CoreGraphics, one package dependency, no Node and no Python. (It once needed `sharp`; that pipeline is what `appshot` replaced, and any repo still carrying it should be migrated rather than patched.) It refuses an output size the store won't accept, fails on a missing capture, and preflights the font — the three ways this step ships something broken without telling you.

On an **iOS** config it composes once per `devices[]` entry, into `<out>/<device-id>/`, because each device has its own canvas — iPhone 6.9" is 1320×2868 and iPad 13" is 2064×2752, and one config cannot carry both in a single `output`.

**Keep it data-driven.** Captions and colors change often, and by non-engineers; the layout engine changes rarely. Everything a marketer touches lives in the config; nothing they touch is code.

**Choice of tool.** Use `appshot`. If you find a repo with its own compositor — `sharp`, `Pillow`, ImageMagick — that is a fork carrying the known bugs in the main skill, not a local preference to respect. What to reject outright is "just resize the raw capture": that yields soft text and a bare screenshot with no branding.

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
appshot compose website --config screenshots/screenshots.config.json \
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

## Three invariants for the compositor

**Composite from raw, always.** Never feed the compositor an image it (or anything else) has already scaled. Two resamples visibly soften text.

**Fail on a missing input.** If `screens[]` names `settings` and `settings~dark.png` doesn't exist, stop with an error naming the file. Silently emitting five of six store images is how a release goes out with a gap.

**Never `fit: "fill"`.** It distorts anything whose aspect ratio differs from the target box. It appears to work while every source is the same size, then silently stretches the day a portrait iOS capture arrives. Use `fit: "contain"` (or `inside`) and let a mismatch show up as letterboxing you can see.

## Localized store assets

`<screen>~<appearance>~<locale>.png` in, one composite per locale out, with the caption text pulled from a per-locale block in the config. The layout must tolerate longer strings — German and French run 30–40% longer than English. Test the longest locale first; if the headline fits there, it fits everywhere.
