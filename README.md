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

<p align="center"><b>Focus follows your nose</b><br>Look at a session and it takes focus, so every gesture lands where you are looking.</p>

<p align="center"><b>Dictate and send hands-free</b><br>A double thumb-index pinch starts and stops Claude's own dictation, and a held thumbs-up sends the draft.</p>

<p align="center"><b>Scroll with one hand</b><br>Pinch and drag to scroll the session, and flick for momentum.</p>

<p align="center"><b>Fits the chat column</b><br>A session you look at widens enough to read, a peace sign makes it as wide as Claude allows, and scissors share the window evenly.</p>

<p align="center"><b>Always shows its state</b><br>A capsule at the top of the screen names the state and the session, so nothing happens by surprise.</p>

<p align="center"><b>Quiet while you talk</b><br>Other audio on your speakers pauses while you dictate, then comes back.</p>

<p align="center"><b>A first-launch tour</b><br>A short tour teaches each gesture while nothing reaches Claude.</p>

## Fit

Use it when:

- You run several Claude Code sessions and want to pick one by looking at it.
- Your hands are busy or tired and you still want to dictate a prompt and send it.
- You sit far enough from the keyboard that reaching for it breaks your flow.

Look elsewhere when:

- You want voice or pointer control of every app, not only Claude.
- You use an Intel Mac or a macOS older than 14.2.
- You use Claude in a browser, since Ensemble drives the desktop app only.

It needs an Apple Silicon Mac with macOS 14.2 or later, a webcam that sees your face and your hands, and Claude desktop with Code sessions.

To install, download the disk image from the [latest release](https://github.com/oficiallyAkshay/ensemble/releases/latest), drag Ensemble to Applications and open it, then, because the app is not notarized yet, choose Open Anyway in System Settings under Privacy and Security. The tour opens on first launch; [setup and calibration](docs/setup.md) covers every install step, calibration, saved setups and more than one screen.

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
- Never updates itself unless you turn on Update automatically (Settings > General: checks soon after launch and then every hour, installs a new version by itself after 30 seconds without dictating, sending, calibrating or the tour, and reopens) or press Check for Updates (one question, "Ensemble x.y.z is available. Install now?", then it downloads, installs and reopens with no more windows; "Update to x.y.z" on the button installs in one press). Nothing installs while you dictate. Updates are signed, and the app installs only an update signed with its own key.
- Never sends telemetry, analytics or crash reports.
- Never acts on another app: with anything else in front, gestures do nothing. The one exception is the audio pause, which presses the system play/pause key while you dictate, and can be turned off.

**Headphone presses.** With Bluetooth headphones as the output, one press on the stem starts dictation in the session you are looking at and one more press stops it, and two presses send, under the same rules as the thumbs-up. macOS gives apps no "headphone tapped" event, so Ensemble listens the way a music player does: it registers for media remote commands and tells macOS it is the Now Playing app, which routes a single press (play/pause) and a double press (next track) to it. It plays no sound, uses no microphone and asks for no extra permission. It holds Now Playing only while the output is Bluetooth, Claude is running and nothing else is playing audio, so while music plays your presses control the music, and Ensemble takes over again when it stops. Turn it off under Settings, Actions, Headphone presses.

While a dictation runs in the session you look at, Ensemble's own or one started with Claude's own button, Return stops it and keeps the text, a second Return sends as Claude always does, and two quick Returns stop and send in one go, under the thumbs-up's rules. By default a thumbs-up sends only while Claude is the app in front, only within 30 seconds of your dictation ending, only into the session you dictated into, and only if you have not typed or clicked since. Gesture send can be turned off in Settings, and so can the audio pause. A Claude update that renames its controls can break Ensemble until it is updated, pointing is as precise as a head pose and picks a session, not a line of text (and a screen turned far from the others is only as accurate as one map per screen can be), pointing keeps working when you slide along the desk because Ensemble also reads where your head is, but that correction assumes your camera reports distances in true centimetres and your monitors stand upright, so recalibrate if you change chairs, camera or monitor tilt (switch it off with Settings > Display > Correct for where I sit), and a second face in view pauses every gesture. While you type, click, scroll or move the mouse, Ensemble steps back: focus and the highlight hold and nothing is resized, while gestures still work on the session you look at; it picks up again 2 seconds after your hands rest (Settings > General).
