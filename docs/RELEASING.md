# Releasing Ensemble

How a release is built, signed, notarized, published, and delivered to installed copies. Nothing in this repo signs, uploads, or publishes by itself: the scripts run on your command, and the GitHub workflow runs only when a tag named `v*` is pushed.

## The pieces

| Piece | What it does |
|---|---|
| `scripts/bundle.sh` | Builds the release binary, assembles `build/Ensemble.app` with Sparkle inside, signs it. Local identity by default; `ENSEMBLE_SIGN_IDENTITY="Developer ID Application: ..."` switches to hardened runtime + secure timestamp + `Sources/Ensemble/Ensemble.entitlements`. |
| `scripts/release.sh` | Runs `bundle.sh`, optionally notarizes and staples the app, builds `build/Ensemble-<version>.dmg` with `hdiutil` (app plus an Applications shortcut), signs/notarizes/staples the DMG, writes the `.sha256`, prints a summary. `--dry-run` prints the Apple-service commands instead of running them. |
| `scripts/appcast.sh` | Adds a DMG to the Sparkle appcast with Sparkle's `generate_appcast`; refuses to write an appcast whose items lack an EdDSA signature. |
| `.github/workflows/release.yml` | On tag `v*`: build, test, import the certificate, run `release.sh`, create the GitHub Release with `gh release create`, update the appcast on the `gh-pages` branch. Hardened like the other workflows (no default permissions, actions pinned to commit SHAs, no stored checkout credentials). Stays disabled on the repository until Developer ID signing exists. |
| `.github/workflows/ci.yml` | On every pull request and push to `main`: `ci` builds in release mode, runs the tests and the repository's network and size checks; `hygiene` runs zizmor, pinact and a secrets scan over the whole history; `coverage`, `periphery` and `website-tests` check EnsembleCore coverage, unused code and the website logic and replay-timeline tests; `gate` passes only when all of them did. It never signs or publishes. |
| `Sources/Ensemble/App/UpdateController.swift` | The Sparkle wrapper and Ensemble's own update interface: feed URL constant, the one alert, the idle gate, the relaunch record. |

Log of the last `release.sh` run: `build/release.log`.

## One-time setup (you)

Do these once, in this order.

1. **Decide the final name and bundle identifier before the first public release.** The bundle identifier is `dev.ensemble.app` (`Sources/Ensemble/Info.plist`, `LoginAgent.swift`). Camera and Accessibility grants, saved settings, the login agent and every future Sparkle update are tied to it, so changing it after release makes every user re-grant permissions and breaks the update chain. If the project becomes "Leanback", rename first: bundle identifier, app name, DMG name, feed URL, cask.
2. **Apple Developer Program: $99 per year.** Enroll at https://developer.apple.com/programs/enroll/ (an individual needs a legal name and two-factor sign-in; an organization needs a D-U-N-S number and a public website). Notarization requires the paid membership. The fee waiver covers only nonprofits, schools, and governments, not individual open-source maintainers (https://developer.apple.com/help/account/membership/fee-waivers/).
3. **Developer ID Application certificate.** Only the account holder can create it. In Keychain Access: Certificate Assistant, Request a Certificate From a Certificate Authority, save to disk. At https://developer.apple.com/account/resources/certificates/add choose "Developer ID Application", upload the request, download the `.cer`, double-click it. Confirm with `security find-identity -v -p codesigning`: a line `"Developer ID Application: Your Name (TEAMID)"`. Export it (Keychain Access, right-click the certificate, Export, `.p12`, choose a password) for the CI secret.
4. **Notarization credentials.** In App Store Connect, Users and Access, Integrations, App Store Connect API: create a key with Developer access and download `AuthKey_XXXX.p8` (downloadable once). Note the key ID and the issuer ID. For local runs store them once:
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
   Then Settings, Pages, Source: Deploy from a branch, `gh-pages`, `/ (root)`. The first release's workflow creates `appcast.xml` there.
7. **Repository secrets** (Settings, Secrets and variables, Actions):

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
   | `DEVELOPER_ID_P12_PASSWORD` | the password chosen when exporting the `.p12` |
   | `NOTARY_KEY_P8` | the full text of `AuthKey_XXXX.p8` |
   | `NOTARY_KEY_ID` | the API key ID |
   | `NOTARY_ISSUER_ID` | the issuer ID |
   | `SPARKLE_ED_PRIVATE_KEY` | the text of `sparkle_private.key` |

   The workflow's first step stops with the name of any missing secret or leftover placeholder.

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

It builds and signs the DMG with the local identity, adds it to the appcast with the update key in this Mac's login keychain (a refusal here stops the run before anything is public), then tags `main`, publishes the GitHub Release, and pushes `appcast.xml` to `gh-pages`, which GitHub Pages serves at the feed address in `UpdateController.swift`. Installed copies then see the version on their next check, or at once with Check for Updates. The release page and the appcast item carry the same notes, the titles of the pull requests merged into `main` with a merge commit since the previous tag (a squash-merged one is not listed), so the update window shows what changed. The update key and feed are set; the private key is also kept outside the keychain by the owner. Copies signed with the local identity update only on this Mac.

## Cut a release

1. Merge to `main`; the tests pass.
2. `git tag v0.1.0 && git push origin v0.1.0`. The version comes from the tag; the build number is the commit count, so it grows with every commit (Sparkle compares the build number, never reuse or lower one).
3. The workflow runs (about 20 to 40 minutes, most of it Apple's notary queue). On success the GitHub Release holds `Ensemble-0.1.0.dmg` and its `.sha256`, and `appcast.xml` on `gh-pages` lists the new version.
4. Check on a Mac that has never run Ensemble: download the DMG from the release page, drag the app to Applications, double-click. It must open with no Gatekeeper warning. `spctl -a -t exec -vv /Applications/Ensemble.app` says `source=Notarized Developer ID`.
5. Tags with a dash (`v0.2.0-beta.1`) publish a pre-release and are not added to the appcast.

If the workflow fails after the GitHub Release is created (for example the appcast push), fix the cause and re-run the failed job; do not move the tag.

## What CI builds

`ci.yml` builds the app bundle with `ENSEMBLE_SIGN_IDENTITY=-`, an ad-hoc signature used only so the network, privacy and size checks read the real app. That bundle is never uploaded or installed: every ad-hoc build is a new identity, which would drop a Mac's Camera and Accessibility grants. Releases are cut on a Mac with the stable signing identity.

Every action in the workflows is pinned to a commit SHA with the version in a trailing comment, and Dependabot proposes the bumps weekly. A bump pull request must pass `gate`, whose `hygiene` job includes `pinact` checking that each SHA is the commit its comment names. To pin by hand: `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`.

The secrets listed under "One-time setup" are the only ones any workflow reads beyond the built-in token. They are recorded as owner opt-ins in `.ossemble/state.json`, with the reason for each.

## The website

GitHub Pages serves the `gh-pages` branch: `appcast.xml` (written by `release.yml`) and the website. `site.yml` copies `docs/index.html`, `docs/logo.png`, `docs/live/` and `docs/assets/` there whenever they change on main, so the site is edited in `docs/` like any other file. It lives at https://oficiallyakshay.github.io/ensemble/.

## How updates reach users

- Each installed copy reads the appcast at `UpdateConfig.feedURL` (GitHub Pages, HTTPS), compares the build number, downloads the DMG from the GitHub Release, verifies the EdDSA signature against `SUPublicEDKey` and the Apple code signature, then replaces the app and relaunches.
- Policy in `UpdateController.swift`: no network until the user turns on "Update automatically" in Settings, General (or presses Check for Updates). With it on, Ensemble checks 15 seconds after launch and Sparkle then checks every hour (`SUScheduledCheckInterval` = 3600, `UpdatePolicy.checkInterval`), downloads in the background, and installs after 30 seconds of unbroken idle time (not dictating, sending, calibrating or in the tour), then relaunches. Sparkle's own "check automatically?" prompt is suppressed. With it off, a manual check is the only check.
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

## Permissions survive updates only with a stable signature

Camera and Accessibility grants are tied to the app's signature. Developer ID signatures are stable across releases, so users keep their grants through updates. Moving from the local "Ensemble Local Signing" identity to Developer ID changes the signature once: everyone, including you, re-grants Camera and Accessibility after first installing a Developer ID build. Never distribute ad-hoc signed builds: every build is a new identity and grants reset each time.

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
