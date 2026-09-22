# Turnip — App Store Connect listing draft

Draft copy for the fields App Store Connect asks for at submission. Nothing
has been entered in App Store Connect yet; this is the source to paste from,
kept in the repo the same way `docs/PRIVACY.md` keeps the privacy-question
answers. Items marked **TODO** need a decision only the account holder can
make — fill those in before submitting, everything else can be pasted as-is.

## App name

```
Turnip
```

30-character limit; "Turnip" is 6. Matches `CFBundleDisplayName` in
`Turnip/Resources/Info.plist`.

## Subtitle (30 chars max)

```
Auto-edit your tricking clips
```

29 characters.

## Promotional text (170 chars max)

Editable any time without a new build — good place to point at what's new
or seasonal.

```
Turnip scans your tricking footage, trims the dead time, crops to you,
and drops one clip per trick straight into Photos — entirely on-device.
```

142 characters.

## Description (4000 chars max)

```
Turnip is an auto-editor for tricking practice videos.

Film a session — with Turnip's own camera or any video already in your
Photos library — and Turnip does the rest: it finds every trick, trims out
the setup and standing-around time, and crops each clip in on the athlete,
ready to post.

HOW IT WORKS
• Point Turnip at a video. It runs on-device pose detection to find every
  span of athletic motion in the footage — no manual scrubbing.
• Each trick gets its own clip, trimmed to a second before the motion
  starts and a few seconds after it settles, so landings aren't cut short.
• Every clip is auto-cropped to follow the athlete, framed for Reels,
  TikTok, and Shorts.
• Preview every clip as an autoplaying loop, keep or discard with a tap,
  then fine-tune the trim and crop by hand before you export.
• Export sends finished clips straight to your Photos library, with a
  share action on each one.

BUILT FOR TRICKERS
Whether you're a tricker, martial artist, gymnast, or anyone drilling
movement on camera, Turnip turns one long practice recording into a
folder of clips worth keeping — without an hour in a video editor.

PRIVACY BY DESIGN
Turnip processes everything on your device. There are no accounts, no
sign-in, and no analytics — your videos never leave your phone. Turnip
asks for Photos access to read and save your videos, and for camera and
microphone access only if you record inside the app.

REQUIREMENTS
iPhone running iOS 16 or later.
```

~1,350 characters, well under the limit.

## Keywords (100 chars max, comma-separated)

```
tricking,martial arts,gymnastics,parkour,video editor,auto crop,trim video,highlight reel
```

89 characters. Don't repeat words already in the app name/category
("Turnip", "video" is already implied by category but kept once since it's
a strong search term).

## Category

- Primary: **Photo & Video**
- Secondary: **Sports**

## Age rating

Questionnaire answers should all be "None" — no violence, no mature/suggestive
content, no gambling, no unrestricted web access, no user-to-user
communication (export goes to the system share sheet, not an in-app feed).
Expected result: **4+**.

## App Privacy (data collection questionnaire)

Answer **"Data Not Collected"** for every category. This matches
[`docs/PRIVACY.md`](PRIVACY.md), which is the canonical source if any
answer here goes stale — re-check that doc before submitting, since it's
maintained against the actual networking/storage code.

## Copyright

**TODO** — confirm the legal name to use, e.g.:

```
© 2026 Hoie Kim
```

## Support URL

```
https://hoiekim.github.io/turnip-ios/support.html
```

Built from [`site/support.html`](../site/support.html), published via
GitHub Pages (see [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)).
Lists `turnip@hoie.kim` for email support and links to GitHub Issues for
bug reports. Live once Pages is enabled for the repo (Settings → Pages →
Build and deployment → Source: GitHub Actions) and this branch merges.

## Marketing URL (optional)

```
https://hoiekim.github.io/turnip-ios/
```

Built from [`site/index.html`](../site/index.html), same deploy as above.

## Version release notes ("What's New")

```
Turnip 1.0 — Turnip finds every trick in your tricking footage, trims the
dead time, crops to the athlete, and exports one clip per trick straight
to Photos. All on-device.
```

## Not covered here

- **Screenshots / app preview video** — need to be captured from a real
  device or simulator run; ask to use the `run` skill to launch the app and
  grab screenshots once there's a build worth shooting.
- **Pricing, availability, SKU, Apple ID** — account/business decisions,
  not content.
- **Export compliance** — already answered in
  [`docs/PRIVACY.md`](PRIVACY.md) § "Export compliance": `NO`.
