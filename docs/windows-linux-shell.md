# App shell for Windows and Linux

A written comparison of the ways to build the menu-bar-style window and the camera path on Windows and on Linux. Nothing here is built. The owner can accept or veto the recommendation at the end. Back to [portability](portability.md).

## What exists today

- The app is a macOS menu bar app. The app target is declared only on macOS, so there is no app for Linux or Windows (`Package.swift`).
- The logic library (`EnsembleCore`) builds and passes its tests on Linux and Windows ([portability](portability.md)).
- Face tracking already runs on MediaPipe inside a web view, and its page, WebAssembly and model ship inside the app. `docs/live/models/face_landmarker.task.gz` is 2,496,541 bytes (read with `wc -c`).
- Reading another app's window tree is proven on a stand-in app on Windows, Linux and macOS with the xa11y library (the manual `window-tree` workflow; see [portability](portability.md)). This note does not run it.
- The size budget is `BUDGET_BYTES=9500000` in `scripts/check-size.sh`. The current app size is not read for this note: unverified.

## What each shell must do

1. Show a small window from a tray icon (the equivalent of the menu bar panel).
2. Open the camera and give frames to the tracker in memory. A frame is never written to disk.
3. Read the window tree of the Claude desktop app (a separate step, see below).
4. Keep the two network connections in the trust rules and no other.
5. Package and update on each system.

## Options

Marks: "read" means the line comes from a page cited below. "unverified" means it was not read.

| Option | Size cost against the 9,500,000-byte budget | Camera access | Tray or menu-bar window | Accessibility reading | Packaging |
|---|---|---|---|---|---|
| A. Native toolkit per system (WinUI on Windows, GTK on Linux), logic library shared | Not measured: unverified. No bundled web engine, so the shell itself is expected to be the smallest, unverified | Each system has its own camera API: unverified. Two camera paths to write | Tray support is per toolkit: unverified | xa11y reads both systems (read, see "Sources") | One installer format per system: unverified |
| B. Electron | A bundled Chromium; no figure read: unverified. The budget is likely exceeded, unverified | Web camera API in the bundled web engine: unverified. The same MediaPipe web page could be reused, unverified | Tray class: Windows supports click, right-click and bounds; Linux click events depend on the desktop and bounds are not listed for Linux (read) | The stand-in app in the `window-tree` check is Electron, so xa11y is proven against it (read in [portability](portability.md)) | Bundler tooling: unverified |
| C. Tauri | The page gives no size figure, only the settings that shrink a build (read). It uses the system web view and does not bundle a browser (read) | Uses the system web view: WebView2 on Windows, WebKitGTK on Linux (read). Camera permission in each web view: unverified | Tray icon with a menu is supported. On Linux tray click events are not emitted, only the menu on right click works (read). Placing a window under the icon is not covered by the page (read) | xa11y: not tested against a Tauri app: unverified | Bundler tooling: unverified. WebKitGTK versions depend on the distribution (read) |
| D. Swift cross-platform UI (SwiftCrossUI) | Not measured: unverified | The page does not mention it (read): unverified | The page does not mention tray or menu-bar support (read): unverified | xa11y: not tested: unverified | Not stated: unverified |

### Notes on the table

- SwiftCrossUI maps to WinUI on Windows and GTK on Linux, so option D is a layer over option A. It says it is a work in progress and pre-1.0 (read).
- A web shell (B or C) lets the existing face tracker page and its model move across unchanged. The tracker page is the part that already runs without Apple frameworks.
- Tauri's Linux tray limit is the largest read fact against C: the click that opens the window does not fire there. A Linux build would open from the menu instead.
- The size of the hand model is a separate cost; see [hand tracking without Apple Vision](hand-tracking-without-vision.md).

## Owner steps (not done here)

- Windows read of the Claude desktop app: Claude desktop signed in on a Windows 365 cloud PC. This is a separate owner step and this note does not do it.
- A Linux virtual machine with a desktop session and a camera passed through, to test the tray and the camera.

## Sources

- Tauri system tray: https://v2.tauri.app/learn/system-tray/
- Tauri binary size: https://v2.tauri.app/concept/size/
- Tauri web view per system: https://v2.tauri.app/reference/webview-versions/
- Electron Tray: https://www.electronjs.org/docs/latest/api/tray
- SwiftCrossUI: https://github.com/stackotter/swift-cross-ui

## Decision for the owner

Recommended: C, Tauri, for the Windows and Linux shell, with the existing tracker page reused, because it keeps the app below a bundled browser's size and reuses the tracker that already runs on MediaPipe; the owner supplies a Windows 365 cloud PC (with Claude desktop signed in) and a Linux virtual machine so the tray, the camera and the size can be measured before the choice is final.
