# Contributing to Ensemble

Thank you for helping. Ensemble drives Claude desktop with a webcam and a user's hands, and it is installed on people's
own Macs, so the bar is trust first, features second. Read the trust rules below before you write code.

Coding agents read `AGENTS.md`, which points here and to the pages under `docs/`. This file is for people. The product overview is the [README](../README.md).

## What you need

- A Mac with Apple Silicon, macOS 14.2 or later (developed on macOS 26), and a webcam.
- Swift 6.2 or newer. Apple's Command Line Tools are enough to build and test (`xcode-select --install`); Xcode is not
  required. Older tools lack the macOS 26 interfaces the app uses (Liquid Glass).
- [Claude desktop](https://claude.com/download) with Code sessions, to try the app end to end.
- `gh` for pull requests, and optionally [pre-commit](https://pre-commit.com) for the repository checks.

## Build, test, bundle, run

```
swift build                 # debug build
swift test                  # unit tests
scripts/bundle.sh           # release build -> build/Ensemble.app, code-signed
open build/Ensemble.app
```

With only the Command Line Tools installed, the tests need the Swift Testing framework paths:

```
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

All tests must pass before you open a pull request. The tests live in `Tests/EnsembleCoreTests`; gesture timing is
replayed from recorded fixtures in `Tests/EnsembleCoreTests/Fixtures`, so a timing change is checked against real hands,
not against a guess.

### Signing

`scripts/bundle.sh` signs with a local code-signing certificate named `Ensemble Local Signing` and stops with an error if
it is missing. It never signs ad hoc, on purpose: macOS ties the Camera and Accessibility permissions to the app's
signature, and an ad-hoc signature is a new identity on every build, so the permissions would silently stop working after
each install. Create the certificate once in Keychain Access, Certificate Assistant, Create a Certificate (type: Code
Signing), or point `ENSEMBLE_SIGN_IDENTITY` at another identity. Keep using the same one; changing it makes macOS ask for
Camera and Accessibility again, and a permission that shows on but does not work is cleared with
`tccutil reset Accessibility dev.ensemble.app`.

`scripts/dev-install.sh` creates that certificate for you and then runs `security set-key-partition-list` on it, which
asks for your login password once in Terminal. That lets the build tools use the key without a "codesign wants to use
the key" prompt on every rebuild. The prompt exists only for people who build from source; the downloaded app never
touches this key. If you cancel, everything still works and the prompt stays until you choose Always Allow.

### Running your build

Quit any installed Ensemble first. Open `build/Ensemble.app`, grant Camera and Accessibility, and choose Calibrate in the
menu bar panel. Claude desktop must be running with at least one Code session. The log is
`~/Library/Logs/Ensemble/ensemble.log`; the hidden setting `detailedTrace` (numbers and states only) adds a per-frame
trace for tuning gestures:

```
defaults write dev.ensemble.app detailedTrace -bool true    # then restart the app
```

### Developer auto-update install

For developers only. Friends install the disk image from the releases page, as the README says. On a Mac you develop on,
this builds the app from source and keeps it on the latest `main`:

```
gh repo clone oficiallyAkshay/ensemble ~/ensemble && ~/ensemble/scripts/dev-install.sh
```

It needs Swift 6.2 or newer, which comes with Apple's 2025 developer tools. It creates a self-signed
`Ensemble Local Signing` identity once, so the Camera and Accessibility grants survive every rebuild, installs
Ensemble.app (over `/Applications/Ensemble.app` when that exists, else in `~/Applications`), and loads a launchd agent
that checks `main` every 2 minutes, rebuilds when it moved and relaunches the app. macOS hides Desktop, Documents and
Downloads from background agents, so a clone kept there gets a build-only clone in
`~/Library/Application Support/Ensemble/checkout` for the agent. With only the Command Line Tools, the build uses the
macOS 26 SDK, because the macOS 27 SDK's SwiftUI macros need Xcode. An update waits while Claude is listening. The log is `~/Library/Logs/Ensemble/updater.log`. Stop it
with `launchctl bootout "gui/$(id -u)/dev.ensemble.updater"`.

## Repository checks

CI runs the same checks you can run locally.

```
env -u GH_TOKEN -u GITHUB_TOKEN pre-commit run --all-files   # gitleaks (secrets) and zizmor (workflow security)
```

Unset the two variables: zizmor forwards any token it finds to github.com, and a placeholder token fails with a 401
instead of a clean finding. If you change a workflow, also run `actionlint` and `pinact run --check`. The pre-commit hooks
pin their tools to commit SHAs; do not loosen a pin to make a hook pass.

## The trust rules

These are not style preferences. A pull request that breaks one will not be merged, however useful it is.

1. **No network except the update feed and the usage report.** Sparkle may fetch the update feed, and only after the user
   turns on automatic checks or presses Check for Updates. `UsageReporter.swift` sends the anonymous daily report
   described in [docs/telemetry.md](../docs/telemetry.md); it is the only file that may use `URLSession`. The face tracker page, its WebAssembly and
   its model ship inside the app bundle and are served through the `ensemble-asset://` scheme. Do not add a network call,
   a remote script, a font or image fetched from the web, or a dependency that talks to the network. If you think the app
   needs one, open an issue first.
2. **Usage reporting stays small.** One anonymous summary a day with the fixed fields in `docs/telemetry.md`, on by default with a Settings switch that stops it at once. No crash upload, no remote logging, no per-event reports, no new field without the owner's approval.
3. **Camera frames stay in memory.** Frames are analysed and discarded. They are never written to disk and never sent
   anywhere. Logs hold events and numbers, never images and never the text of a draft.
4. **Nothing personal in the tree or in history.** No personal email addresses, machine paths, tokens, keys, names of
   private repositories, screenshots of private windows, or recordings of other people. The secrets scan covers the whole
   history, but it is not a substitute for looking at your own diff.
5. **Commit under a no-reply identity.** Use your GitHub no-reply address (GitHub, Settings, Emails, "Keep my email
   addresses private"): `git config user.email "<id>+<username>@users.noreply.github.com"` in this clone. GitHub refuses
   a push whose newest commit carries a private address, and it does not check older commits in the same push, so check
   `git log --format=%ae origin/main..HEAD` before you push. A wrong address in public history stays there.
6. **Dictation is never left recording because of Ensemble.** Anything that touches dictation or sending must keep the
   safety design in [docs/safety.md](../docs/safety.md) intact (written before pressed, dead-man check, standing check, narrow send rules, stop on
   typing or clicking). Say in the pull request how your change preserves it.
7. **Ensemble acts only on Claude.** With another app in front, gestures do nothing.
8. **Pin everything the build runs.** Every GitHub Action is a full commit SHA with the version in a trailing comment;
   workflows start from `permissions: {}`; no `${{ }}` expression inside a `run:` step (pass it through `env:`).
   Dependabot proposes bumps weekly.

## How a change flows

1. Open an issue for anything bigger than a bug fix, so the direction is agreed before you spend time.
2. Branch from current `main`; one change per branch. Do not work on `main`, and do not merge an old branch that predates the
   repository going public: its history was replaced and merging it brings the old commits back.
3. Make the change with a test when it touches `Sources/EnsembleCore`. If it changes behaviour a README, a doc or a count
   describes, update that in the same change.
4. Run `swift build`, the tests and the repository checks above.
5. Commit with a message that states the outcome ("Hold-to-send stops counting after a keystroke"), not the mechanism.
   No emojis in commits, code, comments or docs. Do not amend or force-push a branch someone has reviewed.
6. Open a pull request against `main`. `gate` must pass: it waits for `ci` (build, tests and the repository's own checks on a macOS runner), `hygiene`
   (zizmor, pinact, secrets scan), `website-tests`, `coverage` (every changed line in `Sources/EnsembleCore` covered, and total
   coverage not below `.github/coverage-baseline.json`) and `periphery` (no unused declarations in EnsembleCore). A pull request that changes dictation, sending or the Accessibility bridge
   gets a manual check on a real Mac with Claude desktop; say what you ran.
7. The maintainer merges once the checks pass.

## Code structure

SwiftPM package with two targets plus a separate benchmark package.

| Path | What it is |
|---|---|
| `Sources/EnsembleCore` | The `EnsembleCore` target. Pure logic with no UI and no camera: gesture state machine, setup profiles and matching (`SetupProfile.swift`), nose pointer (calibration fit plus a One Euro filter), covered-camera and multi-face detectors, the size-capped log file, dictation safety records, the frame-rate planner, and the hand-pose classifier adapted from Sleight (`Vendor/`). Unit-tested. |
| `Sources/Ensemble` | The `Ensemble` executable target, the menu bar app. |
| `Sources/Ensemble/Engine` | Camera capture, Apple Vision hand pose, MediaPipe Face Landmarker in a hidden `WKWebView`, and frame scheduling. |
| `Sources/Ensemble/Claude` | The Accessibility bridge: finds Claude's session panes, reads and presses its dictation and Send controls, runs the dictation safety checks, mutes the input device as a last resort. |
| `Sources/Ensemble/Coordinator` | Joins the engine and the bridge: turns gesture intents into actions on the session being looked at, after every safety guard has agreed. |
| `Sources/Ensemble/App` | The shell: menu bar, settings, calibration, status capsule and overlay, hotkey, notifications, Sparkle updater. |
| `Sources/Ensemble/Resources/web` | The bundled MediaPipe runtime, WebAssembly, model and tracker page. |
| `Tests/EnsembleCoreTests` | Swift Testing tests and the recorded gesture fixtures. |
| `Tools/PerfBench` | Separate package of camera-free micro-benchmarks (synthetic frames and head paths). |
| `scripts/` | `appcast.sh`, `auto-release.sh`, `bundle.sh`, `check-network.sh`, `check-size.sh`, `dev-install.sh`, `dev-update.sh`, `dmg-settings.py`, `install-auto-release.sh`, `make-dmg-background.swift`, `make-icon.swift`, `pack-web.swift`, `release.sh`, `ship-release.sh`. |
| `docs/` | Guides and references: [setup](../docs/setup.md), [gestures](../docs/gestures.md), [website review](../docs/website-review.md), [safety](../docs/safety.md), [telemetry](../docs/telemetry.md), [workflows](../docs/workflows.md), [performance](../docs/performance.md), [gotchas](../docs/gotchas.md), [RELEASING.md](../docs/RELEASING.md) and the [changelog](../docs/CHANGELOG.md). |
| `.github/workflows` | `ci.yml` (build, test, workflow and secrets checks, coverage, dead code, and the `gate` job), `auto-release.yml` (releases after every merge that changes app logic, with the signing secrets in the `release` environment), `release.yml` (the later route once a Developer ID exists, disabled). A release is `scripts/ship-release.sh`, run by `auto-release.yml` (and, until its first release succeeded, by the owner's launchd job), as [RELEASING.md](../docs/RELEASING.md) describes. |

### How the pieces fit

```
camera -> Engine (hand pose: Apple Vision, face: MediaPipe in a hidden web view)
       -> EnsembleCore (gesture state machine, nose pointer, detectors)
       -> Coordinator (every safety guard must agree)
       -> Claude bridge (Accessibility: dictation, Send, scroll)
       -> status capsule and overlay (App)
```

Rules of thumb: logic that can be tested without a camera belongs in `EnsembleCore`; only `Coordinator` decides to press
Claude's controls; frame scheduling stays in `Engine`.

## Lessons that were paid for

Ensemble has been broken in specific, repeatable ways, and the fixes are not obvious from the code. They are written down
in [docs/gotchas.md](../docs/gotchas.md). Read it before you touch any of these:

- the signing identity and the Camera and Accessibility permissions;
- Claude desktop's accessibility labels, which are English strings of one Claude version;
- scrolling Claude, which works only through the session event tap;
- the double-pinch timing, which comes from measured frames;
- overlay windows and Liquid Glass animation;
- pausing other audio on macOS 15.4 and later;
- loading resources from the signed bundle;
- workflow pinning and permissions.

Values the owner chose by hand (focus delay, hold-to-send time, the blue outline, the menu bar icon, the motion curve) are
listed there too; do not change them without asking in an issue.

## Roadmap

- Record and publish a demo recording.
- A signed and notarized disk image, then a Homebrew cask.
- Automatic updates.
- Restrict gesture send to Claude's confirm-before-run permission modes.
- Intel and older-macOS testing.
- Rename to Leanback.

## Reporting problems

A bug: open an issue with your macOS version, Claude desktop version and the lines from the log around the problem (remove
anything you do not want shared). A security problem: do not open an issue; see `SECURITY.md`.

## Credits

Ensemble includes MediaPipe by Google (Apache-2.0, with the Face Landmarker model), the hand-pose rules of Sleight (MIT,
adapted in `Sources/EnsembleCore/Vendor/Sleight`), an approach to driving Claude's dictation from claude-dictation-hotkey
(MIT) and the Sparkle updater. Full notices are in `THIRD_PARTY_NOTICES.md`. Ensemble is an independent project and is not
affiliated with or endorsed by Anthropic.

## Licence

By contributing you agree your work is released under the repository's MIT licence (`LICENSE`). Vendored code keeps its
own licence; see `THIRD_PARTY_NOTICES.md`.

## Badge recipes

The README shows the licence badge and a clone count. Recipes, with `<owner>/<repo>` as this repository:

| Badge | Template |
|---|---|
| Licence | `https://img.shields.io/badge/license-MIT-2f6f4e?logo=opensourceinitiative&logoColor=white` |
| Clones | `https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/<owner>/<repo>/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white`, fed by the clonometer workflow, which writes the JSON to the `badges` branch. |
| Works with | `https://img.shields.io/badge/Claude.ai-1e1b4b?logo=claude&logoColor=white` |

## The README and its checks

The README follows the readmerlin shape: hero, Features, Fit, How it compares, Security and limits. The hero graphic
`Assets/hero.svg` is drawn from `Assets/hero.hero.json` with figurehead:

```
node <path-to-figurehead>/scripts/figurehead.mjs render Assets/hero.hero.json --out Assets/hero.svg
node <path-to-figurehead>/scripts/figurehead.mjs check Assets/hero.hero.json Assets/hero.svg --repo .
```

`Assets/social-preview.png` (1280 by 640, the repository's social preview card) is the hero on a white canvas, rendered from `Assets/social-preview.html`. Regenerate it whenever the hero changes, then upload it under Settings, General, Social preview:

```
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --force-color-profile=srgb --window-size=1280,640 --screenshot="$PWD/Assets/social-preview.png" "file://$PWD/Assets/social-preview.html"
```

Check the pages with `readmerlin check --pages` from the repository root. Every comparison cell in the README was read
from the other project's own README or support page, so re-read them before changing a cell.
