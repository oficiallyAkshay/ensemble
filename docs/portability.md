# Portability

What runs on which system, how it is checked, and what is left. Back to the [contributing guide](../.github/CONTRIBUTING.md).

## What runs where

| | macOS | Linux | Windows |
|---|---|---|---|
| The app | Yes, released on every merge that changes app logic | No | No |
| The logic library (`EnsembleCore`) | Builds, tests pass | Builds, tests pass | Builds, tests pass |
| Reading another app's window tree | Proven on a stand-in app | Proven on a stand-in app | Proven on a stand-in app |

The tests that need Vision or CryptoKit (the fixture replay, the usage checksum and summary tests, and the hand-gesture classifier tests) do not run on Linux or Windows. The package manifest lists them with the reason.

## Agents

Ensemble's session code sits behind one adapter interface. The Claude desktop app is one implementation. A read-only adapter for Claude Code in a terminal reads busy, waiting, idle and ended from Claude Code's hook events, replayed on a real recording (`Tests/EnsembleCoreTests/Fixtures/claude-code-terminal`). It is not connected to the coordinator, and nothing types into or interrupts a terminal session yet. Other agents (Gemini, Cursor, Copilot, Codex) are not started.

## How it is checked

- `core-release` (manual): started by hand with `dry_run` left on (its default), it runs the library's tests on macOS, Linux and Windows, keeps the three logs and publishes nothing. A red job means a failing test. See "Release tracks per operating system" in [RELEASING.md](RELEASING.md). `core-v0.1.0` is the first library release.
- `window-tree` (manual): launches a small Electron stand-in app and reads its window tree and four named controls on Windows, Linux and macOS with the xa11y library.

Neither check is part of `gate`.

The current test count is in the logs of the `ci` test job on macOS and of the `core-release` dry run on Linux and Windows. It is deliberately not copied onto this page, because it changes with every pull request that adds a test.

## Rules learned while porting

- Guard each Apple-only import with `canImport` and a Foundation fallback.
- Where tests import an Apple-only module, add a stand-in module to the manifest instead of editing tests; leave out the tests that truly need the framework, listed with the reason.
- Declare the macOS app target only on macOS so a plain `swift test` runs the library's tests elsewhere.
- Recorded fixtures use LF line endings; readers tolerate a trailing carriage return. Windows cannot rename over an existing file.
- Take fixtures only from real runs; never edit one to pass.
