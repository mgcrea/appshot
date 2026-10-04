---
name: appshot-video
description: Make, fix or review a video of an Xcode app — a Mac App Store app preview, a promo or demo video for X/Twitter, LinkedIn or other social ads, a hero loop for the marketing site, a trailer — with appshot's `record` and `compose video`. Use this skill whenever the user wants a "demo video", "promo video", "app preview", "screen recording of the app", "a 20s clip for an ad", "a video for the website", or asks how to film their app without recording it by hand; when they mention `appshot record`, `appshot compose video`, `--from-stills`, `videos[]` in screenshots.config.json, cue files, `-ScreenshotCueFile`, or a contact sheet; and when a video run fails — a caption "is on screen for 1.2s but needs 2.5s", "the cues changed since the take; re-record", a cue that was "never acked" or answered unknown, "no ready event", a focus that "targets X, which no pointer cue reported", an empty or frozen recording. Reach for it even when the ask sounds like pure marketing ("we need something for the ad", "the post got no traction, let's try a video") — the fastest honest video comes from the app's own screenshots, and the steps that keep it honest live here. Also use it to add the cue handler to an app's demo mode so it can be recorded, or to script captions and pacing for a 15-30 s piece. Screenshots themselves belong to appshot-screenshot-pipeline.
---

# App videos with appshot

A good app video is a short script the app performs on cue, filmed, then dressed with
captions, a pointer, a camera and an end card. appshot splits that into two commands so the
expensive part happens once:

```
appshot record          app performs the script → videos/source/<id>~<app>.mov   (the take)
                                                 + <id>~<app>.track.json          (what it did)
appshot compose video   take + track + config   → videos/promo/…, preview/…, report/…
appshot compose video --from-stills <captures>  → the same outputs, from screenshots, no take
```

**Nothing is clicked or typed.** appshot never drives the app with synthetic input — the
person at the Mac keeps working during a take. It writes named **cues** to a file; the
app's demo mode performs them through its own code and writes back what happened. The
pointer you see in the video is drawn afterwards from the rectangles the app reported.
That is why a recorded video needs a small cue handler in the app, and why the
from-stills path needs none.

**The render is a pure function of take + track + config.** Change a caption, its timing,
a focus or the end card and you re-run `compose video` only — seconds, no app. The take
fixes two things:

- **The cues.** Change a cue's name, args or `at`, or add or remove one, and the render
  refuses with *"the cues changed since the take; re-record"*.
- **The length.** The take lasts the `duration` it was recorded with. Shortening
  `duration` afterwards is fine; lengthening it is refused (*"the take is 12s long and the
  video asks for 16s"*), because the master has no frames past its end.

Keep both in mind when scripting; they decide what is cheap to iterate on. Settle the
cues and the length on a stills draft first, then record once.

## Setup

```bash
cd ~/Projects/appshot && make install        # puts `appshot` on PATH
appshot --help                               # must list `record`
appshot compose video --help
```

`record` and `compose video` arrived in the release after 0.19.0. **`appshot --help`
listing `record` is the tell**; if it is missing, the binary on PATH predates video — the
version string alone may not show it while the release is being cut.

Videos live in the same `screenshots.config.json` as the screenshots, under `videos[]`,
and reuse its theme, fonts and layout. A config with no `videos` key behaves exactly as
before. The app's demo mode, launch-argument staging and fixtures are the screenshot
pipeline's (see the **appshot-screenshot-pipeline** skill); a video stage is just another
`-ScreenshotStage` value.

## Pick the path first

| | From stills | Recorded |
|---|---|---|
| App code needed | none | a cue handler in demo mode (`references/app-side.md`) |
| Shows | crossfades between captures, captions, focus, spotlight and pop on fixed rects, a scripted pointer, sheets that spring up, end card | the app actually moving: clicks landing, panels opening, numbers changing |
| Pointer | yes, from `pointer` beats | yes, drawn from reported targets |
| Time to first video | minutes | an afternoon the first time |
| Good for | a first ad test, a site loop, proving the script before investing | App Store previews worth watching, a product that *does* something on screen |

**Start from stills unless the user already has the cue handler.** It produces a real,
reviewable video today, it validates the script (pacing, captions, order) before anyone
writes app code, and every caption and timing decision carries over to the recorded
version unchanged. Recording is the upgrade, not the starting point.

App Store **previews** must show the app itself. Captions over the footage are fine; a
closing marketing card is not app footage, so appshot never draws the end card in a
preview, and the preview's surround is the theme's darkest colour rather than the promo
gradient. The `endCard` beat still *ends the captions* in a preview, so one `videos[]`
entry that makes both a preview and a promo shows a few caption-less seconds at the end of
the preview — put the card late (last 3 s), or give the preview its own entry. For an App
Store preview prefer the recorded path; stills are allowed but weak.

## The `videos[]` entry

```json
"videos": [{
  "id": "intro",                     // lowercase, digits, -   (becomes a filename)
  "stage": "usage",                  // -ScreenshotStage for `record`; unused by --from-stills
  "duration": 22,                    // seconds; a preview must be 15-30
  "poster": 4,                       // optional; default min(5, duration/2)
  "outputs": {
    "preview": false,                // App Store preview, Mac 1920x1080 (iOS: not yet)
    "promo": [[1920, 1080], [1200, 1200]],   // framed promos, any even sizes
    "website": true                  // muted loop, copied at the first promo size
  },
  "motion": "kinetic",               // or "studio"; default kinetic
  "hook": "Every agent, *one menu bar*.",   // opening full-frame line, holds 1.5 s
  "card": { "title": "Armada", "subtitle": "Every agent session, one menu bar", "icon": "icon.png" },
  "beats": [
    { "at": 0,   "screen": "usage" },
    { "at": 1.5, "cue": "pointer.click", "args": { "target": "session-2" } },
    { "at": 2.2, "pop": { "target": "session-2", "until": 5 } },
    { "at": 6,   "screen": "transcript", "caption": "Jump straight to the one that needs you", "focus": "home" },
    { "at": 18,  "endCard": true }
  ]
}]
```

(The `//` comments are explanation only — the file is plain JSON.)

A **beat** is one moment. Any combination on one beat is fine:

| Key | Means |
|---|---|
| `at` | When, in seconds. Beats must be in time order and inside `0..<duration`. |
| `caption` | Text that runs until the next caption, the end-card beat, or the end. Fades 0.25 s. |
| `until` | End this caption **earlier** (needs a caption). It can only shorten: a caption never runs past the next caption or the end-card beat. |
| `cue`, `args` | Recorded path: what the app performs. `args` values are strings, numbers or bools. |
| `focus` | Frame a region: `{ "rect": [x,y,w,h] }` in stage pixels or `{ "target": name }` (a reported element), optional `fill` 0.3-1. `"home"` frames the whole window. The camera computes its own framing; there is no zoom level. |
| `spotlight` | Dim everything but a region until `until`. |
| `pop` | Lift a region out as a floating card until `until` (studio draws an outlined spotlight). |
| `pointer` | `--from-stills` only: move the drawn pointer to `point` or a `rect`'s center; `click: true` clicks. A take uses the app's own pointer reports. |
| `present` | `--from-stills` only, on a `screen` beat: that region is a sheet that springs up; sheet to sheet, they swap. |
| `screen` | From-stills path: cut to that `screens[]` capture (0.5 s crossfade). The first beat must be at 0 and name one. |
| `hook` | Entry-level, not a beat key: the opening line, held for the first 1.5 s; a caption timed before 1.5 s is an error. |
| `endCard` | Promo only: fade to the card (0.4 s). At most one. |

Every command that loads the config validates `videos[]` first and names the beat and the
rule it broke, so a bad entry fails in a second rather than after a take.
Scripting craft — the reading rule, pacing a 20 s piece, when to focus, spotlight or pop — is in
**`references/scripting.md`**. Read it before writing captions; the reading check is the
mistake that fails the most first drafts.

## Path A — from stills

1. Make sure the captures are current (`make screenshots-capture` or the repo's
   equivalent). The video shows exactly these files: a stale capture is a stale video.
2. Add the `videos[]` entry with a `screen` on the first beat (at 0) and on every cut.
   Each name must be a `screens[]` id the config captures; the file read is
   `<screen>~<appearance>.png` in the directory you pass.
3. Render:

   ```bash
   appshot compose video --config Screenshots/screenshots.config.json \
     --from-stills Screenshots/source --videos intro --appearances dark
   ```

4. Review (below), adjust captions and timing, re-render. Repeat until the report is clean.

Captures of different sizes are centered on one canvas, never stretched. Focus, spotlight, pop and `present` on stills
use `rect` in that canvas's pixels — read the capture's size first.

## Path B — recorded

1. **The app side.** Add the cue handler to demo mode: `assets/AppShotCues.swift` is a
   drop-in; the app writes one `switch` saying what each cue does. Everything the handler
   must get right (ready timing, acking after the frame draws, global top-left rects,
   window levels, keeping real data out) is in **`references/app-side.md`** — read it
   before touching the app. `Sources/AppShotFixture/VideoFixture.swift` in the appshot
   repo is a complete working example.
2. **The script.** A `videos[]` entry with `stage` and `cue` beats. Use the shared cue
   names where they fit — `stage` (`{"to": …}`), `pointer.move` / `pointer.click`
   (`{"target": …}`), `scroll` — and an app prefix (`armada.flag-attention`) for the rest.
3. **Record**, always in the background so the person can keep working:

   ```bash
   appshot record --app build/MyApp.app --config Screenshots/screenshots.config.json \
     --videos intro --appearances dark --no-activate
   ```

   A take holds the machine-wide capture lock for its whole duration; another project's
   capture fails fast unless it passes `--wait`. Pass `--wait` yourself if one is running.
4. **Compose and review** (below). From here on, iterate with `compose video` alone.

What fails a take, and why it is a feature: a cue never acknowledged within 1 s, acked
more than 250 ms after its time (warns above 50 ms), answered `unknown`, no `ready` event
within `--settle-max`, or ScreenCaptureKit stopping the stream. Each one terminates the
app it launched and leaves no master behind. A take that cannot be trusted would produce
a video whose captions describe something the screen is not showing.

## Review without watching

Every compose writes, per video and appearance:

- `videos/report/<id>~<app>.contact.png` — one labeled frame per beat (0.8 s after it, once
  transitions settle) and one mid-caption. **Open it with the Read tool and look.** This
  is how you check the focus lands on the right element, the pointer is on the target, a
  caption isn't covering what it describes, and the end card reads.
- `videos/report/<id>~<app>.report.json` — per beat scheduled vs actual time and cue
  latency, per caption shown vs needed seconds and the **margin**, plus `frames` and
  `maxFrameGap` for a recorded take.

A video is reviewable, and done, when:

- every caption margin is ≥ 0 (compose refuses otherwise, before writing anything);
- latencies are under 50 ms (a warning is a cue the app is slow to draw — fix the app);
- `maxFrameGap` is a frame or two (≈0.033 s); a larger gap means the take stuttered;
- the contact sheet shows each beat doing what its caption says;
- the report's `warnings` are empty or understood: `cameraNeverSettles` / `popOverload` do not fail the render, but space focus beats a camera response apart (kinetic 0.7 s, studio 1 s) and keep pops to three.

Report those numbers and the contact sheet path to the user — they decide whether it is
good; you decide whether it is *correct*.

Outputs: `videos/promo/<id>~<app>~<W>x<H>.mp4`, `videos/promo/<id>~<app>.poster.png`,
`videos/preview/<id>~<app>.mp4` (App Store), and with `--website-out <dir>` the loop as
`<dir>/<id>.mp4` (one appearance) or `<id>~<app>.mp4`. All are H.264 at 30 fps with a
silent stereo AAC track (Apple requires stereo audio on previews; the promos match).
Anything interrupted is left as `.partial`, never as a file that looks finished.
Which sizes each destination wants is in **`references/outputs.md`**.

## When it fails

| Message | Meaning | Fix |
|---|---|---|
| `the caption "…" is on screen for 1.2s but needs 2.5s` | Reading rule: 1 s + 0.3 s per word, cut short by the next caption or the end-card beat. Count the words yourself — the caption quoted is the one that's short. | Cut words, or move the *next* caption (or the end card) later. Re-render only. Not `until`: it only shortens. |
| `the cues changed since the take (…); re-record` | A cue's name, args or `at` changed, or one was added/removed. | `appshot record` again, or revert the cue edit. |
| `the take is 12s long and the video asks for 16s` | `duration` was raised after recording. | Re-record at the new length, or bring `duration` back. |
| `focus/spotlight/pop at Ns targets "x", which no pointer cue at or before it reported` | It names an element the app never reported. | Put a `pointer.move`/`pointer.click` on `x` at or before it, or use a `rect`. |
| `beat N uses zoom, which is now focus` (`zoom_renamed`) | An old config. | `"focus": { "rect" \| "target" }`, no `scale`; `"focus": "home"` for `scale: 1`. |
| `no motion preset "x"` (`unknown_motion`, also from `--motion`) | A typo, or a preset that does not exist yet. | `kinetic` or `studio`. |
| `caption at Ns starts under the hook` | A caption before 1.5 s in a video with a `hook`. | Move it to 1.5 s or later, or make it the hook. |
| `beat N has pointer/present, which is for --from-stills` | A stills-only key on a recorded video (raised by `compose video`, not at config validation). | Remove it: the take has the real pointer and sheet. |
| `… leaves no room for the app under the caption` / `… leaves no room for the hook` | A hook (or caption) too long for the canvas; on a kinetic promo, a hook too tall for its own full-frame card. | Shorten the hook (six words or fewer), or use a larger size. |
| `cue #n "…" failed: the app does not implement it` | The handler answered `unknown`. | Implement it, or rename to a cue the app has. |
| `cue #n … no ack within 1.0s` | Cue file not watched, or the handler threw it away. | Check the app reads `ScreenshotCueFile`/`ScreenshotEventFile` and calls the handler; see `references/app-side.md`. |
| `acked 312ms after its time` | The effect took too long to draw. | Make the demo-mode path synchronous (pre-loaded fixtures, no network, no animation waits before acking). |
| `no ready event within 8.0s` | `ready()` never called, or called before the cue file existed. | Call it after the first screen is drawn; raise `--settle-max` only if staging is genuinely slow. |
| `ScreenCaptureKit did not answer … within 15s` | replayd wedged. | `killall replayd`, retry. |
| `--from-stills needs a beat at 0 that names a screen` / missing `<screen>~dark.png` | Stills path setup. | Add `screen` to the first beat; capture the screen or fix the id. |
| `App Store previews for iOS arrive with iOS recording` | iOS previews not supported yet. | `preview: false`; make promos. |
| `an App Store preview must last 15-30s` | Apple's limit. | Change `duration`, or drop `preview`. |

## Hard rules

- **No synthetic input, ever** — no clicks, keystrokes, AppleScript/System Events,
  CGEvent, cliclick — to stage or drive the app. A cue that "needs" a click means the demo
  mode needs a code path; add it. The person is using this Mac.
- **Record with `--no-activate`**, and quit anything you launched when done.
- **The video shows demo data only.** The cue path runs inside screenshot mode, behind the
  same guards that keep the developer's real folders, accounts and sessions out of
  captures. Never add a cue that reaches real data.
- **Don't fake a recorded look from stills** (e.g. hand-drawing a pointer onto a still).
  If the story needs motion, it needs the recorded path.
- Masters and outputs are build artifacts: keep `videos/` git-ignored unless the repo
  already commits its store media.

## Bundled resources

| File | Read when |
|---|---|
| `references/scripting.md` | Writing or fixing the beats and captions; pacing; motion (focus, spotlight, pop) and pointer use. |
| `references/app-side.md` | Adding or debugging the app's cue handler. |
| `references/outputs.md` | Choosing sizes and lengths for App Store, X, LinkedIn, the site; uploading. |
| `assets/AppShotCues.swift` | Drop-in cue handler; the app supplies `perform`. |
