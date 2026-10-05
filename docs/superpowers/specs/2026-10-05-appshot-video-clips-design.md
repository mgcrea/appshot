# appshot video: clips

Status: design approved in conversation 2026-10-05, awaiting spec review.

Amended during implementation (2026-10-05). The text below describes what was built:

- A clip's `frames` counts distinct pictures, and `maxFrameGap` is measured between
  distinct pictures, through to the stop (§2). ScreenCaptureKit sends a frame whenever
  anything on the display changes, so counting every frame called a still window on a busy
  Mac "moving".
- `trafficLights` is replaced by `lightsPatch { rect, recolored }` and a
  `<screen>~<appearance>.lights.png` beside the clip (§2, §3). macOS draws a "screen
  shared" capsule over the buttons of a streamed window in every frame, so the buttons come
  from a pre-roll screenshot taken before filming. Old sidecars with `trafficLights` still
  decode and compose without a patch. A chrome screen whose buttons are not found records
  no patch, and `record --clips` warns.
- `--recolor-traffic-lights` is applied at record time, to the patch, not at compose time
  (§2, §3).
- The CLI example's `--screens` takes space-separated values, like `capture`, and so does
  `--videos` (§2).
- Masters, clips and scripted takes alike, are recorded as sRGB-tagged HEVC so they decode
  to the stills' tones. On an OS whose writer refuses the tags they fall back to the old
  untagged master (§2).

## Goal

Give `compose video` real moving footage without asking the app for a cue handler.

The two paths today sit at the two ends:

- `--from-stills` needs no app code. But the screen never moves: the video is a
  crossfade between screenshots. App Store previews made this way are allowed, but
  they are the weak kind.
- `record` films the app moving. But the app must implement the cue protocol: read
  the cue file, perform each cue, acknowledge after the frame draws and report
  targets. That is an afternoon the first time, and more for an app whose interesting
  states are hard to reach on cue.

Many apps move on their own once they are staged. Notes fall, a chart animates, a
timer counts, a list streams in. For them, a third path fits in between: **one short
clip per screen**. appshot launches each stage the way `capture` does, waits for the
ready file, and films the app moving for as long as the video holds that screen.
`compose video` then cuts between clips the way it cuts between stills.

Pupitre is the first user. Its hero, learning and loop screens play the song from the
staged moment. Its challenge screen needs a demo auto-player before it can move, so it
stays a still until then. This is why a video may mix clips and stills.

### Success criteria

- `appshot record --clips` films every screen that the chosen videos name, for every
  appearance, with no cue file and no event file. An app that already supports
  `--ready-file` captures needs one new behaviour: start moving after ready under
  `-ScreenshotClip YES`.
- `appshot compose video --from-clips <dir> --from-stills <dir>` renders any existing
  `videos[]` entry unchanged. Each screen uses its clip when one is recorded, else its
  still.
- Rects written for stills (`focus`, `spotlight`, `pop`, `pointer`) land on the same
  pixels in the clip of the same screen.
- Changing captions, timing within a screen's recorded length, framing or motion
  needs a render only, never a re-record.
- A clip that never moved, or that is too short for the video, is reported by name
  before anything is written, or as a warning in the report.
- Renders stay deterministic: the same clips, stills and config give identical frames.

### Out of scope

- **Audio.** Clips record no sound, and outputs keep their silent stereo AAC track.
  Capturing and mixing the app's sound is a later spec.
- **iOS clips.** There is still no device or simulator recording; `record --clips`
  refuses an iOS config with `Recorder.iosReason`, as `record` does.
- **Trimming or offsets inside a clip.** Every screen beat plays its clip from clip
  time 0.
- **Cues during a clip.** A video that needs the app to react on cue uses `record`.

## 1. App contract

Under `record --clips`, appshot launches each stage with the arguments `capture`
passes today, plus two of its own:

```
-ScreenshotStage <stage> -ScreenshotAppearance <appearance>
-ScreenshotReadyFile <path> -ScreenshotClip YES
```

The app:

1. stages exactly as it does for a screenshot of that stage, with the same demo data
   and the same guards;
2. writes the ready file once the staged frame is drawn, as `--ready-file` captures
   already require;
3. **starts moving at once**: plays, scrolls or animates in demo mode, through its own
   code;
4. keeps moving, deterministically, for at least the clip's length.

Without `-ScreenshotClip`, nothing changes: a screenshot run must still freeze on the
staged frame.

Synthetic input stays forbidden, as it is for `capture` and `record`. A screen that
can only move because something is clicked needs a demo code path, or the `record`
path.

## 2. Recording: `appshot record --clips`

### CLI

```
appshot record --clips --app build/MyApp.app --config Screenshots/screenshots.config.json \
  --out Screenshots/videos/clips --videos intro preview [--screens hero:hero loop] \
  --appearances dark --no-activate --capture-display builtin --no-wallpaper-tint \
  --recolor-traffic-lights --extra-args="…" --settle-max 8 --wait
```

- `--clips` switches `record` to clip mode. Without it, `record` is unchanged.
- `--videos` picks the videos whose `screen` beats decide which clips to record.
  Omitted, it means every video.
- `--screens` narrows the set and maps screen to stage, using capture's `name[:stage]`
  syntax (`Capture.Screen(spec:)`). The stage defaults to the screen id. A settle
  suffix is accepted and ignored: a clip has no settle floor.
- The placement flags mean what they mean for `capture`, and reuse its code:
  `--capture-display`, `--no-wallpaper-tint` (`GlobalBoolOverride`) and
  `--no-activate` (with `ForegroundGuard`, as `capture` runs it). `--recolor-traffic-lights`
  is applied at record time, to the window-button patch (§3).
- `--wait` and the machine-wide capture lock behave as in `record`: the lock is held
  for the whole run.

### What is recorded

There is one clip per (screen, appearance) named by a `screen` beat in a chosen video.
A clip is shared by every video that uses that screen.

The **length is computed**, never configured:

```
hold(screen) = longest span, across the chosen videos, from a beat naming that screen
               to the next beat naming a screen, or to the video's end
length       = hold + 0.5 s (the crossfade into the next screen) + 0.5 s (margin)
```

Both 0.5 s values are `StillsMaster.crossfade` and a named margin constant, never
literals.

### One clip

1. Launch with `Capture.openArguments` plus the two clip arguments above, then
   `waitForNewPID` and `waitForWindow`.
2. Wait for the ready file (`Capture.waitForReady`) up to `--settle-max`. Clip mode
   does not run the stillness poll, because the screen is supposed to move.
3. Take a pre-roll screenshot of the window, as `capture` does (recoloured under
   `--recolor-traffic-lights`), and cut the window-button patch from it (§3). Then start
   the stream with `StreamRecorder` over the app's windows, as `record` does
   (`stageWindows`, live filter updates, HEVC with alpha, tagged sRGB).
4. **t = 0 is the first complete frame after the ready file appeared.** Record until
   `length`.
5. Stop the stream and terminate the app (`Capture.terminate`).

The crop is the union of the app's windows over the clip (`Recorder.stageCrop`), in
display pixels at the display's backing scale. That is the same scale `capture` shoots
at, so a clip of a stage has the size of its still.

### Files

```
<out>/<screen>~<appearance>.mov         HEVC with alpha, full display, as record's masters
<out>/<screen>~<appearance>.clip.json
<out>/<screen>~<appearance>.lights.png  the window-button patch, when there is one
```

The masters of clips and of scripted takes are tagged sRGB (primaries and matrix BT.709,
transfer sRGB), and `StreamRecorder` asks ScreenCaptureKit for sRGB frames, so they decode
to the tones of the stills. If the writer refuses the tags on an OS, the master falls back
to untagged, as before. Masters recorded before this change keep the old, lighter tone.

`ClipInfo` (`.clip.json`):

| Field | Meaning |
|---|---|
| `screen`, `stage`, `appearance` | what was filmed |
| `length` | seconds recorded, measured from t = 0 to the last frame |
| `crop` | `[x, y, w, h]` in master pixels, top-left origin |
| `lightsPatch` | `{ "rect": [x, y, w, h], "recolored": bool }`: where the patch goes, in crop pixels, and whether it was cut under `--recolor-traffic-lights`. Present on every screen whose `chrome` is not `none` and whose buttons were found; absent otherwise. The image is `<screen>~<appearance>.lights.png` |
| `frames` | distinct pictures filmed: frames that differ from the one before |
| `maxFrameGap` | the longest time between two distinct pictures, the last one to the stop included, so a clip that never moved shows about its whole length |
| `appshotVersion`, `recordedAt` | provenance |

### Failures

- Each clip is written as `.partial` and moved into place only once it is complete.
- A failed clip stops the run and is named in the error, as a take is. Clips already
  finished are kept, since each clip is independent. `--screens hero` re-records one.
- The failure messages are the ones `capture` and `record` already use:
  `appNeverStarted`, `windowNeverAppeared`, `appNeverSignalledReady`, plus `recordFailed`
  for stream failures.
- Cleanup and Ctrl-C handling follow `Recorder`: terminate the pids we launched, then
  delete the `.partial`.

## 3. Compose: `--from-clips`

### CLI

```
appshot compose video --config … --from-clips Screenshots/videos/clips \
  [--from-stills Screenshots/source] --out Screenshots/videos --videos intro
```

- `--from-clips` and `--from-stills` may be passed together. `--from-clips` cannot be
  combined with `--source`, which is the recorded path.
- Each `screen` beat resolves to `<clips>/<screen>~<appearance>.mov` if it exists,
  else to `<stills>/<screen>~<appearance>.png`. If neither exists, the run fails with
  `missingCaptures`, naming both paths.
- compose prints how each screen resolved before rendering:
  `intro~dark: clips hero, learning, loop · stills challenge`.

### `ClipsMaster`

A new `VideoMaster`, beside `StillsMaster` and `RecordedMaster`.

- **Segments.** Every beat that names a `screen` starts a segment. The segment plays
  its clip from clip time 0, or shows its still. A screen named twice restarts its
  clip.
- **Canvas.** Clip crops and still sizes are centered on one canvas, the largest width
  by the largest height, exactly as `StillsMaster` centers captures. Nothing is
  stretched.
- **Crossfade.** The same 0.5 s `Ease.smooth` crossfade as stills. During a crossfade
  both segments produce frames.
- **Decoding.** Each clip segment owns a `RecordedMaster`, opened when the segment
  begins and released when its crossfade out ends. So at most two decoders are open per
  output. Times stay non-decreasing within a segment, which is the reader's contract.
  `RecordedMaster.init` takes a crop rect and a label instead of a whole `VideoTrack`;
  the recorded path passes the track's stage.
- **Traffic lights.** macOS draws a "screen shared" capsule over the buttons of a
  streamed window, in every frame. So `record --clips` takes one pre-roll screenshot (as
  `capture` does, recoloured under `--recolor-traffic-lights`) and cuts the button row plus
  half a disc on each side into `<screen>~<appearance>.lights.png`. Compose pastes it
  (`.copy`) over every decoded frame before centering, so the buttons match the still's and
  a crossfade between a still and a clip does not flicker them. The corner is frozen:
  anything animating beside the buttons does not move. A `chrome: none` screen records no
  patch, and a chrome screen whose buttons are not found records none and `record --clips`
  warns. The recorder's filter stays an allow-list of the app's windows: a display filter
  that excludes other windows would avoid the capsule but let later windows into the stage.
  A sidecar with the old `trafficLights` field decodes and composes with no patch.
- **`present`.** It stays a stills feature. On a clip screen it is refused (§4),
  because the real app draws its own sheet.

The track for a clips video is built like `VideoTrack.stills`: stage `[0, 0, w, h]` of
the canvas, every cue acked at its `at` (there are none, §4), and no targets. It also
carries `frames`, the sum over the clips used, and `maxFrameGap`, the max.

### Report

- Each beat that names a screen gains `source: "clip" | "still"`, and for a clip its
  `frames`, `maxFrameGap` and `length`.
- The top-level `frames` and `maxFrameGap` are the sum and the max over the clips used.
  They are 0 when every screen is a still, as today.
- The contact sheet labels each frame `clip` or `still` after its time.

## 4. Validation and warnings

Errors are raised before anything is written:

| Slug | When | Message |
|---|---|---|
| `clip_too_short` | a clip's `length` is shorter than its hold in this video plus the crossfade | `the clip hero~dark is 4.2s; intro holds hero for 7.0s with the crossfade; re-record hero` |
| `invalid_video` | a `present` beat on a screen that resolved to a clip | `beat 4 presents a sheet on hero, which is a clip: the app draws its own sheets` |
| `invalid_video` | a `cue` beat in a video composed with `--from-clips` | `beat 2 has a cue, which needs a recorded take: clips have no cue channel` |
| `invalid_video` | `--from-clips` with `--source` | `--from-clips and --source are two different paths; pass one` |
| `invalid_video` | `record --clips` on a video that names no screen | `intro names no screen, so there is no clip to record` |

Warnings are written in the report's `warnings`. They do not fail the render:

| Warning | When |
|---|---|
| `clipNeverMoved` | a clip with 3 distinct pictures or fewer over its length: `hero~dark has 2 frames in 7.0s: does the app read -ScreenshotClip?` |
| `clipStillSizeMismatch` | a clip whose crop differs from its screen's still by more than 2 px in either dimension, when both exist: rects written for one land off on the other |

`pointer` beats stay allowed on every screen, clip or still, as they are with
`--from-stills`.

## 5. Testing

Unit tests use synthetic movies made with `VideoMasterTests.writeAlphaMovie` and still
PNGs made with `solid()`:

- segment timing: the clip time is `t - at`, and a reused screen restarts at 0;
- the crossfade decodes two segments and returns the eased mix;
- a mixed canvas centers a clip and a still of different sizes;
- the lights patch is pasted over every frame when `lightsPatch` is present, and a clip whose
  sidecar names a missing patch fails in `segments`;
- the clip-length computation across two videos that hold the same screen for
  different spans;
- `clip_too_short`, `clipNeverMoved` and `clipStillSizeMismatch`;
- validation of `present`, cue beats and `--source` against `--from-clips`;
- the report's `source`, `frames` and `maxFrameGap` fields;
- determinism: two renders produce byte-identical frames.

The integration test (`APPSHOT_INTEGRATION=1`, after `make fixture`):

- the fixture's `video` stage animates its rows when given `-ScreenshotClip YES`;
- a two-screen clip run is recorded, composed and checked end to end, and it leaves
  no `.partial`;
- a fixture stage that ignores the flag records a clip that raises `clipNeverMoved`.

## 6. Docs and skill

- `skills/appshot-video/SKILL.md`:
  - "Pick the path first" gains a **Clips** column: no cue handler needed, real motion,
    no app reactions.
  - A new "Path C: clips" goes between the stills path and the recorded path.
  - "When it fails" gains rows for `clip_too_short`, `clipNeverMoved` and
    `clipStillSizeMismatch`.
- `references/app-side.md` gains a short `-ScreenshotClip` section: start moving right
  after ready, keep demo data, and keep moving for the clip's length.
- The README's video section names the third path.

## 7. Rollout

| Step | Ships | Depends on |
|---|---|---|
| 1 | `ClipsMaster`, `--from-clips` in compose, validation, report, unit tests | synthetic movies only |
| 2 | `record --clips`, `ClipInfo`, the fixture behaviour, the integration test | step 1 |
| 3 | the skill and the README | step 2 |
| 4 | release 0.22.0 | step 3 |

Pupitre adopts it afterwards, in its own repo:

- `-ScreenshotClip` plays the song from the staged moment;
- clips for hero, learning and loop;
- challenge stays a still until its demo auto-player exists.
