import AppKit
import Combine
import EnsembleCore

/// Wires the camera engine, the gesture rules, the nose pointer and the Claude bridge together. Each job has
/// its own controller; this routes camera readings and gesture intents to them, runs the tick, and keeps the steps
/// that cut across controllers (interrupting, refreshing the overlay). The tick runs on events (a camera reading, a
/// key, a headphone press, a session scan, an app switch) and on a 20 Hz timer only while something time-based is
/// pending (`tickPending`), so an idle Ensemble does not wake 20 times a second.
@MainActor
final class Coordinator: AppCoordinating {
    private let ctx: CoordinatorContext
    private let engine = VisionEngine()
    private let health: HealthMonitor
    private let focus: FocusController
    private let dot: DotPlacement
    private let scroll: ScrollController
    private let panes: PaneWidthController
    private let send: SendController
    private let dictation: DictationController
    private let headphone: HeadphoneRemote
    private let microphone: MicrophoneSwitcher
    /// Return while dictating: the first press stops, a second sends. See `handleKey`.
    private let keyTap = ReturnKeyTap()
    private var returnKeys = ReturnKeys()
    /// Fits the focused session to Claude's chat column once focus has settled on it; see `fitFocusedSession`.
    private var fitTrigger = SessionFit.Trigger()
    /// The last tick a calibration was running: no fit for a few seconds after it (`SessionFit.Hold`).
    private var lastCalibratingAt: TimeInterval = -.infinity
    /// The last nose reading focus used, nil without one: a fit waits for the nose to rest inside the session.
    private var focusNose: CGPoint?
    /// The last reason a fit was skipped, so each reason is logged once per rest, not on every tick.
    private var lastFitSkip: String?
    /// Hands on the keyboard, mouse or trackpad: Ensemble steps back until they rest. See `updateHandsBusy`.
    private var handsBusy = HandsBusy()
    private var pausedSince: TimeInterval = 0
    /// The face runs at the planner's slow rate; kept so each change is logged once.
    private var faceSlow = false
    /// The last key the Return watch held back from Claude: your command to Ensemble, not typing.
    private var lastHeldBackKeyAt: TimeInterval = -.infinity
    private var state: AppState { ctx.state }
    private var settings: SettingsStore { ctx.settings }
    private var gestures: GestureMachine { ctx.gestures }

    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var lastTickAt: TimeInterval = -.infinity
    private var inTick = false
    /// The timer keeps running this long after the last pending step ends, so a step's own trailing checks (the
    /// pointer put back after a scroll, the key watch switching off) still run at 20 Hz.
    private var tickTailUntil: TimeInterval = -.infinity
    private static let tickInterval = 1.0 / 20.0
    private static let tickTail = 0.5
    /// A pending overlay push from a reading; see `pushOverlaySoon`.
    private var overlayFlush: Timer?
    private static let overlayInterval = 1.0 / 60.0
    private var cancellables = Set<AnyCancellable>()
    private var headStats: (since: TimeInterval, n: Int, faces: [Int]) = (0, 0, [0, 0, 0])
    private var refreshInFlight = false
    /// Claude reported a change while a refresh was in flight: refresh again when it ends.
    private var refreshAgain = false
    private var promptedAccessibility = false
    private var recoveredAtLaunch = false
    private var lastAwayCheck: TimeInterval = 0
    private var lastSessionScan: TimeInterval = 0
    /// Set only while the tour's gesture-practice step is open; see `enterGesturePractice`.
    private var practiceSink: TourPracticeSink?
    /// True while the tour window is open: Ensemble keeps reading the camera (the tour calibrates and practises with
    /// it) but acts on nothing, so looking at the tour never moves Claude's focus or raises a session behind it.
    private var tourOpen = false
    /// Locked, asleep or behind the screen saver: see `setAway`.
    private var awayState = AwayState()
    private var frameRefreshInFlight = false
    private var lastFrameRefresh: TimeInterval = 0
    private static let staleHeadSeconds = 2.0
    private static let sessionScanFaceWindow = 5.0
    private static let sessionScanIdleInterval = 5.0

    var cameraNames: [String] { VisionEngine.cameraNames() }

    var isBusy: Bool {
        ctx.busy || ctx.listening != nil || send.afterStop || send.inFlight || send.earlyArmed || gestures.progress != nil || panes.isRunning
    }

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        let ctx = CoordinatorContext(state: state, settings: settings, overlay: overlay)
        self.ctx = ctx
        health = HealthMonitor(ctx: ctx, engine: engine)
        focus = FocusController(ctx: ctx)
        dot = DotPlacement(ctx: ctx)
        scroll = ScrollController(ctx: ctx)
        panes = PaneWidthController(ctx: ctx)
        send = SendController(ctx: ctx)
        dictation = DictationController(ctx: ctx, focus: focus, send: send)
        headphone = HeadphoneRemote(settingOn: { [weak settings] in (settings?.headphonePresses ?? false) && (settings?.enabled ?? false) },
                                    claudeRunning: { [weak ctx] in ctx?.bridge.claudeIsRunning() ?? false })
        microphone = MicrophoneSwitcher(settings: settings, overlay: overlay, isIdle: { [weak ctx] in
            guard let ctx else { return false }
            return ctx.listening == nil && !ctx.busy
        })
        headphone.onAction = { [weak self] in self?.apply(headphone: $0); self?.wake() }
        health.relaunchOnGrantAllowed = { [weak self] in !(self?.tourOpen ?? false) }
        ctx.changed = { [weak self] in self?.pushOverlay() }
        ctx.wake = { [weak self] in self?.armTickTimer() }
        panes.sendBusy = { [weak self] in self.map { $0.send.inFlight || $0.send.afterStop } ?? true }
        panes.keyWatchOn = { [weak self] in self?.keyTap.isActive ?? true }
        panes.focusedID = { [weak self] in self?.focus.target?.id }
        panes.framesChanged = { [weak self] in
            guard let self else { return }
            self.focus.refreshFrames()
            self.dot.place(target: self.focus.target)
            self.pushOverlay()
        }
        focus.stopDictation = { [weak self] reason in self?.dictation.end(reason: reason) }
        // The rates follow the switch itself: a tick within the last 50 ms makes wake wait for the next reading.
        focus.frontAppChanged = { [weak self] in self?.updateFaceRate(now: CACurrentMediaTime()); self?.wake() }
        dictation.interrupt = { [weak self] reason in self?.interrupt(reason) }
        dictation.stopResolved = { [weak self] confirmed in self?.stopResolved(confirmed: confirmed) }
        dictation.prepareMicrophone = { [weak self] in await self?.microphone.prepare() }
        keyTap.onKey = { [weak self] isReturn, modified, isRepeat in
            guard let self else { return false }
            defer { self.wake() }
            return self.handleKey(isReturn: isReturn, modified: modified, isRepeat: isRepeat)
        }
        keyTap.onReturnUp = { [weak self] in self?.returnKeys.returnReleased() }
        keyTap.onUnseenKeys = { [weak self] in self?.returnKeys.noteUnseenKeys(now: CACurrentMediaTime()) }
        send.lookedAt = { [weak self] in self?.focus.target }
        send.playStopSound = { [weak self] in self?.dictation.playStopSound() }
        send.returnInputAge = { [weak self] in
            let clicks = ClaudeBridge.secondsSinceClick()
            guard let self else { return clicks }
            return ReturnKeys.inputAge(clickAge: clicks, lastOtherKeyAt: self.returnKeys.lastOtherKeyAt, now: CACurrentMediaTime())
        }

        ctx.pointer.correctsForPosition = settings.correctForPosition
        ctx.pointer.screenSizeProvider = { ScreenGeometry.physicalSizeCm(ofScreenID: $0) }
        // The saved profile of the camera used last points from the first reading; the old single calibration is the
        // fallback for a setup saved before profiles.
        if !ctx.setup.restoreAtLaunch(), let data = settings.calibration { ctx.pointer.calibration = data }
        ctx.setup.startFullCalibration = { [weak self] in self?.calibrate() }
        ctx.setup.runPlan = { [weak self] plan in self?.runCalibration(plan) }
        gestures.mapping = settings.mapping
        ctx.pointer.setSmoothing(settings.pointerSmoothing)
        gestures.sendHold = settings.sendCountdownSeconds
        gestures.maximizeByPeace = settings.maximizeByPeace
        gestures.evenOutByScissors = settings.evenOutByScissors

        settings.$mapping.dropFirst().sink { [weak self] m in self?.gestures.mapping = m; self?.gestures.reset() }.store(in: &cancellables)
        settings.$sendCountdownSeconds.dropFirst().sink { [weak self] v in self?.gestures.sendHold = v }.store(in: &cancellables)
        settings.$maximizeByPeace.dropFirst().sink { [weak self] on in self?.gestures.maximizeByPeace = on }.store(in: &cancellables)
        settings.$evenOutByScissors.dropFirst().sink { [weak self] on in self?.gestures.evenOutByScissors = on }.store(in: &cancellables)
        settings.$correctForPosition.dropFirst().sink { [weak self] on in self?.ctx.pointer.correctsForPosition = on }.store(in: &cancellables)
        settings.$pointerSmoothing.dropFirst().sink { [weak self] k in self?.ctx.pointer.setSmoothing(k) }.store(in: &cancellables)
        settings.$enabled.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self else { return }
            // @Published fires before the stored value changes, so read settings on the next turn of the run loop.
            DispatchQueue.main.async { on ? self.start() : self.stop(disarm: true) }
        }.store(in: &cancellables)
        settings.$headphonePresses.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.headphone.refresh() }
        }.store(in: &cancellables)
        settings.$cameraName.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, self.health.running else { return }
            DispatchQueue.main.async { self.stop(disarm: false); self.start() }
        }.store(in: &cancellables)

        engine.onHand = { [weak self] in self?.handle(hand: $0) }
        engine.onHead = { [weak self] in self?.handle(head: $0) }
        engine.onLight = { [weak self] in self?.handle(light: $0) }
        engine.onStatus = { [weak self] in self?.health.handle(status: $0) }
        engine.onDiagnostic = { note in EnsembleLog.write("engine: \(note)") }
        engine.calibratedCameraIDs = { [weak self] in Set(self?.ctx.setup.profiles.cameras.map(\.cameraID) ?? []) }
        SystemEvents.observe(
            interrupt: { [weak self] in self?.interrupt($0) },
            away: { [weak self] reason, on in self?.setAway(reason, on) },
            sweep: { [weak self] in self?.dictation.sweep() },
            screensChanged: { [weak self] in self?.screensChanged() })
    }

    // MARK: - AppCoordinating

    func start() {
        EnsembleLog.write("start (enabled=\(settings.enabled), camera=\(settings.cameraName == nil ? "automatic" : "chosen"), calibrated=\(ctx.pointer.isCalibrated), accessibility=\(AXIsProcessTrusted()), screens=\(ScreenFacts.displayFingerprint()))")
        state.cameraNames = cameraNames
        if recoveredAtLaunch { recoveredAtLaunch = false } else { recoverAtLaunch() }
        guard settings.enabled else { state.status = .off; return }
        if !Permissions.accessibilityTrusted {
            EnsembleLog.write("accessibility permission missing (if Ensemble is already listed in Settings, remove it and add it again)")
            // Never over the tour: its permissions step has the button, and closing the tour asks (exitTour).
            if !tourOpen { promptAccessibilityOnce() }
        }
        health.begin()
        headphone.start()
        ctx.latestHead = nil
        reconcileAway()
        health.away = awayState.isAway
        if !awayState.isAway { engine.start(cameraName: settings.cameraName) }
        tickTimer?.invalidate(); tickTimer = nil
        lastTickAt = -.infinity
        tick()
        refreshTimer?.invalidate()
        refreshTimer = commonModeTimer(1.0) { [weak self] in self?.refreshSessions() }
        ctx.bridge.watcher.startWorkspaceWatch()
        ctx.bridge.watcher.onChange = { [weak self] in self?.refreshSessions(notified: true) }
        refreshSessions()
        health.update()
    }

    /// Crash recovery that must not wait for the camera: a record or mute left by an earlier run is put right at
    /// launch even when the first-run tour holds `start()` back.
    func recoverAtLaunch() {
        recoveredAtLaunch = true
        dictation.sweep()
        MediaDucker.recoverAfterCrash()
    }

    // MARK: - Away (lock, sleep, screen saver)

    /// Nobody can be at the Mac: the camera goes off (nothing is read while the screen is locked) and nothing
    /// acts on Claude, focus included. It comes back on when every reason has cleared.
    private func setAway(_ reason: AwayReason, _ on: Bool) {
        guard awayState.set(reason, on) else { return }
        applyAway()
    }

    /// A "back" notification macOS never delivered must not leave the camera off: clear what the facts disprove.
    private func reconcileAway() {
        let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        if awayState.reconcile(sessionLockedOrInactive: ScreenFacts.sessionAway(), displayAsleep: displayAsleep,
                               secondsSinceInput: ClaudeBridge.secondsSinceUserInput()) {
            EnsembleLog.write("back at the Mac (found on the 1 s check)")
            applyAway()
        }
    }

    private func applyAway() {
        let away = awayState.isAway
        health.away = away
        if away {
            EnsembleLog.write("away (\(awayState.reasons.map(\.rawValue).sorted().joined(separator: ", "))): camera off")
            engine.stop()
            ctx.latestHead = nil
            focus.forgetTargetAndCandidate()
            focus.clearDeferred()
            dot.clear()
            dot.place(target: nil)
            gestures.reset()
            scroll.cancel()
            ctx.overlay.setGesture(nil)
            pushOverlay()
        } else if health.running, settings.enabled, !engine.isRunning {
            EnsembleLog.write("back at the Mac: camera on")
            ctx.latestHead = nil
            engine.start(cameraName: settings.cameraName)
        }
    }

    private func promptAccessibilityOnce() {
        guard !promptedAccessibility else { return }
        promptedAccessibility = true
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Common run-loop mode keeps the timers firing while a slider is dragged or a menu is open.
    private func commonModeTimer(_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// `disarm`: the owner switched Ensemble off. Any Claude dictation still recording is stopped and confirmed off,
    /// and the safety record and microphone mute are cleared, the same as the old "Clear and disarm" button did.
    func stop(disarm: Bool) {
        EnsembleLog.write("stop")
        health.running = false
        ctx.latestHead = nil
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil; ctx.bridge.watcher.onChange = nil
        headphone.stop()
        if disarm { dictation.clearAndDisarm() } else if ctx.listening != nil { dictation.end(reason: "turned off") }
        engine.stop()
        gestures.reset()
        scroll.cancel()
        focus.clearDeferred(); send.afterStop = false; send.forget(); send.dropEarly()
        ctx.claudeDictations.forgetAll()
        focus.forgetTarget()
        returnKeys.reset(); keyTap.setActive(false)
        state.status = .off
        state.clearRefusal()
        // The last target and nose position would otherwise be pushed again and leave the highlight on a window.
        ctx.targetFrame = nil; ctx.nosePoint = nil; ctx.resizeFrame = nil
        pushOverlay()
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        EnsembleLog.write("shutdown")
        health.running = false
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil; ctx.bridge.watcher.onChange = nil
        headphone.stop()
        ctx.bridge.beginShutdown()
        engine.stop()
        scroll.cancel()
        dictation.shutdown()
        microphone.restoreNow()
        EnsembleLog.flush()
    }

    func calibrate() { calibrate(.recalibrate) }

    func calibrate(_ request: CalibrationRequest) {
        let clickedAt = CACurrentMediaTime()
        guard !state.calibrating else { EnsembleLog.write("calibrate ignored: already in progress"); return }
        guard let plan = ctx.setup.plan(for: request) else { ctx.refuse("That screen is no longer connected"); return }
        EnsembleLog.write("calibrate requested (\(request), \(plan.purpose), enabled=\(settings.enabled), engine running=\(engine.isRunning), face tracker ready=\(health.trackerReady))")
        // The window goes up first, before anything that can take time. Calibrating while off, or while the camera is
        // down, then turns Ensemble on or restarts the camera behind the window, which says what it is waiting for.
        runCalibration(plan, clickedAt: clickedAt)
        if !settings.enabled { settings.enabled = true } else if !health.running || !engine.isRunning { start() }   // the enabled sink starts it
    }

    func removeCalibrationSpot(_ id: String) {
        guard !state.calibrating else { return }
        EnsembleLog.write("calibration position \(id) removed")
        ctx.setup.removeSpot(id)
        health.update()
    }

    /// Runs one calibration plan: every screen or only some, for the position in use or a new one. What the
    /// run collected is stored as the plan's purpose says.
    private func runCalibration(_ plan: CalibrationPlan, clickedAt: TimeInterval = CACurrentMediaTime()) {
        let fingerprint = ScreenFacts.displayFingerprint()
        let camera = state.cameraName
        state.calibrating = true
        let feed = CalibrationFeed(
            head: { [weak self] in self?.ctx.latestHead },
            waitingFor: { [weak self] in
                guard let self else { return "Looking for your face\u{2026}" }
                if !self.health.cameraAllowed { return "Waiting for Camera permission\u{2026}" }
                if !self.engine.isRunning { return "Starting the camera\u{2026}" }
                if !self.health.trackerReady { return "Loading face tracking\u{2026}" }
                return "Looking for your face\u{2026}"
            },
            failure: { [weak self] in
                // Only once the camera path has been (re)started for this run: an earlier failure is not this run's.
                guard let self, self.health.running, self.health.cameraFailed else { return nil }
                return self.health.cameraAllowed ? "The camera did not start: \(self.health.failure ?? "no reading")" : "Calibration needs Camera permission"
            })
        CalibrationController.shared.run(screens: plan.screens, note: plan.note, firstDotFrom: plan.firstDotFrom, feed: feed,
                                         clickedAt: clickedAt) { [weak self] results in
            guard let self else { return }
            self.state.calibrating = false
            EnsembleLog.write("calibration samples: \(results.map(\.samples.count))")
            let failure = CalibrationController.shared.failure
            guard !results.isEmpty else {
                if let failure { self.ctx.refuse(failure) }
                return
            }
            guard ScreenFacts.displayFingerprint() == fingerprint, self.state.cameraName == camera else {
                self.ctx.refuse("Calibration discarded: the screens or the camera changed while it ran; try again")
                return
            }
            switch self.ctx.setup.storeCalibration(results, purpose: plan.purpose) {
            case .saved:
                if let failure { self.ctx.refuse(failure) }
            case .didNotFit:
                self.ctx.refuse("Calibration did not fit; try again sitting where you normally work")
            case .repeats(let screen, let other):
                let setup = self.ctx.setup
                self.ctx.refuse("Not saved: the points on \(setup.name(ofScreenID: screen)) matched where you look at \(setup.name(ofScreenID: other)). "
                                + "Follow the dot on \(setup.name(ofScreenID: screen)), or recalibrate every screen if the camera moved")
            }
            self.health.update()
            self.wake()
        }
        // Calibration owns the hands and the head: end any dictation first, because
        // gesture events are ignored while it runs and a held talk pose would never be seen released.
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "calibrating") }
        wake()
    }

    /// While the tour practices gestures, real intents and head readings go to `sink` instead of acting on
    /// Claude: nothing is pressed, dictated or sent. Ends any dictation already in progress first, the same
    /// as `calibrate()` does, so a hold left over from real use cannot fire once the tour reads it.
    func enterGesturePractice(_ sink: TourPracticeSink) {
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "tour practice") }
        practiceSink = sink
        wake()
    }

    func exitGesturePractice() {
        practiceSink = nil
        gestures.reset()
        scroll.cancel()
        wake()
    }

    func enterTour() {
        tourOpen = true
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "tour opened") }
        focus.forgetTargetAndCandidate()
        dot.clear()
        dot.place(target: nil)
        ctx.overlay.setGesture(nil)
        pushOverlay()
    }

    func exitTour() {
        tourOpen = false
        if settings.enabled, !Permissions.accessibilityTrusted { promptAccessibilityOnce() }
        gestures.reset()
        scroll.cancel()
        wake()
    }

    // MARK: - Inputs

    private func handle(head: HeadObservation) {
        // A reading already in flight when the camera went off for the lock: nothing acts on it.
        if awayState.isAway { return }
        // First, so the reading meets a fresh keyboard-and-mouse pause.
        wake()
        ctx.latestHead = head
        // Head readings are not practised in the tour, but they must not act on Claude while it is open.
        if practiceSink != nil || tourOpen { return }
        if head.faceCount == 1 {
            let returned = head.t - ctx.lastOneFaceT >= Self.sessionScanFaceWindow
            ctx.lastOneFaceT = head.t
            if returned { refreshSessions() }
        }
        logHeadStats(head)
        guard !state.calibrating else { return }
        if head.faceCount == 1, ctx.calibratedHere, let p = ctx.pointer.point(for: head), ctx.setup.isUsable(p) {
            state.set(\.spotInUse, ctx.setup.spotInUseID)
            if ctx.handsBusy, ctx.listening != nil {
                // Hands on the keyboard or mouse while dictating: the dictating session and its edge warnings hold still.
                EnsembleTrace.write(head.t, "head nose=\(Int(p.x)),\(Int(p.y)) paused faces=\(head.faceCount)")
            } else {
                // A pinch or scroll in progress holds everything still: the hand is in front of the face. Paused for
                // the keyboard or mouse, the target still follows the nose (gestures act on the session you look at)
                // while keyboard focus and the windows stay put.
                let under = focus.observe(nose: p, at: head.t, held: gestures.pinchHeld || scroll.isActive, paused: ctx.handsBusy)
                focusNose = p
                dot.follow(nose: p, at: head.t, onSession: under != nil)
                EnsembleTrace.write(head.t, "head nose=\(Int(p.x)),\(Int(p.y)) under=\(under?.id ?? "-") \(focus.traceState(at: head.t))\(ctx.handsBusy ? " paused" : "") faces=\(head.faceCount)")
            }
        } else if head.faceCount != 1 && head.t - ctx.lastOneFaceT <= 1.5 {
            // A hand in front of the face hides it or reads as a second face for a moment: keep the last target and dot.
        } else {
            dot.clear()
            focus.forgetTarget()
            focusNose = nil
        }
        dot.place(target: focus.target)
        pushOverlaySoon()
    }

    private func logHeadStats(_ head: HeadObservation) {
        headStats.n += 1; headStats.faces[min(head.faceCount, 2)] += 1
        guard head.t - headStats.since >= 30 else { return }
        let nose = ctx.pointer.point(for: head).map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
        EnsembleLog.write("head: \(headStats.n) readings in 30 s, faces 0/1/2+ = \(headStats.faces), nose at \(nose), accessibility \(AXIsProcessTrusted()), Claude running \(ctx.bridge.claudeIsRunning()), sessions \(ctx.sessions.count), nose on Claude: \(focus.target != nil), \(ctx.bridge.micSnapshot)")
        headStats = (head.t, 0, [0, 0, 0])
    }

    private func handle(hand: HandObservation) {
        dictation.heartbeat()
        wake()
        guard !state.calibrating else { return }
        let intents = gestures.push(hand)
        for line in gestures.takeDiagnostics() { EnsembleLog.write("hand: \(line)") }
        practiceSink?.tourPractice(hand: hand)
        if let sink = practiceSink {
            for intent in intents { sink.tourPractice(intent: intent) }
            return
        }
        if tourOpen { return }
        EnsembleTrace.write(hand.t, "hand present=\(hand.present ? 1 : 0) pose=\(hand.pose?.rawValue ?? "-")\(hand.gate.map { "(\($0.rawValue))" } ?? "") two=\(hand.twoUp ? 1 : 0) spread=\(hand.fingerSpread.map { String(format: "%.3f", $0) } ?? "-") pinch=\(hand.pinch.map { String(format: "%.3f", $0) } ?? "-") palm=\(hand.palmCenter.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "-") \(gestures.traceState)\(intents.isEmpty ? "" : " -> \(intents)")")
        for intent in intents { apply(intent) }
        let onClaude = focus.target != nil || ctx.listening != nil
        let progress = ctx.cover.covered || !settings.enabled || !onClaude ? nil : gestures.progress
        ctx.gestureShowing = progress != nil
        ctx.overlay.setGesture(progress)
        dot.place(target: focus.target)
        pushOverlaySoon()
    }

    private func handle(light: FrameLight) {
        wake()
        guard let covered = ctx.cover.push(light) else { return }
        if covered {
            if ctx.listening != nil { dictation.end(reason: "camera covered") }
            send.afterStop = false
            scroll.cancel()
            gestures.reset()
            Notifier.shared.notify(title: "Camera covered", body: "Gestures are off until the camera is uncovered.")
        }
        health.update()
    }

    /// An event happened: tick now unless the timer is running or a tick ran within the last 45 ms (head and hand
    /// readings together arrive up to 60 times a second), and start or stop the timer for what is pending now.
    private func wake() {
        guard health.running, !inTick else { return }
        if tickTimer == nil, CACurrentMediaTime() - lastTickAt >= Self.tickInterval - 0.005 { tick() } else { armTickTimer() }
    }

    /// The 20 Hz timer runs only while `tickPending`, and for `tickTail` after. Starting it also applies the face
    /// rate at once, so a gesture, dictation or send that needs every frame gets it without waiting for a tick.
    private func armTickTimer() {
        let now = CACurrentMediaTime()
        if health.running, tickPending(now: now) { tickTailUntil = now + Self.tickTail }
        let want = health.running && now < tickTailUntil
        if want, tickTimer == nil {
            tickTimer = commonModeTimer(Self.tickInterval) { [weak self] in self?.tick() }
            if !inTick { updateFaceRate(now: now) }
        } else if !want, let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
        }
    }

    /// Something in the tick that runs against the clock: the dictation checks (input, no face, the microphone, the
    /// dictating pane's frame), a start, stop or send in flight, a gesture or hold, a scroll, a resize, calibration,
    /// a deferred focus, the Return windows, a refusal to expire, a fit waiting for focus to settle. Everything else
    /// in the tick changes only with an event, and the 1 s session refresh ticks too (stale readings, a camera
    /// that stopped). The dictation safety's own deadman and standing check run on their own timer regardless.
    private func tickPending(now: TimeInterval) -> Bool {
        needsFullRate || send.inFlight || send.returnSendPending || send.earlyHoldPending || gestures.talking
            || scroll.isRunning || focus.hasDeferred || keyTap.isActive
            || returnKeys.wantsKeys(now: now, returnSendPending: send.returnSendPending)
            || state.lastRefusal != nil || ctx.headphoneActive
            || (settings.fitFocusedSession && !ctx.handsBusy && fitTrigger.waiting(for: focus.target?.id))
    }

    private func tick() {
        guard !inTick else { return }
        inTick = true
        defer { inTick = false; armTickTimer() }
        lastTickAt = CACurrentMediaTime()
        dropStaleReadings()
        updateHandsBusy(now: CACurrentMediaTime())
        // Away: a deferred focus move must not land behind the lock screen.
        if !awayState.isAway, !ctx.handsBusy { focus.tick() }
        for intent in gestures.tick(now: CACurrentMediaTime()) {
            if let sink = practiceSink { sink.tourPractice(intent: intent) } else if !tourOpen { apply(intent) }
        }
        let now = CACurrentMediaTime()
        updateFaceRate(now: now)
        scroll.tick()
        if now - lastAwayCheck >= 0.5 {
            lastAwayCheck = now
            if ctx.listening != nil ? !ctx.busy : scroll.isRunning, ScreenFacts.sessionAway() { interrupt("screen locked") }
        }
        dictation.supervise(now: now)
        refreshDictatingFrame(now: now)
        fitFocusedSession(now: now)
        if returnKeys.expire(now: now) { ctx.refuse("Not sent: the stop was not confirmed") }
        if send.earlyHoldPending { send.earlyObserve(holding: gestures.holdingSend) }
        if state.lastRefusal != nil {
            state.clearRefusalIfStale(now: now, lastInputAt: now - ClaudeBridge.secondsSinceTypingOrClick(),
                                      dictating: ctx.listening != nil, onSession: focus.target != nil)
        }
        keyTap.setActive(health.running && (ctx.listening != nil || claudeDictatingHere
                                            || returnKeys.wantsKeys(now: now, returnSendPending: send.returnSendPending)))
    }

    /// The nose resting inside one session for `SessionFit.settle`, with focus on it throughout, widens it to
    /// Claude's chat column, once per focus change; a nose passing over a session never does. Something in the way
    /// (paused for the keyboard or mouse, dictating, sending, mid-gesture, another resize) is logged once with its
    /// reason, and the fit runs as soon as it clears while the nose still rests there. A fit running when focus moves
    /// on stops (`PaneWidthController`), and the session focus moved to is fitted once the nose rests on it.
    private func fitFocusedSession(now: TimeInterval) {
        if state.calibrating { lastCalibratingAt = now }
        let target = focus.target
        let inside = target.map { t in focusNose.map { t.frame.contains($0) } ?? false } ?? false
        guard let id = fitTrigger.observe(target?.id, inside: inside, at: now), let target, target.id == id else { return }
        guard settings.fitFocusedSession, health.running, !awayState.isAway, !tourOpen, practiceSink == nil,
              !focus.userLeftClaude else { return }
        let skip: PaneWidthController.FitSkip?
        if ctx.handsBusy {
            skip = .init(why: "paused while you type or use the mouse", retry: true)
        } else if ctx.listening != nil || ctx.busy || send.inFlight || send.afterStop || send.earlyArmed {
            skip = .init(why: "a dictation or send is in progress", retry: true)
        } else if gestures.progress != nil {
            skip = .init(why: "a gesture is in progress", retry: true)
        } else {
            skip = panes.autoFit(target, calibratedAt: lastCalibratingAt)
        }
        guard let skip else { lastFitSkip = nil; return }
        if skip.retry { fitTrigger.retry() }
        if id + skip.why != lastFitSkip {
            lastFitSkip = id + skip.why
            EnsembleLog.write("pane widths: no fit yet (\(skip.why))\(skip.retry ? "; fitting once it clears" : "")")
        }
    }

    /// While dictating the full session scan is off (see `refreshSessions`), so a Claude window moved or resized
    /// meanwhile would leave the highlight and edge warnings on its old frame. Twice a second, only the dictating
    /// pane's frame is read: one bounded Accessibility read of a cached element, never a tree walk.
    private func refreshDictatingFrame(now: TimeInterval) {
        guard let session = ctx.listening, !frameRefreshInFlight, now - lastFrameRefresh >= 0.5 else { return }
        lastFrameRefresh = now
        frameRefreshInFlight = true
        Task { @MainActor in
            defer { self.frameRefreshInFlight = false }
            guard let frame = await self.ctx.bridge.paneFrame(session), frame.width > 50, frame.height > 50,
                  self.ctx.listening?.id == session.id, self.ctx.listening?.frame != frame else { return }
            self.ctx.listening?.frame = frame
            if let i = self.ctx.sessions.firstIndex(where: { $0.id == session.id }) { self.ctx.sessions[i].frame = frame }
            self.dot.place(target: self.focus.target)
            self.pushOverlay()
        }
    }

    /// Any key, click, scroll or pointer movement of yours pauses Ensemble until the hardware has rested for the
    /// quiet time: keyboard focus and the highlight hold, nothing is resized, the dot and highlight fade out. Gestures
    /// still work, on the session the nose is on. The camera and tracking keep running so resuming is instant, and the
    /// dictation safety checks never pause. Keys the Return watch held back, keys Ensemble posts and the pointer moves
    /// of its own scrolls are not yours.
    private func updateHandsBusy(now: TimeInterval) {
        handsBusy.quiet = settings.pauseAfterInputSeconds
        let input = ClaudeBridge.lastHardwareInput(now: now)
        // The hardware state never holds a key Ensemble posted (the divider keys), so a key read here inside one of
        // its key windows is the owner's own hand and pauses; only a Return held back or a play/pause key is excluded.
        let ownKeyAt = max(lastHeldBackKeyAt, HeadphoneRemote.lastSyntheticKeyAt)
        let busy = handsBusy.update(now: now, keyAt: input.key, clickAt: input.click, scrollAt: input.scroll, moveAt: input.move,
                                    pointer: NSEvent.mouseLocation, ownKeyAt: ownKeyAt,
                                    ownPointerAt: ClaudeBridge.ownPointerMove.withLock { $0 }, ownFocusAt: focus.lastOwnFocusAt)
        guard busy != ctx.handsBusy else { return }
        ctx.handsBusy = busy
        if busy { pausedSince = now }
        EnsembleLog.write(busy ? "paused: keyboard or mouse in use (\(handsBusy.lastInputKind?.rawValue ?? "input"))" : "resumed: no keyboard or mouse use for \(settings.pauseAfterInputSeconds) s")
        // Gestures are deliberate and keep working through a pause (a hand raised from the keyboard to pinch would
        // otherwise land inside the quiet time and do nothing): the pause only holds focus, the highlight and resizes.
        if busy {
            focus.clearDeferred()
            scroll.cancel()
            panes.cancel()
            if send.earlyArmed { send.dropEarly() }
            if send.afterStop, !send.returnSendPending { send.afterStop = false }
        } else {
            focus.resumed()
        }
        health.update()
        pushOverlay()
    }

    /// A gesture or headphone press is acting through a pause: the highlight comes back on the session it acts on.
    private var actingThroughPause: Bool {
        ctx.busy || ctx.headphoneActive || send.inFlight || send.afterStop || send.earlyArmed || gestures.pinchHeld
            || gestures.progress != nil || gestures.peaceOpen || scroll.isActive || scroll.isCoasting
    }

    /// The face runs at 10 Hz while nothing follows the nose closely (`FrameRatePlanner.wantsSlowFace`) and at full rate
    /// again on the next tick once that ends (the next reading, or the app switch itself), or at once when a gesture,
    /// dictation or send needs every frame (`armTickTimer`).
    private func updateFaceRate(now: TimeInterval) {
        let full = needsFullRate
        engine.setForceFullRate(full)
        engine.setOtherAppInFront(focus.userLeftClaude)
        let slow = FrameRatePlanner.wantsSlowFace(needsFull: full, tourOpen: tourOpen, otherAppInFront: focus.userLeftClaude,
                                                  sessionsOnScreen: !ctx.sessions.isEmpty,
                                                  pausedFor: ctx.handsBusy ? now - pausedSince : nil)
        engine.setSlowFace(slow)
        guard slow != faceSlow else { return }
        faceSlow = slow
        let why = focus.userLeftClaude ? "another app in front" : ctx.sessions.isEmpty ? "no Claude session on screen" : "paused for the keyboard or mouse"
        EnsembleLog.write(slow ? "face tracking at 10 Hz (\(why))" : "face tracking at full rate")
    }

    /// Every hand frame is needed while dictating, calibrating, or a gesture is in progress.
    private var needsFullRate: Bool {
        ctx.listening != nil || ctx.busy || send.afterStop || send.earlyArmed || state.calibrating
            || scroll.isActive || scroll.isCoasting || gestures.pinchHeld || gestures.progress != nil || practiceSink != nil
            || gestures.peaceOpen || panes.isRunning
    }

    /// When head readings stop (camera lost, face tracker stalled) the highlight and dot go away instead of freezing.
    private func dropStaleReadings() {
        guard let head = ctx.latestHead, CACurrentMediaTime() - head.t > Self.staleHeadSeconds else { return }
        guard focus.hasTargetOrCandidate || dot.hasDot || dot.hasEdgeWarning || ctx.nosePoint != nil else { return }
        EnsembleLog.write("head readings stopped; clearing the highlight")
        focus.forgetTargetAndCandidate(); dot.clear()
        dot.place(target: nil)
        pushOverlay()
    }

    /// The 1 s check, and `notified` when Claude reported a window or pane change (`ClaudeWatcher`). A notified refresh
    /// skips the idle slowdown (a change is worth reading at once) and, when one is in flight, runs after it.
    private func refreshSessions(notified: Bool = false) {
        wake()
        health.checkPermissions()
        microphone.restoreIfNeeded()
        let claudeUp = ctx.bridge.claudeIsRunning()
        dictation.dropIfClaudeGone(running: claudeUp)
        guard claudeUp else {
            health.sessionsScanned = false; ctx.sessions = []; ctx.claudeDictations.forgetAll()
            focus.forgetAll(); send.forget(); scroll.cancel(); health.update(); return
        }
        if awayState.isAway { reconcileAway() }
        // No refresh while dictating: a slow Claude tree walk would otherwise trip the Accessibility stall limit mid-hold.
        guard ctx.listening == nil else { return }
        // A width step reads the frames itself after its own keys, which Claude reports as divider changes.
        if notified, panes.isRunning { return }
        guard !refreshInFlight else { refreshAgain = refreshAgain || notified; return }
        // Nobody in front of the camera for 5 s: the window scan (which also costs Claude's own process) runs
        // every 5 s instead of every second, and immediately when a face comes back.
        let now = CACurrentMediaTime()
        guard notified || now - ctx.lastOneFaceT < Self.sessionScanFaceWindow
                || now - lastSessionScan >= Self.sessionScanIdleInterval else { return }
        lastSessionScan = now
        refreshInFlight = true
        // During a width step the check works the old way: the layout change it causes must not walk Claude's tree in
        // the middle of it. Its notifications wait for the first check after it.
        let useNotifications = !panes.isRunning
        Task { @MainActor in
            defer {
                self.refreshInFlight = false
                if self.refreshAgain, self.refreshTimer != nil { self.refreshAgain = false; self.refreshSessions(notified: true) }
            }
            let epoch = self.ctx.dictationEpoch
            let scan = await self.ctx.bridge.refreshSessions(watched: useNotifications)
            let found = scan.sessions
            // A read taken before Ensemble started, took over or stopped a dictation would report Ensemble's own.
            if epoch == self.ctx.dictationEpoch, self.ctx.listening == nil {
                let before = self.ctx.claudeDictations.recording
                self.ctx.claudeDictations.observe(present: found.map(\.id), recordingNow: scan.recording, at: CACurrentMediaTime())
                let now = self.ctx.claudeDictations.recording
                if now != before { HeadphoneRemote.noteMicChange(); EnsembleLog.write("Claude is dictating without Ensemble in \(now.count) session(s)") }
            }
            if found.map(\.id) != self.ctx.sessions.map(\.id) { EnsembleLog.write("Claude sessions found: \(found.count) (named \(found.filter { $0.title != nil }.count)) \(found.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" })") }
            self.ctx.sessions = found
            self.health.sessionsScanned = true
            self.health.update()
            // The face rate depends on whether any session is on screen.
            self.wake()
        }
    }

    // MARK: - Intents and cross-cutting steps

    private func apply(_ intent: GestureIntent) {
        switch intent {
        case .scroll, .dragScroll: break
        default: EnsembleLog.write("gesture: \(intent)")
        }
        if intent == .talkBegan || intent == .sendRequested { ctx.overlay.clearBanner() }
        switch intent {
        case .talkBegan: dictation.begin()
        case .talkEnded(let reason):
            guard let session = ctx.listening else { break }
            if gestures.holdingSendAfterStop, settings.mapping.send != nil, !ctx.busy, !ctx.setup.isPromptShowing {
                // A thumbs-up while dictating: stop now and settle the transcript during the hold, so Send is
                // pressed the moment the hold completes.
                send.armEarly(in: session)
                dictation.end(reason: "thumbs-up", tail: DictationController.sendStopTail)
            } else {
                dictation.end(reason: reason.rawValue)
            }
        case .sendRequested:
            // While the setup prompt shows, the held thumbs-up answers it instead of sending.
            if ctx.setup.isPromptShowing { send.dropEarly(); ctx.setup.start(); return }
            if send.earlyArmed { send.earlyHoldCompleted(); return }
            if ctx.listening != nil || ctx.busy { send.sendAfterStop(in: ctx.listening); EnsembleLog.write("send after stop") } else { requestSend() }
        case .scroll(let dy): scroll.scroll(dy, target: focus.target)
        case .dragScrollEnded: scroll.released()
        case .dragScroll(let handDy): scroll.drag(handDy: handDy, target: focus.target)
        case .maximizeSession: panes.request(true, target: focus.target)
        case .evenOutSessions: panes.request(false, target: focus.target)
        }
    }

    /// A stem press. Both go through the same guards as the gestures: a press is the double pinch (dictation
    /// begins only on the session the nose is on, with calibration and every common refusal), a double press is the
    /// thumbs-up (the narrow send rules in SendController, unchanged).
    private func apply(headphone action: HeadphoneAction) {
        // Tour practice promises nothing reaches Claude; a stem press is no exception.
        guard practiceSink == nil, !tourOpen else { return }
        ctx.headphoneUntil = CACurrentMediaTime() + 5
        ctx.overlay.clearBanner()
        switch action {
        case .press:
            guard !ctx.busy else { ctx.refuse("A step is still in flight"); return }
            if ctx.listening != nil {
                ctx.overlay.showBanner(title: "Headphone press", body: "Stopping dictation", style: .info, seconds: 1.5)
                dictation.end(reason: "headphone press")
            } else {
                ctx.overlay.showBanner(title: "Headphone press", body: "Starting dictation", style: .info, seconds: 1.5)
                // The machine takes the state a double pinch leaves: a later double pinch stops this dictation, and
                // a refusal inside begin() flips it back.
                gestures.beginTalkExternally()
                dictation.begin()
            }
        case .doublePress:
            guard settings.mapping.send != nil else { ctx.refuse("Send is off in Settings"); return }
            guard !ctx.busy else { ctx.refuse("Send ignored: a step is still in flight"); return }
            ctx.overlay.showBanner(title: "Headphone double press", body: "Sending the draft", style: .info, seconds: 1.5)
            if ctx.listening != nil {
                // Same as the thumbs-up held from the talk pose: stop, then send once the stop is confirmed.
                send.sendAfterStop(in: ctx.listening)
                dictation.end(reason: "headphone double press")
            } else {
                requestSend()
            }
        }
    }

    /// The looked-at session shows a dictation Claude runs without Ensemble (as of the last refresh).
    private var claudeDictatingHere: Bool {
        ctx.listening == nil && ctx.claudeDictations.isRecording(focus.target?.id)
    }

    /// A send asked for with no Ensemble dictation running and nothing in flight. If Claude is dictating in the
    /// looked-at session, whoever started it, that dictation is stopped through Ensemble's own stop path and sent once
    /// the transcript settles, under every send rule; otherwise the dictated draft is sent under the usual rules.
    private func requestSend() {
        guard let target = focus.target, settings.mapping.send != nil, ctx.bridge.claudeIsFrontmost(),
              ctx.commonRefusal() == nil else { send.request(); return }
        Task { @MainActor in
            let result = await self.dictation.takeOverIfDictating(target, reason: "send") {
                self.send.sendAfterStop(in: target)
            }
            switch result {
            case .stopping: EnsembleLog.write("send after stopping a dictation Claude was running")
            case .notDictating: self.send.request()
            case .refused(let why): self.send.afterStop = false; self.ctx.refuse("Not sent: \(why)")
            }
        }
    }

    /// A key press while the key watch is on (an Ensemble dictation, or just after one). Only Return without
    /// modifiers, with Claude in front, is ever kept from Claude; the rules are in `ReturnKeys`.
    private func handleKey(isReturn: Bool, modified: Bool, isRepeat: Bool) -> Bool {
        let now = CACurrentMediaTime()
        let decision = returnKeys.press(isReturn: isReturn, modified: modified, isRepeat: isRepeat,
                                        claudeInFront: ctx.bridge.claudeIsFrontmost(),
                                        dictating: ctx.listening != nil || claudeDictatingHere,
                                        returnSendPending: send.returnSendPending, now: now)
        if decision != .pass { lastHeldBackKeyAt = now }
        switch decision {
        case .pass:
            return false
        case .swallow:
            return true
        case .swallowAndStop:
            ctx.overlay.clearBanner()
            if ctx.listening == nil, let target = focus.target {
                // A dictation Claude runs without Ensemble: taken over and stopped the same way.
                EnsembleLog.write("Return: stopping a dictation Claude was running")
                Task { @MainActor in
                    if case .stopping = await self.dictation.takeOverIfDictating(target, reason: "Return", beforeStop: {}) { return }
                    self.send.afterStop = false; self.stopResolved(confirmed: false)
                }
                return true
            }
            EnsembleLog.write("Return: stopping dictation")
            // A start or stop press may be in flight; the stop then waits for it, the same as calibrating does.
            if ctx.busy { dictation.endWhenIdle(reason: "Return") } else { dictation.end(reason: "Return") }
            return true
        case .swallowAndSendAfterStop:
            EnsembleLog.write("Return twice: send after stop")
            send.sendAfterStop(in: ctx.listening ?? focus.target, byReturn: true)
            return true
        case .swallowAndSend:
            EnsembleLog.write("Return twice: sending")
            // The stop was confirmed a moment ago; the send waits for Claude to finish the transcript, no longer.
            send.request(byReturn: true, settle: true)
            return true
        }
    }

    private func stopResolved(confirmed: Bool) {
        if confirmed {
            returnKeys.stopConfirmed(now: CACurrentMediaTime())
        } else if returnKeys.stopFailed() {
            ctx.refuse("Not sent: the stop was not confirmed")
        }
    }

    /// The Mac is going to sleep, the screen locked, or the safety check ended the hold: stop dictation now (no
    /// tail wait), and forget anything that was about to act. The text stays; nothing is sent.
    private func interrupt(_ reason: String) {
        EnsembleLog.write("interrupt: \(reason)")
        dictation.markInterrupted()
        send.afterStop = false; focus.clearDeferred()
        returnKeys.reset()
        send.forget(); send.dropEarly()
        ctx.claudeDictations.forgetAll()
        scroll.cancel()
        panes.cancel()
        gestures.reset()
        guard ctx.listening != nil else { pushOverlay(); return }
        if ctx.busy {
            dictation.endWhenIdle(reason: reason, immediate: true)
        } else {
            dictation.end(reason: reason, immediate: true)
        }
    }

    private func screensChanged() {
        ctx.setup.screensChanged()
        ctx.invalidateCalibrationCache()
        EnsembleLog.write("screens changed; calibration valid here: \(ctx.calibratedHere)")
        if ctx.listening != nil { dictation.end(reason: "screens changed") }
        if state.calibrating { CalibrationController.shared.cancel() }
        scroll.cancel()
        focus.forgetTarget()
        health.update()
        wake()
    }

    /// Head and hand readings together arrive up to 60 times a second, both from each camera frame: they mark the
    /// overlay for one push 1/60 s later, which reads the latest values. The tick timer is armed
    /// now, so a gesture, hold or deferred focus the reading started never waits for the push.
    private func pushOverlaySoon() {
        armTickTimer()
        if overlayFlush == nil { overlayFlush = commonModeTimer(Self.overlayInterval) { [weak self] in self?.pushOverlay() } }
    }

    private func pushOverlay() {
        overlayFlush?.invalidate(); overlayFlush = nil
        dictation.restoreAudioIfIdle()
        let acting = ctx.listening ?? (gestures.progress?.action == .send ? send.lastSpoken?.session : nil) ?? focus.target
        ctx.overlay.setSession(name: acting.map(ctx.name(of:)), switching: focus.switching())
        ctx.overlay.setEdge(dot.overlayEdge(focus: focus))
        ctx.overlay.setHandsOnInput(ctx.handsBusy && !actingThroughPause)
        ctx.overlay.setScrolling(DotGlyph.showsScroll(scrollActive: scroll.isActive, pinchHeld: gestures.pinchHeld))
        ctx.overlay.update(target: ctx.targetFrame, nose: ctx.nosePoint, listening: state.listening,
                           showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        health.update()
        armTickTimer()
    }
}
