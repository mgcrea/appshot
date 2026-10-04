# appshot video: motion presets

Status: design approved in conversation 2026-10-04, awaiting spec review.

## Goal

Make `compose video` output look like a produced promo, not a slideshow. The first
Armada render was flat:

- the window filled 40% of a 1200×1200 frame;
- a zoom cropped inside a fixed box, so it read as a pan;
- zoom rects were guessed and landed on half a row;
- nothing moved between beats;
- screens hard-cut.

The fix is a motion layer driven by **presets**. A beat says *what* matters ("frame
this", "this is the point"), and the preset decides *how* it moves. Swapping a look
is one word, and several looks can be rendered side by side from the same config.

### Success criteria

- Pochette's 20 s promo, written as config (§6), renders in the `kinetic` look the
  spike established (§Spike results). That means:
  - a full-frame hook;
  - word-by-word captions with accent words;
  - spring camera moves that fill the frame;
  - pop-out rows;
  - a cursor that clicks before each sheet;
  - a spring end card with a call to action.
- The same config renders in `studio` with `--motion studio`, with no other edit.
- `--motion kinetic,studio` writes both, named apart, in one run.
- No beat names a zoom scale. Framing is computed from a rect or a reported target.
- Changing motion, captions or framing still needs a render only, never a re-record.
- Renders stay deterministic: the same inputs give identical frames.
- A 20 s 1920×1080 kinetic render finishes in under 2 minutes on an Apple-silicon Mac.

### Out of scope

- Music, sound effects and beat-synced cuts.
- The `keynote` preset and 3D tilt. The spike built them, and they can return later
  as just another preset.
- Light-appearance tuning beyond "renders correctly".
- Device frames for iOS videos in motion.

## Spike results (2026-10-04)

Branch `spike/motion-presets` (commit d8f4b00, throwaway) rendered one hard-coded
Pochette script in three presets at 1920×1080 and 1200×1200. The user picked
**kinetic, with studio's cursor added**. These findings are decisions here:

- **Camera.** The camera must place the whole window on the canvas: scale and move
  it, chrome and shadow included, and let the frame edge crop. Cropping inside a
  fixed window box is what made the Armada zooms read as pans.
- **Framing.** Computed framing works: scale = fill × box ÷ rect, capped at 2.6.
  - When the scaled window is larger than the frame, its center is clamped so the
    window covers the frame.
  - When it is smaller, the center is clamped so the window stays inside the frame.
  - One clamp formula covers both cases (§3.2).
- **Sheet swap.** A crossfade between two sheet captures double-exposes their text.
  The sheet must swap instead: the old sheet shrinks 5% and fades over 0.2 s over
  the window, then the new sheet springs up.
- **Exit.** The window's exit into the end card must clear the frame from wherever
  the camera left it. A fixed offset left a zoomed window on screen.
- **Motion blur.** It needs a 90° shutter (0.25 of a frame). A 180° shutter smeared
  fast zoom-outs into mush.
- **Camera settling.** Two focus moves closer together than the camera can settle
  give a whiplash. Studio's toolbar zoom and its return 0.7 s later did. §4 warns
  about this.
- **Cost.** 50–115 s per 20 s output, with six renders in parallel on one Mac.

## 1. Config

### Video level

```json
{
  "id": "promo",
  "motion": "kinetic",
  "hook": "Your music folder is a *mess*.",
  "card": { "title": "Pochette", "subtitle": "Your music, as files.",
            "icon": "card-icon.png", "cta": "On the Mac App Store" },
  "beats": [ ... ]
}
```

- **`motion`** names a preset: `kinetic` (the default) or `studio`. Unknown names
  fail validation and the error lists the known ones.
- **`hook`** is optional. In a preset with a hook card, its text fills the frame
  for the preset's hook time (kinetic: 1.5 s). It then stays on as the first
  caption, in the caption band, until the next caption beat. In a preset without a
  hook card it is that caption from 0 s. Either way, the reading rule measures it
  from 0 s to the next caption. A caption beat timed before 1.5 s is an error, whatever the preset: the
  same config must stay valid under `--motion kinetic,studio`.
- **`card.cta`** is optional: a call to action under the subtitle, drawn as a pill.
- **Accent marks.** `*…*` marks accent words in a caption, the hook or the card
  title. Kinetic draws them in the theme's accent color; other presets drop the
  asterisks. An unclosed `*` is a validation error.

### Theme

**`themes.<appearance>.accent`** is optional, a hex color. It defaults to the
theme's `title` color, which makes accent words look like their neighbours.
Pochette uses `#FF4D6D` dark and `#C3143D` light.

### Beat keys

Every region is `{ "rect": [x, y, w, h] }` in stage pixels or `{ "target": name }`
from a pointer report. Exactly one of the two is required, as today.

| Key | Meaning |
|---|---|
| `focus` | Frame this region. `"home"` frames the whole window. Replaces `zoom`. |
| `spotlight` | Dim everything but this region until `until` (an absolute time). |
| `pop` | Lift this region out as a floating card until `until`. Presets with no pop-out draw a spotlight with an outline instead. |
| `pointer` | Stills only. Move the drawn pointer to `point: [x, y]` or a region's center, arriving at the beat's time; `click: true` adds the click. |
| `present` | Stills only, on a `screen` beat. This region of the new capture is a sheet: it springs up over the window. From one presenting screen to another, the sheets swap. |

- `focus` has an optional `fill` (0.3–1, default from the preset) for "a bit
  looser". There is no scale key anywhere.
- **`zoom` is removed outright, with no alias**, because `videos[]` has never been
  released. A config that still has it fails with
  "`zoom` is now `focus`: drop `scale`, the framing is computed".
- `pointer` and `present` on a recorded video are errors: a take already holds the
  real pointer reports and the real sheet animation.

### CLI

`compose video --motion a[,b…]` overrides the config's preset.

- Given `--motion`, every output is named `<id>~<motion>~<appearance>~<w>x<h>.mp4`,
  even with one preset, so successive comparisons never overwrite each other.
- Without it, names stay as they are today.

Contact sheets and reports follow the same naming.

## 2. Presets

A preset is a value (`MotionPreset`), not a code path. Its fields, with the spike's
values:

| Field | kinetic | studio |
|---|---|---|
| camera spring (response s, damping) | 0.7, 0.78 | 1.0, 1.0 |
| sheet spring | 0.45, 0.7 | 0.55, 0.9 |
| focus fill / zoom cap | 0.92 / 2.6 | 0.9 / 2.6 |
| drift (amplitude, period) | 4%, 10 s | 2.5%, 10 s |
| captions | band at the top, words in a stagger (0.06 s, spring 0.5/0.7), weight 800, 6.2% of the short side | pill at the bottom, fade-up, weight 600, 4% |
| hook card | yes, 1.5 s, 11% of the short side, words staggered 0.08 s | no |
| spotlight dim | 0.62 | 0.5 + white outline |
| pop-out | scale 1.32, spring 0.5/0.62, accent outline | none (spotlight + outline) |
| pointer | drawn, arcing travel 0.7 s, click squash 15% / 0.18 s, ripple 0.5 s | same |
| background | theme gradient, angle ±12° over 20 s, accent glow drifting | gradient only |
| entry | window springs up from below at the hook's end | fade + scale from 94% over 0.8 s |
| exit to card | window falls out of frame, accelerating, 0.45 s | scale to 88% + fade, 0.7 s |
| end card | icon springs (0.55/0.55), title and subtitle rise, CTA pill in accent | fades and rises, CTA outlined |
| motion blur | 6 samples, 90° shutter, above 3 px per 1/60 s | same |

A preset only *chooses* among the drawing styles the renderer knows: caption style,
pop style, entry, exit, card. Adding a third preset made only of existing styles is
data only.

## 3. Rendering

### 3.1 Layout

Sizes scale with the short side of the output (`minDim`), with margin `m` = 5%.

- **Band captions (kinetic).** The band at the top is high enough for the longest
  caption or hook, wrapped at `W − 2m`: lines × 1.15 × font + 2m. The window's box
  is the rest, minus the margin.
- **Pill captions (studio).** The box is the whole frame minus the margin, and the
  pill overlays the bottom.
- **Fit.** `fit = min(box.w ÷ stage.w, box.h ÷ stage.h)`. The window at rest is
  centered in its box.
- **Scrim.** When the camera pushes the window up into the band, a scrim fades in
  under the caption, in proportion to how far the window intrudes. Text never sits
  bare on app pixels.
- **App Store previews** keep their current layout: the caption strip and the dark
  surround. They take the preset's camera, spotlight, pop and pointer, but never its
  hook card or end card. Apple asks for app footage, and a full-frame text card is
  not that.

### 3.2 Camera

- **Focus moves.** The camera state is (log zoom, center in stage pixels). Each
  `focus` beat pulls the state toward its target with the preset's spring, folded
  in order the way `camera(at:)` folds today. The spring is a closed-form step
  response, a function of t alone, so frames can be rendered in any order.
- **Target.** For a region the target is
  `zoom = clamp(fill × min(box.w ÷ (r.w × fit), box.h ÷ (r.h × fit)), 1, cap)`,
  centered on the region. For `"home"` it is zoom 1 at the stage center.
- **Drift.** Drift multiplies zoom by `1 + amp × (½ − ½ cos(2πt ÷ period))`. It is
  continuous, so it never jumps at a beat.
- **Clamp.** With `k = fit × zoom` and the anchor at the box center, each axis's
  center is clamped between `anchor ÷ k` and `stage − (frame − anchor) ÷ k`, taking
  the smaller of the two as the lower bound. This keeps a large window covering the
  frame and a small one inside it.
- **Placement.** Entry and exit transform the placed rect last. Every overlay maps
  stage points through that final rect, so spotlights, pops and the pointer stay
  glued to the window during entry, exit and drift.

### 3.3 Layers, in drawing order

1. **Background.** The animated gradient, plus the accent glow in kinetic.
2. **Window.** The stage image in the placed rect, with a Core Graphics shadow
   (blur 5% and offset 2% of `minDim`). The stage image is the master frame at
   `t`. It is taken once per output frame, not per blur sample, because a recorded
   master can only be read forwards.
3. **Spotlight.** An even-odd fill over the window rect with the region cut out,
   rounded, padded by 1.2% of `minDim`. Its envelope rises on a critically damped
   0.6 s spring and falls over 0.4 s after `until`.
4. **Pop-outs.**
   - The region is cropped from the current stage image and drawn scaled about its
     mapped center, lifted 1.2% of `minDim`.
   - It is clipped to a rounded rect, with a shadow and an accent outline.
   - It is capped at 94% of the frame width and kept inside the frame horizontally.
   - Each pop also implies a spotlight on the same region for the same span.
5. **Pointer.**
   - Drawn, not Apple's artwork. Its size is 3% of `minDim` × √zoom.
   - Travel follows a slight arc. The pointer fades in 0.25 s before its first
     beat and out after its last; when it follows recorded reports, it shows from
     the first report on.
   - Where it comes from depends on the video: pointer reports for a take, `pointer`
     beats for stills.
6. **Scrim and captions.** The caption is band or pill; its exit runs over the last
   0.25 s before the next caption, the end card or the hook handoff.
7. **Hook** (kinetic, 0–1.5 s). Words rise in with a spring and the block exits up
   from 1.15 s. The window enters at 1.25 s.
8. **End card.** The window exits from the card beat's time, and card content
   starts 0.3 s later.

### 3.4 Stills transitions

`StillsMaster` gains the preset's sheet spring.

- **Present.** A `screen` beat with `present` and a screen before it without one:
  - the new capture fades in outside the region over 0.35 s;
  - the region, cropped from the new capture, springs from 90% to 100% with a
    shadow.
- **Swap.** Both screens present:
  - the window is the new capture outside the sheet;
  - inside the sheet's area it is the most recent earlier screen with no `present`;
  - over that, the old sheet shrinks 5% and fades over 0.2 s, and the new one
    presents from 0.16 s;
  - with no bare screen to borrow, it falls back to a crossfade.
- **Everything else** crossfades as today.

### 3.5 Motion blur

- **When.** A frame is blurred when the placed window rect moves more than 3 px
  between `t − 1/60` and `t`. The measure is the sum of origin and width deltas.
- **How.** The frame is then the running average of 6 sub-frames over
  `[t − 0.25/30, t]`. Sub-frames re-run the camera, overlays and text at their own
  times, over the same stage image. Still frames cost nothing extra.

### 3.6 Performance

- **No cached backdrop.** The cached backdrop (gradient + shadow) goes away,
  because the window moves every frame.
- **Parallel outputs.** `compose video` renders its outputs concurrently, one task
  per output, each with its own master, because a recorded master cannot be shared
  across readers.
- **Budget.** The budget is the success criterion: under 2 minutes for a 20 s
  1080p kinetic render. The plan measures it on the Pochette config.

## 4. Validation and the report

- **New `AppShotError` cases**, each with a description and a slug:
  - unknown motion preset;
  - `zoom` present;
  - unclosed accent mark;
  - caption before the hook ends;
  - `pointer` or `present` on a recorded video;
  - `present` on a non-`screen` beat;
  - `spotlight` or `pop` with `until` at or before its beat;
  - `focus` `fill` outside 0.3–1.
- **Unreported targets.** A `focus`, `spotlight` or `pop` target that no pointer
  cue reported at or before its time fails with the message zooms use today.
- **Camera warnings** are listed in the report and do not fail the render.
  - **`cameraNeverSettles`:** two `focus` beats closer than the preset's camera
    response.
  - **`popOverload`:** more than three pops in a video.
- **Report contents.** The report names the preset, and the contact sheet's cells
  include one inside the hook and one inside each pop.

## 5. Testing

All tests use Swift Testing in `AppShotKitTests`.

- **Springs.**
  - A spring is 0 at t ≤ 0 and converges to 1.
  - Critically damped springs never exceed 1; kinetic's camera spring does.
  - The result is identical for the same t.
- **Camera.**
  - A focused region fills `fill` of the box on its binding axis.
  - Zoom stays within 1…cap.
  - The clamp keeps a large window covering the frame and a small one inside it.
  - Placement changes by less than a bound between consecutive frames across a
    whole video. This catches teleports.
  - Drift is continuous across beats.
- **Text.**
  - Accent parsing strips marks and flags words, including a span over several
    words and trailing punctuation.
  - An unclosed mark is an error.
  - Wrapping respects the width.
  - Hook handoff: the first caption's span runs from 0 s, and the reading rule
    uses it.
- **Rendering**, on small canvases (e.g. 320×180):
  - outside a spotlight is darker than inside it;
  - a pop's center pixel matches the enlarged crop and sits above the window;
  - at t = 0.5 kinetic shows the hook and no window pixel;
  - at the card's end the window is fully gone;
  - previews never draw the hook or the card;
  - two renders of one frame are byte-identical.
- **Stills transitions.**
  - Mid-present, the sheet region is scaled below 100%.
  - Mid-swap, no pixel shows both sheets' text, checked on synthetic captures with
    disjoint colors.
- **Config.** Each new error case is covered, and so is the `--motion` naming,
  single and multiple.
- **Visual check.** `make bench-motion` renders the fixture app's video in both
  presets for a look by eye. It stays out of CI, like `bench-record`.

## 6. Docs, skill, migration

- **README.** The video section documents `motion`, `hook`, `accent`, `focus`,
  `spotlight`, `pop`, `pointer`, `present`, `card.cta` and `--motion`. The
  CHANGELOG's unreleased entry describes the final shape; `zoom` never shipped.
- **The `appshot-video` skill.**
  - Update the beat-keys table and the example.
  - Add a motion section to `references/scripting.md`:
    - one message per pop and no more than three pops in 20 s;
    - hooks of six words or fewer;
    - the pointer only for actions that cause a change;
    - focus beats at least a camera response apart.
  - Add the new errors to the error→fix table.
  - Add one stills eval checking for a hook, a focus and a pop.
- **Pochette.** A real `videos[]` entry with the spike's script, made the reference
  example the README and skill point to. It goes in its own commit; the repo has
  someone else's uncommitted work, which stays untouched.
- **Armada.** After appshot lands, its two entries move from `zoom` to `focus`,
  gain a hook, and get a `pop` on the waiting session row. This is a config-only
  commit in the Armada repo.
- **Spike cleanup.** Once this spec is approved, branch `spike/motion-presets` and
  the `~/Projects/appshot-spike` worktree are deleted.

## 7. Rollout

1. appshot: presets, camera, layers, stills transitions, validation, tests, docs and
   skill, on a branch merged to local main. As with the video work, there is no
   push, tag or release without asking.
2. Pochette's config and renders, then a review by eye.
3. Armada's migration and re-render for the X test.
