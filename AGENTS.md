# Ensemble: instructions for coding agents

Ensemble is a macOS menu bar app (Swift, SwiftPM, macOS 14.2+, Apple Silicon) that drives Claude desktop sessions hands-free with a webcam. This is the one agent-instructions file; `CLAUDE.md` only points here. Commands, structure and the order of work are in `.github/CONTRIBUTING.md`. Guides and references are in `docs/`: `setup.md`, `gestures.md`, `safety.md`, `workflows.md`, `performance.md`, `gotchas.md` (incident lessons, read before touching signing, Claude's labels, scrolling, pinch timing, overlays, audio, resources or workflows) and `RELEASING.md`.

## Commands

Build and test before every commit; all tests must pass. With only the Command Line Tools installed, `swift test` needs the Swift Testing framework paths, given in `.github/CONTRIBUTING.md`.

```
swift build                 # debug build
swift test                  # with full Xcode installed
scripts/bundle.sh           # build/Ensemble.app, signed; needs a signing identity (docs/gotchas.md, 1)
```

## Trust rules (do not weaken)

- The app makes no network connection except the Sparkle update feed, and that is off until the user turns on automatic checks or presses Check for Updates. The face tracker page, its WebAssembly and the model ship in the bundle. No telemetry, no analytics, no crash upload, no remote logging. A change that adds a network call needs the owner's explicit approval first.
- Video frames are analysed in memory and never written to disk. Logs hold events and numbers, never images or transcripts.
- Nothing personal in the tree or in history: no personal email, no machine paths, no tokens, no names of private repositories. Commit under the repository's GitHub no-reply identity (`<id>+<user>@users.noreply.github.com`); never change `user.email`. A push whose newest commit carries any other address is refused by GitHub, and older commits are not checked, so check `git log --format=%ae` yourself.
- Dictation safety: Claude's microphone is never left recording because of Ensemble. A change to dictation or send keeps the written-before-pressed record, the dead-man check, the standing check and the narrow send rules (`docs/safety.md`), and the pull request says how.
- Acting only on Claude: with another app in front, gestures do nothing.
- Never run `tccutil`, `defaults` or anything that touches the keychain or the installed app from an agent session.

## Working rules

- Branch before editing; open a pull request; `gate` (which waits for `ci`, `hygiene`, coverage and the other checks) must pass. No force-push to `main`, no `git add -A`, no amended commits, no skipped hooks.
- Commit messages state the outcome. No emojis in commits, code, comments or docs.
- Do not revert values the owner set by hand (`docs/gotchas.md`, 9). Never merge a branch created before the history rewrite (10).
- `Sources/EnsembleCore` has no UI and no camera, and every change there comes with a test. Never edit a fixture to make a test pass. Only `Coordinator` decides to press Claude's controls.
- Comments explain why, not what. Delete dead code instead of hiding it.
- If a README or doc describes something you change (counts, commands, file names), update it in the same change. When a file is renamed, grep the repository for the old name and fix every reference.
