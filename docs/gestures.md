# Gestures and settings

What each gesture does and what Settings can change. The overview is in the [README](../README.md).

## Gestures

| Do this | What happens |
|---|---|
| Look at a Claude session | That session is the target of every gesture. Looking at a different session while listening pauses dictation after 2 seconds, once your nose is at least 15 percent of that session's width (or height) inside it. |
| Pinch thumb and index twice, quickly | Starts listening through Claude's own dictation. Do it again to stop. Your hand can leave the frame in between. |
| Hold a thumbs-up | Sends the dictated draft. The default hold is 0.75 seconds, adjustable from 0.5 to 3 seconds in Settings. It works only within 30 seconds of dictation ending. Made while dictating, it stops the dictation and sends once the transcript has settled; the island shows "Sending" from the end of the hold until "Sent" or "Not sent", as one step with one sound. |
| Press the headphone stem once (Bluetooth output) | Same as the double pinch, in the session you are looking at: starts dictation, or stops it. Refused with the usual message when no session is targeted, Claude is not in front or the calibration is missing. |
| Press the headphone stem twice | Same as the thumbs-up: sends the dictated draft under the same rules. |
| Pinch and drag up or down | Scrolls the session, at your system's scroll direction and speed. A fast release carries on with momentum, a slow release stops dead. |
| Press Return while dictating | Stops the dictation, with the usual short tail so the last word is caught, and keeps the text unsent. Claude never sees that Return. Press Return again once it has stopped and Claude sends as it always does. Only while a dictation Ensemble started is running and Claude is in front; Shift-Return and other modified Returns are left alone. |
| Press Return twice quickly while dictating | Stops, waits for the transcript to settle, then sends the draft under the thumbs-up's rules (Claude in front, a draft, nothing else typed or clicked since). A second Return while the stop is still in progress, or within 0.5 seconds of the first, counts. If the stop cannot be confirmed, nothing is sent and the island says "Not sent". Holding Return down is one press, never two, and its repeats never reach Claude until you let go. |

When Ensemble starts a dictation, it also puts the keyboard in that session's message box, so a key you type while dictating lands there. It does this only while Claude is the app in front, and leaves focus alone otherwise.

Ensemble does no speech recognition of its own. The status capsule at the top of the screen, a floating one on screens without a notch, names the state and the session. Option-Command-K opens the control panel from anywhere.

## Warnings while you dictate

Only while dictating, and only when your look is heading out of the session you dictate into. The outer 15 percent of that session is the warning band.

| What lies beyond that edge | What you see |
|---|---|
| Another Claude session | The edge you share with it lights up blue, brighter as your nose nears it, with its name beside it. That session gets a dashed blue outline and a name chip, a thin dashed line runs from your session to your nose, and the island's session columns lean toward its column. Once your nose is across, the line turns amber and the shared edge fills amber as the 2-second switch wait runs. Looking back before it fills changes nothing. |
| Anything that is not Claude | The whole edge glows amber, brighter as your nose nears it. Turn it off with Settings, Gestures, Warn when my look leaves Claude. |

Two guards apply only while dictating. The switch wait does not advance while you are speaking and resumes after about 0.6 seconds of quiet; it reads the input level, which exists only when live sound bars are on and the microphone is allowed, so without that the speaking guard is inactive. And a look counts as resting on another session only once your nose is 15 percent of its width (height for a session above or below) inside it.

## Settings

| Group | What you can change |
|---|---|
| General | Update automatically (off by default: checks every 6 hours, installs only while idle). Turn Ensemble on or off, open at login (restarts after a crash), play sounds, fade out and pause other audio while dictating. |
| Gestures | Remap gestures, including turning the thumbs-up send off, and the hold time. Warn when my look leaves Claude (on by default). Headphone presses on or off (on by default). |
| Display | Show the nose dot, highlight the session you face, pointer smoothing, correct for where I sit (on by default), live sound bars (asks for microphone access), reverse the pinch-and-drag direction, the send countdown. |
| Calibration | Calibrate from where you usually sit; sliding along the desk afterward needs no recalibration while "Correct for where I sit" is on (Settings, Display). Recalibrate after changing chairs, camera or monitor tilt. Settings, Calibration can redo one screen only, and Add position keeps a second calibration (standing, leaning back) beside the first; the one nearest your head is used, and Calibrate redoes that one. Each dot is captured only once your head has turned toward it and holds still. A new camera or screen asks on its own; while that card shows, a held thumbs-up starts it instead of sending. |
| About | Version, credits and Check for Updates. Update automatically lives under General. The installed version shows beside every Check for Updates button, and after a check the result: "Ensemble x.y.z is available" or "Up to date". |

## Audio pause

While you dictate, other audio on speakers fades out in 0.25 seconds and pauses, then resumes and fades back in over 0.4 seconds. Headphones are left alone. The volume is saved before it is touched, so a crash puts it right on the next launch. The setting is on by default.

## Headphone presses

macOS delivers a stem press only to the app it treats as Now Playing: a single press arrives as play/pause, a double press as next track (older AirPods' double-tap, if set to those). Ensemble claims Now Playing without playing any sound, only while the setting is on, the output is Bluetooth, Claude is running and no other app is playing audio. If music starts, Ensemble lets go at once and presses control the music. The press-and-hold mute goes to the app using the microphone, which is Claude, so Ensemble cannot use it. A play/pause key that Ensemble sends itself for the audio pause is ignored for 1.5 seconds so it can never count as a press.

## Hidden setting

`detailedTrace` writes a per-frame trace of numbers and states for tuning gestures, never images. It is off by default and rolls over at 20 MB. The command to turn it on is in the [contributing guide](../.github/CONTRIBUTING.md).

