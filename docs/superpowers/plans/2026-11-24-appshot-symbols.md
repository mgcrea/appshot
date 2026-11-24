# `appshot symbols`, milestone 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appshot symbols build|check|sheet` turns a folder of layered SVG glyphs into Regular-M custom SF Symbols (`.symbolset`), checks them for drift, and renders a contact sheet from the compiled symbols. Plus the first `appshot-symbols` skill, released as appshot 0.35.0.

**Architecture:**
- All logic is in `Sources/AppShotKit/Symbols/`, as plain functions that return values and never print or exit, as the rest of AppShotKit does. The pipeline runs in five stages, each in its own file:
  1. parse the SVG subset;
  2. outline it into filled `CGPath`s per layer;
  3. place and write the template;
  4. build and lock;
  5. check, and compile, load and render the sheet.
- The CLI is a thin `Sources/appshot/SymbolsCommands.swift`, like `IconCommands.swift`.

**Tech Stack:** Swift 6 package (tools 6.0), macOS 14 floor, swift-argument-parser, swift-testing, CoreGraphics, AppKit, CryptoKit, `xcrun actool`. No new package dependency.

**Spec:** [docs/superpowers/specs/2026-11-24-appshot-symbols-design.md](../specs/2026-11-24-appshot-symbols-design.md). Executors read both. The first consumer is Maquette (`~/Projects/apps/maquette/docs/specs/2026-11-24-feature-glyphs-and-timeline-design.md`), whose needs the sheet's variants and the knockout serve.

## How the work runs

- **Branch and worktree:** branch `symbols` in `~/Projects/appshot/.claude/worktrees/symbols`. `.claude/worktrees` is ignored there, through `.git/info/exclude`.
- **Per task:** one implementer (`model: opus`, effort `medium`) and one reviewer (`model: opus`, effort `high`). A review's fixes are commits of their own.
- **At the end:** a whole-branch review (`opus`, `high`), then Task 8's release.
- **Done means:** every task ends green on `swift test --filter <its suites>` and on `swift format lint --strict --recursive Sources Tests`. That is CI's gate, and the 0.34.0 tag failed it.
- **Tests that call `actool`** check first that `xcrun --find actool` succeeds, and are skipped with `.enabled(if:)` when it doesn't. CI's runner has Xcode, so they run there.

## Rulings on the spec

1. **One drawing box:** a source's `viewBox` must be exactly `0 0 100 100`, and any other value is refused (`symbolBadViewBox`). One box per family makes the stroke width mean the same thing in every file.
2. **Placement, from the template the builder check compiled:**
   - At point size 100, the Regular-M baseline is at y 1126 and the cap line at 1055.54 on the 3300 by 2200 artboard. Cap height is therefore 70.459 points, so one box unit is `0.70459` template points.
   - Box (x, y) maps to glyph (x·k, (y − 100)·k), with k = 0.70459, in the `Regular-M` group's own space. The box's bottom sits on the baseline and its top on the cap line.
   - The group's transform is `matrix(1 0 0 1 L 1126)`, where L is the left-margin guide's x.
3. **Margins:**
   - The left margin guide is at x = L, and the paths are shifted so their outlined left edge sits at `sideBearing·k`.
   - The right margin guide is at L + (outlined width + 2·`sideBearing`)·k.
   - `sideBearing` comes from `symbols.json`, default 4 box units.
   - L is fixed at 1396.3, the reference template's value.
4. **Stroke width default:** 8 box units (about 5.6 points at 100 points), read off the reference template's circle ring. `symbols.json` overrides it, and the sheet beside stock symbols is where a family tunes it.
5. **Layers, in drawing order, and their classes:**

   | Layer | Class |
   |---|---|
   | 0 wash | `monochrome-0 hierarchical-0:tertiary` |
   | 1 outline | `monochrome-1 hierarchical-1:primary` |
   | 2 touch | `monochrome-2 hierarchical-2:secondary` |

   - The palette maps primary, secondary and tertiary to the first, second and third colour an app passes, which is the spec's order (outline, touch, wash).
   - The `<style>` gives `.monochrome-0` `opacity:0.0`, so monochrome drops the wash. It gives no `-sfsymbols-clear-behind` anywhere, because knockout is geometry.
   - A layer whose group is absent or empty is not written, and the indices close up.
   - Whether `actool` wants `multicolor-N` classes too is found in Task 3's first `actool` run. If it does, mirror the hierarchical ones (`multicolor-N:tintColor` for the touch, `:primary` otherwise) and note it in the skill's traps.
6. **Knockout:** for each touch element with `data-knockout="true"`, its outlined shape grown by half the stroke width (`copy(strokingWithWidth: strokeWidth, …)` of that shape, unioned with the shape) is subtracted from the outline layer with `CGPath.subtracting(_:using: .winding)`. The wash is never cut.
7. **Numbers:** written with at most two decimals, trailing zeros dropped, `-0` written as `0`. The same input gives the same bytes on one Mac.
8. **The lock:** `symbols.lock.json`, written next to the sources:

   ```json
   { "geometryVersion": 1,
     "symbols": { "<asset>": { "source": "<sha256 hex>", "template": "<sha256 hex>" } } }
   ```

   - `source` hashes the SVG's bytes, followed by the canonical JSON (sorted keys) of the settings that bear on the drawing: `strokeWidth`, `sideBearing`, `prefix`.
   - `template` hashes the written template SVG.
   - The file is written with sorted keys and pretty-printed, so it diffs cleanly.
9. **Asset names:** `prefix + filename without .svg`. A name must match `^[a-z0-9]+([._-][a-z0-9]+)*$`, or it is refused (`symbolBadName`). This keeps names usable in `Image(_:)` and in `NSImage(named:)`.
10. **Settings precedence:** CLI flags beat `symbols.json`. `--out` is required unless `symbols.json` gives `out`, a path relative to the sources folder.

## Global Constraints

- macOS 14 floor (`Package.swift`). APIs above it (`CGPath.subtracting` is macOS 13, so fine) need no availability gate. Anything newer would need one, so avoid it.
- AppShotKit never prints and never exits. Errors are `AppShotError` cases, each with a message naming the file and what to do.
- Only Regular-M is written. Template writer version `"101"`, matching the comment line of the Resources templates.
- Palette order: primary = outline, secondary = touch, tertiary = wash.
- Supported SVG elements: `path`, `line`, `polyline`, `polygon`, `rect`, `circle`, `ellipse`, `g`. Supported attributes: `transform`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-dasharray`, `fill`, `stroke`, `data-knockout`. Anything else inside the three groups is refused by name.
- `symbols check` never regenerates assets to compare. Only appshot's own tests compare bytes.
- The geometry version starts at `1` (`SymbolGeometry.version`).
- References appear only in the HTML sheet, never in the PNG.

## Review Focus

1. **Real-world SVG path data:** relative commands, implicit repeats (`l 1 2 3 4`), `H`/`V`, `S`/`T` shorthands and `A` arcs must all parse to the right geometry. An arc that silently becomes a line would look fine until the sheet. Pinned in Task 1.
2. **Attributes inherited from a `<g>`:** `stroke-width`, `stroke-linecap`, `fill` set on a group apply to its children, as SVG says. Without this, a generator that sets the stroke once per group would get default strokes. Pinned in Task 1.
3. **A hand-made asset in the same folder,** or one Xcode made, is never deleted or rewritten by `build`. Only assets listed in the lock are touched. Pinned in Task 4.
4. **`actool` unavailable** (Command Line Tools selected, no Xcode) gives `check` and `sheet` one clear error naming `xcode-select`, not a crash or a hang. Pinned in Task 5.
5. **A touch with nothing under it** (a knockout over empty outline) and **an empty `touch` group** build cleanly, with no empty layer written. Pinned in Task 2.

---

### Task 1: The source format

**Files:**
- Create: `Sources/AppShotKit/Symbols/SymbolSource.swift`, `Sources/AppShotKit/Symbols/SVGPathData.swift`, `Sources/AppShotKit/Symbols/SymbolSettings.swift`
- Modify: `Sources/AppShotKit/AppShotError.swift` (new cases)
- Test: `Tests/AppShotKitTests/SymbolSourceTests.swift`, `Tests/AppShotKitTests/SVGPathDataTests.swift`

**Interfaces:**
- Produces:
  - `public enum SymbolLayer: String, CaseIterable, Sendable { case wash, outline, touch }`, in drawing order.
  - `public struct SymbolPaint: Equatable, Sendable { var fill: Bool; var stroke: Bool; var strokeWidth: Double?; var lineCap: CGLineCap; var lineJoin: CGLineJoin; var dash: [Double] }`. A nil `strokeWidth` means the family's own.
  - `public struct SymbolElement: Sendable { let path: CGPath; let paint: SymbolPaint; let knockout: Bool; let description: String }`. `path` is in box units with transforms applied. `description` reads like "<circle> at line 7", for messages.
  - `public struct SymbolDrawing: Sendable { let name: String; let layers: [SymbolLayer: [SymbolElement]] }`.
  - `public enum SymbolSource { static func read(_ url: URL, prefix: String) throws -> SymbolDrawing }`.
  - `public enum SVGPathData { static func parse(_ d: String) throws -> CGPath }`.
  - `public struct SymbolSettings: Codable, Sendable` with `strokeWidth: Double = 8`, `sideBearing: Double = 4`, `prefix: String = ""`, `out: String?`, `companions: [String] = []` (stock symbol names), `variants: [SymbolVariant] = []`, `references: [String] = []`. Plus `static func read(in folder: URL) throws -> SymbolSettings`, which returns the defaults when there's no `symbols.json`.
  - `public struct SymbolVariant: Codable, Sendable { let name: String; let colors: [String]; let tile: String? }`. Each colour is `"#RRGGBB"`, `"#RRGGBBAA"`, `"primary"` or `"accent"`.
  - New `AppShotError` cases: `symbolBadViewBox(URL, found: String)`, `symbolUnsupported(URL, element: String, line: Int)`, `symbolNoOutline(URL)`, `symbolBadName(URL, name: String)`, `symbolBadPathData(URL, String)`.

- [ ] **Step 1: Write the failing tests**

`SVGPathDataTests`:
- `absoluteAndRelativeAgree`: `M10 10 L20 10 L20 20 Z` and `m10 10 l10 0 l0 10 z` give equal bounding boxes, `(10,10,10,10)`.
- `implicitRepeats`: `M0 0 l10 0 0 10` has two line segments ending at `(10,10)`.
- `horizontalVertical`: `M0 0 H30 V40` has bounds `(0,0,30,40)`.
- `smoothCurves`: `M0 0 C0 10 10 10 10 0 S20 -10 20 0` ends at `(20,0)`, and the reflected control point puts the second curve's bounds below y 0.
- `arcs`: `M0 50 A50 50 0 0 1 100 50` is a half circle. Its bounding box is `(0,0,100,50)` within 0.01, it is not a line (`path.boundingBox.height > 49`), and `A` with radius 0 becomes a line.
- `garbageThrows`: `M0 0 L10` throws `symbolBadPathData`.

`SymbolSourceTests` (writing SVGs to a temp folder, as `IconSVGTests.tempDir()` does):
- `readsThreeLayers`: groups `wash`, `outline`, `touch` give one element each, in `SymbolLayer` order, with the name `"feature.extrude"` taken from the file name `feature.extrude.svg`.
- `appliesTransforms`: a `rect` inside `<g transform="translate(10 0) scale(2)">` has bounds `(10+2x, 2y, 2w, 2h)`.
- `inheritsFromGroup`: a `line` inside `<g id="outline" stroke-width="5" stroke-linecap="round">` has `paint.strokeWidth == 5` and `.round` cap. A child's own `stroke-width="3"` wins.
- `knockoutFlag`: `data-knockout="true"` on a touch `circle` sets `knockout`, and it is false when the attribute is absent.
- `refusesWhatItCannotDraw`: a `<text>`, a `<linearGradient>`, a `<use>`, a `clip-path` attribute and a `filter` attribute each throw `symbolUnsupported`, naming the element and its line.
- `refusesWrongBox`: `viewBox="0 0 24 24"` throws `symbolBadViewBox`.
- `outlineRequired`: no `outline` group throws `symbolNoOutline`, while a missing `wash` or `touch` is fine.
- `refusesBadName`: `Feature Extrude.svg` throws `symbolBadName`.
- `settingsDefaults`: a folder without `symbols.json` gives `strokeWidth 8`, `sideBearing 4`, `prefix ""`. One with `{"strokeWidth": 6, "variants": [{"name": "selected", "colors": ["accent", "primary", "#00000022"], "tile": "#007AFF40"}]}` reads them back.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "SymbolSourceTests|SVGPathDataTests"`
Expected: compile failure, because the types are not defined.

- [ ] **Step 3: Implement**

- Use `XMLParser`. Its `lineNumber` gives the line for messages.
- Keep one stack of inherited attributes per `<g>`.
- Transforms: `matrix`, `translate`, `scale`, `rotate` (with an optional centre), `skewX` and `skewY`, composed left to right as SVG does.
- `fill`: `none` means no fill. Absent means filled, unless the element is a `line` or `polyline`, which aren't. `stroke` absent means no stroke.
- Arcs follow the SVG implementation notes' endpoint-to-centre conversion, emitted as cubic curves of at most 90° each.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --filter "SymbolSourceTests|SVGPathDataTests"` and `swift format lint --strict --recursive Sources Tests`
Expected: all pass, no lint output.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppShotKit/Symbols Sources/AppShotKit/AppShotError.swift Tests/AppShotKitTests/Symbol*Tests.swift Tests/AppShotKitTests/SVGPathDataTests.swift
git commit -m "feat(symbols): read a glyph's layered SVG and its family's settings"
```

### Task 2: Outlining and knockout

**Files:**
- Create: `Sources/AppShotKit/Symbols/SymbolGeometry.swift`
- Test: `Tests/AppShotKitTests/SymbolGeometryTests.swift`

**Interfaces:**
- Consumes: `SymbolDrawing`, `SymbolElement`, `SymbolLayer`, `SymbolSettings` (Task 1).
- Produces:
  - `public struct OutlinedSymbol: Sendable { let name: String; let layers: [(SymbolLayer, CGPath)]; var bounds: CGRect }`. Only non-empty layers are kept, in drawing order. `bounds` covers every layer, in box units.
  - `public enum SymbolGeometry { static let version = 1; static func outline(_ drawing: SymbolDrawing, strokeWidth: Double) -> OutlinedSymbol }`.

- [ ] **Step 1: Write the failing tests**

- `strokeIsOutlined`: an outline `line` from (10,50) to (90,50), with the default 8 and a butt cap, outlines to bounds `(10,46,80,8)`.
- `roundCapGrowsTheEnds`: the same line with a `round` cap outlines to `(6,46,88,8)`.
- `filledAndStroked`: a `rect` 20×20 with fill and an 8 stroke outlines to bounds 4 larger on each side, and its centre is inside the path.
- `dashesBreakTheStroke`: a line 0→100 with `stroke-dasharray="10 10"` outlines to a path that contains (5,50) but not (15,50).
- `knockoutCutsTheOutline`: an outline `rect` (0,0,100,100), filled, and a touch `circle` at (50,50) r 10 with `data-knockout="true"`. The outline layer does not contain (50,50) or (50,63), the latter inside the gap of 10 + 4 (half of 8) = 14, and does contain (50,66). The touch layer contains (50,50).
- `noKnockoutDrawsFlush`: the same without the flag. The outline layer still contains (50,50).
- `washIsNeverCut`: the wash layer under a knockout touch still contains (50,50).
- `emptyLayersDropped` (Review Focus 5): an empty `<g id="touch"/>` gives `layers.map(\.0) == [.outline]`. A knockout touch over empty outline gives the touch layer and no outline layer. Neither crashes.
- `deterministic`: outlining one drawing twice gives `CGPath`s that are `==`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter SymbolGeometryTests`
Expected: compile failure.

- [ ] **Step 3: Implement `SymbolGeometry.outline`**

- Per element:
  - fill: the path itself;
  - stroke: dash first (`copy(dashingWithPhase: 0, lengths:)`), then `copy(strokingWithWidth: paint.strokeWidth ?? strokeWidth, lineCap:lineJoin:miterLimit: 10)`.
- Union per layer with `union(_:using: .winding)`.
- Knockout follows Ruling 6.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --filter SymbolGeometryTests` and the lint
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(symbols): outline strokes and cut a marked touch out of the outline"
```

### Task 3: The template

**Files:**
- Create: `Sources/AppShotKit/Symbols/SymbolTemplate.swift`, `Sources/AppShotKit/Symbols/SymbolCatalog.swift`
- Test: `Tests/AppShotKitTests/SymbolTemplateTests.swift`

**Interfaces:**
- Consumes: `OutlinedSymbol` (Task 2).
- Produces:
  - `public enum SymbolTemplate { static let capHeight = 70.459; static let baselineM = 1126.0; static let leftMargin = 1396.3; static func svg(_ symbol: OutlinedSymbol, sideBearing: Double) -> String; static func contentsJSON(svgName: String) -> Data }`.
  - `public enum SymbolCatalog`, used by Tasks 5 and 6:
    - `static func actool() throws -> URL`: the path from `xcrun --find actool`, or `AppShotError.symbolNoActool` (a new case whose message says to run `sudo xcode-select -s /Applications/Xcode.app`).
    - `static func compile(_ catalog: URL) throws -> (bundle: Bundle, warnings: [String])`: wraps the given folder in a scratch `.xcassets` when it isn't one, then runs `actool --compile <scratch>/Contents/Resources --platform macosx --minimum-deployment-target 14.0 --output-format human-readable-text --warnings --errors`. It throws `AppShotError.symbolCatalogRejected(String)` with `actool`'s errors, and returns a `Bundle` over a scratch `.bundle` with a minimal `Info.plist`.

- [ ] **Step 1: Write the failing tests**

- `placesTheBoxOnBaselineAndCapline`: a filled rect covering the box `(0,0,100,100)` with `sideBearing 0` writes a `Regular-M` group with transform `matrix(1 0 0 1 1396.3 1126)`, whose path's bounds are `(0, -70.46, 70.46, 70.46)` within 0.01 when parsed back with `SVGPathData`.
- `marginsFromBounds`: a rect at x 20…60 with `sideBearing 4` writes `left-margin-Regular-M` at x `1396.3` and `right-margin-Regular-M` at `1396.3 + (40 + 8)·0.70459`, within 0.01. The path's left edge is at `4·0.70459`.
- `classesInOrder`: a three-layer symbol writes paths classed `monochrome-0 hierarchical-0:tertiary`, `monochrome-1 hierarchical-1:primary` and `monochrome-2 hierarchical-2:secondary`, in that order. A two-layer symbol (outline and touch) writes indices 0 and 1, primary and secondary.
- `noSmallGuides`: the output holds no `-S` or `-L` margin guide and no `Regular-S` group.
- `numbersRounded`: no number in the output has more than two decimals, and none reads `-0`.
- `compilesWithActool` (skipped without `actool`): a symbol written into a scratch `X.xcassets/feature.test.symbolset` compiles with no errors. `NSImage(symbolName: "feature.test", bundle: bundle, variableValue: 1)` is non-nil, and its `size.height` at a 13-point configuration is within 2 points of `NSImage(systemSymbolName: "cube")`'s at the same configuration.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter SymbolTemplateTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

- Copy the skeleton from `/Applications/SF Symbols.app/Contents/Resources/badge.plus.svg`, taking only the pieces Ruling 5 keeps. Leave out its `Notes` text paths unless `actool` wants them.
- The skeleton is kept as a string constant in `SymbolTemplate.swift`. The file does not read the app at run time, because CI has no SF Symbols app.
- Serialise each `CGPath` with `applyWithBlock`: `M`, `L`, `Q`, `C`, `Z`, absolute, numbers per Ruling 7.
- If the first `actool` run asks for multicolor classes, add them per Ruling 5 and record the finding in a comment above the class writer.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --filter SymbolTemplateTests` and the lint
Expected: pass, with `compilesWithActool` run (not skipped) on this Mac.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(symbols): write a Regular-M template actool compiles"
```

### Task 4: Build and the lock

**Files:**
- Create: `Sources/AppShotKit/Symbols/SymbolBuild.swift`, `Sources/AppShotKit/Symbols/SymbolLock.swift`
- Test: `Tests/AppShotKitTests/SymbolBuildTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `public struct SymbolLock: Codable, Equatable, Sendable { var geometryVersion: Int; var symbols: [String: Entry]; struct Entry: Codable, Equatable, Sendable { var source: String; var template: String } }`, with `static func read(in sources: URL) throws -> SymbolLock?` and `func write(in sources: URL) throws`.
  - `public enum SymbolBuild { static func sourceFingerprint(svg: Data, settings: SymbolSettings) -> String; static func run(sources: URL, out: URL, settings: SymbolSettings) throws -> Report }`.
  - `public struct Report: Sendable { var written: [String]; var unchanged: [String]; var removed: [String]; var warnings: [String] }`.
  - A warning is written when a symbol's outlined bounds run more than 20 box units past the box on any side (spec §4.1, Overhang), naming the symbol and the side. It does not stop the build.

- [ ] **Step 1: Write the failing tests**

- `writesSymbolsetsAndLock`: two sources give `out/a.symbolset/{Contents.json,a.svg}` and the same for `b`. The lock lists both, with `geometryVersion 1`. `Contents.json` is the Xcode shape: `{"info":{"author":"xcode","version":1},"symbols":[{"filename":"a.svg","idiom":"universal"}]}`.
- `idempotent`: a second `run` leaves every file byte-identical and reports both names as `unchanged`.
- `settingsChangeTheFingerprint`: `strokeWidth 6` instead of 8 changes `source` for both, while `companions` and `variants` don't.
- `removesOnlyWhatItWrote` (Review Focus 3): after deleting `b.svg` and running again, `b.symbolset` is gone. A hand-made `c.symbolset` and an `AccentColor.colorset` in `out` are untouched.
- `refusesWholeOnABadSource`: a third source with a `<text>` throws `symbolUnsupported`, and nothing in `out` or the lock changes.
- `overhangWarns`: a filled rect from x −25 to 50 gives one warning naming the symbol and "left". One from −15 gives none.
- `lockSortedAndPretty`: the lock file's keys are in sorted order, and the file ends with a newline.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter SymbolBuildTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

- Read every source and outline it first. Only then write. Each template goes to a temp file and is moved into place.
- SHA-256 via CryptoKit, lowercase hex.
- `JSONEncoder` with `.sortedKeys, .prettyPrinted, .withoutEscapingSlashes`.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --filter SymbolBuildTests` and the lint
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(symbols): build a folder of glyphs into symbolsets with a lock"
```

### Task 5: Check

**Files:**
- Create: `Sources/AppShotKit/Symbols/SymbolCheck.swift`
- Test: `Tests/AppShotKitTests/SymbolCheckTests.swift`

**Interfaces:**
- Consumes: `SymbolLock`, `SymbolBuild.sourceFingerprint`, `SymbolCatalog` (Tasks 3–4).
- Produces:
  - `public enum SymbolFinding: Equatable, Sendable`, one case per finding:
    - `stale(String)`: source fingerprint ≠ lock;
    - `editedByHand(String)`: template hash ≠ lock;
    - `unbuilt(String)`: source with no asset;
    - `orphaned(String)`: asset in the lock, no source;
    - `olderGeometry(found: Int, current: Int)`;
    - `unsupported(String)`: the error's message;
    - `rejected(String)`: `actool`'s error;
    - `empty(String, mode: String)`: hand-made mode.
  - Each finding has `var message: String`.
  - `public enum SymbolCheck { static func run(sources: URL?, out: URL, settings: SymbolSettings, actool: Bool) throws -> [SymbolFinding] }`. The result is empty when all is well. It throws only `symbolNoActool`, when `actool` is asked for and not found.

- [ ] **Step 1: Write the failing tests**

Each test starts from a folder built by `SymbolBuild.run`.
- `cleanIsEmpty`: no findings with `actool: false`.
- `sourceEdited`: a byte appended to `a.svg` gives `[.stale("a")]`.
- `templateEdited`: an edit to `out/a.symbolset/a.svg` gives `[.editedByHand("a")]`.
- `newSource`: a new `c.svg` gives `[.unbuilt("c")]`.
- `sourceDeleted`: deleting `b.svg` gives `[.orphaned("b")]`.
- `oldGeometry`: a lock rewritten with `geometryVersion 0` gives `.olderGeometry(found: 0, current: 1)`.
- `neverWrites`: after any of the above, every file's modification date in `out` and the lock is unchanged.
- `actoolRejects` (skipped without `actool`): a `.symbolset` whose SVG has its `Regular-M` group renamed gives one `.rejected` naming the asset.
- `handMadeMode` (skipped without `actool`): `sources: nil` on a folder built earlier gives no findings. Each symbol is rendered at 16 points in monochrome, hierarchical and palette into a bitmap with at least one non-transparent pixel.
- `noActoolIsOneClearError` (Review Focus 4): with `SymbolCatalog`'s tool lookup pointed at a missing path (a `static var` hook for tests, `internal`), `actool: true` throws `symbolNoActool`, whose message contains `xcode-select`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter SymbolCheckTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

Rendering in hand-made mode:
- `NSImage(symbolName:bundle:variableValue:)`, then `.withSymbolConfiguration(.init(pointSize: 16, weight: .regular).applying(.preferringMonochrome()))`, and likewise with `.preferringHierarchical()` and `paletteColors: [.black, .red, .gray]`;
- each drawn into an `NSBitmapImageRep`.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --filter SymbolCheckTests` and the lint
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(symbols): check a symbol folder against its sources and lock"
```

### Task 6: The sheet

**Files:**
- Create: `Sources/AppShotKit/Symbols/SymbolSheet.swift`
- Test: `Tests/AppShotKitTests/SymbolSheetTests.swift`

**Interfaces:**
- Consumes: `SymbolCatalog.compile`, `SymbolSettings` (`companions`, `variants`, `references`).
- Produces: `public enum SymbolSheet { static let sizes: [CGFloat] = [13, 16, 20, 28]; static func png(assets: URL, settings: SymbolSettings) throws -> Data; static func html(assets: URL, settings: SymbolSettings, referencesRoot: URL) throws -> String }`.

**Layout:**
- One row per symbol, in name order, then one row per companion stock symbol, under a rule.
- Columns, for each of light and dark (the `NSAppearance` set while drawing):
  - monochrome at each size;
  - hierarchical at 20;
  - palette at each size with `[labelColor, controlAccentColor, labelColor @ 0.18]`;
  - palette at 20 with the accent forced to `systemPink` (the non-blue column);
  - each `variants` entry at 20 on its `tile` (a rounded 30×30 square);
  - a `Label`-like cell: the 13-point symbol, then the word "Extrude" in the 13-point system font on the same baseline.
- The HTML page is a header, the PNG (base64), then a strip of the reference images (base64, from the paths in `settings.references`, resolved against `referencesRoot`) with their file names.

- [ ] **Step 1: Write the failing tests** (all skipped without `actool`)

- `pngHasACellPerSymbolAndSize`: for a folder of two symbols, the PNG decodes. Its height grows by one row's height when a third symbol is added, and its width by one column's width when one variant is added.
- `cellsAreNotEmpty`: the cell of symbol 1, monochrome, 13 points, light, has non-transparent pixels.
- `referencesOnlyInHTML`: with `references: ["ref.png"]`, the PNG is byte-identical to the PNG without references. The HTML contains `data:image/png;base64,` twice, once for the sheet and once for the reference, and contains `ref.png`.
- `missingReferenceSaysWhich`: a reference path that doesn't exist throws `AppShotError.symbolMissingReference(URL)`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter SymbolSheetTests`
Expected: compile failure.

- [ ] **Step 3: Implement** with CoreGraphics and AppKit, at 2× scale. The cell and padding sizes are the implementer's call, as long as they are constant so the growth tests hold.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --filter SymbolSheetTests` and the lint
Expected: pass. Open the PNG once and look at it: Maquette's approval round depends on it reading well.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(symbols): a contact sheet from the compiled symbols"
```

### Task 7: The commands

**Files:**
- Create: `Sources/appshot/SymbolsCommands.swift`
- Modify: `Sources/appshot/AppShot.swift` (register `Symbols_` after `Icon_`)
- Test: `Tests/appshotTests/SymbolsCommandsTests.swift`

**Interfaces:**
- Consumes: `SymbolSettings.read`, `SymbolBuild.run`, `SymbolCheck.run`, `SymbolSheet.png/html`.
- Produces:
  - `appshot symbols build --from <dir> [--out <dir>]`
  - `appshot symbols check --out <dir> [--from <dir>] [--no-actool]`
  - `appshot symbols sheet --assets <dir> [--from <dir>] --out <file.png|file.html>`. `--from` gives `symbols.json` and the references' root, and the extension picks the output, as `IconFormat` does.

- [ ] **Step 1: Write the failing tests**

- `parsesBuild`: `["symbols", "build", "--from", "g"]` parses to `SymbolsBuild` with `from == "g"` and `out == nil`.
- `checkFailsWithFindings`: `SymbolsCheck.exitCode(for: [.stale("a")])` is `1`, and `[]` gives `0`.
- `sheetPicksFormatByExtension`: `.png` and `.html` are accepted, and `.jpg` throws `AppShotError.unknownSheetFormat`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter SymbolsCommandsTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

Write the `discussion` in `Icon_`'s voice, including the line "It deliberately does not own what is *in* the glyph". `build` prints its report: one line per written or removed symbol, a count of unchanged ones, and each warning prefixed `warning:`. `check` prints each finding's message and exits 1 if there are any.

- [ ] **Step 4: Run, then try it by hand**

Run: `swift test --filter SymbolsCommandsTests` and the lint.
Then run `swift run appshot symbols build --from Tests/AppShotKitTests/Fixtures/Symbols --out /tmp/…` on a two-glyph fixture (an isometric cube outline with an up-arrow touch, and a rounded-edge block). Then run `check` (exit 0), edit one SVG, run `check` again (exit 1, `stale`), and run `sheet --out sheet.png`.
Expected: as described. The fixture SVGs are committed as test fixtures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(symbols): appshot symbols build, check and sheet"
```

### Task 8: The skill, the docs, the release

**Files:**
- Create: `skills/appshot-symbols/SKILL.md`, `skills/appshot-symbols/references/appshot-symbols.md`
- Modify: `README.md` (a Symbols section after Icons), `CHANGELOG.md` (`## [0.35.0]`, Added), `Sources/AppShotKit/Version.swift` (`0.35.0`)
- Link: `~/.claude/skills/appshot-symbols` → `~/Projects/appshot/skills/appshot-symbols` (`ln -s`, as `appshot-app-icon` is linked)

**Content of the skill:**
- Frontmatter: `name: appshot-symbols`. The description carries the triggers from spec §5: a custom icon or glyph for a command, tool, feature or menu-bar item; SF Symbols, custom symbol, `.symbolset`, two-tone icon; icons that look foreign beside system symbols; `appshot symbols`; not app icons.
- Body, the spec's §5 items 1–5 in that order. The traps section holds what Tasks 1–7 found, at least:
  - the `-M` margin guides;
  - Regular-M required;
  - outlined strokes;
  - layer classes and palette order;
  - knockout per element;
  - `NSImage(named:)` against `NSImage(systemSymbolName:)`;
  - the 13-point monochrome floor;
  - multicolor classes, if Task 3 found them needed.
- `references/appshot-symbols.md`: the three commands, the source format, `symbols.json`, the lock, the findings and what to do about each.

- [ ] **Step 1: Write the skill, the reference, README and CHANGELOG; bump `Version.swift`**
- [ ] **Step 2: Verify**

Run: `swift test` (the whole suite), the lint, `make install`, and `appshot symbols --help`.
Expected: green; `appshot --version` prints `0.35.0`; the help lists build, check and sheet.

- [ ] **Step 3: Link the skill and confirm it loads**

Run: `ln -s ~/Projects/appshot/skills/appshot-symbols ~/.claude/skills/appshot-symbols && head -5 ~/.claude/skills/appshot-symbols/SKILL.md`

- [ ] **Step 4: Commit**

```bash
git commit -am "docs(symbols): the appshot-symbols skill; release 0.35.0"
```

- [ ] **Step 5: Merge to main.** Ask Olivier before tagging `v0.35.0` and pushing, which builds the public release binary in `release.yml`. Maquette's cycle 1 needs only the local `make install`.
