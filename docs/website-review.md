# Website review runbook

Questions a review agent asks of the website (`docs/index.html`, `docs/live/`, `docs/assets/`) on a regular basis. The aim is to keep finding small defects, not to redesign. Back to [Contributing](../.github/CONTRIBUTING.md).

## Rules for the reviewer

1. Find, do not redesign. Report defects against the questions below. Do not propose new layouts, palettes or copy rewrites. If something needs a design decision, mark it DECISION and stop.
2. Every finding has evidence: a screenshot or a measured number, with viewport, URL and selector. "Feels cramped" is not a finding.
3. Give the smallest fix, one line where possible. Do not bundle cleanups into it.
4. Say what you did not check.
5. Do not touch the hero, copy in the owner's voice, or the friends' messages. Flag them only.

## Setup

- Viewports: 1440x900, 1280x720, 2560x1440, 1000x800, 820x900, 390x844 (touch, mobile user agent). On the touch sizes the demo shows only its "available on desktop" message.
- Pages and states: the letter page top to bottom, scrolled so every 3D scene loads. The demo: desktop, Claude open, panel open, Ensemble on (mouse mode, and camera mode with a fake camera), each step, the Headphones tab, the install step, the finish card, the error card.
- Run `node --test docs/live/test/logic.test.mjs`. On a Mac also run `node docs/live/test/e2e.mjs all`. On Linux or a cloud session, set `CHROME_PATH` to a Chrome or Chromium binary before running the end-to-end test. After a change to the page's buttons or the demo's entry, also run `node docs/live/test/first-run.mjs` against the live website (`docs/first-run.md`).
- Measure in the page: distinct computed font sizes and weights per section, overlaps between sibling blocks, `scrollWidth - innerWidth`, console errors, every network request.

## Questions

### A. Layout integrity
- A1. Does any text overlap another element, an animation or a decorative shape at any viewport? Test every pair of sibling rectangles.
- A2. Is anything cut off by the viewport or a clipped container?
- A3. Does each description sit directly under its title, with a gap smaller than the gap between steps?
- A4. Do sections share left edges?
- A5. Is spacing driven by content, so a few tall items do not spread the rest apart? Is any text buried under another tile or card by default?
- A6. Is there horizontal scroll at any width?
- A7. Is anything absolutely positioned or rotated that does not need to be?
- A8. Does anything float over the content it explains?

### B. Typographic hierarchy
- B1. After a heading, how many distinct size and style combinations appear in the body? Target: one body style plus at most one emphasis.
- B2. Is the headline two lines or fewer at 1440 px?
- B3. Is anything under 14 px that a visitor has to read? Check text inside scaled mini screens and the island.
- B4. Are mono and all-caps chips used for labels only?
- B5. Is line length under about 70 characters, with no widows or orphans?
- B6. Is contrast adequate, especially over wallpaper, glass and dim overlays?

### C. The animation is the point
- C1. Is each animation at least about 70% of the content width at 1440 px, visible without scrolling past its own title?
- C2. Are the animation cards straight and free of decorative overlap?
- C3. Does each animation carry one caption saying what to notice?
- C4. Does the gesture panel show the gesture rather than repeat what a tooltip says?
- C5. Does each loop show the full cause and effect?

### D. Redundancy and meaning
- D1. Does any heading or line say the same thing as the one next to it?
- D2. Do the headings make sense read alone, by a first-time visitor?
- D3. Is a phrase repeated across sections?
- D4. Does the step counter count only real steps? Setup, calibration, optional extras and closing notes are not steps.
- D5. Is any element duplicated across the page?

### E. Fidelity to the real product
Every website pull request first checks whether the product UI changed since the demo was last synced: run `git log` on `Sources/Ensemble/App/MenuPanelView.swift`, `IslandView.swift` and the files in `Sources/Ensemble/App/Tour/` since the last sync commit, and reconcile any difference before merging. A directional match is enough; do not chase pixels.
- E1. Does the menu-bar panel match `MenuPanelView.swift` (rows, order, labels, controls, version format)? Do status words match `AppStatus.title`?
- E2. Do the island and notch match the app's modes and wording?
- E3. Is `docs/live/logic.js` in step with `EnsembleCore`, changed in the same pull request as the Swift change (gotcha 19)?
- E4. Does the demo show any removed feature or gesture? Compare against `docs/gestures.md`.
- E5. Are `docs/assets/3d/scene3d.js` and `capture-default.js` byte-identical to the copies under `Sources/Ensemble/Resources/web/tour/`?
- E6. Do the Claude window mock, icon and wording still match the real Claude desktop app, and is it framed as a mock?
- E7. Do the headphone claims match `docs/gestures.md` (Bluetooth only, one press toggles, two send)?
- E8. Does the version string match the latest release and changelog?

### F. Guidance
- F1. At each point is the next action unambiguous, and does the tooltip point at the actual control?
- F2. Does the spotlight dim everything else, keep the target and its parent lit, and never block the click?
- F3. Does every gesture or press show success on the control it used?
- F4. Is everything optional skippable, never blocking, and written for someone without the gear (headphones, camera, laptop)?
- F5. Does every failure have an exit?
- F6. Are the first and last states handled: empty desktop, all done, replay?
- F7. Can every control be reached by keyboard with a visible focus ring? Do tabs and menus handle Escape and arrows?
- F8. Are setup order and dependencies enforced?

### G. Content truth and voice
- G1. Is every friend quote verbatim, only about the app, with names, photos and companies removed?
- G2. Does any `sample` entry appear in production?
- G3. Are all claims true and checkable (unsigned note, free and open source, requirements, privacy line)?
- G4. Does the copy sound like the owner: casual, not salesy? Flag, do not rewrite.
- G5. Are there emojis in code, comments or docs?

### H. Trust and privacy
- H1. Are the only off-origin requests the star count, the clone ledger and the anonymous visit events to PostHog (`docs/analytics.js`, listed in `docs/telemetry.md`, "The website"), and does the page send nothing with Do Not Track or Global Privacy Control on?
- H2. Does video stay in the tab, in memory, never displayed or stored? Is the privacy line accurate?
- H3. Do the tree and history contain personal names, emails, handles or private repository names?
- H4. Are commits authored under the repository's GitHub no-reply identity?
- H5. Are third-party assets used within their licence and credited where required?

### I. Performance and robustness
- I1. Is nothing heavy loaded before consent or scroll? Do scenes sleep off-screen?
- I2. Are fallbacks present: no WebGL, Save-Data, reduced motion, phone?
- I3. Is first-load weight up or down versus the last audit?
- I4. Any console errors or warnings?
- I5. Does every new file get published (`site.yml` copies `docs/index.html`, `docs/logo.png`, `docs/live`, `docs/assets`)?
- I6. Does late font loading break tile heights or wrapping?
- I7. Do touch and pointer interactions work?

### J. Process hygiene
- J1. Is each change described in the repository's pull request format (what was broken, what changed, what is true now, what was checked and how, what was left out)?
- J2. Were tests updated with the behaviour, and does the website job pass?
- J3. Is dead code removed, and are docs, README and changelog consistent?
- J4. Is anything left undone ticketed rather than dropped?
- J5. Are generated or shared files regenerated, with no secrets, tokens or machine paths?

## Report format

One table sorted by severity, then end with one line saying what was not tested.

| ID | Lens | Severity | Where (URL, viewport, selector) | Evidence | Minimal fix | Decision needed |
|---|---|---|---|---|---|---|

P0 is broken or leaking (overlap, cut-off text, privacy, wrong claim). P1 is confusing or off-brand. P2 is polish.

## Cadence

- Every website pull request: sections A, B, D, F, H, the E check above, and any lens the diff touches.
- Weekly: all lenses with a screenshot set at every viewport.
- Stop when a full pass has no P0 or P1. Do not invent polish.
