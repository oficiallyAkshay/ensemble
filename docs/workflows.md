# Workflows

The four GitHub workflows and what each one guards. Back to the [contributing guide](../.github/CONTRIBUTING.md).

| Workflow | Runs on | What it does |
|---|---|---|
| ci | Every pull request and push to main | One workflow, six jobs. `ci` builds in release mode, runs the unit tests, then the network check and the size check, and keeps the logs as an artifact. `hygiene` audits workflows with zizmor, verifies every action is pinned to the commit its version comment names with pinact, and scans the whole history for secrets with gitleaks. `website-tests` runs the website logic tests (`docs/live/test/logic.test.mjs`). `coverage` measures line coverage of `Sources/EnsembleCore`, fails if any line the change adds or edits there is untested (diff-cover against main) or if total coverage falls below `.github/coverage-baseline.json` (`.github/coverage-ratchet.py`). `periphery` fails on unused declarations in EnsembleCore. `gate` waits for the other five and fails unless each succeeded; it is the one check a branch ruleset should require. |
| Release | A pushed tag named v followed by a version | Builds, tests, signs, notarizes, publishes the disk image and updates the update feed. Stays disabled on the repository until Developer ID signing exists. The steps are in [RELEASING.md](RELEASING.md). |
| clonometer | Daily at 03:17 UTC, and by manual start | Counts the repository's clones and views with the pinned clonometer action, using the `TRAFFIC_TOKEN` secret (its permissions are explained in `.ossemble/state.json`), and writes the daily count to the `badges` branch. The README clones badge and the website's clone total read that branch; with no token or no count there, the website leaves the clones number out. GitHub disables a scheduled workflow after 60 days with no commit to the repository, so regular commits keep it running. |
| Site | A push to main that changes `docs/index.html`, `docs/logo.png`, `docs/live/` or `docs/assets/` | Copies those files, except `docs/live/test`, onto the `gh-pages` branch next to the update feed; one publish at a time, newest wins. It runs no tests of its own: the `website-tests` job in ci guards a website change on its pull request before it reaches this publish. See [the website](RELEASING.md#the-website) in RELEASING.md. |

## Rules every workflow follows

- Every action is a full commit SHA with the version in a trailing comment. Dependabot proposes bumps weekly.
- Workflows start from empty permissions and each job declares its own.
- Every checkout turns off stored credentials.
- No expression syntax inside a run step: pass values through the environment instead.
- A run step that pipes into tee needs the bash shell so the pipe fails the step.

## The two checks CI runs

| Script | Fails when |
|---|---|
| `scripts/check-network.sh` | A network call or web address appears outside a short allowlist of source, web files and the built app. |
| `scripts/check-size.sh` | The built app passes the byte budget set at the top of the script. |
