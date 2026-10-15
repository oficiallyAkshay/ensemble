import AppKit
import Combine
import EnsembleCore

/// Wires the camera engine, the gesture rules, the nose pointer and the Claude bridge together. Each job has
/// its own controller; this routes camera readings and gesture intents to them, runs the 20 Hz tick, and keeps
/// the steps that cut across controllers (interrupting, refreshing the overlay).
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
    /// Return while dictating: the first press stops, a second sends. See `handleKey`.
    private let keyTap = ReturnKeyTap()
    private var returnKeys = ReturnKeys()
    /// Fits the focused session to Claude's chat column once focus has settled on it; see `fitFocusedSession`.
    private var fitTrigger = SessionFit.Trigger()
    /// Hands on the keyboard, mouse or trackpad: Ensemble steps back until they rest. See `updateHandsBusy`.
    private var handsBusy = HandsBusy()
    /// The last key the Return watch held back from Claude: your command to Ensemble, not typing.
    private var lastHeldBackKeyAt: TimeInterval = -.infinity
    private var state: AppState { ctx.state }
    private var settings: SettingsStore { ctx.settings }
    private var gestures: GestureMachine { ctx.gestures }

    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var headStats: (since: TimeInterval, n: Int, faces: [Int]) = (0, 0, [0, 0, 0])
    private var refreshInFlight = false
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
        headphone.onAction = { [weak self] in self?.apply(headphone: $0) }
        ctx.changed = { [weak self] in self?.pushOverlay() }
        panes.sendBusy = { [weak self] in self.map { $0.send.inFlight || $0.send.afterStop } ?? true }
        focus.stopDictation = { [weak self] reason in self?.dictation.end(reason: reason) }
        dictation.interrupt = { [weak self] reason in self?.interrupt(reason) }
        dictation.stopResolved = { [weak self] confirmed in self?.stopResolved(confirmed: confirmed) }
        keyTap.onKey = { [weak self] isReturn, modified, isRepeat in
            self?.handleKey(isReturn: isReturn, modified: modified, isRepeat: isRepeat) ?? false
        }
        keyTap.onReturnUp = { [weak self] in self?.returnKeys.returnReleased() }
        keyTap.onUnseenKeys = { [weak self] in self?.returnKeys.noteUnseenKeys(now: CACurrentMediaTime()) }
        send.lookedAt = { [weak self] in self?.focus.target }
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
        SystemEvents.observe(
            interrupt: { [weak self] in self?.interrupt($0) },
            away: { [weak self] reason, on in self?.setAway(reason, on) },
            sweep: { [weak self] in self?.dictation.sweep() },
            screensChanged: { [weak self] in self?.screensChanged() })
    }

    // MARK: - AppCoordinating

    func start() {
        EnsembleLog.write("start (enabled=\(settings.enabled), camera=\(settings.cameraName ?? "automatic"), calibrated=\(ctx.pointer.isCalibrated), accessibility=\(AXIsProcessTrusted()), screens=\(ScreenFacts.displayFingerprint()))")
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
        tickTimer?.invalidate()
        tickTimer = commonModeTimer(1.0 / 20.0) { [weak self] in self?.tick() }
        refreshTimer?.invalidate()
        refreshTimer = commonModeTimer(1.0) { [weak self] in self?.refreshSessions() }
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
        refreshTimer?.invalidate(); refreshTimer = nil
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
        pushOverlay()
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        EnsembleLog.write("shutdown")
        health.running = false
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        headphone.stop()
        ctx.bridge.beginShutdown()
        engine.stop()
        scroll.cancel()
        dictation.shutdown()
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
        CalibrationController.shared.run(screens: plan.screens, note: plan.note, feed: feed, clickedAt: clickedAt) { [weak self] results in
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
            let ok = self.ctx.setup.storeCalibration(results, purpose: plan.purpose)
            if !ok { self.ctx.refuse("Calibration did not fit; try again sitting where you normally work") }
            else if let failure { self.ctx.refuse(failure) }
            self.health.update()
        }
        // Calibration owns the hands and the head: end any dictation first, because
        // gesture events are ignored while it runs and a held talk pose would never be seen released.
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "calibrating") }
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
    }

    func exitGesturePractice() {
        practiceSink = nil
        gestures.reset()
        scroll.cancel()
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
    }

    // MARK: - Inputs

    private func handle(head: HeadObservation) {
        // A reading already in flight when the camera went off for the lock: nothing acts on it.
        if awayState.isAway { return }
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
            if ctx.handsBusy {
                // Hands on the keyboard or mouse: focus and the highlight stay where they are. The faded dot keeps
                // up with the nose so it comes back where you look; while dictating the edge warnings hold still.
                if ctx.listening == nil { dot.follow(nose: p, at: head.t, onSession: false) }
                EnsembleTrace.write(head.t, "head nose=\(Int(p.x)),\(Int(p.y)) paused faces=\(head.faceCount)")
            } else {
                // A pinch or scroll in progress holds everything still: the hand is in front of the face.
                let under = focus.observe(nose: p, at: head.t, held: gestures.pinchHeld || scroll.isActive)
                dot.follow(nose: p, at: head.t, onSession: under != nil)
                EnsembleTrace.write(head.t, "head nose=\(Int(p.x)),\(Int(p.y)) under=\(under?.id ?? "-") \(focus.traceState(at: head.t)) faces=\(head.faceCount)")
            }
        } else if head.faceCount != 1 && head.t - ctx.lastOneFaceT <= 1.5 {
            // A hand in front of the face hides it or reads as a second face for a moment: keep the last target and dot.
        } else {
            dot.clear()
            focus.forgetTarget()
        }
        dot.place(target: focus.target)
        pushOverlay()
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
        guard !state.calibrating else { return }
        let intents = gestures.push(hand)
        practiceSink?.tourPractice(hand: hand)
        if let sink = practiceSink {
            for intent in intents { sink.tourPractice(intent: intent) }
            return
        }
        if tourOpen { return }
        EnsembleTrace.write(hand.t, "hand present=\(hand.present ? 1 : 0) pose=\(hand.pose?.rawValue ?? "-") pinch=\(hand.pinch.map { String(format: "%.3f", $0) } ?? "-") palm=\(hand.palmCenter.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "-") \(gestures.traceState)\(intents.isEmpty ? "" : " -> \(intents)")")
        for intent in intents { apply(intent) }
        let onClaude = focus.target != nil || ctx.listening != nil
        let progress = ctx.cover.covered || !settings.enabled || !onClaude || ctx.handsBusy ? nil : gestures.progress
        ctx.gestureShowing = progress != nil
        ctx.overlay.setGesture(progress)
        dot.place(target: focus.target)
        pushOverlay()
    }

    private func handle(light: FrameLight) {
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

    private func tick() {
        dropStaleReadings()
        updateHandsBusy(now: CACurrentMediaTime())
        // Away: a deferred focus move must not land behind the lock screen.
        if !awayState.isAway, !ctx.handsBusy { focus.tick() }
        for intent in gestures.tick(now: CACurrentMediaTime()) {
            if let sink = practiceSink { sink.tourPractice(intent: intent) } else if !tourOpen { apply(intent) }
        }
        engine.setForceFullRate(needsFullRate)
        scroll.tick()
        let now = CACurrentMediaTime()
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

    /// Focus that has rested on one session for `SessionFit.settle` widens it to Claude's chat column, once per
    /// focus change. Never while away, paused for the keyboard or mouse, in the tour, dictating, sending, mid-gesture
    /// or mid-resize; the controller adds the checks every action on Claude makes (Claude in front, no recent input).
    private func fitFocusedSession(now: TimeInterval) {
        guard let id = fitTrigger.observe(focus.target?.id, at: now), let target = focus.target, target.id == id else { return }
        guard settings.fitFocusedSession, health.running, !awayState.isAway, !ctx.handsBusy, !tourOpen, practiceSink == nil,
              ctx.listening == nil, !ctx.busy, !send.inFlight, !send.afterStop, !send.earlyArmed,
              gestures.progress == nil, !panes.isRunning, !focus.userLeftClaude else { return }
        panes.autoFit(target)
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
    /// quiet time: no focus moves, no highlight moves, no gesture acted on, the dot and highlight faded out. The camera
    /// and tracking keep running so resuming is instant, and the dictation safety checks never pause. Keys the Return
    /// watch held back, keys Ensemble posts and the pointer moves of its own scrolls are not yours.
    private func updateHandsBusy(now: TimeInterval) {
        handsBusy.quiet = settings.pauseAfterInputSeconds
        let input = ClaudeBridge.lastHardwareInput(now: now)
        let ownPointerAt = HandsBusy.ownPointerAt(drags: ClaudeBridge.ownPointerEventsNow(),
                                                  ownScrollAt: ClaudeBridge.ownPointerMove.withLock { $0 }, now: now)
        let busy = handsBusy.update(now: now, keyAt: input.key, clickAt: input.click, scrollAt: input.scroll, moveAt: input.move,
                                    pointer: NSEvent.mouseLocation,
                                    ownKeyAt: max(lastHeldBackKeyAt, HeadphoneRemote.lastSyntheticKeyAt),
                                    ownPointerAt: ownPointerAt)
        ctx.overlay.setHandsOnInput(busy)
        guard busy != ctx.handsBusy else { return }
        ctx.handsBusy = busy
        EnsembleLog.write(busy ? "paused: keyboard or mouse in use" : "resumed: no keyboard or mouse use for \(settings.pauseAfterInputSeconds) s")
        // A gesture half made on either side of the pause never completes across it; a running dictation keeps its
        // place in the machine, so a double pinch afterwards still stops it.
        let talking = gestures.talking
        gestures.reset()
        if talking { gestures.beginTalkExternally() }
        if busy {
            focus.clearDeferred()
            scroll.cancel()
            panes.cancel()
            if send.earlyArmed { send.dropEarly() }
            if send.afterStop, !send.returnSendPending { send.afterStop = false }
            ctx.gestureShowing = false
            ctx.overlay.setGesture(nil)
        }
        health.update()
        pushOverlay()
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

    private func refreshSessions() {
        health.checkPermissions()
        let claudeUp = ctx.bridge.claudeIsRunning()
        dictation.dropIfClaudeGone(running: claudeUp)
        guard claudeUp else {
            health.sessionsScanned = false; ctx.sessions = []; ctx.claudeDictations.forgetAll()
            focus.forgetAll(); send.forget(); scroll.cancel(); health.update(); return
        }
        if awayState.isAway { reconcileAway() }
        // No refresh while dictating: a slow Claude tree walk would otherwise trip the Accessibility stall limit mid-hold.
        guard !refreshInFlight, ctx.listening == nil else { return }
        // Nobody in front of the camera for 5 s: the window scan (which also costs Claude's own process) runs
        // every 5 s instead of every second, and immediately when a face comes back.
        let now = CACurrentMediaTime()
        guard now - ctx.lastOneFaceT < Self.sessionScanFaceWindow || now - lastSessionScan >= Self.sessionScanIdleInterval else { return }
        lastSessionScan = now
        refreshInFlight = true
        Task { @MainActor in
            defer { self.refreshInFlight = false }
            let epoch = self.ctx.dictationEpoch
            let scan = await self.ctx.bridge.refreshSessions()
            let found = scan.sessions
            // A read taken before Ensemble started, took over or stopped a dictation would report Ensemble's own.
            if epoch == self.ctx.dictationEpoch, self.ctx.listening == nil {
                let before = self.ctx.claudeDictations.recording
                self.ctx.claudeDictations.observe(present: found.map(\.id), recordingNow: scan.recording, at: CACurrentMediaTime())
                let now = self.ctx.claudeDictations.recording
                if now != before { EnsembleLog.write("Claude is dictating without Ensemble in \(now.count) session(s)") }
            }
            if found.map(\.id) != self.ctx.sessions.map(\.id) { EnsembleLog.write("Claude sessions found: \(found.count) (named \(found.filter { $0.title != nil }.count)) \(found.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" })") }
            self.ctx.sessions = found
            self.health.sessionsScanned = true
            self.health.update()
        }
    }

    // MARK: - Intents and cross-cutting steps

    private func apply(_ intent: GestureIntent) {
        switch intent {
        case .scroll, .dragScroll: break
        default: EnsembleLog.write("gesture: \(intent)")
        }
        if ctx.handsBusy {
            // Paused: nothing a gesture asks for is done, except stopping a dictation, which only ever turns the
            // microphone off. The machine forgets a start it announced, so the next double pinch starts again.
            switch intent {
            case .talkBegan: gestures.abortTalk()
            case .talkEnded(let reason): if ctx.listening != nil { dictation.end(reason: reason.rawValue) }
            default: break
            }
            return
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
        // Paused for the keyboard or mouse: only a press that stops a running dictation is acted on.
        if ctx.handsBusy, !(action == .press && ctx.listening != nil) { ctx.refuse("Paused while you type or use the mouse"); return }
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
    }

    private func pushOverlay() {
        dictation.restoreAudioIfIdle()
        let acting = ctx.listening ?? (gestures.progress?.action == .send ? send.lastSpoken?.session : nil) ?? focus.target
        ctx.overlay.setSession(name: acting.map(ctx.name(of:)), switching: focus.switching())
        ctx.overlay.setEdge(dot.overlayEdge(focus: focus))
        ctx.overlay.update(target: ctx.targetFrame, nose: ctx.nosePoint, listening: state.listening,
                           showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        health.update()
    }
}
