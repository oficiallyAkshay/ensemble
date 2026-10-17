import AppKit
import EnsembleCore
import Foundation

/// The rule this class enforces: Claude's microphone is never left recording because of this app.
/// It owns the crash-recovery episode file, a deadman for the hold, a standing check that runs even
/// when nothing is wrong, and the alarm + input-mute fallback for when stopping cannot be confirmed.
final class DictationSafety: @unchecked Sendable {
    private let bridge: ClaudeBridge
    private let queue = DispatchQueue(label: "ensemble.dictation-safety", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let callbackLock = NSLock()
    private var alarmHandler: ((String) -> Void)?
    private var alarmEndedHandler: (() -> Void)?
    private var mutedHandler: ((Bool) -> Void)?
    private var holdEndedHandler: ((String) -> Void)?

    var onAlarm: ((String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return alarmHandler }
        set { callbackLock.lock(); alarmHandler = newValue; callbackLock.unlock() }
    }
    /// The alarm ended because the microphone was confirmed off; called on the main queue.
    var onAlarmEnded: (() -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return alarmEndedHandler }
        set { callbackLock.lock(); alarmEndedHandler = newValue; callbackLock.unlock() }
    }
    /// The safety check ended the hold itself (no heartbeat, or Accessibility stalled); called on the main queue.
    var onHoldEnded: ((String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return holdEndedHandler }
        set { callbackLock.lock(); holdEndedHandler = newValue; callbackLock.unlock() }
    }
    var onMuted: ((Bool) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return mutedHandler }
        set { callbackLock.lock(); mutedHandler = newValue; callbackLock.unlock() }
    }

    // Everything below is confined to `queue`.
    private var episode: EpisodeRecord?
    private var session: ClaudeSession?
    private var holdActive = false
    private var lastHeartbeat = Date.distantPast
    private var holdEndedAt = Date.distantPast
    private var offSince: Date?
    /// Since when, with a record open and no hold, the microphone state could not be read.
    private var unreadableSince: Date?
    private var stopInFlight = false
    private var stopStartedAt: Date?
    private var stopReason = ""
    private var escalated = false
    private var sound: NSSound?
    private var muter = InputMuter()
    private var ticks = 0

    init(bridge: ClaudeBridge) {
        self.bridge = bridge
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    /// Runs `work` on the safety queue without blocking the caller's thread (the main thread, usually), since the
    /// queue can be busy with a CoreAudio read that stalls while devices change.
    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: work()) } }
    }

    // MARK: Episode lifecycle

    /// Records the episode on disk (fsynced) before anything presses the microphone control. Returns why the start
    /// is refused, or nil once the record is written; callers must not press unless it is nil. Refuses while an
    /// earlier dictation is still owed a confirmed stop, so that dictation's record, alarm and mute are never abandoned.
    func episodeStarting(session: ClaudeSession) async -> String? {
        await onQueue {
            let refusal = DictationRules.startRefusal(stopOwed: self.stopStartedAt != nil, alarmOn: self.escalated,
                                                      muteInEffect: self.muter.isActive && self.muter.anyDeviceConnected)
            return DictationRules.pressRefusal(refusal) { self.writeEpisode(session: session) }
        }
    }

    private func writeEpisode(session: ClaudeSession) -> Bool {
        let record = EpisodeRecord(id: UUID().uuidString, startedAt: Date(), pid: ProcessInfo.processInfo.processIdentifier,
                                   bootSessionUUID: SafetyFiles.bootSessionUUID(), sessionID: session.id,
                                   claudeVersion: bridge.claudeVersion)
        do { try SafetyFiles.writeEpisode(record) } catch { return false }
        episode = record
        self.session = session
        holdActive = true
        lastHeartbeat = Date()
        offSince = nil
        unreadableSince = nil
        return true
    }

    func episodeConfirmed() {
        queue.async { self.lastHeartbeat = Date() }
    }

    /// Call on every fresh frame in which the talk pose is held.
    func heartbeat() {
        let now = Date()
        queue.async { if self.holdActive { self.lastHeartbeat = now } }
    }

    /// The hold is over. The episode file stays until capture has been off for the settle window.
    func episodeEnded() {
        queue.async {
            self.holdActive = false
            self.holdEndedAt = Date()
            self.offSince = nil
        }
    }

    /// Forget everything: delete the episode file, undo our mute, silence the alarm. Refuses (returns false)
    /// unless Claude is definitely not capturing: while it captures, or while CoreAudio cannot say, the episode
    /// stays and the standing check keeps trying to stop it.
    func clearAndDisarm() async -> Bool {
        await onQueue { self.clearAndDisarmNow() }
    }

    private func clearAndDisarmNow() -> Bool {
        holdActive = false
        if !DictationRules.confirmedOff(capture: bridge.claudeCaptureActive()) {
            holdEndedAt = Date()
            offSince = nil
            return false
        }
        stopInFlight = false
        stopStartedAt = nil
        unreadableSince = nil
        episode = nil
        session = nil
        SafetyFiles.deleteEpisode()
        stopAlarm()
        restoreMute()
        return true
    }

    /// Quit path: stops Claude's dictation and undoes our mute before the process exits. The caller blocks for at
    /// most `timeout` seconds. If the stop cannot be confirmed, the input is muted and the episode file is left
    /// for the next launch's sweep, which restores the mute once capture is off.
    func stopForTermination(session: ClaudeSession?, timeout: TimeInterval = 2) {
        timer?.cancel()
        bridge.beginShutdown()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            self.terminationStop(session: session, deadline: Date().addingTimeInterval(timeout))
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            EnsembleLog.write("quit: the microphone stop did not finish within \(timeout) s")
        }
    }

    private func terminationStop(session: ClaudeSession?, deadline: Date) {
        // A start press already sent can open the microphone after a first "off" reading. Wait for it to land (one
        // not yet sent is refused by the shutdown flag); if it is still in flight at the deadline, nothing counts as off.
        while bridge.startPressInFlight, Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        let startInFlight = bridge.startPressInFlight
        if startInFlight { EnsembleLog.write("quit: a start press is still in flight; the safety record stays") }
        let (episodeOpen, remembered) = queue.sync { (episode != nil || holdActive || stopStartedAt != nil, self.session) }
        guard session != nil || episodeOpen || startInFlight || SafetyFiles.episodeFileExists() else {
            queue.sync { restoreMute() }
            return
        }
        var off = !startInFlight && bridge.claudeCaptureActive() == false
        if !off {
            let left = deadline.timeIntervalSinceNow
            let result = left > 0.1 ? bridge.stopDictationBlocking(session ?? remembered, timeout: left) : nil
            var capture = bridge.claudeCaptureActive()
            while !DictationRules.confirmedOff(capture: capture), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.075)
                capture = bridge.claudeCaptureActive()
            }
            // A stop that reported done without a definite "not capturing" reading is not proof: mute and keep the record.
            off = !bridge.startPressInFlight && DictationRules.confirmedOff(capture: capture)
            if !off { EnsembleLog.write("quit: stop \(result.map { "\($0)" } ?? "timed out"), capture \(capture.map(String.init) ?? "unreadable")") }
        }
        EnsembleLog.write("quit: microphone \(off ? "confirmed off" : "NOT confirmed off; muting the input")")
        queue.sync {
            if off {
                holdActive = false
                stopStartedAt = nil
                episode = nil
                self.session = nil
                SafetyFiles.deleteEpisode()
                stopAlarm()
                restoreMute()
            } else {
                _ = muter.apply()
            }
        }
    }

    // MARK: Timer

    private func tick() {
        ticks += 1
        let now = Date()
        switch DictationRules.holdLoss(holdActive: holdActive, heartbeatAge: now.timeIntervalSince(lastHeartbeat),
                                       longestStall: bridge.longestAXCallSeconds) {
        case .noHeartbeat: endHoldAndStop("no talk-pose heartbeat for \(Int(DictationRules.heartbeatTimeout)) s")
        case .stalled: endHoldAndStop("an Accessibility call stalled for more than \(Int(DictationRules.stallLimit)) s")
        case nil: break
        }
        if stopStartedAt != nil { driveStop(now) }
        if ticks % 4 == 0 {
            standingCheck(now)
            retryUnmute()
        }
    }

    private func endHoldAndStop(_ reason: String) {
        holdActive = false
        holdEndedAt = Date()
        let handler = onHoldEnded
        DispatchQueue.main.async { handler?(reason) }
        beginStop(reason)
    }

    /// Runs once a second: an episode on disk, Claude capturing, and no hold active means a stop is owed.
    private func standingCheck(_ now: Date) {
        guard DictationRules.standingCheckActs(recordOpen: episode != nil, holdActive: holdActive,
                                               sinceHoldEnded: now.timeIntervalSince(holdEndedAt)) else { return }
        let capture = bridge.claudeCaptureActive()
        switch capture {
        case .some(true):
            offSince = nil
            unreadableSince = nil
            if stopStartedAt == nil { beginStop("Claude is capturing audio with no hold active") }
        case .some(false):
            unreadableSince = nil
            if stopStartedAt != nil || escalated { stopConfirmed() }
            // The hold can end (an Accessibility stall, the dead-man check) while a start press is still queued or
            // running, and that press can open the microphone after this reading: off settles only once it has landed.
            let reading = DictationRules.offReading(offSince: offSince, now: now, startInFlight: bridge.startPressInFlight,
                                                    settle: DictationRules.settleWindow)
            offSince = reading.offSince
            if reading.recordMayGo { finishEpisode() }
        case .none:
            // Unreadable is never off. Left alone it could last for ever with nothing stopping or muting, so after a
            // while it is handled as a stop that cannot be confirmed: keep trying to stop, sound the alarm, mute.
            offSince = nil
            if unreadableSince == nil { unreadableSince = now }
            if DictationRules.escalateUnreadable(recordOpen: true, holdActive: holdActive,
                                                 unreadableFor: now.timeIntervalSince(unreadableSince!)) {
                if stopStartedAt == nil { beginStop("Claude's microphone state could not be read") }
                if !escalated { escalate("Claude's microphone state could not be read for \(Int(DictationRules.unreadableLimit)) s") }
            }
        }
    }

    /// A device unplugged while muted kept its mute record. Once it is back and no stop is owed, the mute is undone.
    private func retryUnmute() {
        guard muter.isActive, stopStartedAt == nil, !escalated, !holdActive, muter.anyDeviceConnected else { return }
        if episode != nil, !DictationRules.confirmedOff(capture: bridge.claudeCaptureActive()) { return }
        if muter.restore(logIncomplete: false) {
            EnsembleLog.write("safety mute undone on a reconnected input device")
            notifyMuted(false)
        }
    }

    // MARK: Stopping

    private func beginStop(_ reason: String) {
        if stopStartedAt == nil {
            stopStartedAt = Date()
            stopReason = reason
        }
        driveStop(Date())
    }

    /// One stop attempt at a time; retried every tick until capture is confirmed off.
    private func driveStop(_ now: Date) {
        if bridge.claudeCaptureActive() == false {
            stopConfirmed()
            return
        }
        if let started = stopStartedAt, DictationRules.escalateStop(alarmOn: escalated, owedFor: now.timeIntervalSince(started)) {
            escalate("Claude's microphone could not be confirmed off (\(stopReason))")
        }
        guard !stopInFlight else { return }
        stopInFlight = true
        let target = session
        Task { [weak self] in
            guard let self else { return }
            if let target {
                // A refused stop usually means the session moved or went away: try whichever session shows an active mic.
                if case .refused = await self.bridge.stopDictation(target) { _ = await self.bridge.stopAnyDictation() }
            } else {
                _ = await self.bridge.stopAnyDictation()
            }
            self.queue.async { self.stopInFlight = false }
        }
    }

    private func stopConfirmed() {
        stopStartedAt = nil
        stopInFlight = false
        unreadableSince = nil
        stopAlarm()
        restoreMute()
    }

    private func finishEpisode() {
        episode = nil
        session = nil
        offSince = nil
        unreadableSince = nil
        SafetyFiles.deleteEpisode()
        stopAlarm()
        restoreMute()
    }

    // MARK: Alarm and mute

    private func escalate(_ message: String) {
        escalated = true
        startAlarm()
        if muter.apply() { notifyMuted(true) }
        let handler = onAlarm
        DispatchQueue.main.async { handler?(message) }
    }

    private func startAlarm() {
        DispatchQueue.main.async {
            if self.sound == nil { self.sound = NSSound(named: "Sosumi") ?? NSSound(named: "Basso") }
            self.sound?.loops = true
            self.sound?.play()
        }
    }

    /// Called only once the microphone reads definitely off: ends the sound, and the island alarm if one was raised.
    private func stopAlarm() {
        let wasRaised = escalated
        escalated = false
        let handler = onAlarmEnded
        DispatchQueue.main.async {
            self.sound?.stop()
            self.sound = nil
            if wasRaised { handler?() }
        }
    }

    private func restoreMute() {
        guard muter.isActive || !SafetyFiles.readMutes().isEmpty else { return }
        muter = InputMuter()
        if muter.restore() { notifyMuted(false) }
    }

    private func notifyMuted(_ muted: Bool) {
        let handler = onMuted
        DispatchQueue.main.async { handler?(muted) }
    }

    // MARK: Launch and wake

    /// Run at launch and after wake. Acts only on evidence this app left behind: an episode file from the
    /// current boot while Claude is capturing means a recording of ours may still be running.
    func launchSweep() async {
        let hadLiveEpisode: Bool = await onQueue {
            guard let record = SafetyFiles.readEpisode() else { return false }
            if record.bootSessionUUID != SafetyFiles.bootSessionUUID() {
                SafetyFiles.deleteEpisode()
                return false
            }
            if self.episode == nil {
                self.episode = record
                self.session = nil
                self.holdActive = false
                self.holdEndedAt = .distantPast
            }
            return true
        }

        guard hadLiveEpisode else {
            await onQueue { if !self.holdActive { self.restoreMute() } }
            return
        }

        switch bridge.claudeCaptureActive() {
        case .some(false):
            // After wake a start press may still be in flight; the standing check then clears the record once it lands.
            await onQueue {
                if DictationRules.offReading(offSince: nil, now: Date(), startInFlight: self.bridge.startPressInFlight, settle: 0).recordMayGo {
                    self.finishEpisode()
                }
            }
        case .some(true):
            await onQueue { if self.stopStartedAt == nil { self.beginStop("recording found at launch from a previous run") } }
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if await onQueue({ self.episode == nil || self.escalated }) { break }
            }
        case .none:
            break
        }
    }

    // MARK: Test hooks

    var debugState: String {
        queue.sync {
            "episode=\(episode?.id ?? "none") hold=\(holdActive) stopping=\(stopStartedAt != nil) escalated=\(escalated) muteActive=\(muter.isActive)"
        }
    }
}
