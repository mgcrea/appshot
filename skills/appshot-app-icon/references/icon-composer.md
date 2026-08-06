# Icon Composer / `.icon` bundles

The supported way to author an app icon for macOS 26 / iOS 26 and later. Xcode 26 ships
`Icon Composer.app` at `/Applications/Xcode.app/Contents/Applications/Icon Composer.app`.

Everything below was verified against a real `.icon` bundle and a real `actool` compile on
Xcode 26.6 / macOS 26.6 — not from documentation.

## Bundle layout

A `.icon` is a plain directory. Two entries, nothing else required:

```
Cadence.icon/
├── icon.json
└── Assets/
    └── 1024.png
```

It is a normal directory, so it is diffable and scriptable — you do not need the GUI to produce
one, though the GUI is the intended authoring tool for multi-layer effects.

**`appshot icon build --out Cadence.icon` writes exactly this and then audits it.** The
hand-assembly below is worth reading to understand the format, but it is not work you have to
do. See `appshot-icon.md`, including the `--mark-fraction` conversion a migration needs.

## The layer image: full-bleed and fully opaque

This is the single most important requirement, and it goes further than "no margin":

**The layer PNG is 1024×1024 with every pixel opaque, including the corners. No rounding at all.**

Verified on a shipped `.icon`: opaque bounding box `(0, 0, 1024, 1024)`, corner pixel alpha 255.

The system applies the squircle mask, the shadow, and the material treatment. Any rounding you
bake in gets masked *again*, which either does nothing or leaves artefacts at the corners. Author
the plate as a square that bleeds off all four edges.

This differs from a full-bleed `.appiconset`, where you keep a rounded plate because nothing
masks it on older systems. Same word, different requirement — do not copy the radius across.

## `icon.json`

The verified schema of a minimal single-layer icon:

```json
{
  "fill-specializations" : [
    { "value" : "automatic" },
    { "appearance" : "dark", "value" : "automatic" }
  ],
  "groups" : [
    {
      "layers" : [
        { "glass" : false, "hidden" : false, "image-name" : "1024.png", "name" : "1024" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "circles" : [ "watchOS" ], "squares" : "shared" }
}
```

Field notes:

- **`fill-specializations`** — per-appearance fills. `"automatic"` lets the system derive the
  dark variant. Add an entry with an explicit `appearance` to override one.
- **`groups[].layers[]`** — draw order, back to front. `image-name` refers to a file in `Assets/`.
  `glass: true` opts a layer into the specular/material treatment; keep it `false` for flat
  artwork that should not pick up highlights.
- **`shadow`** and **`translucency`** — per-group, applied by the system.
- **`supported-platforms`** — `squares: "shared"` means one square artwork covers macOS/iOS;
  `circles` lists platforms wanting a circular crop.

**Separate layers to get depth.** A single flattened 1024 layer works and is the right starting
point, but the format's value is layering: plate as one layer, glyph as another, so the system can
parallax and light them independently. If a user wants the "real" Tahoe look, that is the lever.

## Compiling

Xcode does this as part of the build, but compiling by hand is how you verify a bundle without a
full project:

```bash
xcrun actool Cadence.icon \
  --compile out/ \
  --app-icon Cadence \
  --output-partial-info-plist out/partial.plist \
  --platform macosx --minimum-deployment-target 26.0 \
  --output-format human-readable-text
```

Verified output: `out/Assets.car`, `out/Cadence.icns`, and a partial plist containing

```
CFBundleIconFile => Cadence
CFBundleIconName => Cadence
```

Those two keys are what Xcode merges into the app's `Info.plist`.

### The `.icns` looks truncated — that is expected

The `.icns` that `actool` emits carries only up to `icon_128x128@2x` (256px). That is not a
failure and not a misconfiguration: the full-resolution icon lives in `Assets.car`, and the
`.icns` is a small legacy fallback.

Confirmed by checking the system's own apps — `/System/Applications/Notes.app`'s `AppIcon.icns`
has exactly the same four slots. So if you extract a modern app's `.icns` and find nothing above
256px, you are looking at the fallback, not at the icon. Measure via `NSWorkspace` instead
(`assets/render-icon.swift`), which returns what the system actually composes.

## Wiring it into an Xcode project

Replace the asset-catalog app icon with the `.icon`:

1. Add `Cadence.icon` to the target (it is a folder reference the build system understands).
2. Point the icon setting at it. In `project.pbxproj` the existing line is usually
   `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;` — set it to the `.icon`'s base name.
3. Remove the old `AppIcon.appiconset` only once the new icon is confirmed rendering, so there is
   something to fall back to if the wiring is wrong.

Verify by rebuilding, re-registering with `lsregister -f`, then rendering and measuring — a
mis-wired icon shows the generic app icon, which is easy to miss in a small Dock tile.

## Migrating from `.appiconset`

1. Produce a **square, fully opaque** 1024 PNG of the artwork. If your source SVG has a rounded
   plate, override the radius to 0 rather than editing the source:
   `svg.replace('rx="230"', 'rx="0"')`.
2. Build the `.icon` directory with the minimal `icon.json` above.
3. `actool`-compile it standalone to confirm it is well-formed before touching the project.
4. Wire it up, rebuild, re-measure against peers.
5. Consider splitting plate and glyph into two layers once the flat version is confirmed working.
