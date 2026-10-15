<h1 align="center">🎻 Ensemble</h1>

<p align="center"><b>Drives Claude's Code sessions from across the room with only a webcam.</b></p>

<p align="center"><img src="Assets/hero.svg" width="900" alt="Your face and your hands feed four gestures, look to focus, double pinch to dictate, thumbs-up to send, pinch and drag to scroll, into one hands-free Claude Code session"></p>

<p align="center">
<a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/license-MIT-2f6f4e?logo=opensourceinitiative&logoColor=white"></a>
</p>

<p align="center">Works with<br>
<a href="https://claude.ai"><img alt="Claude.ai" src="https://img.shields.io/badge/Claude.ai-1e1b4b?logo=claude&logoColor=white"></a>
</p>

## Features

Ensemble is a macOS menu bar app that lets you run Claude desktop's Code sessions without touching the keyboard or the mouse.

<p align="center"><b>Focus follows your nose</b><br>Look at a session and it takes focus, so every gesture lands where you are looking.</p>

<p align="center"><b>Dictate and send hands-free</b><br>A double thumb-index pinch starts and stops Claude's own dictation, and a held thumbs-up sends the draft.</p>

<p align="center"><b>Scroll with one hand</b><br>Pinch and drag to scroll the session, and flick for momentum.</p>

<p align="center"><b>Make room for one session</b><br>A session you look at that is narrower than Claude's chat column widens to it on its own. Hold a peace sign and it widens to most of the window; close the two fingers like scissors and the sessions share the window evenly again.</p>

<p align="center"><b>Always say what it sees</b><br>A capsule at the top of the screen names the state and the session, so nothing happens by surprise.</p>

<p align="center"><b>Quiet while you talk</b><br>Other audio on your speakers fades out and pauses while you dictate, then comes back.</p>

<p align="center"><b>A five-step tour on first launch</b><br>It shows each gesture on a flat Claude window with one focused session and a 3D hand beside it, lets you practise them without anything reaching Claude while a panel under the 3D hand draws your own hand's 21 joints as the camera reads them (the joint points stay in the app; no image is kept or sent), and replays from the menu bar panel, the panel under Option-Command-K, or Settings.</p>

<p align="center"><b>Private stays private</b><br>Camera frames are analysed in memory and never stored or sent anywhere.</p>

## Fit

Use it when:

- You run several Claude Code sessions and want to pick one by looking at it.
- Your hands are busy or tired and you still want to dictate a prompt and send it.
- You sit far enough from the keyboard that reaching for it breaks your flow.

Look elsewhere when:

- You want voice or pointer control of every app, not only Claude.
- You use an Intel Mac or a macOS older than 14.2.
- You use Claude in a browser, since Ensemble drives the desktop app only.

It needs an Apple Silicon Mac with macOS 14.2 or later, a webcam that sees your face and your hands, and Claude desktop with Code sessions, so Intel is untested and a covered camera pauses every gesture. To install, download the app as a disk image from the [latest release](https://github.com/oficiallyAkshay/ensemble/releases/latest), drag Ensemble to Applications and open it, then, because the app is not notarized yet, macOS says Apple could not verify it is free of malware: press Done, choose Open Anyway in System Settings under Privacy and Security, and enter your Mac password when asked, then follow the five-step tour that opens on first launch: it asks for Camera, calibrates each screen and asks for Accessibility (skip it any time, and replay it from the menu bar panel's Replay tour button; while the tour is open Ensemble acts on nothing in Claude). Ensemble remembers a calibration for each camera and screen, so changing your desk asks only for what is new: a restored setup shows a short notice, a new screen asks to calibrate just that screen (about 11 seconds) while your other screens keep working, and a new camera asks for a full calibration before looking and dictation resume. Answer with the button or a held thumbs-up, or choose Later to keep working without it. With more than one screen, each screen gets its own pointer map, so an angled or portrait screen beside a flat one points accurately: Ensemble reads the screen layout from macOS, works out which screen your head is turned toward from the angles you calibrated, and treats the empty space where no screen exists as no target. Calibrate by turning to face each screen in turn: the calibration window opens at once on every screen with the screens it found (name, size, place), and each dot is captured only after your head has turned toward it and holds still, so eyes alone do not count. Ensemble records where your head is during calibration, so afterward you can slide along a long desk and your nose still lands where you point, with no second calibration; calibrations saved before this version point by angle alone until you recalibrate. In Settings, Calibration you can redo just one screen while the others keep theirs, and add a position (standing, or leaning back) beside the one you have: Ensemble then uses, screen by screen, the saved position nearest where your head is.

## How it compares

| | [oficiallyAkshay/ensemble](https://github.com/oficiallyAkshay/ensemble) | [FlorianRiquelme/sleight](https://github.com/FlorianRiquelme/sleight) | [google/project-gameface](https://github.com/google/project-gameface) | [Apple head pointer and Voice Control](https://support.apple.com/guide/mac-help/use-head-pointer-mchlb2d4782b/mac) |
|---|---|---|---|---|
| Platform | macOS | macOS | Windows, Android | macOS |
| Input | Face, hands | Hands | Head, face | Head, voice |
| Built for | Claude sessions | Shortcuts | Games | Desktop |
| Install | Disk image | Source | Zip | Built in |

## Security and limits

No credential: everything runs on your Mac, and Ensemble asks only for Camera and Accessibility, plus the microphone if you turn on the optional live sound bars.

- Never stores or sends a camera frame.
- Never records your dictation or your screen; it logs events and numbers only.
- Never reaches the internet from the face tracker page.
- Never updates itself unless you turn on Update automatically or press Check for Updates, and installs only updates signed with its own key.
- Never sends telemetry, analytics or crash reports.
- Never acts on another app, except pausing other audio while you dictate.

Headphone presses (Bluetooth only) are explained in [Gestures and settings](docs/gestures.md#headphone-presses).

Defaults, each with its way out. A gesture or two quick Returns send only with Claude in front, within 30 seconds of dictation ending, into the session you dictated into, with nothing typed or clicked since; set Send to Off in Settings, Actions. Other audio pauses while you dictate; turn it off in Settings, General. Pointing corrects for where you sit, assuming true distances from the camera and upright monitors; turn it off in Settings, Display, Correct for where I sit. Headphone presses are on; turn them off in Settings, Actions.

Known limits: a Claude update that renames its controls can break Ensemble until it is updated; pointing picks a session, not a line of text, and a screen turned far from the others is less accurate; a second face in view pauses every gesture.
