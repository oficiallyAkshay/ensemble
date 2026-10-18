import AppKit
import AVFoundation
import EnsembleCore

/// Live permission facts and the Settings panes that fix them. Nothing here is cached: grants change while Ensemble runs.
enum Permissions {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// The three camera states the tour shows. Only "not asked" can still be answered with a prompt.
    static var cameraAccess: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// False only when the owner has denied the camera or it is restricted. Health uses this: "not yet asked" must
    /// not read as a failure, because starting the camera is what asks.
    static var cameraAllowed: Bool { cameraAccess != .denied }

    /// Shows macOS's Camera prompt; a no-op once the owner has answered.
    static func requestCamera() {
        guard cameraAccess == .notAsked else { return }
        AVCaptureDevice.requestAccess(for: .video) { _ in }
    }

    /// The prompt is shown only once per install, so a button that only re-asks does nothing the second time:
    /// it also opens the Accessibility list for the owner to switch Ensemble on.
    static func grantAccessibility() {
        requestAccessibility()
        openSettings(for: "Accessibility")
    }

    /// Shows the system's "would like to control this computer" prompt if Accessibility is not already granted.
    /// Harmless to call again once granted.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openSettings(for what: String) {
        let pane = what == "Camera" ? "Privacy_Camera" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// What to do next, shown under the status. A grant that is listed but does not work is stale after a rebuild.
    static func guidance(for what: String) -> String {
        what == "Accessibility"
            ? "Turn Ensemble on in the Accessibility list; it restarts by itself. Already on and still stuck? Press \"Still stuck?\" below."
            : "Turn Ensemble on in the \(what) list, then press \"Still stuck?\" below and Restart Ensemble."
    }

    /// Quits and opens Ensemble again so macOS applies a grant made while it ran. Quitting stops any dictation first
    /// (the normal terminate path), which can take a few seconds, so a detached shell waits for this process to
    /// exit (up to 10 s) before reopening: a copy started earlier would see this one alive and exit at once,
    /// leaving nothing running. With open-at-login on, launchd is asked to start its job; otherwise the bundle is opened.
    static func relaunch() {
        reopenAfterExit()
        NSApp.terminate(nil)
    }

    /// Starts the detached shell that opens Ensemble again once this process has exited (see `relaunch`). Also
    /// used by the copy Sparkle opens after an update to hand itself to the login agent (`UpdateController.afterLaunch`).
    static func reopenAfterExit() {
        DetachedShell.run("""
        i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        reopen
        """)
    }

    /// A grant that shows on but does not work belongs to an earlier signature of the app (gotcha 1). Clearing
    /// Ensemble's own entry and asking again puts the current app in the list; then a restart applies it.
    static func resetAndAsk(for what: String) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let service = what == "Camera" ? "Camera" : "Accessibility"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, id]
        try? task.run()
        task.waitUntilExit()
        if service == "Accessibility" { requestAccessibility() } else { AVCaptureDevice.requestAccess(for: .video) { _ in } }
        openSettings(for: what)
    }
}
