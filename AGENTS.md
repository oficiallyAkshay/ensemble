# Ensemble: instructions for coding agents

Ensemble is a macOS menu bar app (Swift, SwiftPM, macOS 14.2+, Apple Silicon) that drives Claude desktop sessions hands-free with a webcam. This is the one agent-instructions file; `CLAUDE.md` only points here. Commands, structure and the order of work are in `.github/CONTRIBUTING.md`. Guides and references are in `docs/`: `setup.md`, `gestures.md`, `safety.md`, `telemetry.md` (the usage report), `workflows.md`, `performance.md`, `gotchas.md` (incident lessons, read before touching signing, Claude's labels, scrolling, pinch timing, overlays, audio, resources or workflows) and `RELEASING.md`.

## Commands

Build and test before every commit; all tests must pass. With only the Command Line Tools installed, `swift test` needs the Swift Testing framework paths, given in `.github/CONTRIBUTING.md`.

```
swift build                 # debug build
swift test                  # with full Xcode installed
scripts/bundle.sh           # build/Ensemble.app, signed; needs a signing identity (docs/gotchas.md, 1)
```

## Trust rules (do not weaken)

- The app makes two network connections and no other: the Sparkle update feed (off until the user turns on automatic checks or presses Check for Updates) and the anonymous daily usage report to PostHog Cloud US (`docs/telemetry.md`; on by default, off with Settings, General, Share anonymous usage). `Sources/Ensemble/App/UsageReporter.swift` is the only file that may use `URLSession`, and `scripts/check-network.sh` allows that one address. The face tracker page, its WebAssembly and the model ship in the bundle. No crash upload, no remote logging, no per-event reporting, and the report holds only the fixed list of numbers and short words in `docs/telemetry.md`: never video, text, names, paths or titles. A change that adds a network call, or a field to the report, needs the owner's explicit approval first.
- Video frames are analysed in memory and never written to disk. Logs hold events and numbers, never images or transcripts.
- Nothing personal in the tree or in history: no personal email, no machine paths, no tokens, no names of private repositories. Commit under the repository's GitHub no-reply identity (`<id>+<user>@users.noreply.github.com`); never change `user.email`. A push whose newest commit carries any other address is refused by GitHub, and older commits are not checked, so check `git log --format=%ae` yourself.
- Dictation safety: Claude's microphone is never left recording because of Ensemble. A change to dictation or send keeps the written-before-pressed record, the dead-man check, the standing check and the narrow send rules (`docs/safety.md`), and the pull request says how.
- Acting only on Claude: with another app in front, gestures do nothing.
- Never run `tccutil` or `defaults`, never delete or reset a permission grant, and never touch the keychain from an agent session, with one exception: cutting a release (an agent session, interactive or scheduled, runs `scripts/ship-release.sh`, which signs with the login keychain, as `docs/RELEASING.md` ("Release on every merge") describes). The same release also runs in CI (`auto-release.yml`), with the signing identity and the update key held as secrets of the GitHub `release` environment, which only `main` may use; an agent session never reads or prints them. An agent session may open and look at the installed app to check a change on the owner's Mac: launch it, read its version, open the menu bar panel and Settings, and take screenshots. It changes nothing there beyond what a person looking would: no setting is switched, no permission granted or reset, no calibration redone, and nothing is installed over it except by an update or a release.

## Working rules

- Branch before editing; open a pull request; `gate` (which waits for `ci`, `hygiene`, coverage and the other checks) must pass. No force-push to `main`, no `git add -A`, no amended commits, no skipped hooks.
- After a pull request that changes app logic merges to `main`, the release is cut (`docs/RELEASING.md`, "Release on every merge"): by the `auto-release` workflow (until its first release succeeded, also by the owner's launchd job), or by hand with `scripts/ship-release.sh` if it is off. Never reuse or lower a version, never move a tag, never release from anything but a clean, green `main`.
- Commit messages state the outcome. No emojis in commits, code, comments or docs.
- Do not revert values the owner set by hand (`docs/gotchas.md`, 9). Never merge a branch created before the history rewrite (10).
- `Sources/EnsembleCore` has no UI and no camera, and every change there comes with a test. Never edit a fixture to make a test pass. Only `Coordinator` decides to press Claude's controls.
- Comments explain why, not what. Delete dead code instead of hiding it.
- If a README or doc describes something you change (counts, commands, file names), update it in the same change. When a file is renamed, grep the repository for the old name and fix every reference.
