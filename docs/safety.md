# Safety, permissions and privacy

The rule: Claude's microphone is never left recording because of Ensemble. The summary a reader needs is in the [README](../README.md).

## Safety design

| Check | What it does |
|---|---|
| Written before pressed | A record of "dictation started" is saved and flushed to disk before the microphone button is pressed. If the app crashes mid-recording, the next launch finds the record and stops it. |
| Dead-man check | While listening, the app must keep confirming it is alive roughly every second, or dictation is stopped. |
| Standing check | A timer verifies, even when nothing seems wrong, that Claude's microphone state matches what Ensemble believes. |
| Fallback | If a stop cannot be confirmed within 3 seconds, or the microphone state cannot be read for 3 seconds while a record is open, Ensemble sounds an alarm and mutes the input device Claude is using (the same Claude processes, helpers included, that the recording check counts), recording the change so it can be undone later. A mute counts only once macOS accepts it and reads back silent; otherwise its record is dropped and the alarm still sounds. A muted device that was unplugged is unmuted when it comes back, once no stop is owed. |
| Only a definite "off" counts | The record is deleted, and the safety mute undone, only when macOS says plainly that Claude is not recording; the record also stays while a start press is still in flight, since it could open the microphone after that reading. An unreadable reading (the audio system restarting, say) counts as possibly recording, and a stop that finds no Claude session to press is not counted as a stop. |
| One dictation at a time | A new dictation is refused while an earlier one is still owed a confirmed stop, its alarm sounds or its safety mute is on, so that dictation's record, stop and mute are never replaced. |
| Switching off | Turning Ensemble off (or the automatic switch-off after a Claude update) stops any dictation and confirms the microphone is off before the record is cleared. A start press still in flight is waited for, up to 8 seconds; if it turns the microphone on, it is stopped at once. If it is still in flight after 8 seconds, the record stays, the dictation is stopped the moment the press lands, and the standing check clears the record once the microphone is off. |
| Quitting | Quitting stops dictation before the process exits. A start press already sent is waited for first, within the same 2 seconds, so a microphone it opens late is not read as off; if it is still in flight, nothing counts as off. A stop that cannot be confirmed with a definite "off" leaves the record and mutes the input, and the next launch puts it right. |
| Refusals | Dictation stops and gestures are refused when you type or click, when more than one face is in view, when no face has been seen for 10 seconds, when the camera is covered, when another app starts using a microphone, when the input device changes, when the Mac sleeps, the screen locks or the screen saver starts, or when Claude quits. While the Mac sleeps, the display sleeps, the screen is locked or the screen saver runs, the camera is off and Ensemble moves no focus; it comes back on when you do. |
| Return key | Only while a dictation Ensemble started is running (or for a moment after it, see below) does Ensemble watch the keyboard, and it only ever holds back a plain Return with Claude in front: the first one stops the dictation, a second one within the stop or 0.5 seconds asks for a send. Every other key, Shift-Return and any key with another app in front pass untouched, and no key is logged except as "Return". Holding Return down never sends: its repeats never count as a second press and are held back until the key is released. The watch goes off as soon as the dictation, that short window, any such hold and any send asked for with Return end, so a key typed before that send presses Send is seen and refuses it; if macOS pauses it, it is switched back on and any keys it may have missed count as typing, so no send follows (Ensemble switching the watch off itself is not a pause); if it cannot be created, Return keeps its normal behaviour. |
| Narrow send | Send needs Claude to be the app in front, a non-empty draft, dictation that ended in the last 30 seconds, and no keyboard or mouse use since. Claude being in front is checked when the thumbs-up arrives and again right before Send is pressed; otherwise the island says "Not sent". A send asked for with Return twice goes through the same rules, with only those Returns not counted as typing, and only after the stop is confirmed. A dictation that sleep, a lock or the safety check interrupted at any point, even while it was starting or stopping, is never sendable. Once the stop is confirmed the send waits only until the draft has not changed for 0.3 seconds (at most 1.2 seconds), and the rules are checked again just before Send is pressed. A draft you walked away from can never go out later from a stray gesture. |

Sending by gesture is not restricted by Claude's permission mode. Turn gesture send off in Settings to press Send yourself.

## Permissions

| Permission | Why |
|---|---|
| Camera | Reads your head direction and hand pose. Frames are analysed in memory and discarded. |
| Accessibility | Finds Claude's session panes and presses its dictation, Send and scroll controls. |
| Microphone, optional | Loudness only, for the live sound bars while Claude is listening. Never recorded. |
| Notifications, optional | Alerts and sound cues when a safety check refuses or stops something. |

Ensemble asks for the Microphone permission only for the live sound bars, and only when that setting is on, while Claude is listening. It reduces the input to one loudness number to animate the bars; the audio is never recorded, stored or sent. With the setting off, Ensemble never touches the microphone: Claude records, and Ensemble only watches which apps are recording. A Microphone permission request would appear the first time the bars are turned on.

## Privacy

- Video is analysed on your Mac. Frames are never written to disk and never sent anywhere.
- The face tracker is a web page served from inside the app through a custom address scheme, its model ships in the app, and every web address it could load is blocked.
- The only files written are settings, a small log rolled over at 1 MB with one backup, and the two safety records above.

The full table of what the app touches is in [SECURITY.md](../SECURITY.md).
