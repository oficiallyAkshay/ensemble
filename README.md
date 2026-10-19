<h1 align="center">Ensemble</h1>

<p align="center"><b>Drives Claude's Code sessions from across the room with only a webcam.</b></p>

<p align="center"><img src="Assets/hero.svg" width="900" alt="Look at a Claude session, pinch twice to talk, hold a thumbs-up to send, all from across the room with only a webcam; pinch and drag scrolls, a peace sign widens the session, scissors even out the sessions"></p>

<p align="center">
<a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/license-MIT-2f6f4e?logo=opensourceinitiative&logoColor=white"></a>
<a href="https://github.com/oficiallyAkshay/ensemble"><img alt="clones of this repository, last seven days and all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/ensemble/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white"></a>
<a href="https://github.com/oficiallyAkshay/ensemble"><img alt="stars on GitHub" src="https://img.shields.io/github/stars/oficiallyAkshay/ensemble?logo=github&logoColor=white"></a>
</p>

<p align="center">Works with<br>
<a href="https://claude.com/product/claude-code"><img alt="Claude Code" src="https://img.shields.io/badge/Claude%20Code-1e1b4b?logo=claude&logoColor=white"></a>
</p>

## Features

A free Mac menu bar app: look at one of your Claude Code sessions, pinch to dictate, give a thumbs-up to send, and never touch the keyboard. Every gesture is in [Gestures and settings](docs/gestures.md).

<p align="center"><b>Focus follows your nose</b><br>Look at a session and it takes focus, so every gesture lands where you are looking.</p>

<p align="center"><b>Dictate and send hands-free</b><br>A double thumb-index pinch starts and stops Claude's own dictation, and a held thumbs-up sends the draft.</p>

<p align="center"><b>Scroll with one hand</b><br>Pinch and drag to scroll the session, and flick for momentum.</p>

<p align="center"><b>Fits the chat column</b><br>A session you look at widens enough to read, a peace sign widens it to the chat's default width and no further, and scissors share the window evenly.</p>

<p align="center"><b>Always shows its state</b><br>A capsule at the top of the screen names the state and the session, so nothing happens by surprise.</p>

<p align="center"><b>Quiet while you talk</b><br>Other audio on your speakers pauses while you dictate, then comes back.</p>

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

To install, download the app as a disk image from the [latest release](https://github.com/oficiallyAkshay/ensemble/releases/latest), drag Ensemble to Applications and open it, then, because the app is not notarized yet, press Done on the macOS warning, choose Open Anyway in System Settings under Privacy and Security, and enter your Mac password when asked. A short tour opens on first launch, asks for Camera and Accessibility, calibrates each screen and lets you practise every gesture with nothing reaching Claude; [setup and calibration](docs/setup.md) covers each step. To try the gestures first, the [website](https://oficiallyakshay.github.io/ensemble/) runs a demo in your browser with your camera.

## How it compares

| | [oficiallyAkshay/ensemble](https://github.com/oficiallyAkshay/ensemble) | [FlorianRiquelme/sleight](https://github.com/FlorianRiquelme/sleight) | [google/project-gameface](https://github.com/google/project-gameface) | [Apple head pointer and Voice Control](https://support.apple.com/guide/mac-help/use-head-pointer-mchlb2d4782b/mac) |
|---|---|---|---|---|
| Platform | macOS | macOS | Windows, Android | macOS |
| Input | Face, hands | Hands | Head, face | Head, voice |
| Built for | Claude sessions | Shortcuts | Games | Desktop |
| Install | Disk image | Source | Zip | Built in |

## Security and limits

No credential: everything runs on your Mac, and Ensemble asks only for Camera and Accessibility, plus the microphone if you turn on the optional live sound bars. It makes two network connections and no other: one anonymous usage report a day, on by default and sent only after a notice in the menu bar panel (counts of gestures, refusals and safety stops, versions and the camera format, under a random id, and never video, text, names, paths or titles), and the update check. Turn the report off in Settings, General, Privacy, and read every field in [the usage report](docs/telemetry.md). The update check runs only when you turn on Update automatically or press Check for Updates, and it installs only updates signed with its own key.

- Never stores or sends a camera frame.
- Never records your dictation or your screen; it logs events and numbers only.
- Never reaches the internet from the face tracker page.
- Never sends crash reports.
- Never acts on another app, except pausing other audio while you dictate.

By default, a gesture or two quick Returns send only with Claude in front, within 30 seconds of dictation ending, into the session you dictated into, with nothing typed or clicked since; set Send to Off in Settings, Actions. Other audio pauses while you dictate, and pointing corrects for where you sit; turn them off in Settings, General and Display. Known limits: a Claude update that renames its controls can break Ensemble until it is updated, pointing picks a session and not a line of text, and a second face in view pauses every gesture. The safety design is in [Safety, permissions and privacy](docs/safety.md).
