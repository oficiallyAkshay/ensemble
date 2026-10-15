# Gestures and settings

What each gesture does and what Settings can change. The overview is in the [README](../README.md).

## Gestures

| Do this | What happens |
|---|---|
| Look at a Claude session | That session is the target of every gesture. Looking at a different session while listening pauses dictation after 2 seconds, once your nose is at least 15 percent of that session's width (or height) inside it. |
| Pinch thumb and index twice, quickly | Starts listening through Claude's own dictation. Do it again to stop. Your hand can leave the frame in between. If Claude is already dictating in that session (started with its own button or shortcut), it stops that dictation instead, the same way, and the text counts as just dictated for a send. |
| Hold a thumbs-up | Sends the dictated draft. The default hold is 0.75 seconds, adjustable from 0.5 to 3 seconds in Settings. It works only within 30 seconds of dictation ending, whether Ensemble or Claude's own button started it. Made while dictating, it stops the dictation as soon as the thumbs-up is recognised and lets the transcript settle while the bar fills, so Send is pressed as the hold completes; drop your hand before then and the text stays, unsent ("Kept, not sent"). Made while Claude is dictating in the session on its own, it stops that dictation and sends once the transcript has settled. The island shows "Sending" from the end of the hold until "Sent" or "Not sent", as one step with one sound, and a thumbs-up still up after a send does not start a second hold. |
| Press the headphone stem once (Bluetooth output) | Same as the double pinch, in the session you are looking at: starts dictation, or stops it. Refused with the usual message when no session is targeted, Claude is not in front or the calibration is missing. |
| Press the headphone stem twice | Same as the thumbs-up: sends the dictated draft under the same rules. |
| Hold a peace sign (index and middle apart, the other fingers folded) for 0.6 seconds | Maximizes the session you look at: it widens to most of the window and the other sessions side by side with it narrow to 300 points (or Claude's own minimum, if larger). Ensemble drags the dividers between sessions for you, each along the one smooth curve over 0.3 seconds, and puts the pointer back where it was. |
| Scissors: make a peace sign and close the two fingers together within 0.6 seconds | Evens out the sessions in that window: each gets an equal share of the width again. A peace sign held long enough to maximize does nothing more when it closes. |
| Pinch and drag up or down | Scrolls the session, at your system's scroll direction and speed. A fast release carries on with momentum, a slow release stops dead. |
| Press Return while dictating | Stops the dictation, with the usual short tail so the last word is caught, and keeps the text unsent. Claude never sees that Return. Press Return again once it has stopped and Claude sends as it always does. Only while a dictation runs in the session you look at (Ensemble's own, or one Claude started that Ensemble has seen) and Claude is in front; Shift-Return and other modified Returns are left alone. |
| Press Return twice quickly while dictating | Stops, waits for the transcript to settle, then sends the draft under the thumbs-up's rules (Claude in front, a draft, nothing else typed or clicked since). A second Return while the stop is still in progress, or within 0.5 seconds of the first, counts. If the stop cannot be confirmed, nothing is sent and the island says "Not sent". Holding Return down is one press, never two, and its repeats never reach Claude until you let go. |

Looking at a session narrower than Claude's chat column widens it to that column (the width past which Claude's text stops growing) once your look has rested on it for 0.6 seconds, and the other sessions side by side with it each give up an equal share, none below 300 points. A look passing over a session never resizes it, and it happens once each time you look at a session. Ensemble reads the column from a session wide enough to show it; until one is on screen it uses 832 points (Claude's default 768-point text column with its 32-point margins). It moves the dividers the same way the peace sign does, never while you type or use the mouse, and Settings, Actions, "Fit the focused session to the chat width" turns it off. The peace sign and the scissors still work by hand.

The peace sign and the scissors act only with Claude in front, never while a dictation is running, starting or stopping or a send is in progress, and stop at once, button released, if Claude leaves the front, another window covers the divider, or you touch the keyboard, mouse or trackpad. Ensemble's own press on the divider never counts as you clicking, so it neither holds off gestures nor refuses a later send; a click of yours during the drag still does.

## Hands on the keyboard or mouse

While you type, click, scroll or move the pointer more than a few points, Ensemble steps back: it moves no focus, the highlight and nose dot fade out, and no session is resized. Gestures and headphone presses still work: they are deliberate, and a hand raised from the keyboard to pinch lands inside the quiet time. The menu panel's status says "Paused while you type or use the mouse". Once the keyboard, mouse and trackpad have rested for 2 seconds (Settings, General, Pause after typing or mouse use: 1 to 5 seconds), the dot and highlight fade back in and focus follows the nose again. The camera and tracking keep running throughout, so resuming is instant. Only your own hardware input counts: the Returns Ensemble holds back while you dictate, the keys it posts, the pointer moves of its own scrolls and its divider drags never pause it. A pause also stops a divider drag in progress and drops a send asked for by gesture that had not gone out yet. Every dictation safety check keeps running.

When Ensemble starts a dictation, it also puts the keyboard in that session's message box, so a key you type while dictating lands there. It does this only while Claude is the app in front, and leaves focus alone otherwise.

Ensemble does no speech recognition of its own. The status capsule at the top of the screen, a floating one on screens without a notch, names the state and the session. Option-Command-K opens the control panel from anywhere. The panel, top to bottom: the on/off switch with the live status, the camera with its rate and the dot's ("camera 30 fps · dot 75 Hz": a webcam such as the C920 delivers at most 30 frames a second, while the dot moves on every refresh of its screen), how many screens are calibrated (click it to see your screens drawn where macOS has them, then click one to recalibrate only that screen), the nose dot and highlight switches, then Replay tour, the update button, Calibrate and Settings, and a footer with the installed version and a power button that quits. A refused gesture adds a short note under the camera that clears after a few seconds, or sooner once what it described no longer holds.

## Warnings while you dictate

Only while dictating, and only when your look is heading out of the session you dictate into. The outer 15 percent of that session is the warning band.

| What lies beyond that edge | What you see |
|---|---|
| Another Claude session | The edge you share with it lights up blue, brighter as your nose nears it, with its name beside it. That session gets a dashed blue outline and a name chip, a thin dashed line runs from your session to your nose, and the island's session columns lean toward its column. Once your nose is across, the line turns amber and the shared edge fills amber as the 2-second switch wait runs. Looking back before it fills changes nothing. |
| Anything that is not Claude | The whole edge glows amber, brighter as your nose nears it. Turn it off with Settings, Actions, Warn when my look leaves Claude. |

Two guards apply only while dictating. The switch wait does not advance while you are speaking and resumes after about 0.6 seconds of quiet; it reads the input level, which exists only when live sound bars are on and the microphone is allowed, so without that the speaking guard is inactive. And a look counts as resting on another session only once your nose is 15 percent of its width (height for a session above or below) inside it.

## Settings

| Group | What you can change |
|---|---|
| General | Update automatically (off by default: checks soon after launch and then every hour, installs only while idle). Turn Ensemble on or off, open at login (restarts after a crash), play sounds, fade out and pause other audio while dictating, and Pause after typing or mouse use (1 to 5 seconds, 2 by default). |
| Actions | One row per action, with the action's icon and the gesture that does it: Talk (pinch twice), Send (any pose, or Off; thumbs-up by default) with its hold time, and Scroll (pinch and move) with Reverse the scroll direction. Under "Other ways to scroll", Scroll up and Scroll down can each take a held pose; both are Off by default because pinch and move already scrolls, and a held pose would scroll whenever your hand rested in that shape. Under "Session widths", Maximize session (peace sign) and Even out sessions (scissors), each on by default and each can be Off; both stand aside while two fingers is another action's pose. Fit the focused session to the chat width (on by default). Warn when my look leaves Claude (on by default). Headphone presses on or off (on by default). |
| Display | Show the nose dot, highlight the session you face, pointer smoothing, correct for where I sit (on by default), live sound bars (asks for microphone access). |
| Calibration | Calibrate from where you usually sit; sliding along the desk afterward needs no recalibration while "Correct for where I sit" is on (Settings, Display). Recalibrate after changing chairs, camera or monitor tilt. Settings, Calibration opens with your screens drawn where macOS has them (as System Settings, Displays draws them), each with its name, size and calibration date; click a screen, or its Recalibrate button below, to redo that screen only. Add position keeps a second calibration (standing, leaning back) beside the first; the one nearest your head is used, and Calibrate redoes that one. Each dot is captured only once your head has turned toward it and holds still. A new camera or screen asks on its own; while that card shows, a held thumbs-up starts it instead of sending. |
| About | Version, credits and the update button. Update automatically lives under General. The update button says "Check for Updates", "Update to x.y.z" once any check finds a new version (pressing it installs), or "Up to date" for a few seconds after a check you started finds nothing. |

## Audio pause

While you dictate, other audio on speakers fades out in 0.25 seconds and pauses, then resumes and fades back in over 0.4 seconds. Headphones are left alone. The volume is saved before it is touched, so a crash puts it right on the next launch. The setting is on by default.

## Headphone presses

macOS gives apps no "headphone tapped" event, so Ensemble listens the way a music player does: it registers for media remote commands, and macOS delivers a stem press only to the app it treats as Now Playing: a single press arrives as play/pause, a double press as next track (older AirPods' double-tap, if set to those). Ensemble claims Now Playing without playing any sound, using the microphone or asking for any extra permission, only while the setting is on, the output is Bluetooth, Claude is running and no other app is playing audio. If music starts, Ensemble lets go at once and presses control the music; it takes over again when the music stops. The press-and-hold mute goes to the app using the microphone, which is Claude, so Ensemble cannot use it. A play/pause key that Ensemble sends itself for the audio pause is ignored for 1.5 seconds so it can never count as a press.

## Hidden setting

`detailedTrace` writes a per-frame trace of numbers and states for tuning gestures, never images. It is off by default and rolls over at 20 MB. The command to turn it on is in the [contributing guide](../.github/CONTRIBUTING.md).
