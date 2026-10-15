<h1 align="center">🎻 Ensemble</h1>

<p align="center"><b>Drives Claude's Code sessions from across the room with only a webcam.</b></p>

<p align="center"><img src="Assets/hero.svg" width="900" alt="Your face and your hands feed four gestures, look to focus, double pinch to dictate, thumbs-up to send, pinch and drag to scroll, into one hands-free Claude Code session"></p>

<p align="center">
<a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/license-MIT-2f6f4e?logo=opensourceinitiative&logoColor=white"></a>
<a href="https://github.com/oficiallyAkshay/ensemble"><img alt="clones of this repository, last seven days and all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/ensemble/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white"></a>
</p>

<p align="center">Works with<br>
<a href="https://claude.ai"><img alt="Claude.ai" src="https://img.shields.io/badge/Claude.ai-1e1b4b?logo=claude&logoColor=white"></a>
</p>

## Features

Ensemble is a macOS menu bar app that lets you run Claude desktop's Code sessions without touching the keyboard or the mouse.

<p align="center"><b>Focus follows your nose</b><br>Look at a session and it takes focus, so every gesture lands where you are looking.</p>

<p align="center"><b>Dictate and send hands-free</b><br>A double thumb-index pinch starts and stops Claude's own dictation, and a held thumbs-up sends the draft.</p>

<p align="center"><b>Scroll with one hand</b><br>Pinch and drag to scroll the session, and flick for momentum.</p>

<p align="center"><b>Make room for one session</b><br>A session you look at that is narrower than Claude's chat column widens to it on its own. Hold a peace sign and it becomes as wide as Claude allows; close the two fingers like scissors and the sessions share the window evenly again.</p>

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

No credential. Everything runs on your Mac, and Claude's own dictation does the listening, so Ensemble asks for Camera and Accessibility, and for the microphone only if you turn on the optional live sound bars, which also let Ensemble hold a session switch back while you are speaking.

- Never stores or sends a camera frame.
- Never records what you dictate or what is on your screen: it presses Claude's buttons and logs events and numbers only.
- Never reaches the internet from the face tracker page: every web address is blocked.
- Never updates itself unless you turn on Update automatically (Settings > General: checks soon after launch and then every hour, shows a new version on the update button, installs only while you are not dictating) or press Check for Updates; updates are signed, and the app installs only an update signed with its own key.
- Never sends telemetry, analytics or crash reports.
- Never acts on another app: with anything else in front, gestures do nothing. The one exception is the audio pause, which presses the system play/pause key while you dictate, and can be turned off.

**Headphone presses.** With Bluetooth headphones as the output, one press on the stem starts dictation in the session you are looking at and one more press stops it, and two presses send, under the same rules as the thumbs-up. macOS gives apps no "headphone tapped" event, so Ensemble listens the way a music player does: it registers for media remote commands and tells macOS it is the Now Playing app, which routes a single press (play/pause) and a double press (next track) to it. It plays no sound, uses no microphone and asks for no extra permission. It holds Now Playing only while the output is Bluetooth, Claude is running and nothing else is playing audio, so while music plays your presses control the music, and Ensemble takes over again when it stops. Turn it off under Settings, Actions, Headphone presses.

While a dictation runs in the session you look at, Ensemble's own or one started with Claude's own button, Return stops it and keeps the text, a second Return sends as Claude always does, and two quick Returns stop and send in one go, under the thumbs-up's rules. By default a thumbs-up sends only while Claude is the app in front, only within 30 seconds of your dictation ending, only into the session you dictated into, and only if you have not typed or clicked since. Gesture send can be turned off in Settings, and so can the audio pause. A Claude update that renames its controls can break Ensemble until it is updated, pointing is as precise as a head pose and picks a session, not a line of text (and a screen turned far from the others is only as accurate as one map per screen can be), pointing keeps working when you slide along the desk because Ensemble also reads where your head is, but that correction assumes your camera reports distances in true centimetres and your monitors stand upright, so recalibrate if you change chairs, camera or monitor tilt (switch it off with Settings > Display > Correct for where I sit), and a second face in view pauses every gesture. While you type, click, scroll or move the mouse, Ensemble steps back: no focus moves and no resizing (gestures still work), the dot and highlight fade out, and it picks up again 2 seconds after your hands rest (Settings > General).
