# Browser tests: Firefox and WebKit

Runs the website's home page and the live demo in Firefox and in WebKit (Safari's engine, not the Safari app) with Playwright, on a 1400 by 860 desktop window. `../e2e.mjs` covers Chrome and is not replaced.

| File | What it holds |
|---|---|
| `package.json` | Playwright as the one dependency. |
| `playwright.config.mjs` | A `firefox` project (fake camera through Firefox preferences) and a `webkit` project, both running `demo.spec.mjs`; starts `../serve.mjs` on port 8791. |
| `demo.spec.mjs` | The home page loads with no console errors and shows its sections; the demo opens on the desktop; turning Ensemble on reaches the running state. WebKit has no fake camera, so it runs the demo's mouse mode. |

Off-origin requests keep the allow-list of `LETTER_ALLOWED` in `../e2e.mjs` (the two GitHub counts and the anonymous visit events); each is answered with an empty stand-in, and any other address fails the test.

## Where it runs

These tests run in the `browser-tests` job of `ci.yml`, which `gate` requires, together with `../first-run.mjs`. The `site.yml` workflow runs the same two tests in its `test` job, and `publish` waits for it: a failing test leaves the site unpublished.

## Run it by hand

```
cd docs/live/test/browsers
npm install                            # creates package-lock.json; commit it
npx playwright install firefox webkit
npx playwright test --list             # the same tests under both projects
npx playwright test                    # the live run in both browsers
```
