# Releasing Ensemble

How a release is built, signed, notarized, published, and delivered to installed copies. Nothing in this repo signs, uploads, or publishes by itself except the `auto-release` workflow and, until the first workflow release has succeeded, the launchd job the owner installs on their Mac (see "Release on every merge"): the other scripts run on your command. Developer ID signing, notarization and a tag-triggered release workflow are not in use (the owner cancelled that plan for now); the one-time steps for them are kept below, marked, and the workflow would be rebuilt if it were ever needed.

## The pieces

| Piece | What it does |
|---|---|
| `scripts/bundle.sh` | Builds the release binary, assembles `build/Ensemble.app` with Sparkle inside, signs it. Local identity by default; `ENSEMBLE_SIGN_IDENTITY="Developer ID Application: ..."` switches to hardened runtime + secure timestamp + `Sources/Ensemble/Ensemble.entitlements`. |
| `scripts/release.sh` | Runs `bundle.sh`, optionally notarizes and staples the app, builds `build/Ensemble-<version>.dmg` with `hdiutil` (app plus an Applications shortcut), signs/notarizes/staples the DMG, writes the `.sha256`, prints a summary. `--dry-run` prints the Apple-service commands instead of running them. |
| `scripts/appcast.sh` | Adds a DMG to the Sparkle appcast with Sparkle's `generate_appcast`; refuses to write an appcast whose items lack an EdDSA signature. |
| `.github/workflows/auto-release.yml` | After `ci` passes on a push to `main`, or by hand: decides whether app logic changed since the newest tag, imports the signing identity from the `release` environment, runs `scripts/ship-release.sh` and checks the release and the feed. See "Release on every merge". |
| `.github/workflows/ci.yml` | On every pull request and push to `main`: `ci` builds in release mode, runs the tests and the repository's network and size checks; `hygiene` runs zizmor, pinact and a secrets scan over the whole history; `coverage`, `periphery` and `website-tests` check EnsembleCore coverage, unused code and the website logic and replay-timeline tests; `gate` passes only when all of them did. It never signs or publishes. |
| `Sources/Ensemble/App/UpdateController.swift` | The Sparkle wrapper and Ensemble's own update interface: feed URL constant, the one alert, the idle gate, the relaunch record. |

Log of the last `release.sh` run: `build/release.log`.

## One-time setup (you)

Steps 1, 5 and 6 are what the current route needs (the self-signed identity, the update key, the feed). Steps 2 to 4 and the Developer ID secrets in step 7 are only for a future move to Developer ID signing, which is not in use: there is no tag-triggered workflow for it, and one would be rebuilt then. The self-signed identity and its secrets are described under "Release on every merge".

Do these once, in this order.

1. **Decide the final name and bundle identifier before the first public release.** The bundle identifier is `dev.ensemble.app` (`Sources/Ensemble/Info.plist`, `LoginAgent.swift`). Camera and Accessibility grants, saved settings, the login agent and every future Sparkle update are tied to it, so changing it after release makes every user re-grant permissions and breaks the update chain. If the project becomes "Leanback", rename first: bundle identifier, app name, DMG name, feed URL, cask.
2. **(Only for a future Developer ID move.) Apple Developer Program: $99 per year.** Enroll at https://developer.apple.com/programs/enroll/ (an individual needs a legal name and two-factor sign-in; an organization needs a D-U-N-S number and a public website). Notarization requires the paid membership. The fee waiver covers only nonprofits, schools, and governments, not individual open-source maintainers (https://developer.apple.com/help/account/membership/fee-waivers/).
3. **(Only for a future Developer ID move.) Developer ID Application certificate.** Only the account holder can create it. In Keychain Access: Certificate Assistant, Request a Certificate From a Certificate Authority, save to disk. At https://developer.apple.com/account/resources/certificates/add choose "Developer ID Application", upload the request, download the `.cer`, double-click it. Confirm with `security find-identity -v -p codesigning`: a line `"Developer ID Application: Your Name (TEAMID)"`. Export it (Keychain Access, right-click the certificate, Export, `.p12`, choose a password) if a workflow ever needs it.
4. **(Only for a future Developer ID move.) Notarization credentials.** In App Store Connect, Users and Access, Integrations, App Store Connect API: create a key with Developer access and download `AuthKey_XXXX.p8` (downloadable once). Note the key ID and the issuer ID. For local runs store them once:
   ```
   xcrun notarytool store-credentials ensemble-notary --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUERID
   ```
   (An app-specific password works too: `--apple-id ... --password ... --team-id ...`.)
5. **Sparkle update-signing key.** From the repo root, once packages are resolved (`swift package resolve`):
   ```
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   It stores the private key in your login keychain and prints the public key. Paste the public key over `TODO-REPLACE-WITH-SPARKLE-PUBLIC-ED-KEY` in `Sources/Ensemble/Info.plist`. Export the private key for CI and for backup: `generate_keys -x sparkle_private.key`; keep the file in a password manager. If this key is lost, installed copies cannot be sent signed updates and users must reinstall by hand.
6. **GitHub.** Replace `OWNER/REPO` in `UpdateConfig.feedURL` (`Sources/Ensemble/App/UpdateController.swift`) with `https://<account>.github.io/<repo>/appcast.xml`. Create the branch that serves the appcast and turn on Pages:
   ```
   git switch --orphan gh-pages && git commit --allow-empty -m "Appcast branch" && git push origin gh-pages && git switch -
   ```
   Then Settings, Pages, Source: Deploy from a branch, `gh-pages`, `/ (root)`. The first release creates `appcast.xml` there.
7. **Secrets.** The current route's secrets (`ENSEMBLE_SIGN_P12_BASE64`, `ENSEMBLE_SIGN_P12_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`) are environment secrets of `release`, listed under "Release on every merge"; `SPARKLE_ED_PRIVATE_KEY` is the text of `sparkle_private.key`. A Developer ID route would additionally need the certificate `.p12` (base64) and its password, the notary key `.p8`, its key ID and its issuer ID; none of these is set or read by any workflow now.

## Try it locally first

```
scripts/release.sh                                   # local identity: a DMG for this Mac only
ENSEMBLE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ENSEMBLE_NOTARY_PROFILE=ensemble-notary scripts/release.sh --dry-run   # signs, prints the notarization commands
ENSEMBLE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ENSEMBLE_NOTARY_PROFILE=ensemble-notary scripts/release.sh             # the real thing; waits on Apple (2 to 15 minutes, twice)
```

A DMG made with the local identity opens on this Mac only. Gatekeeper rejects it elsewhere.

## Ship from this Mac (current route)

Until a Developer ID exists, releases are built on the owner's Mac right after a merge to `main`, from a clean checkout of `main`:

```
scripts/ship-release.sh 0.2.0
```

It builds and signs the DMG with the local identity, adds it to the appcast with the update key in this Mac's login keychain (a refusal here stops the run before anything is public), then tags `main`, publishes the GitHub Release, and pushes `appcast.xml` to `gh-pages`, which GitHub Pages serves at the feed address in `UpdateController.swift`. Installed copies then see the version on their next check, or at once with Check for Updates. The release page and the appcast item carry the same notes, the titles of the pull requests merged into `main` since the previous tag, whether by merge commit or by squash, so the update window shows what changed. The update key and feed are set; the private key is also kept outside the keychain by the owner. Copies signed with the local identity update only on this Mac.

## Release on every merge

Every pull request that changes app logic is released as soon as it merges to `main`. Bug fixes are app logic, so they ship the same way and at once. The GitHub workflow `.github/workflows/auto-release.yml` cuts the release once `ci` has passed on the merge commit (see "The workflow" below). Until the first workflow release has succeeded, a plain launchd job on the owner's Mac does the same within about 5 minutes of the checks passing, and stays installed; after that it is removed (`scripts/install-auto-release.sh --uninstall`) so two releasers never race. The job: `scripts/install-auto-release.sh` installs the agent `dev.ensemble.releaser`, which runs `scripts/auto-release.sh` every 5 minutes. No Claude session or routine is involved, so nobody has to remember to release. An agent or a person may still run `scripts/ship-release.sh` by hand; the job then sees the new tag and has nothing to do.

**The workflow.** `auto-release.yml` has two jobs. `decide` (no secrets, no environment) runs when `ci` completes green for a push to `main`, or on `workflow_dispatch`: it stops quietly unless the commit is still the tip of `main` and a file under `Sources/`, `Package.swift` or `Package.resolved` changed since the newest `v*` tag, picks the next patch version and refuses one that exists as a tag or a release. `release` runs on a macOS runner in the GitHub environment `release` (limited to `main`): it checks out exactly the decided commit, imports the signing identity into a temporary keychain, refuses unless that identity's SHA-1 is `40B0779A528926B904971BBDB913DC4860CD1D49`, then, unless `main` has moved on since `decide` (a merge while the job queued: the step ends with a notice and the run for the newer commit decides, instead of failing in `ship-release.sh`), runs `scripts/ship-release.sh` (build, sign as "Ensemble Local Signing", DMG, signed appcast item, tag, GitHub Release with `Ensemble-<version>.dmg`, its `.sha256` and `Ensemble.dmg`, appcast to `gh-pages`, all through the API with the run's token) and finally checks that the release and `https://oficiallyakshay.github.io/ensemble/appcast.xml` show the version, retrying for 3 minutes. Before anything is public `ship-release.sh` mounts the DMG and refuses unless the app's designated requirement is `identifier "dev.ensemble.app" and certificate leaf = H"40b0779a528926b904971bbdb913dc4860cd1d49"`, the one releases 0.2.24 and later carry: another certificate would reset every user's Camera and Accessibility grants. The temporary keychain is deleted at the end of every run.

The secrets are environment secrets of `release` (values never in the repository): `ENSEMBLE_SIGN_P12_BASE64` (the signing identity as a base64 PKCS12 file), `ENSEMBLE_SIGN_P12_PASSWORD` and `SPARKLE_ED_PRIVATE_KEY` (the Sparkle update key; its public half is `SUPublicEDKey` in `Info.plist`).

Dry run, which builds, signs, checks the requirement and signs the appcast item but creates no tag, no release and no push (and skips the "is anything due" check so there is always something to build):

```
gh workflow run auto-release.yml -f dry_run=true
```

A real run by hand, with the due check: `gh workflow run auto-release.yml -f dry_run=false`.

**What counts as app logic.** A change to any file under `Sources/` (the app, `EnsembleCore` and the bundled resources) or to `Package.swift` or `Package.resolved`. A change that touches only docs, tests, scripts, CI or the website does not release by itself; it ships with the next release.

**What the launchd job does.** Each run fetches `origin`, finds the newest `v*` tag and compares it with `origin/main`. If nothing under `Sources/`, `Package.swift` or `Package.resolved` changed, it stops without a word. Otherwise it waits for the `ci` run on the newest commit of `main` to finish green (pending: it tries again in 5 minutes; failed: it logs that once and does not release), works out the next patch version, refuses a version that exists as a tag or a GitHub release, makes a throwaway worktree of that exact commit, runs `scripts/ship-release.sh <version>` there and removes the worktree on every exit path. Where `scripts/whats-new.sh` exists it first writes an untracked `docs/whats-new/<version>.txt` from the commit subjects and checks it. Afterwards it confirms that the GitHub release exists and the appcast lists the version (retrying for 3 minutes). A macOS notification appears on a release or a refusal, never when nothing is due. One run at a time (a lock directory, taken over after 30 minutes).

- Log, one UTC line per decision: `~/Library/Logs/Ensemble/releaser.log`; the build output of each release: `~/Library/Logs/Ensemble/releaser-ship.log`; the agent's own output: `~/Library/Logs/Ensemble/releaser.out`.
- See what it would do now, building and publishing nothing: `scripts/auto-release.sh --dry-run`.
- Remove it once the first workflow release has succeeded (proved by a dry run, then a real release); it stays until then. Off switch: `launchctl bootout "gui/$(id -u)/dev.ensemble.releaser"`, or `scripts/install-auto-release.sh --uninstall` (also removes the agent file). Releases are then cut by hand as below.
- The agent runs the copy of `scripts/auto-release.sh` on `origin/main`, so an old checkout still releases with the current script. A checkout under Desktop, Documents or Downloads is hidden from background agents, so the installer gives the agent its own clone in `~/Library/Application Support/Ensemble/releaser-checkout`.
- The job needs `gh` signed in, `jq`, and the signing identity in the login keychain (the first run may ask to let `codesign` use the key: choose Always Allow, as for `scripts/dev-install.sh`).

**By hand.** From a clean checkout of `main` whose latest commit has passing checks (`gate`):

```
scripts/ship-release.sh <next version>
```

The next version is the latest tag with one added to the patch number (`0.2.24` becomes `0.2.25`). There is no major or minor policy; the owner changes the leading numbers by naming a version. A version is never reused or lowered, and a tag is never moved. The release notes are the `docs/CHANGELOG.md` "Unreleased" entries. `ship-release.sh` signs with the owner's login keychain, so this runs on the owner's Mac (the launchd job above runs it for you). It stops before anything is public if the build, the signature or the appcast refuses; fix the cause and run it again, do not work around it.

**Taking it back.** A bad release is fixed by the next release; the version that shipped stays published because installed copies compare build numbers. Stop the releases by removing this section and the exception in `AGENTS.md`.

## Cut a release

Releases are cut by `auto-release.yml` after a merge, or by hand with `scripts/ship-release.sh` (see "Release on every merge" and "Ship from this Mac"). The version is the next patch number after the newest `v*` tag; the build number is the commit count, so it grows with every commit (Sparkle compares the build number, never reuse or lower one). Pushing a tag does not start a release: no workflow reacts to a tag, and one is never pushed by hand. Developer ID signing, notarization and the tag-triggered workflow that went with them are not in use; if they are ever wanted, that workflow is rebuilt from `scripts/release.sh` and the steps under "One-time setup".

After a release, on a Mac that has run Ensemble before, check for updates and confirm the new version installs; the GitHub Release holds `Ensemble-<version>.dmg`, its `.sha256` and `Ensemble.dmg`, and `appcast.xml` on `gh-pages` lists the version. A DMG signed with the local identity is not notarized, so Gatekeeper warns on a Mac that has never run Ensemble.

If a release fails after the GitHub Release is created (for example the appcast push), fix the cause and run the release again for the same version only if the tag was not created; do not move a tag.

## Release tracks per operating system

Each system has its own release, so one does not wait for another.

| System | What is released | How it is cut | Tag |
|---|---|---|---|
| macOS | The app (signed, notarized DMG, update feed) | Automatically after a merge that changes app logic, see "Release on every merge" | The app's own version tags |
| Linux and Windows | The logic library (`EnsembleCore`) only, because there is no app for these systems | Manual workflow `core-release`: enter a version and turn `dry_run` off. It runs `swift test` on macOS, Linux and Windows and publishes only if all three pass | `core-v<version>` |

Run `core-release` with `dry_run` on first: it tests and publishes nothing. The release notes say what is and is not included, and that tests needing Apple-only frameworks (Vision, CryptoKit) do not run on Linux or Windows. The first library release is `core-v0.1.0`. A bad library release is fixed by the next one; a tag is never moved.

## What CI builds

`ci.yml` builds the app bundle with `ENSEMBLE_SIGN_IDENTITY=-`, an ad-hoc signature used only so the network, privacy and size checks read the real app. That bundle is never uploaded or installed: every ad-hoc build is a new identity, which would drop a Mac's Camera and Accessibility grants. Releases are cut on a Mac with the stable signing identity.

Every action in the workflows is pinned to a commit SHA with the version in a trailing comment, and Dependabot proposes the bumps weekly. A bump pull request must pass `gate`, whose `hygiene` job includes `pinact` checking that each SHA is the commit its comment names. To pin by hand: `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`.

The secrets of the `release` environment and `TRAFFIC_TOKEN` are the only ones any workflow reads beyond the built-in token. They are recorded as owner opt-ins in `.ossemble/state.json`, with the reason for each.

## The website

GitHub Pages serves the `gh-pages` branch: `appcast.xml` (written by `scripts/ship-release.sh`) and the website. `site.yml` copies `docs/index.html`, `docs/logo.png`, `docs/live/` and `docs/assets/` there whenever they change on main, so the site is edited in `docs/` like any other file. It lives at https://oficiallyakshay.github.io/ensemble/.

## How updates reach users

- Each installed copy reads the appcast at `UpdateConfig.feedURL` (GitHub Pages, HTTPS), compares the build number, downloads the DMG from the GitHub Release, verifies the EdDSA signature against `SUPublicEDKey` and the Apple code signature, then replaces the app and relaunches.
- The usage report (`UsageReporter.swift`, [telemetry.md](telemetry.md)) is separate from updates and does not wait for them. Policy for updates in `UpdateController.swift`: no update network until the user turns on "Update automatically" in Settings, General (or presses Check for Updates). With it on, Ensemble checks 15 seconds after launch and Sparkle then checks every hour (`SUScheduledCheckInterval` = 3600, `UpdatePolicy.checkInterval`), downloads in the background, and installs after 30 seconds of unbroken idle time (not dictating, sending, calibrating or in the tour), then relaunches. Sparkle's own "check automatically?" prompt is suppressed. With it off, a manual check is the only check.
- What the user sees. Ensemble draws its own update interface (`UpdateController` is Sparkle's `SPUUserDriver`); none of Sparkle's windows appear. Decisions are in `Sources/EnsembleCore/UpdateFlow.swift`.

  | The user | Before (Sparkle's windows) | Now |
  |---|---|---|
  | Update automatically on | button showed the version; install on idle | installs by itself after 30 s idle, no question; the island says "Installing Ensemble x.y.z", then "Updated to x.y.z" after the reopen |
  | Presses Check for Updates and a version exists | Check, "Update", "Install Update", restart, open by hand: six clicks | one alert, "Ensemble x.y.z is available. Install now?" with Install, Later and a "What's new" link; Install downloads, installs and reopens: two clicks |
  | Button already says "Update to x.y.z" | press, then Sparkle's windows | one press does everything |
  | Presses while dictating, sending, calibrating or in the tour | could restart Ensemble at once if the update was already downloaded | the button says "Installs x.y.z when you finish"; the install starts at the first idle moment |
  | A background check finds a version with automatic install off (only if Sparkle's checks are on without downloads) | Sparkle's window | the alert once per version; Later stops it until the next launch or a press |
  | The download or install fails | Sparkle's error window | one alert, "Ensemble could not update", with Retry |

  The button reads "Checking..." during a check and "Installing x.y.z..." while it downloads and installs. "What's new" opens the release page in the browser; its address comes from the signed feed (the release notes link, or the GitHub release the download comes from), and Ensemble itself fetches nothing for it.
- Relaunch. Sparkle's installer quits Ensemble, installs and opens the new copy. Three things back it up: (1) before quitting, Ensemble starts a detached shell in its own session (so launchd does not kill it with the login agent's job) that looks for a running Ensemble 30 and 60 seconds after the old copy exits and opens it if none is there; (2) with open at login on, the copy Sparkle opened is outside launchd's job, so it quits at once and asks launchd to start the job (`launchctl kickstart`), once only, which keeps crash restarts working; (3) the clean quit for the install exits with status 0, so the login agent's `KeepAlive` (restart on failure only) never starts a second copy, and a second copy would exit at launch anyway. The new copy logs "update: relaunched after update to x.y.z" with who started it, or "did not install" if the version did not change.
- The new flow ships in a release, so it takes effect from the update after the one that carries it: installing that release still goes through the old windows.
- To check for updates by default (Sparkle's standard behavior is a prompt on the second launch), remove the `updaterShouldPromptForPermissionToCheck` override and let Sparkle ask, or set `SUEnableAutomaticChecks` to true in `Info.plist` (no consent step).
- A build whose `SUPublicEDKey` is still the placeholder, or whose feed URL still says `OWNER`, has updates off: the menu entry explains it and Sparkle never starts.
- Both updaters on one Mac: a development build from `scripts/dev-update.sh` is made without `SUPublicEDKey`, so its Sparkle never starts and a release never installs over it. If a release copy gets there anyway (installed by hand, or by Sparkle before the development updater was set up), the development updater sees the key in the installed copy and replaces it with its own build on its next run, even when `main` has not moved, waiting while Claude is listening (`docs/gotchas.md`, 14).

## Permissions survive updates only with a stable signature

Camera and Accessibility grants are tied to the app's signature. Developer ID signatures are stable across releases, so users keep their grants through updates. Moving from the local "Ensemble Local Signing" identity to Developer ID changes the signature once: everyone, including you, re-grants Camera and Accessibility after first installing a Developer ID build. Never distribute ad-hoc signed builds: every build is a new identity and grants reset each time.

## Signing certificate expiry

Releases from this Mac are signed with a self-signed local certificate ("Clutch Local Signing" on the production Mac, the app's earlier working name; "Ensemble Local Signing" elsewhere), without a secure timestamp. Once it expires, releases signed with it break the update path, and signing with a new certificate resets every user's Camera and Accessibility grants.

Expiry date of the production Mac's signing certificate: **2036-10-11** (re-check it with `openssl x509 -noout -enddate -in <certificate file>`, from an exported copy of the certificate, never the key).

`scripts/ship-release.sh` reads the expiry date from the certificate in the keychain before anything else, unless the identity is a Developer ID one:

| The certificate | What the script does |
|---|---|
| Already expired | Stops with an error, before anything is built or published |
| Expires within 60 days | Logs a warning with the date and carries on |
| Expires later | Nothing |
| Not found or unreadable | Logs a warning and carries on (`scripts/bundle.sh` still refuses a missing identity) |

On the warning: move to Developer ID signing (the one-time setup above) and ship a Developer ID release before the date. That move changes the signature once, so everyone re-grants Camera and Accessibility after installing it: announce it with the release. A new self-signed certificate would cost the same re-grant and only move the date.

## First Developer ID build: checks nobody has run yet

These need a notarized build on a real Mac and could not be run from the development machine:

- Face tracking starts (MediaPipe's WASM runs in WebKit's separate process, so no JIT entitlement is expected; if it fails under the hardened runtime, add `com.apple.security.cs.allow-jit` to `Ensemble.entitlements`, nothing broader).
- The Camera prompt appears and the camera opens (`com.apple.security.device.camera`).
- Accessibility control of Claude and the pinch gestures work.
- Settings, About, Check for Updates reaches the appcast and the button reads "Up to date" for a few seconds.
- Install version N, publish N+1, confirm the update installs and the app relaunches (the login agent has `KeepAlive` only on failure exit, so Sparkle's clean quit should not fight it).

## Check by hand on the first release after the one-click flow

The first release that carries the flow is installed through the old windows; these checks need the release after it.

1. Update automatically off, open at login on: Check for Updates shows one alert; Install; Ensemble quits and reopens with no other window, and the island says "Updated to x.y.z". `~/Library/Logs/Ensemble` has "relaunched as ... handing over to launchd", then "relaunched after update to x.y.z (started by the login agent)".
2. Same with open at login off: the log says "(opened by Sparkle)".
3. Press Later, then "Update to x.y.z": one press installs and reopens.
4. Start a dictation, then press "Update to x.y.z": the button says "Installs x.y.z when you finish" and nothing installs until the dictation ends.
5. Update automatically on: the update installs about 30 seconds after you stop using Ensemble, with no alert.

## Homebrew

The main `homebrew-cask` repository disabled casks that fail Gatekeeper on 2026-09-01 (https://github.com/orgs/Homebrew/discussions/6334, https://brew.sh/2025/11/12/homebrew-5.0.0/), so the main repository takes only the notarized build, and also judges notability. Start with your own tap: a repository named `homebrew-tap` with `Casks/ensemble.rb`:

```ruby
cask "ensemble" do
  version "0.1.0"
  sha256 "<contents of Ensemble-0.1.0.dmg.sha256, the hash only>"

  url "https://github.com/OWNER/REPO/releases/download/v#{version}/Ensemble-#{version}.dmg"
  name "Ensemble"
  desc "Control the Claude desktop app hands-free with a webcam"
  homepage "https://github.com/OWNER/REPO"

  livecheck do
    url "https://OWNER.github.io/REPO/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Ensemble.app"

  uninstall quit: "dev.ensemble.app"

  zap trash: [
    "~/Library/Application Support/Ensemble",
    "~/Library/LaunchAgents/dev.ensemble.app.plist",
    "~/Library/Logs/Ensemble",
    "~/Library/Preferences/dev.ensemble.app.plist",
  ]
end
```

Users: `brew install --cask OWNER/tap/ensemble`. After each release, update `version` and `sha256` in the tap (edit the file and push, or `brew bump-cask-pr` for the main repository). An un-notarized cask in a tap installs, but Homebrew no longer has a flag to skip the quarantine check, so users would run `xattr -dr com.apple.quarantine /Applications/Ensemble.app` themselves.

## If you ship before notarizing

Users on macOS 15 and later see a block message with no Control-click bypass. They open System Settings, Privacy & Security, scroll to "Open Anyway" (https://support.apple.com/en-us/102445), or run `xattr -dr com.apple.quarantine /Applications/Ensemble.app`. Reports of an extra "damaged" message on macOS 26 exist but are from blogs only. Sparkle updates still work, but each one is a new un-notarized download.

## Sources

- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Developer ID: https://developer.apple.com/developer-id/
- Sparkle documentation: https://sparkle-project.org/documentation/ (publishing, customization, sandboxing, gentle reminders)
- Sparkle releases (2.10.0, 2026-09-13): https://github.com/sparkle-project/Sparkle/releases
- GitHub's certificate import recipe: https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- Runner images: https://github.com/actions/runner-images
- What similar apps ship: Rectangle (DMG + Sparkle), Ice (zip + Sparkle, appcast on GitHub Pages), Stats (DMG): their READMEs and Homebrew cask files.
