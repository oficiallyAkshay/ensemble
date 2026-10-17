# Security policy

## Reporting a vulnerability

Use GitHub private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**
(https://github.com/oficiallyAkshay/ensemble/security/advisories/new). The report is visible only to the maintainer.
Please do not open a public issue or pull request for a vulnerability.

Include what you did, what you expected and what happened, the Ensemble version (menu bar panel, About), and your macOS
and Claude desktop versions. A screenshot or a log excerpt helps; remove anything you do not want shared.

Ensemble is maintained by one person, so there is no service-level promise. A report is acknowledged as soon as it is
read, and a confirmed vulnerability is fixed and released before it is described publicly.

## What counts

- Ensemble acting on something other than Claude, or sending a draft the user did not dictate, to a session the user did
  not dictate it to, or after the safety rules in [docs/safety.md](docs/safety.md) should have stopped it.
- Claude's microphone left recording because of Ensemble.
- Any network connection other than the update feed, any data leaving the Mac, or any camera frame reaching disk.
- A way for a web page, another app or a crafted update to make Ensemble run code or press Claude's controls.
- A secret, token or personal address committed to the repository or its history.

Out of scope: a Claude desktop update that renames the controls Ensemble reads (it makes Ensemble stop working, not act
wrongly; the app turns itself off if a dictation step fails after an update), and findings that need the attacker to
already control the user's Mac account.

## What the app touches, and what leaves the Mac

Nothing leaves the Mac. The app has no analytics, no telemetry and no crash upload.

| What | How it is used | Where it goes |
|---|---|---|
| Camera frames | Head pose (MediaPipe in a web view served from inside the app) and hand pose (Apple Vision), analysed in memory | Discarded after analysis; never written to disk, never sent anywhere |
| Claude desktop's accessibility tree | Finds session panes and presses Claude's dictation, Send and scroll controls, and finds the dividers between panes that the peace sign and scissors drag | Stays in the process |
| Which apps use the microphone, and the default output device state | Safety checks while Claude is listening, and pausing other audio | Stays in the process |
| The lid state, the list of audio inputs and the default input | With the lid closed, the default input moves to a working microphone before a dictation starts and is put back when the lid opens (a Settings switch turns it off); device names go to the log | Stays in the process |
| Keyboard and mouse activity | Only whether a key was pressed or a button clicked since a draft was dictated, to refuse a send | Not stored |
| Settings (calibration, gesture options) | The app's preferences, domain `dev.ensemble.app` | Stay in the user's Library |
| Log | Events and numbers, no images and no text of drafts, rolled over at 1 MB, in `~/Library/Logs/Ensemble` | Stay on disk; optional per-frame trace (numbers and states only) only when the user turns it on |
| Safety records | "Dictation started" and "input muted" records so a crash can be undone on the next launch, in `~/Library/Application Support/Ensemble` | Stay on disk |

The one network connection the app can make is Sparkle's request for the update feed (an appcast file on GitHub Pages),
and only after the user turns on automatic update checks or presses Check for Updates; until the feed and signing key
are configured it never starts. Updates are verified against an EdDSA key pinned in the app and Apple's code signature
before they are installed. The face tracker's page, WebAssembly and model are bundled and served through a custom URL
scheme, so nothing is fetched at run time. CI fails if a network call appears in the app sources
(`scripts/check-network.sh`).

## Supported versions

Only the latest release receives fixes.
