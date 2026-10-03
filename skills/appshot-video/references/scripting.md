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
| 0-0.5 | first screen, caption 1 | **Hook**: the problem or the outcome, in ≤ 7 words. On feeds the first second decides whether anyone keeps watching. |
| ~3 | cue or cut, zoom in | Show the core moment; the zoom points the eye at it. |
| ~8 | caption 2, zoom out (`scale: 1`) | Second proof point on a different screen or state. |
| ~13 | caption 3 | Third proof point, or the "and also" that widens the claim. |
| ~18 | `endCard` | Name, one-line promise (the subtitle), icon. Hold ≥ 3 s. Promo only. |

Fewer captions is usually better: three captions plus the card fit 20 s comfortably;
five rarely do. For an App Store preview (no card), let the last moment run to the end.

## Zooms

- Zoom to make a small detail legible on a phone screen, not to add motion. One or two
  zooms per video; a zoom on every beat reads as nervous.
- `scale` 1.4-1.8 is usually right. Beyond 2 the window's UI pixels show.
- The ease takes 0.6 s; hold at least 1.5 s after it before the next change.
- Return with `{ "scale": 1 }` before cutting to a different screen, or the next screen
  arrives zoomed on a spot that no longer means anything.
- Recorded path: zoom on `target` (an element a pointer cue reported, at or before the
  zoom). From stills: zoom on `rect`, in pixels of the stills canvas (the largest
  capture's size); read the capture size first rather than guessing.

## The pointer (recorded path)

The pointer is drawn, not filmed. It appears 0.5 s before the first pointer cue, travels
between reported targets so it *arrives* as each cue fires, and ripples after a
`pointer.click`. So:

- Leave ≥ 0.6 s between pointer cues, or it teleports.
- Use `pointer.move` to set up attention before the click that matters.
- A zoom on the clicked element ~0.5 s after the click lets the ripple land first.

## Cuts and stills

`--from-stills` cuts with a 0.5 s crossfade on each beat that names a `screen`. Hold each
screen ≥ 3 s — it is a still, and the caption needs reading time anyway. Order screens as
a user's path through the app, not as the store screenshot order.

## Poster and loop

`poster` is the still App Store Connect and social players show before play (default
`min(5, duration/2)`). Put it on a beat where the caption is fully faded in and the
screen is at its most explanatory — usually the first zoom's hold. For the website loop,
make the last frame close to the first (end zoomed out, on the first screen) so the loop
doesn't jump.

## Copy

Write captions in the product's own voice and the user's words. Concrete beats clever:
"See which session is waiting on you" over "Agent awareness, reimagined". Check them with
the **humanize-ui-copy** skill if available, and keep em dashes out.
