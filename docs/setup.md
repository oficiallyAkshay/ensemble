# Setup and calibration

Installing Ensemble, the first-launch tour, and how calibration follows your cameras, screens and seat. Back to the [README](../README.md).

## Requirements

It needs an Apple Silicon Mac with macOS 14.2 or later, a webcam that sees your face and your hands, and Claude desktop with Code sessions, so Intel is untested and a covered camera pauses every gesture.

## Install and the tour

To install, download the app as a disk image from the [latest release](https://github.com/oficiallyAkshay/ensemble/releases/latest), drag Ensemble to Applications and open it, then, because the app is not notarized yet, macOS says Apple could not verify it is free of malware: press Done, choose Open Anyway in System Settings under Privacy and Security, and enter your Mac password when asked, then follow the six-step tour that opens on first launch: it asks for Camera, calibrates each screen, asks whether to show the nose dot and asks for Accessibility (skip it any time, and replay it from the menu bar panel's Replay tour button; while the tour is open Ensemble acts on nothing in Claude).

## Saved setups

Ensemble remembers a calibration for each camera and screen, so changing your desk asks only for what is new: a restored setup shows a short notice, a new screen asks to calibrate just that screen (about 11 seconds) while your other screens keep working, and a new camera asks for a full calibration before looking and dictation resume. Answer with the button or a held thumbs-up, or choose Later to keep working without it.

## More than one screen

With more than one screen, each screen gets its own pointer map, so an angled or portrait screen beside a flat one points accurately: Ensemble reads the screen layout from macOS, works out which screen your head is turned toward from the angles you calibrated, and treats the empty space where no screen exists as no target. Calibrate by turning to face each screen in turn: the calibration window opens at once on every screen with the screens it found (name, size, place), and each dot is captured only after your head has turned toward it and holds still, so eyes alone do not count.

## Where your head is

Ensemble records where your head is during calibration, so afterward you can slide along a long desk and your nose still lands where you point, with no second calibration; calibrations saved before this version point by angle alone until you recalibrate. In Settings, Calibration you can redo just one screen while the others keep theirs, and add a position (standing, or leaning back) beside the one you have: Ensemble then uses, screen by screen, the saved position nearest where your head is.
