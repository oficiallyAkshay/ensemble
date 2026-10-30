# Workflows

The GitHub workflows and what each one guards. Back to the [contributing guide](../.github/CONTRIBUTING.md).

| Workflow | Runs on | What it does |
|---|---|---|
| ci | Every pull request and push to main | One workflow, six jobs. `ci` builds in release mode, runs the unit tests, then the network check and the size check, and keeps the logs as an artifact. `hygiene` audits workflows with zizmor, verifies every action is pinned to the commit its version comment names with pinact, and scans the whole history for secrets with gitleaks. `website-tests` runs the website logic tests (`docs/live/test/logic.test.mjs`) and the capture page's replay-timeline tests (`docs/live/test/capture-events.test.mjs`). It also fails when `Assets/hero.svg` is not what `Assets/hero.hero.json` and `Assets/hero-hands` build (`scripts/make-hero.mjs --check`). `coverage` measures line coverage of `Sources/EnsembleCore`, fails if any line the change adds or edits there is untested (diff-cover against main) or if total coverage falls below `.github/coverage-baseline.json` (`.github/coverage-ratchet.py`). `periphery` fails on unused declarations in EnsembleCore. `gate` waits for the other five and fails unless each succeeded; it is the one check a branch ruleset should require. |
| auto-release | When `ci` completes green for a push to main, and by manual start (`dry_run` input, default true) | Releases after every merge that changes app logic: a `decide` job without secrets, then a `release` job in the `release` environment that imports the pinned signing identity into a temporary keychain, refuses any other certificate, runs `scripts/ship-release.sh` and checks the GitHub release and the update feed. A dry run builds and signs and publishes nothing. See [RELEASING.md](RELEASING.md#release-on-every-merge). |
| clonometer | Daily at 03:17 UTC, and by manual start | Counts the repository's clones and views with the pinned clonometer action, using the `TRAFFIC_TOKEN` secret (its permissions are explained in `.ossemble/state.json`), and writes the daily count to the `badges` branch. The README clones badge reads that branch; with no token or no count there, the badge shows nothing. The website no longer reads it (its counter is the Ensemble.dmg download count from the releases API). GitHub disables a scheduled workflow after 60 days with no commit to the repository, so regular commits keep it running. |
| Site | A push to main that changes `docs/index.html`, `docs/logo.png`, `docs/live/` or `docs/assets/` | Copies those files, except `docs/live/test`, onto the `gh-pages` branch next to the update feed; one publish at a time, newest wins. It runs no tests of its own: the `website-tests` job in ci guards a website change on its pull request before it reaches this publish. See [the website](RELEASING.md#the-website) in RELEASING.md. |
| codeql | A pull request to main that changes `Sources/`, `Package.swift`, `Package.resolved` or `codeql.yml`, and weekly on Monday | CodeQL static analysis of the Swift sources. Swift needs a real `swift build` on a macOS runner, about 20 minutes, which is why a pull request that cannot change the analysed code skips it. Results appear under Security, Code scanning. Not a required check: the weekly run still covers main. The repository's CodeQL default setup must stay off, or GitHub reports a conflict. |
| core-portability | Manual start, and a push to a `portability/**` branch | Builds `EnsembleCore` and runs its tests on Linux (the Swift 6.2 container) and Windows, keeping each system's logs as an artifact. Informational: the steps may fail and the workflow is not part of `gate`, because the core does not compile on either system yet. |
| window-tree | Manual start | Launches a stand-in Electron app with accessibility on, on Windows, Ubuntu (virtual display) and macOS runners, reads its window tree with xa11y, and keeps the printed tree and one screenshot per system as artifacts. Informational: not part of `gate`; read each system's `tree.txt`, because the reader step is `continue-on-error`. See `scripts/window-tree/README.md`. |
| core-release | Manual start (`version`, `dry_run` default on) | Releases the logic library, not an app. Runs `swift test` on macOS, Linux and Windows; only if all three pass and `dry_run` is off it makes the GitHub release `core-v<version>` with a source archive and the three test logs. Tests that need Apple-only frameworks do not run off Apple, and the notes say so. The macOS app keeps its own release on every merge (`auto-release`). |
| dependency-review | Every pull request | Reads the dependency graph diff from the GitHub API and fails when the pull request adds a package with a known vulnerability. It runs none of the pull request's code and writes nothing to the repository. |
| scorecard | Weekly on Tuesday, and every push to main | The OpenSSF Scorecard of the repository's security practices (pinned actions, token permissions, branch protection and so on). Publishes the result to the public Scorecard API for a badge and uploads the findings to code scanning. |

Only `gate` (the ci row) is the check a branch ruleset should require; `codeql`, `dependency-review` and `scorecard` are not part of it.

## Rules every workflow follows

- Every action is a full commit SHA with the version in a trailing comment. Dependabot proposes bumps weekly.
- Workflows start from empty permissions and each job declares its own. A secret is an environment secret of the job that needs it (`auto-release` uses the `release` environment, limited to main).
- Every checkout turns off stored credentials.
- No expression syntax inside a run step: pass values through the environment instead.
- A run step that pipes into tee needs the bash shell so the pipe fails the step.

## The two checks CI runs

| Script | Fails when |
|---|---|
| `scripts/check-network.sh` | A network call or web address appears outside a short allowlist of source, web files and the built app (the update feed and the one usage-report address). |
| `scripts/check-size.sh` | The built app passes the byte budget set at the top of the script. |
