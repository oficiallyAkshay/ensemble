# First run: from the website link to a first working gesture

The path a person who has never seen Ensemble takes on a Mac, in order. Each step says what they see and what would make them stop. Steps marked **test** are followed on the live website by `node docs/live/test/first-run.mjs`; steps marked **by hand** need a real Mac, a real camera or a real Claude session. Back to [Setup](setup.md).

## Running the test

```
node docs/live/test/first-run.mjs                 # the live website
node docs/live/test/first-run.mjs http://127.0.0.1:8791/   # a local copy: node docs/live/test/serve.mjs 8791
```

It needs the network and Chrome at the usual macOS path (`CHROME_PATH` overrides), prints one PASS or FAIL line per step it checked, and exits 1 on any FAIL. It runs a headless Chrome with a fake camera, asks GitHub for the disk image's headers only, installs nothing, and grants or resets no permission. It is not part of the required checks: it needs the network, so run it from a developer's Mac after a website change or when the path is in doubt.

## The steps

| # | Step | What the person sees | What would make them stop | Covered by |
|---|---|---|---|---|
| 1 | Open the website link | The home page with a headline and two buttons, See the demo and Download | A blank page, a failed request | test: page loads with a title and headline, no failed request |
| 2 | Read the page | What Ensemble does, how it works, the requirements | Not knowing whether it fits their Mac (see stop 1) | by hand |
| 3a | Choose the demo: press See the demo | The browser asks to use the camera, then the demo opens | Refusing the camera (the page then shows how to allow it in Safari, Firefox and Chrome, and offers the mouse) | test: See the demo opens the demo with the camera allowed |
| 4 | In the demo, double-click Claude, then turn Ensemble on from the menu bar | The tracker loads, the camera starts, the guide moves to centring on the camera, then looking at a session | The trackers (about 12 MB) failing to load; no camera | test: the demo reaches its running state with a fake camera and the guide moves on |
| 5 | Make the first gesture the guide asks for | The guide asks them to look at one session and shows success on the control | A camera that cannot see the face | by hand: a real face in front of a real camera |
| 3b | Or choose the download: press Download | A disk image, Ensemble.dmg, starts downloading | The link failing or pointing at nothing | test: all three Download links point at the latest disk image, and it resolves (header request) |
| 6 | Open the disk image and drag Ensemble into Applications | A window with the app and an Applications folder, headed "Drag Ensemble into Applications" | Not knowing where the file went | by hand |
| 7 | Open Ensemble from Applications | macOS says Apple could not verify Ensemble | Not knowing what to do (see stop 1) | by hand: press Done, then Open Anyway in System Settings, Privacy & Security, and enter the Mac password |
| 8 | Finish the first-launch tour | Six steps: Camera, calibrating each screen, the nose dot, Accessibility | A refused Camera or Accessibility grant; the tour can be skipped and replayed from the menu bar panel | by hand: grant Camera, then Accessibility in System Settings |
| 9 | Make the first gesture on a real Claude session | Look at a Claude session, then use the gesture the tour shows; Claude reacts | Claude desktop not installed or no Code session open | by hand: a real hand, a real camera and a real Claude session |

## Where a stranger stops

None known. The requirements and the Open Anyway note sit under the hero Download button and in the nav Download link's tooltip, and the Claude desktop name in both requirements lines links to where to get it.
