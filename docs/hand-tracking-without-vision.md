# Hand tracking without Apple Vision

A written note on replacing Apple Vision for hand joints on Windows and Linux, with the table a later measured run will fill. Nothing here is built, and no model is added to the app. Back to [portability](portability.md).

## How the gesture classifier takes joints today

- The hand joint types in `EnsembleCore` do not depend on Vision. `HandJoint` has 21 joints (wrist, and for each finger the base, two middle joints and the tip).
- The Vision mapping is in `Sources/EnsembleCore/HandClassifierAdapter.swift`, behind `canImport(Vision)`. It reads a Vision `Hand` and builds a `HandSkeletonFrame` and a `HandObservation` (pose, pinch ratio, palm centre).
- The gesture classifier itself (`Sources/EnsembleCore/Vendor/Sleight/GestureClassifier.swift`) and the `Hand` type also import Vision. On Linux and Windows they are not built.
- So a new model needs one thing: a source of the same 21 joints in image coordinates, fed to the same classifier through a version of the `Hand` type that Vision does not own.

## Candidate: MediaPipe hands

Facts read on the MediaPipe hand landmarker page (see "Sources"):

| Fact | Value |
|---|---|
| Platforms with a guide | Android, Python, Web |
| Joints per hand | 21 |
| Output | Landmarks in image coordinates and in world coordinates, plus left or right |
| Latency | 17.12 ms on a CPU and 12.27 ms on a GPU, on a Pixel 6 (a phone, not a laptop; the page's number, not measured here) |
| Licence | Apache License 2.0 (read in the repository's LICENSE file) |
| Model bundle size | The page does not state it. unverified |

Facts read in this repository:

- The website already ships MediaPipe models: `docs/live/models/face_landmarker.task.gz` is 2,496,541 bytes and `docs/live/models/gesture_recognizer.task.gz` is 6,320,973 bytes (read with `wc -c`). The budget in `scripts/check-size.sh` is 9,500,000 bytes, so the gesture bundle alone is about 66 percent of it. Whether that bundle holds the hand model that would ship in the app: unverified.
- Face tracking in the app already runs on MediaPipe in WebKit, so the web build of MediaPipe is proven to run in this project's web view.
- Whether the 21 MediaPipe landmarks map one to one onto the 21 joint names of `HandJoint` (the thumb joint names differ in some tools): unverified. The page gives the count only.

## Why the table below is unverified

The fixtures in `Tests/EnsembleCoreTests/Fixtures` hold joints that Vision already produced (2D points per joint and a left or right mark), not camera images. MediaPipe cannot run on joints, and the Vision frame time cannot be measured again from them. So no hit rate or frame time can be read from the repository today. Every number is marked unverified. No fixture and no number is invented.

| Gesture | Fixture it will be measured on | Vision hit rate | MediaPipe hit rate | Vision frame time | MediaPipe frame time |
|---|---|---|---|---|---|
| openPalm | to be recorded (the repository fixture is `openPalm-hold.jsonl`) | unverified | unverified | unverified | unverified |
| fist | to be recorded (`fist-hold.jsonl`) | unverified | unverified | unverified | unverified |
| twoFingers | to be recorded (`twoFingers-hold.jsonl`) | unverified | unverified | unverified | unverified |
| thumbsUp | to be recorded (`thumbsUp-hold.jsonl`) | unverified | unverified | unverified | unverified |
| none (desk life, no gesture) | to be recorded (`none-desk-life.jsonl`) | unverified | unverified | unverified | unverified |

Hit rate means: of the frames with a hand present while the person holds the named gesture, the share where the classifier returns that gesture. For the "none" row it means the share of frames where the classifier returns no gesture.

## Steps that will replace each number

The existing fixtures cannot give these numbers, so the owner records new clips. The rules from the trust section of the agent instructions hold:

- A video frame is never written to disk. A recorded clip stays on the owner's Mac. No clip and no frame is committed, in this change or a later one.
- The run uses no new network call. The model file is loaded from the local disk.
- Only numbers leave the run: a joint list per frame (as the existing fixtures are), a gesture label, and a time in milliseconds. These may be committed later as new fixtures in a separate change, never edited by hand.

Steps:

1. On the owner's Mac, start a throwaway run outside the app's source tree. It opens the camera and keeps each frame in memory only.
2. Show the run one prompt at a time: openPalm, fist, twoFingers, thumbsUp, then no gesture. Hold each for 10 seconds. Repeat the set 3 times.
3. For each frame, run Apple Vision and MediaPipe hands on the same frame. Time each with a monotonic clock around the model call only, and record the milliseconds.
4. Feed each model's 21 joints to the repository's gesture classifier. Only the joint source differs between the two columns.
5. Write one line per frame: the time, the prompted gesture, each model's joints, each model's label and each model's milliseconds. Discard the frame.
6. Compute hit rate per gesture as defined above, and the median and 95th percentile frame time per model.
7. Replace each "unverified" cell with the number. In the same cell or a line below it, write the fixture file name and the exact command that produced it. A cell without both stays "unverified".
8. Record the Mac model and the operating system version beside the table. The frame time is for that machine only.

For Windows and Linux, a second pass repeats steps 1 to 7 for MediaPipe alone on the Windows 365 cloud PC and on the Linux virtual machine. Apple Vision does not run there.

## Which tests would move and which stay Apple-only

The manifest (`Package.swift` comments) and [portability](portability.md) name the tests left out of the Linux and Windows build.

| Test file | Why it is left out today | If MediaPipe joints feed the classifier |
|---|---|---|
| `FixtureReplay.swift` (helper), `FixtureTests.swift`, `PeaceRecognitionTests.swift` | They call the fixture replay helper, which uses Vision | The fixtures hold Vision joints, so they stay a Vision-based check. A MediaPipe version needs its own recorded joints. Whether `PeaceRecognitionTests.swift` could move: unverified |
| `PointingClassifierTests.swift` | It builds a `Hand` and calls the gesture classifier, behind `canImport(Vision)` | Would move once `Hand` and the classifier no longer import Vision, because they only use joint positions |
| `WidthGesturesTests.swift` | It builds a `Hand` and calls the gesture classifier and its adapter, behind `canImport(Vision)` | Would move for the classifier part. The adapter part (`HandClassifierAdapter`) maps Vision joints, so it stays Apple-only |
| `UsageSummaryTests.swift`, `UsageTrackerTests.swift` | They need CryptoKit, not Vision | Not related to hand tracking; they stay out |

The step that makes the first move possible is to make `Hand` and the classifier independent of Vision. That is a change to the library and is not done here.

## Sources

- MediaPipe hand landmarker: https://developers.google.com/edge/mediapipe/solutions/vision/hand_landmarker
- MediaPipe licence: https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE

## Decision for the owner

Recommended: adopt MediaPipe hands as the Windows and Linux hand source, but keep the choice open until the steps above replace the unverified numbers; the owner supplies clips recorded on their own Mac, a Windows 365 cloud PC and a Linux virtual machine.
