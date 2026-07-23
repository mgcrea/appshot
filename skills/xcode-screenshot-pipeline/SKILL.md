---
name: xcode-screenshot-pipeline
description: Build, repair, align, or audit an automated App Store screenshot pipeline for an Xcode app (macOS or iOS) — demo-mode seeding and fixtures, launch-argument screen staging, XCUITest or staged capture, golden-image regression checks, and framed store composites. Use this skill whenever the user mentions App Store screenshots, marketing screenshots, screenshot tests, screenshot automation, appshot, fastlane snapshot, XCUIScreenshot, ScreenCaptureKit or screencapture, simctl status bar overrides, or demo/fixture data used for captures — and also when their screenshot run is flaky, captures the wrong window or the developer's real data, bakes in a hover tooltip, shows opaque window corners, grows a stray tab bar, produces identical or missing images, or drifts out of sync after a UI change. Reach for it especially when a Mac app under xcodebuild test never comes to the front, ignores typeKey or menu shortcuts, or when app.activate() / NSApplication.activate(ignoringOtherApps:) / orderFrontRegardless refuse to raise the window — that focus dead end has a known fix here. Also use it for "my screenshot test broke", "regenerate the store images", or reviewing an existing screenshot setup — including upgrading one that predates newer appshot features. Reach for it too when a capture fails with "another capture run is in progress", when two projects need to take screenshots at the same time, when golden images changed without anyone running accept, when a settle timeout is being padded defensively because async data may not have rendered, or when a script or agent needs a machine-readable pass/fail out of the golden gate instead of grepping its prose.
---

# Xcode Screenshot Pipeline

An App Store screenshot pipeline is a small program with an unusually hostile runtime: a real window server, a real app, real animations, and a test runner that fights you for focus. Most of the work is not "take a picture" — it is **making the app look identical every single run**, then framing the result into upload-ready assets.

**The pipeline is one tool: `appshot`.** Do not hand-roll it, and do not copy scripts between projects.

That is not a style preference — it is the lesson this skill was rewritten around. Three apps once shared this pipeline as ~1,100 lines of bash + Python + TypeScript. The scripts stayed identical; the *make targets* did not, so they drifted, and then the scripts drifted too. Each repo ended up carrying a fix the others were missing, so **no copy was the good one and there was no "just take the newer one"**. Worse, one bug in the shared gate propagated to all three, and none of them could see it (see *The alpha trap*).

```
appshot capture   (staged relaunch — macOS)   ─┐
                                                ├─→  Screenshots/source/<id>~<appearance>.png
appshot extract   (--xcresult, from XCUITest) ─┘    + screenshots.config.json
                                                              │
                                              appshot check ──┴── appshot compose
```

**The contract is that middle line, not the driver.** Two apps can reach their screens completely differently and still share every downstream line of code. This is the most important idea here: unify the contract, keep the driver pluggable.

## Setup

```bash
cd ~/Projects/appshot && make install                     # puts `appshot` on PATH
appshot --version
appshot doctor --config Screenshots/screenshots.config.json
```

`doctor` checks the three things that otherwise fail *silently*: the caption font resolves, Screen Recording is granted, and the output size is one App Store Connect will actually accept.

Check the version when a project's settings look odd rather than assuming they are wrong — waiting changed shape underneath them. Before **0.2.0** `--settle` was a single fixed sleep with no per-screen override, so a repo pinning 2.5s was doing the only correct thing available; from 0.2.0 it is a floor followed by a frame poll, and **0.4.0** dropped the default to 0.3s on measured evidence. An old repo on a new binary is usually just paying for a wait it no longer needs.

The release after 0.4.0 changed three more things a pre-existing pipeline will not be using: the capture lock covers **the shutter, not the whole run** (so two projects can capture concurrently, and `--wait` queues instead of failing), `accept` **seals** the goldens so a later change to them is detectable, and `--ready-file` lets the app say when a screen is ready instead of `--settle` guessing. `appshot capture --help` listing `--wait` is the tell that a binary has them; see *Upgrading a pre-existing pipeline*.

| Command | Does |
|---|---|
| `appshot run` | The whole chain: capture → gate → compose. |
| `appshot capture` | Staged-relaunch driver (macOS). |
| `appshot extract` | Pull captures out of an `.xcresult` (XCUITest driver). |
| `appshot check` | Golden gate. |
| `appshot accept` | Accept the captures as the new goldens, and seal them. |
| `appshot seal` | Adopt the goldens already on disk as the sealed baseline. |
| `appshot selftest` | **Prove the gate fails when it should.** |
| `appshot compose appstore\|website` | Framed store visuals; bare site captures. |
| `appshot doctor` | Font, permission, config. |

Copy [assets/Makefile.screenshots](assets/Makefile.screenshots) verbatim and edit only the variables at the top. The target names are canonical — `screenshots`, `screenshots-capture`, `screenshots-check`, `screenshots-update`, `screenshots-seal`, `screenshots-selftest`, `screenshots-appstore`, `screenshots-website`, `screenshots-compose`, `screenshots-doctor`, `screenshots-clean`. Two names for one action is two sets of muscle memory and two places a fix has to land.

## Where the screenshots live

**In the app repo. Always. Every project the same.**

```
MyApp/
  Screenshots/
    screenshots.config.json    committed — text: captions, theme, store order
    golden/                    committed via GIT LFS — the reviewable baseline
    source/                    generated → gitignored
    appstore/                  generated → gitignored
    diff/                      generated → gitignored
```

`.gitattributes`:
```
Screenshots/golden/*.png filter=lfs diff=lfs merge=lfs -text
```

Three rules, each of which one project got wrong:

**1. The goldens must be versioned.** An untracked baseline is only ever "whatever this machine captured last": the gate catches drift between your own runs and nothing else, there is no diff to review when a screenshot changes, and a fresh clone has nothing to compare against. A regression gate whose baseline is unversioned is not really a gate. The same goes double for a *sibling assets folder that is not a git repo* — nothing that must be reviewable can live there.

**2. The goldens must be in LFS.** They are large binaries rewritten *in full* on every UI change. One project's 14 goldens were 12.7 MB of an 18 MB repo after three refreshes, and every future refresh would add the whole set again, permanently, in every clone. LFS is what makes committing them affordable — which means it is what makes rule 1 possible. Only the goldens: `source/`, `appstore/` and `diff/` are regenerated every run, and the config is text.

**3. The directory case must match the index.** One project had `Screenshots/` on disk and `screenshots/` in the git index. APFS is case-insensitive so nothing ever complained — but the repo does not check out correctly on a case-sensitive volume, i.e. on any Linux CI. Use `Screenshots/`, matching the capitalised source dirs Xcode projects already have.

⚠️ **The LFS pointer trap.** A clone that has not run `git lfs pull` gets **131-byte text pointers, still named `.png`**. Anything that checks "does the file exist" walks straight past them. Worse, they are byte-identical to each other, so a hash-based fast path will call them a clean match and pass the whole gate without decoding a single image. `appshot` rejects them up front and tells you to run `git lfs pull` — but recognise the shape: *a check that is structurally unable to see the thing it is checking.* It is the same shape as the alpha trap below.

⚠️ **The migrate-everything trap.** If the goldens are already committed as ordinary blobs, move them with:

```bash
git lfs migrate import --everything --include="Screenshots/golden/*.png"
```

**Never omit `--include`.** Without it, `migrate import` migrates *every file it finds* and writes one `.gitattributes` rule per extension — `*.swift`, `*.md`, `*.json`, `/Makefile`, the pbxproj, the lot. The entire source tree ends up in LFS: no diffs, no code review, no `git grep` over history, and the working tree fills with pointer files. This is not hypothetical; it happened, and the tell was a `git push` reporting **366 LFS objects** instead of 14. Check the count before you let a force-push finish, and keep a backup branch until it lands.

## Pick the mode first

| The user says | Mode | Start at |
|---|---|---|
| "set up screenshots", "automate our store images" | **Bootstrap** | Step 1 |
| "the test broke", "screenshots are stale after the redesign" | **Align** | Step 0, then "Aligning a pipeline" |
| "review our screenshot setup", "can this be better?" | **Audit** | The audit checklist |
| "this was set up a while ago", "are we missing anything newer?" | **Audit**, then **Upgrade** | The audit checklist → *Upgrading a pre-existing pipeline* |

If it's ambiguous, look before asking: a `*ScreenshotTests.swift`, a `snapshot`/`fastlane` directory, or a `screenshots` make target means a pipeline already exists.

**If you find a hand-rolled pipeline — its own `compare_goldens.py`, `capture_macos.sh`, `generateAppStore.ts` — the job is to migrate it to `appshot`, not to patch it.** Those scripts carry known bugs (below). Migration is a Makefile rewrite plus deleting the scripts; the config schema is unchanged, so nothing else moves.

## Step 0 — Read the existing pipeline before touching it

Screenshot pipelines accumulate scar tissue. Nearly every strange-looking line is load-bearing — a fix for a flake that took someone an afternoon. Deleting it because it "looks redundant" reintroduces the flake.

Before editing, **run it once** to see what actually breaks. A test that fails on step 5 has already told you steps 1–4 work.

A run **seizes the keyboard and screen** — it activates the app, types keystrokes, moves the pointer. If someone is working at that machine it will interrupt them, and their stray click can fail the run. Say so before you start one. This is also why a failure here is often environmental: a screenshot test that fails only while the developer is using the computer is not necessarily broken.

For the staged driver the seizure is per *shot*, not per run: only parking the pointer, activating the app and the frame poll are exclusive. Two projects can therefore capture at once, taking turns at the shutter — pass `--wait` and a colliding run queues behind the other instead of failing. Without it the error names who holds the lock (app, pid, working directory, how long it has been going), which is the answer, not a prompt to go and run `ps`.

## The five invariants

Everything below is in service of these. When a decision is unclear, pick the option that protects them.

**1. Determinism.** Two runs a week apart must produce byte-comparable images. This forbids real network calls, the real user store, absolute dates in fixtures, random ordering, anything time-of-day dependent — and **ambient machine state** (see *The ambient-defaults trap*).

**2. Isolation.** The capture must never touch or display the developer's real data. Screenshot mode swaps in an in-memory (or temp-dir) store, disables cloud sync, and seeds from a fixture. Getting this wrong publishes someone's private repositories to the App Store.

**3. Identity.** You must capture *your* app's window. A developer's real copy is often already running under the same bundle id. `appshot` matches on the **process id it launched** — never bundle id or app name.

**4. Quiescence.** Capture only when the UI has stopped moving: animations finished, async content rendered, pointer parked so no hover state or tooltip is baked in. A fixed sleep is the crude version — `appshot` waits a floor (`--settle`) and then polls frames until two consecutive captures match, so the frame that proves stillness is the screenshot. Keep the floor small and let the poll absorb the slow screens; `--timings` tells you which is doing the work.

  Know what this cannot see, though, because it decides where you look when the gate flakes: a poll detects *motion*, so it is blind to anything wrong-but-still. An unfilled empty state, a skeleton row, and a selection drawn in the wrong colour are all perfectly still, and the poll settles on them happily. Stillness is necessary, not sufficient — invariant 1 is what actually catches those.

  The floor exists only to cover that gap, and a floor is a guess: someone pads `--settle` to 3s because a cost figure once landed late, and still cannot be sure. The app is the only thing that *knows*. With `appshot capture --ready-file`, appshot passes a path and waits for the app to create it, then skips the floor entirely — one line in the app, at the moment the content actually exists. A signal that never arrives fails the run rather than quietly reverting to the guess. Reach for this the first time you see a defensively padded settle.

**5. Legibility of failure.** A pipeline that silently degrades is worse than one that fails. Every guard below exists because something once shipped quietly.

## Step 1 — Screenshot mode in the app

This is the part `appshot` cannot do for you, and it is where the real work is.

Drive it from launch arguments: `open --args` and `XCUIApplication.launchArguments` both land in `NSArgumentDomain`, so `-ScreenshotMode YES` is readable via `UserDefaults` with **no plumbing at all**, and applies to that launch only — leaving a developer's normal runs untouched.

Use these **exact key names**; they are what `appshot` passes by default:

| Argument | Purpose |
|---|---|
| `-ScreenshotMode YES` | Turns demo mode on. Everything else is inert without it. |
| `-ScreenshotStage <stage>` | Which screen to open directly onto. |
| `-ScreenshotAppearance light\|dark` | Forces the appearance. |
| `-ScreenshotReadyFile <path>` | Passed only with `--ready-file`. The app creates this file when the screen's data has actually landed; appshot waits for it instead of guessing with `--settle`. |

`appshot` *also* always passes `-ApplePersistenceIgnoreState YES`, `-NSAutomaticWindowAnimationsEnabled NO` and `-AppleWindowTabbingMode manual` — each closes a specific failure mode (see the traps). Anything else goes through `--extra-args`.

```swift
enum DemoSeed {
    static let launchKey = "ScreenshotMode"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: launchKey) }
}
```

At startup, when the flag is on: build an **in-memory** store (SwiftData `isStoredInMemoryOnly: true`, `cloudKitDatabase: .none`; Core Data `NSInMemoryStoreType`), seed it from a fixture, force any entitlement state you need, and pin the window to an exact content size.

A useful consequence of `NSArgumentDomain`: `-isProUnlocked YES` is picked up by whatever code already reads `UserDefaults.bool(forKey: "isProUnlocked")`, so entitlement overrides usually need **no new code** — just make sure the live check can't reconcile it back off (don't start StoreKit in demo mode).

**Pin every window, not just the first.** Pinning at startup only reaches the windows that exist *then*. A Settings window opened later by `⌘,` captures at whatever size it likes — which is why one screenshot in a set is often mysteriously smaller than the rest. Pin on window *appearance* instead (an `NSViewRepresentable` in the scene's `.background`, or an observer on `NSWindow.didBecomeKeyNotification`), and skip sheets — they're windows too, and forcing a main-window size onto them blows out their layout.

Two things bite here, in order:

- **Never pin from `NSWindow.didUpdateNotification`.** It fires continuously, and ordering a window front from inside it re-enters the notification until the app dies by recursion. `didBecomeKey` fires once per window.
- **An AppKit resize cannot always beat a SwiftUI content clamp.** SwiftUI sizes a `Settings` window to its content, so `setContentSize` may take the height and silently lose the width. If it does, give the content an exact `.frame(width:height:)` in demo mode and let the window size to *it*. Verify empirically — two minutes, and it is the only way to know:

```bash
osascript -e 'tell application "System Events" to tell process "MyApp" to get size of every window'
```

Force-unlocking paid features is legitimate — you are photographing your own product — but keep the override behind the demo flag so it cannot ship enabled.

## Step 2 — Pick a driver

Both ship in `appshot`. They fail differently, and that — not platform folklore — is the choice.

### The focus fact

**What is true:** the *test process* cannot raise your app. `XCUIApplication.activate()` from the test does not reliably make it frontmost under `xcodebuild test`, where the app launches behind the runner. And `typeKey` delivers to whichever app is *frontmost* — so with no focus, keyboard navigation isn't flaky, it's **inert**. The run goes green, advances through nothing, and captures the same screen repeatedly.

**What is not true:** that nothing can raise it. **The app can raise itself.** From inside the app, on its own main thread, once its window exists:

```swift
// Root view's .task — behind the demo flag, so it can't ship enabled.
NSApplication.shared.activate(ignoringOtherApps: true)
for window in NSApplication.shared.windows {
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}
```

Who calls it is the whole distinction. **Timing is the catch:** this must run from the root view's `.task`, not `init` or `applicationDidFinishLaunching` — earlier than that there is no window to order front, the call is wasted, and that is exactly how people conclude "it doesn't work".

Do not repeat the claim that a Mac app "cannot be made frontmost under `xcodebuild test`" as though it were a platform fact. It is half true, and the half that's wrong changes the whole architecture. Two projects wrote it into their headers as settled; a third was driving an XCUITest successfully the whole time.

### Which one

| | **`appshot capture`** (staged — macOS *and* iOS) | **`appshot extract`** (XCUITest) |
|---|---|---|
| Reaches a screen by | relaunching with a `stage` arg | navigating in-session |
| Launches, 5 screens × 2 appearances | 10 | 2 |
| Knows the screen actually rendered | no — it settles and shoots | **yes** — `waitForExistence`, and it *fails* |
| Survives a renamed label / restyled view | **yes** — never touches the a11y tree | no — element queries break |
| Mid-flow states (typed-in sheet, open menu, a settled async result) | needs a stage for each | free |
| Cost lands on | **the app** (a `stage` enum + view code) | the test |

Choose **staged** when the screens are reachable from a cold launch, or when you want a pipeline a redesign cannot break. Its genuine weakness: it cannot tell whether the screen rendered, so an empty window yields a beautiful, correctly-sized screenshot of nothing. Lean on the golden gate to compensate.

Choose **XCUITest** when the app self-activates and the screens sit behind menus, popovers, a settings pane, or a live async result — staging all of those pushes real code into the app.

**Do not migrate a working driver on principle.** Unify the contract; leave the driver alone.

The staged driver covers **iOS and iPadOS too** — `"platform": "ios"` plus a `devices[]`
entry per store canvas, and `appshot capture` boots the simulator, pins the status bar and
photographs each staged screen. Do not reach for fastlane or a hand-written XCUITest for
screens that a cold launch can reach.

Platform detail: **[references/macos.md](references/macos.md)** · **[references/ios.md](references/ios.md)** (the iOS driver, the device matrix, and three measured hazards: first-run system banners, the unpinnable iPad date, the 0.4s frame).

## Step 3 — The golden gate, and proving it works

```bash
appshot check      # gate
appshot accept     # accept the captures as the new goldens, and seal them
appshot selftest   # prove the gate fails when it should
```

Commit `Screenshots/golden/`. Review diffs like you review code.

**Commit `golden/manifest.json` with them.** `accept` writes it — a sha256 per golden, plus who accepted them, from where, and with what argv — and `check` verifies it before comparing anything. It travels with the goldens, which is what makes it discriminating rather than noisy: a `git lfs pull`, a branch switch or a fresh clone rewrites every mtime and fires nothing, because the manifest that arrived with those images still agrees with them. Anything else that edited the bytes is a hard failure naming each file. Use `--require-manifest` in CI, and `appshot seal` once to adopt goldens that predate it.

**Driving the gate from a script or an agent:** `appshot check --json` emits one document — `{status, pixelDiffPercent, diffPath}` per screen — including for failures that happen *before* the comparison, so a caller never gets prose on one run and JSON on the next. `status` is a stable slug (`pixel_drift`, `size_changed`, `alpha_lost`, `alpha_drift`, `new_screen`, `missing_capture`). If you find a wrapper grepping `✗` or a percentage out of the human output, that is what it wanted.

**Reading a diff image.** `check` writes one per failure into `diff/`. It is an *amplified* difference, not a side-by-side: black means those pixels are identical, and anything bright is where the two images disagree — amplified because a real regression is often a shift of a few units per channel that is invisible unrendered. So look at *where* the brightness is, not how pretty it is. A bright band confined to one control is a state difference; brightness smeared across all the text is a font or scale problem; a bright rectangle where content should be is something that failed to load. And read the percentage the gate reports alongside it — on a repeated failure, whether that number is stable or varies is the single most useful bit of information you have (see [flakes.md](references/flakes.md#the-gate-fails-on-some-runs-and-passes-on-others)).

**Run `appshot selftest`, and keep it in the routine.** `accept` only ever *copies* files — it never decodes one — so a gate whose comparison path is completely broken will still install a baseline, bless it, and print success. You then get months of green from a check that has never once compared two images. `selftest` synthesizes mutants from the real goldens and asserts the verdict *and the reason*: identity → pass, alpha wipe → fail, **sub-threshold noise → pass** (the negative control, which proves the gate isn't simply failing on everything), visible rect → fail, size drift → fail, missing candidate → fail.

### The alpha trap

This is the bug that reached three apps and hid in all of them. The *shape* of it recurs, so it is worth understanding rather than memorising.

Captures carry **transparent rounded window corners**, and the compositor depends on that — it lays them over a gradient with no masking. The old gate flattened RGBA over black before comparing, so alpha was discarded by design: a capture that had *lost* its transparency scored zero difference.

The obvious fix — fold alpha into the pixel diff — **does not work either.** The transparent corners are only **~0.056%** of a 2880×1800 capture, and the tolerance is **0.1%**. A *total* alpha wipe therefore scores *under tolerance* and passes. Measured against real goldens, it passed on 12 of 14 images.

**Alpha loss is categorical, not gradual drift.** It needs its own check, outside the tolerance — which is what `appshot` does. The general lesson: *when a property is binary and small in area, a fractional tolerance can never see it.*

## Step 4 — Store composites

Raw window captures are not store assets. Finish the job — a pipeline that stops at raw captures leaves the last mile to be redone by hand in Figma every release, and that is exactly the mile that rots (the screenshot gets refreshed; the caption describing the old feature does not).

```bash
appshot compose appstore    # gradient, caption, shadow, exact-size PNG
appshot compose website     # bare app UI for the marketing site
```

Captions, colours, layout and store order all live in [assets/screenshots.config.json](assets/screenshots.config.json), so marketing copy changes without touching code.

- **Store order is `screens[]`, not the capture filenames.** The array index stamps the `01-`/`02-` prefix, because App Store Connect sorts uploads by filename. Captures stay unnumbered, so reordering the listing never renames an image. Numbering both gives you two orderings with nothing keeping them honest.
- **A screen with no `website` key is store-only** — that is how a paywall stays off your own pricing page.
- `appshot` **hard-fails** on a missing capture, a caption that overflows the margins, an output size the store will reject, and a font that doesn't resolve. Every one of those used to be a warning, and every one shipped at least once.

Dimensions and layout in full: [references/appstore.md](references/appstore.md).

## The traps

Each of these shipped, or nearly did. `appshot` closes them — this section is so you recognise them in *someone else's* pipeline, and so you don't "simplify" them back out of it.

**The ambient-defaults trap.** A demo flag you don't pass doesn't default to off — it falls back to **whatever is persisted in the capturing Mac's UserDefaults**. One project never passed `-isProUnlocked`, so the Pro state in its store screenshots depended on the machine that took them. It looked perfectly correct on the developer's laptop, because his happened to be unlocked. On a clean machine or CI, every screenshot would have shipped with padlocks on the toolbar. *Pass every flag the screens depend on, explicitly.*

**The tab-bar trap.** With the system-wide "prefer tabs when opening documents" set to `always`, macOS attaches a **tab bar** to the captured window — and whether it does is timing-dependent, so the same screen grows a stray tab strip on one run and not the next. `appshot` pins `-AppleWindowTabbingMode manual` per launch. Captures must never depend on how the capturing Mac happens to be configured.

**The sheet trap.** A sheet is a window in its own right and sits *in front of* its parent. Take "the frontmost window" and you photograph the **bare sheet** — a floating dialog on a transparent background — instead of the app window with the sheet presented on it, dimmed backdrop and all, which is the picture the screen is meant to show. `appshot` takes the *largest* normal window and includes everything in front of it. A stage that genuinely wants a secondary window should `orderOut` the main one, leaving its window the only candidate.

**The restored-frame trap.** Without `-ApplePersistenceIgnoreState YES`, macOS restores the *previous* staged launch's window frame and the app's own pinning loses the race. It also means one crash mid-run leaves a "reopen its windows?" alert in front of the next launch — and the capture then falls back to a full-screen shot of the developer's desktop, which is a privacy leak as well as a bad image.

**The dead-flag trap.** A staging argument the app *reads* but nothing *passes* is worse than no flag at all: the screen silently falls back to its default and looks fine. One app's Data Catalog screenshot spent months showing the free Overview tab — a list reading "Disabled / Not set" — while the comment beside the unused flag said "the workbench panes are the point of this shot". *Grep for who passes each flag, not just who reads it.*

**The inactive-window trap.** An unfocused macOS window renders grey traffic lights, a flat sidebar and dimmed toolbar icons. The shot looks plausible on its own; you only notice next to an active one. A failure to come frontmost must therefore be **fatal**, not a warning.

**The first-responder trap.** Focus is visible *twice*, and the second one is easy to misdiagnose as the first. Beyond which **window** is key, there is which **view** inside it holds focus — and a `List(selection:)` draws its selected row in the accent colour while it is first responder, muted grey when it is not. Nothing assigns that focus deliberately in most apps, so it is whatever AppKit resolved by the time the shutter fired: grey on most runs, accent on some. That is a gate that fails perhaps one run in three with no code change, and the driver's own re-activation before each shot is what makes it a coin flip — a window becoming key is exactly when AppKit hands first responder to the first candidate. Pin it in demo mode by clearing focus on every `didBecomeKey` (not just at launch, or you miss the re-activation), one runloop hop later so SwiftUI's own assignment doesn't overwrite you. Unfocused is usually the state your goldens already hold, and it keeps a blinking text caret out of the captures too. Full diagnosis in [flakes.md](references/flakes.md#the-gate-fails-on-some-runs-and-passes-on-others).

**The silently-rewritten-baseline trap.** A golden set can change without anyone running `accept` — a second terminal accepting for the same project, a `git lfs pull`, a branch switch. All three look identical from the outside: every mtime moved, maybe a couple of new files, and no entry in anyone's shell history. One session found all 18 goldens modified plus two new ones, never root-caused it, and reverted. The gate cannot help here — it compares captures to whatever is in the directory, and a rewritten directory is simply the new truth as far as it is concerned. **A baseline nothing can vouch for is not a baseline.** The manifest is the answer: sealed at accept, verified at check, and specific enough to tell a harmless `git lfs pull` from someone rewriting the images. `check` also re-reads the directory at the end of its own run and withholds the verdict if it moved, because a check racing an accept is describing a directory that no longer exists — and gets it right about as often as not.

**The leaked-instance trap.** If a driver fails *before* it has resolved the app's pid, a naive teardown has nothing to kill — so the instance keeps running with its screenshot launch arguments, holding focus and automation state, and breaks the *next* run. In one case it surfaced as an XCUITest in a different repo failing with "timed out while enabling automation mode", about as far from the cause as a symptom gets. Kill anything not in the pre-existing pid set on the way out, however you leave.

**The XCTest-mangling trap.** XCTest splices an occurrence index and a UUID into attachment names (`main~dark.png` → `main~dark_0_8C756F5A-….png`). The attachment's *name* is the filename the pipeline keys on, so it has to be put back. `appshot extract` does.

**The count-not-set trap.** A run can produce the right *number* of files with two duplicated and two missing. And a test that executes zero tests still exits `TEST SUCCEEDED`. Always check the expected **set** against the config (`appshot extract --config`, `appshot check --expect`).

Symptom → cause → fix for everything else: **[references/flakes.md](references/flakes.md)**.

## Aligning a pipeline after a UI change

A redesign breaks a pipeline in a predictable order. Work outside in, because each stage's failure masks the next.

1. **The test can't find an element.** A label was renamed, or a view moved and now matches twice. Fix the query — and replace the label lookup with an `accessibilityIdentifier`, which is what would have prevented it.
2. **The navigation route is wrong.** A screen moved behind a different shortcut, or a new onboarding sheet intercepts the first launch.
3. **The golden gate fails.** *This is the pipeline working.* Open the diff and decide, screen by screen, whether the change is the redesign you intended or a regression you introduced. Then `appshot accept` deliberately.
4. **The captions no longer describe the screens.** Marketing copy rots silently — a screenshot showing the new feature under a caption about the old one is worse than a stale screenshot. And if you change *which* pane a screen shows, the caption moves with it.

Resist the urge to accept the goldens first to "get green". That discards the only signal telling you what changed.

## Upgrading a pre-existing pipeline

A pipeline built against an older `appshot` keeps working — nothing here is a breaking change — but it is missing guarantees it now could have. Audit first, then apply only what the findings justify. In rough order of what it buys:

1. **Seal the goldens.** `appshot seal --golden Screenshots/golden`, then commit `manifest.json` alongside them. Until this exists, "the goldens changed and nobody ran accept" is unanswerable — see *The silently-rewritten-baseline trap*. One command, no re-capture, and every later `accept` maintains it.
2. **Add `--require-manifest` to the check target**, once sealed. It turns an unvouched-for baseline into a CI failure instead of a warning.
3. **Add `--wait` to the capture targets** if more than one project on the machine takes screenshots — which is the normal case for an agent working across repos, and the only case where a collision costs anything. The failure it removes is `Error: another capture run is in progress`, followed by someone hand-writing a polling loop.
4. **Lower a defensively padded `--settle`.** Run `appshot capture --timings` first: at the minimum frame count the window was already still on arrival, so the floor is the whole per-shot cost. If a screen genuinely needs the wait because its data lands late, that is the `--ready-file` case, not a bigger number.
5. **Adopt `--ready-file`** for any screen whose settle was tuned by trial and error. It is one line in the app; it replaces the guess with a fact.
6. **Replace prose-scraping wrappers with `check --json`.** Anything grepping `✗` or a percentage out of the gate's output is matching on sentences written for a person.

Do not do all six because the list exists. Each is worth its diff only if the audit found the failure it prevents.

## Audit checklist

Each line is a real failure someone shipped. Report findings with the *consequence*, not the rule — "captures by bundle id, so it will photograph your real app's window if you have DevPulse open" lands; "should use PID" does not.

**Alignment**
- [ ] Is it using `appshot`, or a hand-rolled copy of the scripts? A local `compare_goldens.py` / `capture_macos.sh` / `generateAppStore.ts` is a fork carrying known bugs — migrate it.
- [ ] Are the make targets the canonical set? Two names for one action is drift in progress.
- [ ] If the org has more than one app, do they share target names and flags? Diff them.

**Storage** (see *Where the screenshots live* — three projects, three different answers, all wrong)
- [ ] Are the goldens **in the app repo**, or in a sibling assets folder? If that folder isn't even a git repo, the baseline is unversioned and the gate is decorative.
- [ ] Are the goldens **committed**? `git ls-files Screenshots/golden | wc -l`. Zero means a local-only baseline — no diff to review, nothing for a fresh clone or CI to compare against.
- [ ] Are they in **LFS**? `git check-attr filter -- Screenshots/golden/*.png` must say `lfs`. Without it, every screenshot refresh adds the whole set to history, forever, in every clone.
- [ ] Does the **git index agree with the disk on case**? `git ls-files | grep -i screenshots/golden` vs `ls -d Screenshots`. A mismatch is invisible on APFS and breaks checkout on any case-sensitive volume.
- [ ] Are `source/`, `appstore/` and `diff/` gitignored? They are regenerated on every run.
- [ ] Are the goldens **sealed**, and is `manifest.json` committed with them? `appshot check` says so, or run `appshot seal`. Without it, a golden set that changes outside `accept` — a second terminal, a stray script — leaves no trace, and the gate treats whatever is in the directory as the new truth.

**Correctness**
- [ ] Does every demo flag the screens depend on actually get *passed*, or does it fall back to ambient UserDefaults? Grep for who passes each key, not who reads it.
- [ ] Is the store in-memory with cloud sync off? Could real user data appear?
- [ ] Are fixture dates relative to launch — and does the *view* render them relatively? An offset is only deterministic if the UI doesn't format it as an absolute date and time.
- [ ] Is **every** captured window pinned? Compare the dimensions of all captures; an odd one out is an unpinned secondary window. Sizes must be stable and *intentional* — not necessarily identical. **The gate will never catch a wrong-but-stable size**: it matches its own golden run after run.
- [ ] Are nondeterministic screens (progress, benchmarks, anything timed) **seeded** with a fixed result, or do they run for real and produce different numbers every capture? A screenshot's timing is a prop, not a measurement — pin it.

**Robustness**
- [ ] macOS: does the app self-activate from its root view's `.task`? Without it an XCUITest driver captures nothing, or the same screen repeatedly. Identical images are the tell.
- [ ] Does a failure to come frontmost *fail the run*, or does it bake in an inactive title bar?
- [ ] Element queries: stable `accessibilityIdentifier`s, or localized display strings that break in the first non-English run?
- [ ] Is the first click on a freshly-opened window retried until its *consequence* is observable?
- [ ] Is `--settle` padded defensively — a round number well above what `--timings` says the shots need? That is a guess standing in for a readiness signal. Ask what it is waiting for; if the answer is "some async thing lands late", that screen wants `--ready-file`, not a bigger floor.
- [ ] If more than one project on this machine captures, do the capture targets pass `--wait`? Without it, two runs colliding is an error a human has to resolve.

**Fidelity**
- [ ] Transparent rounded corners, or opaque desktop pixels baked into them?
- [ ] iOS: is the status bar overridden to 9:41 / full battery / full signal? (`appshot`'s iOS driver does this for you — check for a hand-rolled pipeline that doesn't.)
- [ ] iOS: were the goldens accepted from the **first** run on a freshly created simulator? Those carry iOS first-run system banners — one measured case baked an Apple Intelligence notification across 7.7% of the canvas.
- [ ] Are composites built from raw captures, or from already-scaled images (soft text)?
- [ ] **Does the caption font actually resolve?** `appshot doctor`. A substituted font never errors — it just ships.
- [ ] Does each screen actually show the feature its caption promises? A shot of the wrong tab under the right caption is a listing that undersells the product.

**Operations**
- [ ] Does the pipeline stop at raw captures, leaving the framing to be redone by hand each release?
- [ ] **Is there a marketing site, and is it fed by the pipeline?** Nearly always the answer is "yes" and "no" — the site's images were `cp`'d in by hand at some past release. They are usually the oldest images the project owns, and the last place the developer's real data is still on display long after the store set was cleaned up.
- [ ] Are the goldens **versioned**? In an unversioned sibling folder they degrade into "whatever this machine captured last" — which catches your own drift and nothing from anyone else, and gives a fresh clone nothing to compare against. Defensible for large binaries; just make it a choice, not an accident.
- [ ] Has anyone ever run `appshot selftest`? A gate that has never failed is not known to work.
- [ ] Does anything **parse the gate's prose** — a CI step or wrapper grepping `✗`, `match`, or a percentage? Those sentences are written for a person and get reworded. `check --json` is the contract; exit codes are the other one.
- [ ] Does CI pass `--require-manifest`? A green check against an unsealed baseline is green about a directory, not about a reviewed baseline.
- [ ] Is the screenshot test excluded from the default test action? **Check the scheme, not the Makefile.** A `-only-testing:` flag proves nothing about what a plain `xcodebuild test` runs — and it cannot resurrect a scheme-skipped test either: xcodebuild prints `Executed 0 tests` and `TEST SUCCEEDED`, having captured nothing. Use a dedicated scheme.

## CI

XCUITest cannot run headless: it needs an Aqua session with a window server. Options, cheapest first: a **macOS VM** ([Tart](https://tart.run)), a **second login session** (its own window server, so tests there don't steal the active display), or a **dedicated Mac runner**. Because a run seizes focus, move it off the developer's desktop as soon as it stabilizes.

Grant Screen Recording to the **terminal** that runs `appshot` (or to the test runner, for XCUITest) — never to the app. `appshot doctor` preflights it, so a missing grant names its cause instead of surfacing as N mysteriously opaque images.

## Bundled resources

- **[assets/Makefile.screenshots](assets/Makefile.screenshots)** — the canonical targets. Copy verbatim; edit only the variables.
- **[assets/screenshots.config.json](assets/screenshots.config.json)** — captions, theme, layout, store order.
- **[assets/ScreenshotHarness.swift](assets/ScreenshotHarness.swift)** — XCUITest helpers (settle, park cursor, attach captures), each commented with the failure it prevents.
- **[references/macos.md](references/macos.md)**, **[references/ios.md](references/ios.md)** — platform detail.
- **[references/flakes.md](references/flakes.md)** — symptom → cause → fix. Go here first when something is intermittently wrong.
- **[references/appstore.md](references/appstore.md)** — store dimensions and compositing.

The tool itself lives at **`~/Projects/appshot`** — an `AppShotKit` library plus a thin CLI, one dependency, no Node and no Python. Its unit tests pin the gate's behaviour; `appshot selftest` proves it end-to-end against real goldens; `make bench` captures a deliberately awkward fixture app (instant, late, restless, slow-window) and reports where a shot's time actually goes. If something here is wrong, fix it there and reinstall — never fork it into a project.
