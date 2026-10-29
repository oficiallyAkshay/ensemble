import AppKit
import EnsembleCore

/// What the camera engine and the permissions last reported, kept apart from `state.status` so every pass
/// recomputes the status from facts.
@MainActor
final class HealthMonitor {
    private let ctx: CoordinatorContext
    private let engine: VisionEngine
    var running = false
    /// The screen is locked or asleep: the camera is off on purpose and is not restarted as if it had failed.
    var away = false
    private(set) var cameraProblem: String?
    private(set) var trackerFailure: String?
    private(set) var trackerReady = false
    private(set) var accessibilityTrusted = true
    /// Reopens Ensemble once when Accessibility is granted while it runs (macOS applies the grant only to a new process).
    private var grantRelaunch = GrantRelaunch(startedWithGrant: true)
    /// False while the tour is open: its permissions step shows the grant live and the tour must not be torn down.
    var relaunchOnGrantAllowed: () -> Bool = { true }
    private(set) var cameraAllowed = true
    /// A session scan has finished since Claude started running; until then an empty list means "not looked yet".
    var sessionsScanned = false
    private var lastCameraRestart = Date.distantPast
    private var claudeRunningCache: (value: Bool, at: TimeInterval)?

    init(ctx: CoordinatorContext, engine: VisionEngine) {
        self.ctx = ctx
        self.engine = engine
    }

    /// Ensemble is turning on: read both permissions and forget earlier camera trouble.
    func begin() {
        running = true
        accessibilityTrusted = Permissions.accessibilityTrusted
        grantRelaunch = GrantRelaunch(startedWithGrant: Permissions.accessibilityTrusted)
        cameraAllowed = Permissions.cameraAllowed
        cameraProblem = nil; trackerFailure = nil; trackerReady = false
        lastCameraRestart = Date()
    }

    func handle(status: EngineStatus) {
        if case .running = status {} else { EnsembleLog.write("engine: \(status)") }
        switch status {
        case .starting:
            cameraProblem = nil; trackerFailure = nil; trackerReady = false
        case .running(let fps, let camera, let cameraID):
            cameraProblem = nil
            ctx.state.set(\.fps, fps)
            ctx.state.set(\.dotRate, ctx.overlay.dotRefreshRate)
            ctx.state.set(\.cameraName, camera)
            ctx.setup.cameraInUse(id: cameraID, name: camera)
        case .permissionDenied:
            cameraAllowed = false
        case .noCamera:
            cameraProblem = "No camera found"
        case .error(let msg):
            cameraProblem = msg
        case .faceTrackerReady:
            trackerReady = true; trackerFailure = nil
        case .faceTrackerRestarting:
            trackerReady = false
        case .faceTrackerFailed(let msg):
            trackerReady = false; trackerFailure = msg
        case .stopped:
            trackerReady = false
        }
        update()
    }

    func update() {
        ctx.state.set(\.status, current())
        // Runs on every head reading; the screen ids are cached until the arrangement changes.
        let connected = ctx.setup.connectedScreenIDs
        let valid = connected.filter { ctx.setup.validScreenIDs.contains($0) }.count
        ctx.state.set(\.calibratedLine, ctx.pointer.isCalibrated ? ScreenLayout.calibratedLine(valid: valid, connected: connected.count) : nil)
    }

    /// The camera is refused, missing or its face tracker has failed.
    var cameraFailed: Bool { !cameraAllowed || cameraProblem != nil || trackerFailure != nil }
    var failure: String? { cameraProblem ?? trackerFailure }

    /// Re-reads both permissions every second. A grant that arrives while Ensemble runs clears the status and
    /// restarts the camera; a camera that stopped for another reason is retried every 5 s.
    func checkPermissions() {
        guard running else { return }
        let trusted = Permissions.accessibilityTrusted && !ctx.agent.accessibilityDisabled
        if trusted != accessibilityTrusted { EnsembleLog.write("accessibility permission is now \(trusted ? "granted" : "missing")") }
        accessibilityTrusted = trusted
        if relaunchOnGrantAllowed(), grantRelaunch.shouldRelaunch(granted: Permissions.accessibilityTrusted) {
            EnsembleLog.write("accessibility granted: restarting to apply it")
            Permissions.relaunch()
            return
        }
        let allowed = Permissions.cameraAllowed
        let flippedOn = allowed && !cameraAllowed
        if allowed != cameraAllowed { EnsembleLog.write("camera permission is now \(allowed ? "granted" : "denied")") }
        cameraAllowed = allowed
        if flippedOn, !away {
            restartCamera("camera permission granted")
        } else if allowed, !away, !engine.isRunning, Date().timeIntervalSince(lastCameraRestart) >= 5 {
            restartCamera("the camera was not running")
        }
        update()
    }

    private func restartCamera(_ why: String) {
        EnsembleLog.write("camera restart: \(why)")
        lastCameraRestart = Date()
        cameraProblem = nil; trackerFailure = nil; trackerReady = false
        ctx.latestHead = nil
        engine.start(cameraName: ctx.settings.cameraName)
    }

    private var claudeRunning: Bool {
        let now = CACurrentMediaTime()
        if let c = claudeRunningCache, now - c.at < 1 { return c.value }
        let value = ctx.agent.claudeIsRunning()
        claudeRunningCache = (value, now)
        return value
    }

    private func current() -> AppStatus {
        if !ctx.settings.enabled || !running { return .off }
        if !accessibilityTrusted { return .needsPermission("Accessibility") }
        if !cameraAllowed { return .needsPermission("Camera") }
        if let problem = cameraProblem { return .error(problem) }
        if let failure = trackerFailure { return .error("Face tracking is retrying: \(failure)") }
        if ctx.cover.covered { return .cameraCovered }
        if ctx.dim.dim { return .pictureDim }
        if !ctx.calibratedHere { return .needsCalibration }
        if !claudeRunning { return .claudeNotRunning }
        if sessionsScanned, ctx.sessions.isEmpty { return .claudeNotOnScreen }
        if ctx.state.listening { return .listening }
        return ctx.handsBusy ? .pausedForInput : .watching
    }
}
