# Where the video goes: sizes, lengths, uploads

Pick outputs per destination, in one `videos[]` entry: `preview` for the App Store,
`promo` sizes for social and ads, `website` for the site's loop. Every file is H.264 at
30 fps (~10 Mbps) with a silent stereo AAC 48 kHz track, so it uploads anywhere below.

From 0.33.0 the video track is tagged BT.709 (primaries, transfer and matrix). A file
rendered earlier is untagged, and players guess: App Store Connect showed Parcelle's teal
preview ground about 20 levels lighter than the same colour in the screenshots beside it
(2026-11-08). Re-render anything older before uploading it, and check with `ffprobe -v error
-select_streams v:0 -show_entries stream=color_primaries,color_space -of csv=p=0 <file>`,
which should print `bt709,bt709`. To compare a frame with a screenshot, extract it with
ffmpeg decoding as BT.709 (`-vf scale=out_color_matrix=bt709` or a tagged input), never
by eye in a player.

Platform specs move; the dates here say when they were checked. Re-check the vendor page
before an upload that matters, and update this file when they change.

## App Store app preview (checked 2026-10-03, Apple's App Preview specifications)

| | |
|---|---|
| Mac size | **1920 × 1080**, landscape only (appshot renders exactly this) |
| iPhone size | **886 × 1920** or 1920 × 886 (appshot renders this for every iPhone canvas) |
| iPad size | **1200 × 1600** or 1600 × 1200 |
| Length | **15-30 s** (appshot refuses `preview: true` outside it) |
| Frame rate | ≤ 30 fps |
| Codec | H.264 High Profile 4.0, 10-12 Mbps, or ProRes 422 HQ |
| Audio | stereo, 256 kbps AAC, 44.1 or 48 kHz; every track enabled |
| Per localization | up to 3 previews |
| Poster frame | App Store Connect picks one when unset; set it to the config's `poster` |
| Content | the app itself; captions allowed; no closing marketing card |
| Surround | appshot: the theme's darkest stop; `"surround": "theme"` draws the screenshots' gradient and layers (opt-in, App Review's call) |

On iOS appshot renders previews from stills only (no iOS recording yet), one per
`devices[]` entry, in the orientation of that device's store canvas. Apple also lists
1080 × 1920 for older iPhones; appshot doesn't render it, since 886 × 1920 covers the 6.9"
and 6.5" display sizes App Store Connect asks for.

Upload by hand in App Store Connect (Media Manager, the version's previews), or with
`mcp-appstore-connect`'s `upload_preview` into the localization's preview set for the
device type (`APP_DESKTOP` for the Mac). A set holds three, so delete the old preview
before replacing it. The poster is the config's `poster` as a timecode (`hh:mm:ss:ff` at
30 fps, so 0.8 s is `00:00:00:24`), and Apple only takes one once processing has finished,
which takes minutes. A timecode passed with the upload was dropped on Parcelle's 1.3.1
previews, which came back at `00:00:05:01` (2026-11-08). So poll `get_preview` until
`videoDeliveryState` is `COMPLETE`, then call `set_preview_poster_frame`, and read it back. Over a slow uplink, upload with
`waitSeconds: 0` and poll afterwards rather than waiting inside the upload call.

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
playsinline poster="…">`, with the `.poster.png` from `Screenshots/videos/promo/` as the poster, and
`preload="metadata"`. Keep the first promo size the one the site layout wants (16:9 for
a hero, 1:1 for a card). Use the **fleet-website-conventions** skill for where assets go
in a fleet site and its CSP (`media-src` must allow the asset's origin).

## Sizing rules appshot enforces

- Every promo side must be even (H.264).
- A promo reserves room above the stage for the longest caption, so very short or very
  wide canvases leave a small app: if the contact sheet shows a tiny window, use a taller
  size or shorter captions.
- `website` needs at least one promo size.
