# The app side: a cue handler in demo mode

`appshot record` doesn't touch the app's input. It launches the app staged (the same
`-ScreenshotStage` the screenshot pipeline uses), writes cues to a file, and expects the
app's demo mode to perform them and report back. This file is everything that handler
must get right. `assets/AppShotCues.swift` implements the plumbing; the app writes only
what each cue *means*.

## The contract

appshot launches with, on top of the screenshot arguments:

```
-ScreenshotCueFile   <path>    appshot appends cues here, one JSON object per line
-ScreenshotEventFile <path>    the app appends events here, one JSON object per line
```

Both files exist before launch, in the app's sandbox container when it has one
(`~/Library/Containers/<bundle id>/Data/tmp`), otherwise in the temporary directory.
A sandboxed app can read and append to them by the path it's given; don't create, move or
truncate them.

Cue lines: `{"seq":3,"t":1.5,"cue":"pointer.click","args":{"target":"row-2"}}`. `seq`
counts the video's cues from 0; `t` is the scheduled second; `args` values are strings,
numbers or bools.

Events the app writes:

| Event | When |
|---|---|
| `{"kind":"ready"}` | Once, when the first screen is staged and drawn. Recording starts after it. |
| `{"kind":"ack","seq":n}` | After every cue it performed, **one runloop turn after the effect is drawn**. |
| `{"kind":"target","seq":n,"name":"row-2","rect":[x,y,w,h]}` | For pointer cues (and any element a zoom should find), before the ack. |
| `{"kind":"unknown","seq":n,"cue":"…"}` | For any cue the app doesn't implement, instead of an ack. |

appshot matches events by `seq`, so their order across cues doesn't matter.

## Using the drop-in

Copy `assets/AppShotCues.swift` into the app target next to its screenshot-mode code
(e.g. `DemoSeed.swift`). Then, where screenshot mode stages the first screen:

```swift
@MainActor enum DemoCues {
    static var handler: AppShotCues?

    static func start(model: DemoModel) {
        handler = AppShotCues.start { cue in
            switch cue.name {
            case "stage":
                guard let to = cue.string("to"), let stage = Stage(rawValue: to) else { return .unknown }
                model.show(stage)
                return .done
            case "pointer.move", "pointer.click":
                guard let name = cue.string("target"), let view = model.view(named: name),
                    let rect = AppShotCues.screenRect(of: view)
                else { return .unknown }
                if cue.name == "pointer.click" { model.activate(name) }
                return .target(name: name, rect: rect)
            case "myapp.flag-attention":
                model.session(cue.string("id"))?.state = .needsAttention
                return .done
            default:
                return .unknown
            }
        }
        handler?.ready()      // after the staged window is on screen and drawn
    }
}
```

`start` returns nil unless appshot passed both arguments, so normal screenshot captures
and normal launches are unaffected.

## What it has to get right, and why

**`ready` after the first screen is drawn.** t = 0 of the video is the first recorded
frame after `ready`. Sent early, the take opens on a half-loaded window; never sent, the
take fails with "no ready event". If staging loads fixtures asynchronously, send it from
the completion, not from launch.

**Ack after the frame, not after the state change.** The recorder stamps each ack and
moves the beat's caption and zoom to that time. An ack written in the same turn as the
state change claims the effect is on screen before it is. The drop-in forces a display
pass on visible windows and acks on the next main-queue turn. For SwiftUI, mutate the
observed state inside `perform` and return; the hosting view redraws in that turn's
commit, before the ack. If the visible effect is an animation, ack when it *starts*
(that's what the drop-in does); the take films the rest.

**Fast, synchronous effects.** The recorder warns when an ack arrives > 50 ms after the
cue's time and fails the take at 250 ms. Demo mode should have every fixture in memory:
no network, no disk scans, no `Task.sleep` before the change. If a real code path is
slow, give demo mode a direct one.

**Targets in global screen points, top-left origin.** The CGWindowList convention: origin
at the top-left of the *primary* display, y down. `AppShotCues.screenRect(of:)` converts a
view's bounds (or a sub-rect) correctly from any window on any display. A rect in window
or view coordinates puts the pointer and the zoom in the wrong place — check the contact
sheet. SwiftUI: wrap the element in a tiny `NSViewRepresentable` anchor, or store frames
from a `GeometryReader` in `.global` space and convert from the window, then flip.

**Answer `unknown`; never silently ignore.** An ignored cue times out after 1 s with a
vaguer message; a no-op that acks records a video whose caption describes nothing. Both
are worse than a clear failure naming the cue.

**Windows the recorder can see.**
- Present windows with `makeKeyAndOrderFront(nil)`, as screenshot staging does. Never
  `orderFrontRegardless()`: under `--no-activate` it raises the window over the person's
  own app, which appshot's capture guard treats as a failure. ScreenCaptureKit records
  windows behind others, so the window doesn't need to be in front.
- Windows at the main-menu and status-item levels (status item menus, the menu bar
  itself) are left out of the recording. To show a menu bar panel, stage its content in
  an ordinary window at a normal level, as the screenshot pipeline does for menu bar apps.
- A window opened mid-take joins the recording within about 0.25 s. Report it as a
  `target` if a zoom should find it.
- Pin window positions and sizes in demo mode, so takes are comparable and the stage crop
  (the union of every window the app showed) doesn't change between takes.

**Launch-argument staging pins state; cues need a way to move it.** Screenshot staging
usually sets the screen through launch arguments (`-ScreenshotStage usage`, a pinned
sidebar selection), and values passed as arguments live in UserDefaults' argument domain,
which outranks anything the app writes. So a `stage` cue that writes the same default does
nothing visible. Give demo mode a small in-memory override the views read first (a
`DemoDirector.sidebar` the window's selection consults before the pinned default), set it
from the cue, and keep it compiled out or inert outside screenshot mode.

**Frozen clocks are frozen on camera too.** Demo fixtures usually pin "now" so stills are
reproducible. In a video that means countdowns and "2 min ago" labels never move. That's
fine (takes stay identical); if the story needs time to pass, advance the demo clock from
a cue, never from the wall clock.

**Plan windows for the crop.** The recorded stage is the union of every window the app
showed during the take, fixed for the whole video. Opening a second window mid-take (a
transcript, a panel) widens the frame from the first second, leaving empty space until it
appears. Prefer cues that change content inside one window; if a second window is the
point, place it so the union stays compact, or record it as its own video.

**Demo data only.** The cue path is part of screenshot mode, behind the same guards that
keep the developer's real accounts, folders and sessions out of captures. A cue must
never read or write real data. If a guard refuses something at launch, the cue handler
must not open a way around it.

**No synthetic input.** If a cue "needs" a click to work, the demo mode is missing a code
path: call the action the click would have called.

## Testing it without the screen

`AppShotCues.cues(from:)` is pure and `nonisolated`: unit-test it with partial lines
(a line split across two reads must come out once, complete). Unit-test the app's
`perform` switch against the model: each cue's state change, `.unknown` for unknown
names, `.target` rects for known elements. Then one real take of a short video
(`--no-activate`) proves the rest; read its `report.json` latencies and the contact sheet.

## When a take fails

| Symptom | Look at |
|---|---|
| no ready event | `ready()` not called, called before staging finished, or the handler never started (arguments not read: is screenshot mode on?). |
| no ack within 1 s | Handler not running (nil from `start` — the arguments weren't passed through), or `perform` threw the cue away. |
| acked Nms late | `perform` waits on something; make the demo path synchronous. |
| zoom targets "x", which no pointer cue … reported | The handler returned `.done` instead of `.target` for that cue, or the name differs. |
| pointer or zoom in the wrong place | Rect not in global top-left points (forgot the flip, or used window coordinates). |
| part of the app missing from the video | It's a menu-level window, or it opened and closed between the 0.25 s checks. |
