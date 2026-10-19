import AppKit
import EnsembleCore

/// What every controller shares: the services, the facts more than one of them reads, and the guards that
/// decide whether a gesture may act on Claude.
@MainActor
final class CoordinatorContext {
    /// A send is refused, and focus is not moved, within this long after typing or a click.
    static let inputQuiet = 1.5

    let state: AppState
    let settings: SettingsStore
    let overlay: OverlayController
    let bridge = ClaudeBridge()
    let gestures = GestureMachine()
    let cover = CoverDetector()
    let dim = DimPicture()
    /// The newest brightness reading (taken about every 0.1 s, so it can be that old), for the detailed trace.
    var latestLuma: Double?
    let pointer = NosePointer()
    /// Created lazily: it needs `self` fully formed first (it reads settings, the pointer and the overlay back).
    lazy var setup = SetupController(ctx: self)

    var latestHead: HeadObservation?
    /// Where the nose dot is drawn and the highlighted pane, global top-left. They change on every head reading, so
    /// they live here, not in the published `AppState`: there they re-rendered Settings and the menu 30 times a second.
    /// The overlay gets them through `OverlayController.update`.
    var nosePoint: CGPoint?
    var targetFrame: CGRect?
    /// While a pane resize runs: where the resized session will end up, from the plan. The highlight goes there at
    /// once instead of trailing Claude's frames, and the read-back corrects it when the resize ends.
    var resizeFrame: (id: String, frame: CGRect)?
    /// Whether the person is speaking, from the level meter; never active while the meter is not running.
    var speech = SpeechLock()
    var sessions: [ClaudeSession] = []
    /// The session being dictated into, from the press until the stop is confirmed.
    var listening: ClaudeSession?
    /// A start, stop or send is in flight.
    var busy = false
    /// Your hands are on the keyboard, mouse or trackpad (`HandsBusy`): focus and the highlight hold, no resizes;
    /// gestures still work, on the session the nose is on.
    var handsBusy = false
    /// Dictations Claude runs without Ensemble, as the session refresh sees them.
    var claudeDictations = ForeignDictations()
    /// Moves on whenever Ensemble starts, takes over or stops a dictation, so a refresh that read the checkboxes
    /// before that never reports Ensemble's own dictation as one Claude ran.
    var dictationEpoch = 0

    /// Ensemble now owns (or just ended) the dictation in this session: what the refresh saw there is accounted for.
    func ownDictation(in session: ClaudeSession) {
        claudeDictations.forget(session.id)
        dictationEpoch += 1
    }
    /// The last time exactly one face was seen.
    var lastOneFaceT: TimeInterval = -.infinity
    var gestureShowing = false
    /// A headphone press acted until this time, so refusals it causes are shown on the island and labelled.
    var headphoneUntil: TimeInterval = -.infinity
    var headphoneActive: Bool { CACurrentMediaTime() < headphoneUntil }
    /// Redraws the overlay from the current facts.
    var changed: () -> Void = {}
    /// Something time-based may have started (a refusal to expire): the Coordinator's tick timer checks whether to run.
    var wake: () -> Void = {}

    private var calibratedCache: (value: Bool, at: TimeInterval)?

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        self.state = state
        self.settings = settings
        self.overlay = overlay
    }

    /// True while the pointer is fit and at least one connected screen has usable samples for the camera
    /// in use. A screen with no samples (or whose frame moved) is simply not among them: pointing and
    /// dictation still work on the screens that are, while that one screen is treated as uncalibrated.
    var calibratedHere: Bool {
        guard pointer.isCalibrated else { return false }
        // Read on every camera frame; the setup only changes in setup.screensChanged/cameraInUse, so cache briefly.
        let now = CACurrentMediaTime()
        if let c = calibratedCache, now - c.at < 1 { return c.value }
        let value = !setup.validScreenIDs.isEmpty
        calibratedCache = (value, now)
        return value
    }

    func invalidateCalibrationCache() { calibratedCache = nil }

    /// Shared guards for every gesture that acts on Claude. Returns a refusal reason, or nil when allowed.
    /// `inputAge`: seconds since typing or a click; a send asked for with Return passes its own, without those Returns.
    /// `checkInput` false (talk and scroll): gestures work through the keyboard-and-mouse pause, so a pinch made right
    /// after typing acts; only a send keeps the recent-input refusal, so a draft you just edited is never sent by a stray pose.
    func commonRefusal(inputAge: Double = ClaudeBridge.secondsSinceTypingOrClick(), checkInput: Bool = true) -> String? {
        if !settings.enabled { return "Ensemble is off" }
        if cover.covered { return "Camera is covered" }
        if ScreenFacts.sessionAway() { return "The screen is locked" }
        // The hand often covers the face as it rises: one face within the last 1.5 s counts. Two faces block only
        // when they persist: a stray two-face reading is a false alarm.
        let now = CACurrentMediaTime()
        if now - lastOneFaceT > 1.5 { return "No face in view" }
        if checkInput, inputAge < Self.inputQuiet { return "You just typed or clicked" }
        return nil
    }

    /// `resolves`: `.whenOnSession` for a refusal about where the nose points, so the panel drops it once the nose
    /// is back on a session.
    func refuse(_ why: String, title: String? = nil, resolves: RefusalNotice.Resolves = .byTime) {
        state.showRefusal(why, resolves: resolves)
        if gestureShowing || headphoneActive || why.hasPrefix("Send") || why.hasPrefix("Not sent") {
            let sendRelated = why.hasPrefix("Send") || why.hasPrefix("Not sent")
            let body = why.hasPrefix("Not sent: ") ? String(why.dropFirst("Not sent: ".count)) : why
            if headphoneActive, !sendRelated {
                // Labelled as the headphone press, with the usual title folded into the line.
                let line = (title.map { $0 + ": " } ?? "") + body
                overlay.showBanner(title: "Headphone press", body: line.prefix(1).uppercased() + line.dropFirst(), style: .refused, seconds: 2.5)
            } else {
                overlay.showBanner(title: title ?? (sendRelated ? "Not sent" : "Nothing done"), body: body.prefix(1).uppercased() + body.dropFirst(), style: .refused, seconds: 2.5)
            }
        }
        EnsembleLog.write("refused: \(why)")
        wake()
    }

    /// The session's name as Claude shows it now, for the island.
    func name(of session: ClaudeSession) -> String {
        (sessions.first { $0.id == session.id }?.title ?? session.title) ?? "this session"
    }
}
