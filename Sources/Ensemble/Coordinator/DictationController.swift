import AppKit
import Combine
import EnsembleCore

/// Starts and stops Claude's dictation and keeps it safe while it runs: pauses other audio, watches for typing,
/// leaving, another microphone user or a changed input device, and records each episode for the safety check.
@MainActor
final class DictationController {
    private let ctx: CoordinatorContext
    private let focus: FocusController
    private let send: SendController
    private let safety: DictationSafety
    private let meter = AudioLevelMeter()
    /// Fades out and pauses other audio on speakers while dictating, so it is not transcribed.
    private let ducker = MediaDucker()
    private var duckWanted = false
    private var disarming = false            // "Clear and disarm" is stopping the microphone
    /// A start press is between the press request and its result; it could still turn the microphone on.
    private var startInFlight = false
    /// Switching off gave up waiting for a start press: stop that dictation the moment the press lands.
    private var stopWhenStarted = false
    /// Sleep, a lock or the safety check interrupted this dictation at some point: its stop is immediate and
    /// it is never sendable, whichever route ends up stopping it. Cleared when the next dictation begins.
    private var interrupted = false
    private var cancellables = Set<AnyCancellable>()
    /// Claude's process when the dictation began: a different (or missing) one later means the dictation is gone.
    private var processID: pid_t?
    private var startedAt: TimeInterval = 0
    /// Input device at the start of the dictation; a change mid-dictation stops it.
    private var inputDevice: String?
    private var lastAudioCheck: TimeInterval = 0
    private var audioCheckInFlight = false
    /// Wait this long after the hand opens before stopping, so the last word is caught.
    private static let stopTail = 0.4
    /// A thumbs-up made while dictating is recognised only after 0.35 s of the pose, which already holds the last
    /// word; the short tail keeps the stop (and the transcript settle after it) inside the send hold.
    static let sendStopTail = 0.1

    /// Ends everything that was about to act and stops the dictation (wired by the Coordinator).
    var interrupt: (String) -> Void = { _ in }
    /// Every stop's outcome, by any route: true when the microphone was confirmed off (wired by the Coordinator).
    var stopResolved: (Bool) -> Void = { _ in }
    /// Runs right before a start, with the lid closed moves the default input to a microphone that works; returns why
    /// the dictation must not start, or nil (wired by the Coordinator).
    var prepareMicrophone: () async -> String? = { nil }

    init(ctx: CoordinatorContext, focus: FocusController, send: SendController) {
        self.ctx = ctx
        self.focus = focus
        self.send = send
        safety = DictationSafety(bridge: ctx.bridge)
        meter.onLevel = { [weak self] v in
            guard let self else { return }
            self.ctx.overlay.setAudioLevel(v)
            if self.meter.isRunning { self.ctx.speech.note(level: v, at: CACurrentMediaTime()) } else { self.ctx.speech.meterStopped() }
        }
        ctx.overlay.setLiveSoundBars(ctx.settings.liveSoundBars)
        ctx.settings.$liveSoundBars.dropFirst().sink { [weak self] on in
            guard let self else { return }
            self.ctx.overlay.setLiveSoundBars(on)
            if !on { self.meter.stop() } else if self.ctx.listening != nil { self.meter.start() }
        }.store(in: &cancellables)
        safety.onAlarm = { [weak self] msg in
            self?.ctx.refuse("Alarm: \(msg)")
            Notifier.shared.alarm(title: "Claude's microphone may still be on", body: msg)
        }
        safety.onMuted = { [weak self] muted in
            self?.ctx.state.muted = muted
            if !muted { Notifier.shared.resolveAlarm() }   // the mute is undone only after a definite "off"
        }
        // The alarm ends only after a definite "off". With no safety mute in effect (it could not be set), nothing
        // else would ever clear the island banner; with one, the unmute above clears it.
        safety.onAlarmEnded = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ctx.state.muted else { return }
                Notifier.shared.resolveAlarm()
            }
        }
        safety.onSafetyStop = { [weak self] stop in
            MainActor.assumeIsolated { self?.ctx.usage.count(.safetyStop(stop)) }
        }
        safety.onHoldEnded = { [weak self] why in
            MainActor.assumeIsolated {
                guard let self, self.ctx.listening != nil else { return }
                self.ctx.refuse("The safety check stopped dictation (\(why))")
                self.interrupt("safety check: \(why)")
            }
        }
    }

    // MARK: - Start and stop

    func begin() {
        guard ctx.listening == nil, !ctx.busy, !disarming else {
            if ctx.listening == nil || ctx.busy { ctx.gestures.abortTalk() }
            return
        }
        if let why = ctx.commonRefusal(checkInput: false) { refuseStart(why); return }
        guard ctx.calibratedHere else { refuseStart("Calibrate first (or recalibrate for this screen arrangement)"); return }
        guard let session = focus.target else {
            // No session at all while Claude runs: its windows are on another Space, minimized or behind a
            // full-screen app, and pointing better cannot help.
            refuseStart(ctx.sessions.isEmpty && ctx.bridge.claudeIsRunning() ? "Claude isn't on screen" : "Your nose is not on a Claude session",
                        resolves: .whenOnSession)
            return
        }
        send.afterStop = false; send.dropEarly(); focus.clearDeferred()
        interrupted = false
        // Busy from here: no second start, and switching off waits for this one.
        ctx.busy = true
        startInFlight = true
        let bridge = ctx.bridge
        Task { @MainActor in
            // CoreAudio and the safety queue can stall while devices change; neither is waited on from the main thread.
            let other = await Task.detached { bridge.otherProcessCapturingInput() }.value
            if other == nil {
                // Claude may already be dictating here, started with its own button or shortcut: the double pinch then
                // stops it. Never start while it is on, and never press a checkbox whose state is unclear.
                switch ClaudeDictation.talkStep(target: await bridge.micState(session)) {
                case .start:
                    // Claude's microphone is off and nothing has been written or pressed yet, so this is the one moment
                    // the default input may change without tripping the input-device check of any dictation.
                    if let why = await self.prepareMicrophone() {
                        self.ctx.busy = false
                        self.startInFlight = false
                        self.refuseStart(why)
                        self.ctx.changed()
                        return
                    }
                case .stopRunning:
                    if let why = await self.takeOver(session, reason: "double pinch") {
                        self.ctx.busy = false
                        self.startInFlight = false
                        self.refuseStart(why)
                    }
                    self.ctx.changed()
                    return
                case .refuse(let why):
                    self.ctx.busy = false
                    self.startInFlight = false
                    self.refuseStart(why)
                    self.ctx.changed()
                    return
                }
            }
            let refusal: String?
            if let other { refusal = "\(other) is using a microphone" } else { refusal = await self.safety.episodeStarting(session: session) }
            // While those were read, the pose may have been released, the screen locked or Ensemble switched off.
            let called = self.disarming || self.stopWhenStarted || self.interrupted || !self.ctx.gestures.talking
                || self.ctx.commonRefusal(checkInput: false) != nil
            if refusal != nil || called {
                self.ctx.busy = false
                self.startInFlight = false
                self.stopWhenStarted = false
                // A written record stays until the standing check sees the microphone off for its settle window.
                if refusal == nil { self.safety.episodeEnded() }
                if let refusal { self.refuseStart(refusal) } else { self.ctx.gestures.abortTalk(); EnsembleLog.write("start called off before the press") }
                self.ctx.changed()
                return
            }
            self.ctx.listening = session
            self.ctx.ownDictation(in: session)
            self.processID = bridge.claudePID
            self.ctx.state.listening = true
            self.ctx.changed()
            // Other audio is paused before the microphone opens, so neither it nor the pause is transcribed; the
            // pause never lowers the volume, so the start cue after the press plays at full volume.
            if self.ctx.settings.pauseMediaWhileDictating { self.duckWanted = true; await self.ducker.duck() }
            let claudeOutputBefore = await Task.detached { Self.claudeOutputs() }.value
            HeadphoneRemote.noteMicChange()
            let result = await self.ctx.bridge.startDictation(session)
            HeadphoneRemote.noteMicChange()
            self.ctx.busy = false
            self.startInFlight = false
            // An interruption (lock, sleep, the safety check) while the press was in flight stops at once, like a switch-off.
            let switchedOff = self.disarming || self.stopWhenStarted || self.interrupted
            self.stopWhenStarted = false
            var confirmedOn = false
            if case .done = result { confirmedOn = true }
            // The hand may already have opened, or Ensemble been switched off, while the press was in flight.
            let next = DictationRules.afterStart(confirmedOn: confirmedOn, switchedOff: switchedOff, poseHeld: self.ctx.gestures.talking)
            switch result {
            case .done:
                EnsembleLog.write(next == .stopSwitchedOff ? "dictation started after Ensemble was switched off or interrupted; stopping it now" : "dictation started")
                if !self.ctx.headphoneActive { self.ctx.usage.count(.gestureSucceeded(.pinch)) }
                if self.ctx.settings.liveSoundBars, next != .stopSwitchedOff { self.meter.start() }
                self.startedAt = CACurrentMediaTime()
                self.inputDevice = await Task.detached { bridge.defaultInputDeviceName() }.value
                self.safety.episodeConfirmed()
                if DictationAudio.startSoundDue(after: next, soundsOn: self.ctx.settings.playSounds) {
                    self.playDictationSound(.start, check: Self.soundCheck(before: claudeOutputBefore))
                }
                // Pressing the microphone can leave the keyboard on the button; a key typed while dictating belongs in
                // this session's message box.
                if next == .keepListening {
                    Task { @MainActor in EnsembleLog.write(await self.ctx.bridge.focusComposerIfNeeded(session)) }
                }
            case .refused(let why), .unknown(let why):
                self.ctx.listening = nil
                self.ctx.state.listening = false
                self.safety.episodeEnded()
                self.ctx.gestures.abortTalk()
                EnsembleLog.write("start dictation \(result): \(self.ctx.bridge.micSnapshot)")
                self.ctx.refuse(why == ClaudeDictation.alreadyDictating ? why : "Could not start dictation: \(why)", title: "Dictation not started")
                self.checkClaudeUpdate()
            }
            switch next {
            // The record stays until the stop is confirmed and capture has been off for the settle window.
            case .stopSwitchedOff: self.end(reason: "switched off while starting", immediate: true)
            case .stopReleased: self.end(reason: "released")
            case .keepListening, .notStarted: break
            }
            self.ctx.changed()
        }
    }

    /// `tail`: how long to wait before the stop press so the last word is caught; ignored when `immediate`.
    func end(reason: String, immediate: Bool = false, tail: TimeInterval? = nil) {
        guard let session = ctx.listening, !ctx.busy else { return }
        ctx.busy = true
        Task { @MainActor in
            if !immediate { try? await Task.sleep(nanoseconds: UInt64((tail ?? Self.stopTail) * 1e9)) }
            // An immediate stop waits on nothing, not even this read (CoreAudio can stall while devices change).
            let claudeOutputBefore: Int? = immediate ? nil : await Task.detached { Self.claudeOutputs() }.value
            HeadphoneRemote.noteMicChange()
            let result = await self.ctx.bridge.stopDictation(session)
            HeadphoneRemote.noteMicChange()
            // Whether Claude plays its own stop sound, looked at once for this stop: the stop banner's cue and a later
            // "Kept, not sent" cue both follow it, so neither doubles Claude's.
            if case .done = result { self.stopSoundCheck = Self.soundCheck(before: claudeOutputBefore) }
            self.ctx.busy = false
            self.ctx.listening = nil
            self.ctx.ownDictation(in: session)
            self.ctx.state.listening = false
            self.meter.stop()
            self.safety.episodeEnded()
            if self.ctx.gestures.talking { self.ctx.gestures.reset() }
            // Read after the stop: an interruption during the tail or the press counts as much as one before it.
            let sendable = DictationRules.sendableAfterStop(immediate: immediate, interrupted: self.interrupted)
            let sendWasPending = self.send.afterStop && !self.send.afterStopByReturn
            if case .done = result {} else { self.send.afterStop = false; self.focus.clearAfterStop() }
            switch result {
            case .done:
                EnsembleLog.write("dictation stopped")
                if let next = self.focus.afterStop {
                    self.focus.clearAfterStop()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        // Typing or a new dictation during the pause means the user is working here: do not move focus.
                        guard self.ctx.listening == nil, !self.ctx.busy, !self.focus.userLeftClaude, ClaudeBridge.secondsSinceTypingOrClick() >= CoordinatorContext.inputQuiet else { return }
                        _ = await self.ctx.bridge.focus(next, unlessTypedWithin: CoordinatorContext.inputQuiet)
                    }
                }
                self.ctx.settings.lastClaudeVersion = self.ctx.bridge.claudeVersion
                // An interrupted dictation (sleep, lock, safety stop) is never sent by a later thumbs-up.
                if sendable { self.send.spoke(in: session) } else { self.send.afterStop = false; self.send.dropEarly() }
                if self.send.afterStop {
                    // One step on the island and one sound: "Sending" runs on into "Sent" with the send cue, so
                    // neither the stopped banner nor the stop cue plays in between.
                    self.send.stopConfirmedForSend()
                } else if self.send.earlyStopConfirmed(session) {
                    // A thumbs-up is still being held (or was let go): its "Sent" or "Kept, not sent" speaks for this stop.
                } else {
                    self.ctx.overlay.showBanner(title: "Dictation stopped", body: self.ctx.name(of: session), style: .stopped, seconds: 2.5)
                    if self.ctx.settings.playSounds { self.playStopSound() }
                }
                self.stopResolved(true)
            case .refused(let why), .unknown(let why):
                EnsembleLog.write("stop dictation \(result): \(self.ctx.bridge.micSnapshot)")
                self.ctx.refuse("Stop not confirmed (\(why)); the safety check keeps watching")
                // A Return-asked send says so through stopResolved; a gesture-asked one says so here.
                if sendWasPending { self.ctx.refuse("Not sent: the stop was not confirmed") }
                self.send.earlyStopFailed()
                self.stopResolved(false)
                self.checkClaudeUpdate()
            }
            self.ctx.changed()
        }
    }

    /// How many Claude processes (helpers included) are sending audio out; nil when CoreAudio cannot be read.
    nonisolated static func claudeOutputs() -> Int? {
        CoreAudioInput.processes()?.filter { $0.isRunningOutput && $0.bundleID.hasPrefix(ClaudeLabels.bundleID) }.count
    }

    /// The last confirmed stop's look at Claude's output: true when Ensemble should play the stop sound.
    private var stopSoundCheck: Task<Bool, Never>?

    /// Looks at Claude's output `DictationAudio.claudeSoundWindow` after a press: true when Ensemble should play.
    private static func soundCheck(before: Int?) -> Task<Bool, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(DictationAudio.claudeSoundWindow * 1e9))
            let after = await Task.detached { Self.claudeOutputs() }.value
            return DictationAudio.ensemblePlays(claudeOutputsBefore: before, claudeOutputsAfter: after)
        }
    }

    /// The stop sound for the last confirmed stop, unless Claude played its own: the stop banner's cue and the
    /// "Kept, not sent" cue of a thumbs-up let go both come here.
    func playStopSound() {
        playDictationSound(.stop, check: stopSoundCheck ?? Task { true })
    }

    /// Claude plays its dictation sounds only after a real user gesture, which Ensemble's press is not: unless
    /// Claude's output is seen rising right after the press, Ensemble plays Claude's sound itself. The output volume
    /// is never lowered (DictationAudio), and on Bluetooth the sound waits out the headset's profile switch.
    private func playDictationSound(_ sound: ClaudeDictationSound, check: Task<Bool, Never>) {
        let bluetooth = MediaDucker.defaultOutput().map(MediaDucker.isBluetooth) ?? false
        let delay = DictationAudio.soundDelay(outputIsBluetooth: bluetooth)
        let started = CACurrentMediaTime()
        Task { @MainActor in
            guard await check.value else {
                EnsembleLog.write("Claude played its own dictation \(sound == .start ? "start" : "stop") sound")
                return
            }
            let rest = delay - (CACurrentMediaTime() - started)
            if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1e9)) }
            Notifier.shared.playDictationSound(sound)
        }
    }

    enum TakeOver: Equatable {
        /// Claude was dictating there; its stop is under way through Ensemble's stop path.
        case stopping
        /// Nothing is recording there (or its state is unclear): nothing was pressed.
        case notDictating
        /// It could not be taken over now.
        case refused(String)
    }

    /// A send (thumbs-up, two Returns, a headphone double press) with no Ensemble dictation running. If Claude is
    /// dictating in `session`, whoever started it, Ensemble takes that dictation over and stops it through its own
    /// stop path. `beforeStop` runs before the stop begins, so the stop's end already sees the send it asked for.
    func takeOverIfDictating(_ session: ClaudeSession, reason: String, beforeStop: () -> Void) async -> TakeOver {
        guard ctx.listening == nil, !ctx.busy, !disarming else { return .refused("a step is still in flight") }
        ctx.busy = true
        startInFlight = true
        interrupted = false
        let state = await ctx.bridge.micState(session)
        guard ClaudeDictation.sendStep(target: state) == .stopThenSend else {
            ctx.busy = false
            startInFlight = false
            return .notDictating
        }
        beforeStop()
        if let why = await takeOver(session, reason: reason) {
            ctx.busy = false
            startInFlight = false
            return .refused(why)
        }
        return .stopping
    }

    /// Takes over a dictation Claude is running in `session` that Ensemble did not start, and stops it the way
    /// Ensemble stops its own: the safety record is on disk before the stop press (written before pressed), the hold
    /// and the dead-man check run until the stop, only a definite "off" confirms it, and a confirmed stop counts as
    /// dictated just now for the send window. Runs with `ctx.busy` set; returns why not, or nil once the stop is under way.
    private func takeOver(_ session: ClaudeSession, reason: String) async -> String? {
        if let refusal = await safety.episodeStarting(session: session) { return refusal }
        ctx.listening = session
        ctx.ownDictation(in: session)
        processID = ctx.bridge.claudePID
        ctx.state.listening = true
        startedAt = CACurrentMediaTime()
        inputDevice = nil
        safety.episodeConfirmed()
        EnsembleLog.write("Claude was already dictating in this session; stopping it the way Ensemble stops its own (\(reason))")
        // Switched off, asleep or locked meanwhile: stop at once, and never send it.
        let immediate = disarming || stopWhenStarted || interrupted
        stopWhenStarted = false
        ctx.busy = false
        startInFlight = false
        end(reason: reason, immediate: immediate)
        return nil
    }

    /// Sleep, a lock or the safety check interrupted whatever dictation is starting, running or stopping.
    func markInterrupted() {
        if ctx.listening != nil || startInFlight { interrupted = true }
    }

    func endWhenIdle(reason: String, immediate: Bool = false) {
        Task { @MainActor in
            for _ in 0..<30 where self.ctx.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            if self.ctx.listening != nil { self.end(reason: reason, immediate: immediate) }
        }
    }

    /// The machine already flipped to talking when it announced the start; a refusal must flip it back,
    /// or the next double tap would be read as a stop.
    private func refuseStart(_ why: String, resolves: RefusalNotice.Resolves = .byTime) {
        ctx.gestures.abortTalk()
        ctx.refuse(why, title: "Dictation not started", resolves: resolves)
    }

    // MARK: - While it runs

    /// A fresh camera frame arrived: the engine is alive.
    func heartbeat() {
        if ctx.listening != nil { safety.heartbeat() }
    }

    /// From the 20 Hz tick. With the hand free while dictating, other signals end it: you take the keyboard or
    /// mouse, you leave, another app opens a microphone, or the input device changes.
    func supervise(now: TimeInterval) {
        if ctx.listening != nil, !ctx.busy, now - startedAt > 1.5 {
            if ClaudeBridge.secondsSinceTypingOrClick() < 0.3 { ctx.refuse("Typing or a click; dictation stopped"); ctx.usage.count(.safetyStop(.typingOrClick)); end(reason: "input"); return }
            if now - ctx.lastOneFaceT > 10 {
                ctx.refuse("No face for 10 seconds; dictation stopped")
                ctx.usage.count(.safetyStop((ctx.latestHead?.faceCount ?? 0) > 1 ? .multipleFaces : .noFace))
                end(reason: "away")
                return
            }
        }
        if let session = ctx.listening, !ctx.busy, !audioCheckInFlight, now - lastAudioCheck >= 0.5 {
            lastAudioCheck = now
            audioCheckInFlight = true
            let bridge = ctx.bridge, device = inputDevice
            // CoreAudio can stall for a while when a device is changing; never wait on it from the main thread.
            Task.detached {
                let other = bridge.otherProcessCapturingInput()
                let current = device == nil ? nil : bridge.defaultInputDeviceName()
                await MainActor.run {
                    self.audioCheckInFlight = false
                    guard self.ctx.listening?.id == session.id, !self.ctx.busy else { return }
                    if let other {
                        self.ctx.refuse("\(other) started using a microphone; dictation stopped")
                        self.ctx.usage.count(.safetyStop(.otherMicrophone))
                        self.end(reason: "other capturer")
                    } else if let device, current != device {
                        self.ctx.refuse("The input device changed; dictation stopped")
                        self.ctx.usage.count(.safetyStop(.inputDeviceChanged))
                        self.end(reason: "input device changed")
                    }
                }
            }
        }
    }

    /// Claude quit (or restarted) during the dictation: its microphone went with it, so there is nothing left
    /// to stop. Leaving the flag set would keep the red marker up and feed the safety heartbeat forever.
    func dropIfClaudeGone(running claudeUp: Bool) {
        guard ctx.listening != nil, !ctx.busy, !claudeUp || ctx.bridge.claudePID != processID else { return }
        EnsembleLog.write("Claude quit or restarted during dictation; clearing the listening state")
        drop()
        ctx.usage.count(.safetyStop(.claudeQuit))
        ctx.refuse("Claude quit; dictation ended")
    }

    /// Local teardown for a dictation whose Claude process is gone; there is no microphone to press.
    private func drop() {
        ctx.listening = nil
        processID = nil
        ctx.state.listening = false
        meter.stop()
        safety.episodeEnded()
        send.afterStop = false; focus.clearAfterStop()
        ctx.gestures.reset()
        stopResolved(false)
        ctx.changed()
    }

    /// Every dictation end passes through the overlay refresh: audio paused for it resumes.
    func restoreAudioIfIdle() {
        if duckWanted, ctx.listening == nil { duckWanted = false; ducker.restore() }
    }

    // MARK: - Leaving

    func sweep() {
        Task { await self.safety.launchSweep() }
    }

    func clearAndDisarm() {
        guard !disarming else { return }
        disarming = true
        send.afterStop = false
        ctx.gestures.reset()
        EnsembleLog.write("clear and disarm requested")
        Task { @MainActor in
            // A start press still in flight could turn the microphone on after the check below reads it off.
            let began = CACurrentMediaTime()
            waiting: while true {
                switch DictationRules.disarmStep(stepInFlight: self.ctx.busy, startInFlight: self.startInFlight, waited: CACurrentMediaTime() - began) {
                case .wait:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                case .proceed:
                    break waiting
                case .stopWhenStarted:
                    // The listening state and the safety record stay with the start; it stops the moment the press lands.
                    self.disarming = false
                    self.stopWhenStarted = true
                    EnsembleLog.write("clear and disarm: a start press is still in flight after \(Int(DictationRules.disarmWait)) s; it is stopped when it lands and the safety record stays")
                    self.ctx.refuse("Could not confirm the microphone is off; the safety check keeps watching")
                    self.ctx.changed()
                    return
                }
            }
            let result = await self.ctx.bridge.stopAnyDictation()
            let bridge = self.ctx.bridge
            // Read off the main thread: CoreAudio can stall while devices change.
            let capture = await Task.detached { () -> Bool? in
                var capture = bridge.claudeCaptureActive()
                for _ in 0..<15 where !DictationRules.confirmedOff(capture: capture) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    capture = bridge.claudeCaptureActive()
                }
                return capture
            }.value
            self.disarming = false
            self.ctx.listening = nil
            self.ctx.state.listening = false
            // An unreadable microphone state is not off: the record and any mute stay for the standing check.
            let cleared = DictationRules.confirmedOff(capture: capture) ? await self.safety.clearAndDisarm() : false
            if !cleared {
                EnsembleLog.write("clear and disarm: microphone still recording (stop \(result)); the safety check keeps watching")
                self.safety.episodeEnded()
                self.ctx.refuse("Could not confirm the microphone is off; the safety check keeps watching")
            } else {
                EnsembleLog.write("clear and disarm: microphone confirmed off")
            }
            self.ctx.changed()
        }
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        let session = ctx.listening
        ctx.listening = nil
        ducker.restoreNow()
        safety.stopForTermination(session: session)
    }

    /// A failure right after Claude updated may mean its controls changed: switch off and say why.
    private func checkClaudeUpdate() {
        guard let now = ctx.bridge.claudeVersion, let last = ctx.settings.lastClaudeVersion, now != last else { return }
        EnsembleLog.write("Claude updated \(last) -> \(now) and a dictation step failed; switching off")
        Notifier.shared.notify(title: "Ensemble switched off", body: "Claude updated to \(now) and its microphone controls did not respond as before.")
        ctx.settings.enabled = false
    }
}
