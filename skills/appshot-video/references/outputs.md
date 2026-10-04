# Where the video goes: sizes, lengths, uploads

Pick outputs per destination, in one `videos[]` entry: `preview` for the App Store,
`promo` sizes for social and ads, `website` for the site's loop. Every file is H.264 at
30 fps (~10 Mbps) with a silent stereo AAC 48 kHz track, so it uploads anywhere below.

Platform specs move; the dates here say when they were checked. Re-check the vendor page
before an upload that matters, and update this file when they change.

## App Store app preview (checked 2026-10-03, Apple's App Preview specifications)

| | |
|---|---|
| Mac size | **1920 × 1080**, landscape only (appshot renders exactly this) |
| Length | **15-30 s** (appshot refuses `preview: true` outside it) |
| Frame rate | ≤ 30 fps |
| Codec | H.264 High Profile 4.0, 10-12 Mbps, or ProRes 422 HQ |
| Audio | stereo, 256 kbps AAC, 44.1 or 48 kHz; every track enabled |
| Per localization | up to 3 previews |
| Poster frame | default 5 s; choose it in App Store Connect |
| Content | the app itself; captions allowed; no closing marketing card |

iPhone previews (886 × 1920, 1080 × 1920) and iPad (1200 × 1600) need iOS recording,
which appshot doesn't do yet: validation says so if a config asks for it on iOS.

Upload is manual in App Store Connect (Media Manager, the version's previews), alongside
the screenshots. Set the poster there to the same moment as the config's `poster`.

## X (Twitter) promoted video (checked 2026-10-03)

X's own spec page (business.x.com, "creative ad specifications") refuses automated
fetches; these figures come from current guides that quote it. Confirm in Ads Manager's
upload dialog.

| | |
|---|---|
| Recommended | **1200 × 1200 (1:1)** or **1920 × 1080 (16:9)**; also 4:5 1440 × 1800, 2:3 1080 × 1620, vertical 9:16 up to 1080 × 1920 |
| Length | max 2:20; **≤ 15 s recommended** for ads; loops if under 60 s |
| File | MP4 or MOV, ≤ 1 GB (under ~30 MB recommended) |

On a phone feed a square or 4:5 video takes more of the screen than 16:9. For an ad test,
render `[[1200, 1200], [1920, 1080]]` and let the campaign try both. A 20-25 s piece is
fine organically; for paid placements consider a 15 s cut (a second `videos[]` entry with
the same screens and fewer beats).

## LinkedIn video ad (checked 2026-10-03)

| | |
|---|---|
| Sizes | 1920 × 1080 (16:9), 1080 × 1080 (1:1), 1080 × 1350 (4:5), 1080 × 1920 (9:16) |
| Length | 3 s to 30 min; short is what works |
| File | MP4, 75 KB-200 MB, 30 fps recommended, AAC audio |

## Website loop

`"website": true` copies the first promo size to `--website-out <dir>` as `<id>.mp4`
(single appearance) or `<id>~<appearance>.mp4`. On the page: `<video autoplay muted loop
playsinline poster="…">`, with the `.poster.png` from `Videos/promo/` as the poster, and
`preload="metadata"`. Keep the first promo size the one the site layout wants (16:9 for
a hero, 1:1 for a card). Use the **fleet-website-conventions** skill for where assets go
in a fleet site and its CSP (`media-src` must allow the asset's origin).

## Sizing rules appshot enforces

- Every promo side must be even (H.264).
- A promo reserves room above the stage for the longest caption, so very short or very
  wide canvases leave a small app: if the contact sheet shows a tiny window, use a taller
  size or shorter captions.
- `website` needs at least one promo size.
