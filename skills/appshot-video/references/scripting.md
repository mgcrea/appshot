# Scripting a short app video

A 15-30 s app video is closer to a slide sequence than a film: three or four ideas, each
shown once, each with one line of text. Most bad first drafts have too many words, too
many cuts, or a caption that describes something the screen isn't showing yet.

## Start from the claim, not the features

Write the one sentence the viewer should leave with ("Armada shows which agent session
needs you"). Then pick the 3-4 moments on screen that *prove* it, in the order a user
would hit them. Each moment becomes one caption and one screen or cue. Anything that
doesn't prove the claim is cut, however good it looks.

Sound is off by default on every feed and appshot's track is silent, so **the captions
carry the message**. Read only the captions in order: they should still make the pitch.

## The reading rule

A caption must be on screen for **1 s + 0.3 s per word** (1 s to notice it, 0.3 s per
word to read it). compose refuses any shorter caption, before writing a file, and tells
you which one. A caption runs from its beat until the next caption, the end-card beat, or
the end; `until` can only end it earlier, never extend it.

| Words | Needs |
|---|---|
| 3 | 1.9 s |
| 5 | 2.5 s |
| 7 | 3.1 s |
| 10 | 4.0 s |

Plan for the need plus about a second of slack: the reading rule is a floor. Five to
eight words per caption is the comfortable range. Beyond ten, split the idea or cut it.

When the check fails there are two real fixes: cut words (the line is usually better
shorter), or move the next caption or the end card later. `until` doesn't help — it only
shortens. Use `until` the other way round: to end a caption early and leave a
caption-free stretch so a moment can breathe (fine for a second or two, bad for long).

## A 20-25 s skeleton

| Time | Beat | Purpose |
|---|---|---|
| 0-1.5 | first screen, `hook` | **Hook**: the problem or the outcome, in ≤ 6 words. On feeds the first second decides whether anyone keeps watching. |
| ~3 | cue or cut, focus, pop the point | Show the core moment; the pop points the eye at it. |
| ~8 | caption 2, `focus: "home"` | Second proof point on a different screen or state. |
| ~13 | caption 3 | Third proof point, or the "and also" that widens the claim. |
| ~18 | `endCard` | Name, one-line promise (the subtitle), icon. Hold ≥ 3 s. Promo only. |

Fewer captions is usually better: three captions plus the card fit 20 s comfortably;
five rarely do. For an App Store preview (no card), let the last moment run to the end.

## Motion

- **One message per pop; more than three pops warns (`popOverload`).** A pop is "this
  is the point": the before/after row, the waiting session. Past three, none stands out.
- **Focus frames, spotlight points.** Focus a region the size of what the caption talks
  about (a list, a panel), then spotlight or pop the one row inside it.
- **Space focus beats at least a camera response apart**: kinetic 0.7 s, studio 1 s. A
  focus and its return closer than that is a whiplash (`cameraNeverSettles`).
- **The hook is six words or fewer**, and states the problem, not the product. It holds
  the first 1.5 s, then stays on as the first caption.
- **The pointer is for actions that cause a change**: it travels to the button, clicks,
  and the next screen arrives. A pointer wandering over static UI is noise.
- **Sheets**: from stills, `present` the sheet's rect on the `screen` beat that shows it;
  two presenting screens in a row swap sheets instead of crossfading text over text.
- **Accent one phrase per caption** with `*…*`, in the theme's `accent` colour (set it:
  without one, accents look like the rest and kinetic draws no background glow). Accents
  are coloured on kinetic promos only; studio draws one colour, and App Store previews
  draw captions plain.
- **App Store previews** draw no hook card and no end card, and the window sits at rest
  from frame 0; focus, spotlight, pop and pointer all still work, and the caption strip
  stays clear of the window even while a focus zooms in.

## The pointer (recorded path)

The pointer is drawn, not filmed. It appears 0.5 s before the first pointer cue, travels
between reported targets so it *arrives* as each cue fires, and ripples after a
`pointer.click`. So:

- Leave ≥ 0.6 s between pointer cues, or it teleports.
- Use `pointer.move` to set up attention before the click that matters.
- A focus on the clicked element ~0.5 s after the click lets the ripple land first.

## Cuts and stills

`--from-stills` cuts with a 0.5 s crossfade on each beat that names a `screen`. Hold each
screen ≥ 3 s — it is a still, and the caption needs reading time anyway. Order screens as
a user's path through the app, not as the store screenshot order.

## Poster and loop

`poster` is the still App Store Connect and social players show before play (default
`min(5, duration/2)`). Put it on a beat where the caption is fully faded in and the
screen is at its most explanatory — usually the first pop. For the website loop,
make the last frame close to the first (end on `focus: "home"`, on the first screen) so the loop
doesn't jump.

## Copy

Write captions in the product's own voice and the user's words. Concrete beats clever:
"See which session is waiting on you" over "Agent awareness, reimagined". Check them with
the **humanize-ui-copy** skill if available, and keep em dashes out.
