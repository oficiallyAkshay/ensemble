# window-tree

Proves that another app's window tree can be read on Windows (UI Automation), Linux (AT-SPI) and macOS (Accessibility), using a small stand-in Electron app instead of the real Claude desktop app. Nothing here is part of Ensemble: no credential, no account, and no network call in the app.

| File | What it is |
|---|---|
| `package.json` | The stand-in app's package; Electron 45.1.0, pinned exactly. |
| `main.js`, `index.html` | The stand-in app: one window titled "Window Tree Stand-In" with two buttons, a text field and a checkbox, each with a fixed accessible name. |
| `requirements.txt` | The reader: [xa11y](https://pypi.org/project/xa11y/) 0.15.4, pinned exactly. |
| `read_tree.py` | Starts the stand-in app with `--force-renderer-accessibility`, reads its tree with xa11y, prints the window titles and control names, then one `RESULT:` line. Each failure is one `DIAG:` line. |
| `linux-run.sh` | Runs the reader under a virtual display and a private session bus with the accessibility bus started. |
| `screenshot-windows.ps1` | Writes the Windows screenshot. Linux uses ImageMagick `import`, macOS uses `screencapture`. |
| `window-tree.yml.txt` | The text of the manual workflow `window-tree` (Windows, Ubuntu, macOS jobs). |

## The workflow is not live

GitHub reads workflows only from `.github/workflows/`. Copy `window-tree.yml.txt` there as `window-tree.yml` by hand, then start it from the Actions tab. Each job uploads `tree.txt` and `screenshot.png` as an artifact. Read `tree.txt` (its `RESULT:` line and `DIAG:` lines), not the job colour: the reader step is `continue-on-error`, so a job is green even when no tree was read.

## No lockfile

No `package-lock.json` is committed, so each run installs the pinned Electron version fresh. To pin the transitive packages too, run `npm install --package-lock-only` in this folder and commit the result.

## Not run yet

The reader and the stand-in app were written without being run. The first run of the hand-copied workflow is the first test of both.
