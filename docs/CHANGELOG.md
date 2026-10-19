# Changelog

Each release and what changed, newest first, dated by its release on GitHub. Back to the [README](../README.md).

## Unreleased

- The website demo loads its trackers (about 12 MB) quietly in the background as soon as it opens, so the camera button no longer shows a loading bar or a size, and the page no longer says that nothing downloads until you press it; and the "What Ensemble sees" panel shows a resting face and hand skeleton instead of an empty grey box when nothing is tracked.
- The friends' texts on the website now look like iOS Messages in light mode: a white card, the sender and time in small grey, and the words in a light grey bubble with a tail, instead of a dark notification.
- Releases are cut by a plain launchd job on the owner's Mac within about 5 minutes of the checks passing on a merge that changes app logic (`scripts/install-auto-release.sh`, `scripts/auto-release.sh`); no Claude routine is involved.
- The first-launch tour's gestures step has a Headphones tab while Headphone presses is on: one stem press does what a double pinch does, two presses send like thumbs-up, Bluetooth output only. It shows a check if a press arrives (the press never reaches Claude during the tour) and can always be skipped; with the setting off the step is unchanged.
- Ensemble sends one anonymous usage report a day (counts of gestures, refusals and safety stops, versions and the camera format, under a random id), on by default with a one-time notice in the menu bar panel. Settings, General, Privacy turns it off at once, shows the exact report and resets the id; every field is in [telemetry.md](telemetry.md).
- Automatic camera now starts a camera that has a saved calibration before one that has none, so a phone camera that appears on its own no longer leaves Ensemble uncalibrated; with no saved calibration the order is unchanged (external, built-in, any other).
- A missing permission shows one button that opens the right list; Restart Ensemble and Reset sit behind a small "Still stuck?" link.
- With a face or hand in view, the overlay is refreshed at most once per screen refresh instead of on every camera reading, so the app does less work on its main thread.
- With another app in front, a hand in view is checked about 8 times a second instead of on every camera frame, unless you are dictating, sending, calibrating or mid-gesture; switching back to Claude restores every frame at once.
- While the face tracker waits to retry, the panel says it is retrying instead of "Face tracking stopped"; a tracker that recovers is no longer reloaded by the waiting retry, and one failure lengthens the wait only once.
- Facing an archived session now outlines the bar with the Unarchive button instead of drawing no outline; unarchiving brings back the outline around the whole session.
- The dictation safety records can no longer be redirected by a link planted in their folder, the folder is made private to you on every write, and deleting a record is flushed to disk so a crash cannot bring it back.
- With the lid closed, each dictation first moves the Mac's input to a microphone that works (the webcam's, then a wired one, then a Bluetooth headset; never a virtual, aggregate or iPhone microphone) and the old input comes back when the lid opens. With none, the dictation does not start and the island says "No microphone while the lid is closed". The new Settings switch "Use another microphone when the lid is closed" is on by default.
- The menu panel's camera row opens a choice of Automatic and every connected camera, with the current one ticked, and switches the camera at once; it is the same setting as Settings' Camera picker. A chosen camera that is unplugged stays listed as "(not connected)", in the panel and in Settings, and the list is read again each time the panel opens.
- While you pinch and drag to scroll, the nose dot turns into the up-and-down scroll arrows, and turns back into the dot when the pinch releases; the website demo does the same.
- The menu bar icon gains a small upward arrow beside the three dots while a newer version has been found and not yet installed; with automatic checks off it appears only after you press Check for Updates.
- The nose dot is off on a new install, and the first-run tour gains a "Show the nose dot?" step after the gestures with On and Off, Off preselected. Installs that already had Ensemble keep the setting they have; Settings' "Show nose dot" is the same choice.
- The island says "Turn on a light" when the picture has stayed dim for 4 seconds, and clears it one second after the light returns; a covered camera still says "Camera is covered". With the hidden `detailedTrace` setting on, every head reading, with or without a face, now writes a trace line with the face count, nose position and brightness, and a test command turns saved traces into lost-face rate, still-head wander and follow lag (`docs/performance.md`).

## 0.2.21 - 2026-10-15

- Pressing "Update to x.y.z" installs at once, and the "Install now?" alert no longer comes back from an earlier update check.
- The chat-column fit widens the session to 10 percent past the chat column, moving as few dividers as it can from the wider side, in one fast burst.

## 0.2.20 - 2026-10-15

- Maximize leaves every other session in its row at Claude's narrowest, each divider moves once, and the highlight goes straight to where the session ends up.
- The chat-column fit acts only on the session your nose rests on and stops when you look elsewhere; the highlight moves between sessions twice as fast.

## 0.2.19 - 2026-10-15

- A peace sign is recognised with the thumb out, at desk distance and as a narrow V.

## 0.2.18 - 2026-10-15

- The menu panel, Settings and the safety page no longer say gestures are ignored while you type or use the mouse. The status now reads "Focus holds while you type or use the mouse", and Settings says focus and the highlight hold while gestures still work.
- Ensemble uses less energy when you are not pointing at Claude: face tracking drops from every frame (30 a second) to 10 a second while another app is in front, while no Claude session is on screen, and after 3 seconds on the keyboard or mouse, and goes back to every frame on the next tick once that ends or a gesture, dictation or send starts. Hand detection is unchanged. The face tracker is most of Ensemble's CPU (about 60 percent of one core with the web content and GPU processes at full rate), so in those states that part should fall to about a third; this is an estimate, not yet measured on the app.
- The keyboard-and-mouse pause flaps less. Within 1 second of a resume, or of Ensemble raising Claude or moving its focus, one stray input reading no longer pauses again; a second reading within half a second is needed (measured: 108 pauses in 46 minutes, 23 within 1 second of a resume, 10 within 1 second of a focus move). The log line now says what paused it: key, click, scroll or move.
- A double pinch, a headphone press or a pinch-and-drag scroll made right after typing or clicking now acts instead of being refused with "You just typed or clicked" (seen four times on 0.2.16). Only a send keeps that check, so a draft you just edited by hand is never sent by a stray thumbs-up.
- While Ensemble is paused for the keyboard or mouse, a gesture or headphone press acts on the session your nose is on, not the one focused before you started typing. The target keeps following your look through the pause (no window is raised and keyboard focus stays put until you resume), the highlight comes back on that session as soon as a gesture starts, and with your nose off every session the gesture is refused with the usual "Your nose is not on a Claude session". Before, the target froze at the pause and the highlight was hidden, so a pinch could start dictation in a session you were no longer looking at.
- Claude tells Ensemble when its windows and panes change, so Ensemble asks Claude far less often. Every second it now checks only each session's microphone button (as fresh as before); the session frames are read when Claude reports a window moved or resized or a divider moved, within about a tenth of a second instead of up to a second, and Claude's whole window is searched again only when a window or pane opens or closes, and every 15 seconds as a safety net (before: every 10 seconds, and every second while a window was being moved or resized).
- The face tracker uses about 13% less CPU per camera frame and answers about 3 ms sooner: frames reach it as raw pixels from memory instead of being compressed to JPEG, turned into text and decoded again.
- Claude's own dictation start and stop sounds play again when Ensemble starts and stops a dictation. Claude plays them only after a real click or key, which Ensemble's press is not, so they had gone silent; Ensemble now plays the same two sounds from your installed Claude (its own Tink and Pop if Claude's files are missing), and plays nothing when Claude's own sound is heard starting, so they never double. With Bluetooth output the sound waits 0.35 seconds so the headset's switch to or from its microphone does not swallow it. Settings, General, Play sounds turns them off.
- The audio pause no longer touches the output volume: other audio on speakers is paused with the play/pause key alone and resumes after the stop sound, so Claude's sounds and Ensemble's own always play at your volume. The setting now reads "Pause other audio while dictating".
- Updating takes one click instead of six, and Ensemble reopens by itself. Sparkle's windows are gone. With Update automatically on, a new version installs by itself once you have been idle for 30 seconds, with no question, and the island says "Updated to x.y.z" after the reopen. With it off, Check for Updates asks once, "Ensemble x.y.z is available. Install now?" (Install, Later, and a "What's new" link), and Install downloads, installs and reopens with no further window; a button that already reads "Update to x.y.z" does all of that in one press. A press while you dictate, send, calibrate or run the tour waits: the button says "Installs x.y.z when you finish" and the install starts at the first idle moment (before, an update already downloaded could restart Ensemble mid-dictation). A failed download or install shows one alert with Retry. Ensemble now reopens even if the updater's relaunch never comes, and with open at login on the reopened copy runs under the login agent again, so crash restarts keep working. The script that reopens Ensemble (also used by Restart Ensemble, the permission button) now runs in its own session, so launchd ending the login agent's job cannot stop it. This takes effect for updates after this version is installed: installing this version itself still goes through the old windows.
- Maximize, even out and the chat-column fit move Claude's dividers with its own keyboard control instead of a mouse drag. Maximize makes the session you look at as wide as Claude allows and every other session in its row as narrow, in about half a second (Home and End on each divider); before, it stopped short, left the other sessions wide and the highlight behind. The highlight follows the session as it resizes, the keyboard goes back to its message box afterwards, the pointer never moves, and Ensemble's own keys never count as your typing.
- The chat-column fit no longer shrinks its column (a session's padding was read as the column: 832, then 736, then 646 points) and no longer undoes its own last fit on every glance: a session a fit narrowed waits three minutes, a fit that would squeeze a recently fitted session is skipped, and nothing is fitted for five seconds after a calibration.
- Logs name a session by its place in its row ("pane 2 of 4"), never by its title.
- Calibration dots sit 4% in from each screen edge instead of 8%, so sessions at a screen's edge are measured rather than guessed, and every dot stays whole and clear of the menu bar and the notch. Recalibrate after updating (menu panel, Calibrate) to get the wider reach; calibrations from before keep working as they were.
- Recalibrating one screen after moving or rotating monitors no longer saves the wrong screen. The first dot of a one-screen run now waits for your head to turn away from the screen you were looking at, and a run whose points repeat another calibrated screen's is not saved: Ensemble says "Not saved: the points on ... matched where you look at ..." instead of leaving the nose unable to reach that screen. The log says when a calibration is saved, for which screens and position, and which screens point with it.

## 0.2.16 - 2026-10-15

- The log names a camera by its model id, never its device name (which can carry the owner's name). The start line says only whether a camera was chosen in Settings, and a newly connected camera is named by its model id too.
- Gestures and headphone presses work while Ensemble is paused for the keyboard or mouse: the pause now only holds focus, the highlight and resizes. Before, a double pinch made right after typing landed inside the 2-second quiet time and did nothing, and each pause began or ended by resetting a half-made gesture.
- Holding an open hand no longer asks for a cancel that nothing acted on: a resting open hand does nothing, and Settings, Actions drops the Cancel row. Saved settings keep their Send and scroll gestures.
- A face tracker that keeps failing recovers by itself instead of leaving the pointer and focus-follow dead until Ensemble restarts. The first failure retries at once, as before; each later one waits 2, 4, 8, 16, then 30 seconds before the next try and never gives up. The menu panel shows the failure during the wait, and a good head reading or a camera restart starts the count over.

## 0.2.15 - 2026-10-15

- The session you look at widens to Claude's chat column when it is narrower. Once your look has rested on a session for 0.6 seconds, Ensemble drags the dividers so the session is as wide as Claude's text column (read from a wider session on screen, 832 points until one is) and the other sessions beside it each give up an equal share, none below 300 points. Once per look, only with Claude in front, never while dictating or sending or while you type or use the mouse. On by default; Settings, Actions, "Fit the focused session to the chat width" turns it off. The peace sign and scissors work as before.

## 0.2.14 - 2026-10-15

- Ensemble steps back while your hands are on the keyboard, mouse or trackpad: typing, clicking, scrolling or moving the pointer more than a few points stops focus following your look, fades the nose dot and highlight out, and ignores gestures and headphone presses, so working by hand never meets a session switch you did not ask for. The menu panel says "Paused while you type or use the mouse". Two seconds after your hands rest (Settings, General, Pause after typing or mouse use, 1 to 5 seconds) the dot and highlight fade back in and Ensemble acts again; the camera never stops, so it is instant. Ensemble's own scrolls, divider drags and held-back Returns never pause it, stopping a dictation still works while paused, and every dictation safety check keeps running.
- Peace sign and scissors change session widths. Hold a peace sign for 0.6 seconds and the session you look at widens to most of the Claude window while the sessions beside it narrow; make a peace sign and close the two fingers within 0.6 seconds and every session there gets an equal share again. Ensemble drags Claude's own dividers between sessions, one at a time along the smooth curve over 0.3 seconds each, and puts the pointer back. Only with Claude in front and never while dictating or sending; touching the keyboard or mouse stops it. Settings, Actions has a "Session widths" section to turn either one off.

## 0.2.13 - 2026-10-15

- A dictation started with Claude's own button no longer locks Ensemble out. A double pinch in that session stops it (before: "mic is not verifiably off: on"), a thumbs-up, a headphone double press or two Returns stop it and send it, and once it has ended a thumbs-up within 30 seconds sends it (before: "Nothing dictated in the last 30 seconds"). A start that finds Claude already dictating says "Claude is already dictating here; pinch twice to stop".
- A send reads and presses only the pane that was dictated into. When Claude changed its layout a second after a stop (one pane shown, then four), the send read another pane and said "The draft is empty"; another pane's draft could have been sent. It now finds the same pane again by window, session name and place, or sends nothing and says it could not read that session's message box.
- A thumbs-up while dictating feels like one motion: the dictation stops as soon as the thumbs-up is recognised and the transcript settles while the bar fills, so Send is pressed as the hold completes instead of about 0.8 s after. Dropping the hand before the bar fills keeps the text unsent and says "Kept, not sent". A thumbs-up still up after a send no longer starts a second bar. The log carries each send's timeline.
- Clicking "Calibrated for N screens" in the menu panel opens your screens drawn where macOS has them, as System Settings, Displays draws them: each at its real position and relative size, with its name, size, a menu bar strip on the main screen and "Calibrated Oct 15" or "Not calibrated". Click a screen to recalibrate only that one. The same arrangement heads Settings, Calibration, above a row per screen with its Recalibrate button, and both follow screens being plugged in, moved or removed.
- The Settings tab "Gestures" is now "Actions": each row is an action with its own icon (microphone for Talk, paper plane for Send, arrows for Scroll) and the gesture that does it on the right. Scroll is a row of its own, done by pinch and move, with Reverse the scroll direction beside it; the hold-to-send time sits under Send. The pose-held Scroll up and Scroll down move to "Other ways to scroll", still Off by default because pinch and move already scrolls. The Talk row no longer offers a pose picker that did nothing: talking is always a double pinch.
- The panel's camera row names both rates, "HD Pro Webcam C920 · camera 30 fps · dot 75 Hz". The 30 is the camera's own limit (every C920 format tops out at 30); the dot already moves on every refresh of its screen.

## 0.2.12 - 2026-10-15

- The menu panel's status line is always the live state, and a refused gesture's note no longer sticks: it clears after 6 seconds, when a dictation starts, when you type or click, and for "Your nose is not on a Claude session" or "Claude isn't on screen" as soon as your nose is back on a session. Switching Ensemble off clears it too.
- With Update automatically on, Ensemble checks 15 seconds after launch and then every hour instead of every 6 hours, and a new version found by any check, background ones included, shows on the update button without you pressing it.
- One update button everywhere (menu bar panel, Option-Command-K panel, Settings): "Check for Updates", "Update to x.y.z" when one is found (pressing it installs), or "Up to date" for a few seconds after your check finds nothing. The separate "is available" and "Up to date" lines are gone; the installed version is a small caption in the panel's footer and beside the button in Settings.
- The menu panel reads top to bottom: on/off, the camera and "Calibrated for N screens", the nose dot and highlight switches, then Replay tour, the update button, Calibrate and Settings. Quit is a power button in the footer, and the "⌥⌘K shows this panel" caption is gone (the shortcut still works).

## 0.2.11 - 2026-10-15

- The menu bar panel says "Claude isn't on screen" instead of "Watching" while Claude runs but none of its windows is on screen (another Space, minimized, behind a full-screen app), and goes back to "Watching" when a session is found.
- Return twice while talking sends again when the stop takes longer than half a second: Ensemble switching its own key watch off after the stop came back from macOS as a pause, counted as typing, and refused the send with "You just typed or clicked". The watch now also stays on until a send asked for with Return is done, so a key typed meanwhile still refuses it.
- The session list no longer empties for a second when Claude's tree reads empty while it re-renders: one empty scan keeps the sessions while their dictation checkboxes still answer, and two in a row drop them.
- Ensemble costs Claude far less: the once-a-second session check re-reads only the known dictation checkboxes and pane frames, and walks Claude's whole accessibility tree only when its windows change, something stops answering, or every 10 seconds. A walk stops after 2 seconds, so a hung Claude cannot stall Ensemble's own Claude work.
- Session ids stay put while a Claude window moves or resizes: windows are matched by the window server's own number, an on-screen window is preferred over a hidden Claude window with the same frame, and a frame briefly apart still matches the one window it nearly covers.
- Starting a dictation confirms the keyboard is in that session's message box from what Claude says has focus, not from a flag Claude never sets; with several Claude windows it makes the session's window the main one when needed.
- With Claude's windows on another Space, minimized or behind a full-screen app, a dictation gesture is refused with "Claude isn't on screen" instead of "Your nose is not on a Claude session".
- The nose dot no longer hitches several times a second. Hand pose runs off the camera's own queue, so camera frames are no longer dropped while it works (about 3 a second were) and the dot gets about every one of the camera's 30 readings a second. The camera's once-a-second status report no longer re-decides the desk setup and restarts the pointer's smoothing; only a real change (another camera, a screen added, removed or moved, a new calibration) does. Pointing works from the first reading after launch instead of about a second later, and "Desk setup recognised" shows only when the setup actually changed, not at every launch. Settings and the menu no longer redraw on every head reading.
- A thumbs-up send feels like one step: the island goes from "Sending" straight to "Sent" (or "Not sent" with the reason) instead of flicking back to the dictation and folding away first, and only the send sound plays. The fixed 0.6 s wait for Claude's transcript is replaced by waiting until the draft stops changing for 0.3 s, and Send's result is checked every 30 ms instead of every 100 ms.
- When macOS cannot read whether Claude is recording for 3 seconds while a dictation record is open, the alarm sounds and the input is muted, instead of waiting for a reading that may never come.
- A new dictation is refused while an earlier one's stop is unconfirmed, its alarm sounds or its safety mute is on, so that dictation's stop is never abandoned. The alarm now also ends when the microphone is confirmed off without a mute having been needed.
- Quitting while a dictation is starting waits for the start press before reading the microphone, so the safety record is not deleted moments before Claude's microphone opens.
- A dictation interrupted by sleep, a lock or the safety check while it was starting or stopping can no longer be sent by a later thumbs-up.
- The safety mute counts only when macOS accepts it and reads back silent, lands on the device of every Claude process the recording check counts (helpers included), and is undone when an unplugged device comes back.
- Starting a dictation, sending and switching off no longer read the audio system or wait on the safety check on the main thread, so a stalled audio device cannot freeze the app.
- Music paused for a dictation no longer resumes in the middle of the next one started within 0.7 s.
- The camera turns off while the Mac or display sleeps, the screen is locked or the screen saver runs, and Ensemble moves no focus meanwhile; it comes back on when you return.
- Moving or resizing the Claude window you are dictating into keeps the highlight and edge warnings on it.
- An automatic update no longer installs while a send is pending or a gesture is being held.
- The nose dot glides instead of stepping and lands where you look: the camera is held at 30 frames a second (dim light no longer halves it where the camera allows), every frame becomes a head reading instead of every second one, and the dot moves on every screen refresh as a spring. In a replay of a head turn it covers 90% of the move in about 0.27 s instead of about 1 s, rests within a few points of the aim instead of about 20 points short, and stays still while your head is still. Center Stage is turned off for Ensemble's camera, and a camera restart no longer reloads the face tracker. The Pointer smoothing slider keeps its place; its scale is retuned.

## 0.2.9 - 2026-10-15

- The onboarding tour is in light mode, like the website's live demo: a white window with the app's blue on the selected tab and buttons, the gestures step's Claude window in Claude's light theme, the hand and the welcome and calibration scenes on a white background, and the camera panel and success badge on white.
- The "Claude's microphone may still be on" alarm now always shows as a banner on the island and stays until the safety check confirms the microphone is off and the mute is undone, even when notifications are refused or a Focus mode hides them; the system notification is sent as well when allowed.
- On first launch the tour's Welcome step is no longer covered by the Accessibility prompt and the Camera request: the camera starts when the tour moves on to calibration, and the Accessibility prompt waits for the tour's permissions step or for the tour to close.
- The tour's Camera card now has three states: Allow (not asked yet), Open Settings with a plain explanation (denied), and Granted. The Accessibility Grant button also opens the Accessibility list in System Settings, because macOS shows its own prompt only once.
- Opened from the disk image or Downloads, Ensemble offers to move itself to Applications and reopens from there. Until then it refuses to turn on open at login and says why, instead of recording a path that goes away.
- The website and README now quote the current macOS 15 and later install wording (Apple could not verify the app; Done; Open Anyway asks for your Mac password). The live demo's no-JavaScript message is readable.
- The release workflow also uploads Ensemble.dmg, the fixed name the Download button links to, and stands down when scripts/ship-release.sh has already published the release.
- Return stops a dictation Ensemble started: the text stays unsent and Claude never sees that key, and the next Return sends as usual. Two quick Returns while you talk stop and then send, under the same rules as the thumbs-up; if the stop cannot be confirmed, the island says "Not sent". Only with Claude in front and only plain Return: Shift-Return and every other key are left alone. Starting a dictation also puts the keyboard in that session's message box while Claude is in front.

## 0.2.8 - 2026-10-15

- Settings, Calibration can recalibrate one screen: pick it under Screens and press Calibrate this screen; every other screen keeps its calibration. Add position calibrates again from another place, such as standing or leaning back, and keeps it beside the ones you have; Ensemble uses, screen by screen, the saved position nearest where your head is (switching only once another is clearly nearer), Calibrate redoes the position in use, and Remove forgets one. Calibrations saved before this version become Position 1, nothing lost.
- Turning Ensemble off while a dictation is starting no longer leaves Claude's microphone recording: the start is waited for and, if it turns the microphone on, stopped at once, and the safety record is kept until the microphone is confirmed off.
- When macOS cannot say whether Claude is recording (the audio system restarting, say), Ensemble treats the microphone as possibly on: the safety record and any safety mute stay until a definite "off". On quit, a stop that finds no Claude session is no longer counted as confirmed.
- A thumbs-up sends nothing while another app is in front, even right after dictating; the island says "Not sent". This is checked when the gesture arrives and again right before Send is pressed.
- Next to every Check for Updates button (menu bar panel, Option-Command-K panel, Settings) Ensemble shows the version you have installed, and after a check it says "Ensemble 0.5.0 is available" or "Up to date". The latest version is learned only from a check you start or the automatic checks you turned on; nothing is fetched otherwise.

## 0.2.7 - 2026-10-15

- With one chat session open in Claude, the highlight, focus and edge warnings cover just that session, not the whole window with its top bar and left navigation. Two or more sessions side by side are unchanged.

## 0.2.6 - 2026-10-15

- Pointing follows your nose when you slide along the desk: Ensemble reads where your head is as well as which way it points, so the screen you aim at stays the one you aim at without recalibrating. It is on by default and can be switched off in Settings, Display, "Correct for where I sit". Calibrations saved before this version keep pointing by angle until you recalibrate.

## 0.2.5 - 2026-10-15

- Calibrate puts its full-screen window up at once, even when Ensemble was off or the camera is still starting; it says what it is waiting for ("Starting the camera...", "Looking for your face...") and shows the first dot only after a face reading arrives. The log records the time from click to window and from click to first face reading.
- A calibration dot is captured only when your head has turned toward it and holds still for 0.4 s; the ring does not fill before that. The text reads "Turn your nose to the dot", then "Move your head, not just your eyes" after 4 s, and after 12 s offers Skip this point or Retry (a skipped point leaves that screen uncalibrated).
- Calibration opens with "Found 2 screens", listing each screen's name, size, orientation and place in the display arrangement and the order they will be calibrated in, on every screen at once; each step names its screen ("Screen 2 of 2 - DELL U2723QE - turn to face it"). The menu bar panel says "Calibrated for 2 screens".

## 0.2.4 - 2026-10-15

- A missing permission offers Restart Ensemble (quits and reopens itself) and Reset (clears a stale grant and asks again), so nobody has to quit and reopen by hand.

## 0.2.3 - 2026-10-15

- Update automatically (off until you turn it on, Settings, General): checks every 6 hours, downloads in the background and installs only while Ensemble is idle, then reopens.

## 0.2.2 - 2026-10-15

- The nose dot glides at the screen's refresh rate instead of jumping 15 times a second with each head reading.
- While the tour is open Ensemble acts on nothing in Claude: no focus moves, no raised sessions, no dictation or send; the camera keeps running for the tour's own calibration and practice.
- Replay tour and Check for Updates are full buttons in the menu panel, beside Calibrate and Settings.

## 0.2.1 - 2026-10-15

- Pointing fits one map per screen and picks the screen from your head's angles, so an angled portrait screen beside a landscape one points correctly.

## 0.2.0 - 2026-10-15

- A five-step tour opens on first launch (welcome, calibrate, three gestures to practise (dictate, send, scroll) shown in 3D scenes with the owner's recorded motion, permissions), can be skipped at any step, and replays from the menu bar panel, the Option-Command-K panel or Settings. While its gesture step is open, gestures only drive the tour and nothing reaches Claude, and the gestures step is one canvas: a flat Claude window with one session focused (blue outline, never filled) and the others as skeletons, reacting to the gesture, with a column on its right edge holding a 3D hand on top and, below it, your own hand's 21 joints as the camera reads them with the gesture it recognises. When you do the gesture, "Pinch detected" (or its kin) appears at the canvas's bottom left; the "Your turn" line below the canvas keeps its height, so the window does not jump. The skeleton holds coordinates only: no frame is stored or sent.

## 0.1.1 - 2026-10-14

- The app is 6.9 MB instead of 19 MB, and the download 5.4 MB instead of 10 MB.
- The face tracker page is blocked from the internet, and every build checks that no network code or build-machine detail is inside the app.
- Other audio on your speakers fades out and pauses while you dictate; Claude's own start and stop sounds play normally.
- The island names the session and what Claude is doing: "Claude dictation on", "Sending in", "Sent in", "Activating".
- The double pinch follows a natural rhythm and ignores fingertips brushing as a thumbs-up is lowered.
- Focus follows your nose after 0.075 s; highlight fades use one smooth curve.
- The menu bar icon is three dots: hollow when off, filled when on.
- Turning Ensemble off stops any Claude dictation and confirms the microphone is off.

## 0.1.0 - 2026-10-14

First release. Face a session to pick it, double pinch to dictate, hold a thumbs-up to send, pinch and drag to scroll.

- Requires an Apple Silicon Mac, macOS 14.2 or later, and a webcam.
- Video is analysed on your Mac and never stored or sent.
- A draft sends only in the moment you spoke it, to the session you spoke it to.
- No automatic updates yet: download each new version from the releases page.
- Tested against one Claude desktop version, in English.
- macOS shows the unidentified-developer warning until the app is signed and notarized.
