import Foundation
import EnsembleCore
import QuartzCore

/// Sends what was dictated when a thumbs-up asks for it, if nothing has changed since.
@MainActor
final class SendController {
    private let ctx: CoordinatorContext
    private(set) var lastSpoken: (session: ClaudeSession, stoppedAt: Date)?
    /// Thumbs-up made straight from the fist, or Return pressed twice while dictating: send once the stop is confirmed.
    var afterStop = false {
        didSet {
            guard !afterStop else { return }
            afterStopByReturn = false
            if !inFlight { showSending(nil) }
        }
    }
    /// The pending send was asked for with Return, so the Return presses are not "typing since dictation".
    var afterStopByReturn = false
    /// For a send asked for with Return: seconds since a click or any key other than those Returns.
    /// Called on the bridge queue at the press as well, so it must not touch main-thread state.
    var returnInputAge: @Sendable () -> Double = { ClaudeBridge.secondsSinceTypingOrClick() }
    /// The stop sound for the dictation this send followed, through the same look at Claude's own sound as the stop.
    var playStopSound: () -> Void = { Notifier.shared.playDictationSound(.stop) }
    /// A send is between its request and its result (reading the draft, waiting for it to settle, pressing Send).
    private(set) var inFlight = false {
        didSet { if !inFlight { inFlightByReturn = false } }
    }
    private var inFlightByReturn = false
    /// A send asked for with Return is pending or in flight: the key watch stays on until it ends, so a key typed
    /// meanwhile is seen and refuses it.
    var returnSendPending: Bool { afterStopByReturn || (inFlight && inFlightByReturn) }

    /// The session the nose is on, for a dictation Claude ran there without Ensemble (wired by the Coordinator).
    var lookedAt: () -> ClaudeSession? = { nil }

    /// A thumbs-up made while dictating, sent as one motion (`EarlySend`): stopped when recognised, settled during
    /// the hold, pressed when the hold completes.
    private var early = EarlySend()
    private var earlySession: ClaudeSession?
    private var earlyText: String?
    /// The hand dropped before the hold completed while the stop was still under way: "Kept, not sent" once it lands.
    private var keptWhenStopped = false
    var earlyArmed: Bool { early.isArmed }
    var earlyHoldPending: Bool { early.isArmed && !early.holdCompleted }

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    func spoke(in session: ClaudeSession) { lastSpoken = (session, Date()) }
    func forget() { lastSpoken = nil }

    /// A send was asked for while dictating: the island shows "Sending" from now until the result, as one step,
    /// instead of falling back to the dictation and folding away while the stop completes.
    func sendAfterStop(in session: ClaudeSession?, byReturn: Bool = false) {
        afterStop = true
        if byReturn { afterStopByReturn = true }
        showSending(session)
    }

    // MARK: - A thumbs-up while dictating, as one motion

    /// The thumbs-up was recognised while dictating and the stop begins now.
    func armEarly(in session: ClaudeSession) {
        early.arm(at: CACurrentMediaTime())
        earlySession = session
        earlyText = nil
        keptWhenStopped = false
        EnsembleLog.write("thumbs-up while dictating: stopping now, sending when the hold completes")
    }

    /// The stop under an early send is confirmed: the transcript settles while the hold runs. True when this send (or
    /// its "Kept, not sent") speaks for the stop, so no "Dictation stopped" banner or cue plays in between.
    func earlyStopConfirmed(_ session: ClaudeSession) -> Bool {
        if keptWhenStopped {
            keptWhenStopped = false
            showKept(session)
            return true
        }
        guard early.isArmed else { return false }
        _ = early.stopWasConfirmed(at: CACurrentMediaTime())
        let armedAt = early.armedAt
        Task { @MainActor in
            let text = await self.settledDraft(session)
            // Dropped, let go or re-armed meanwhile: this reading belongs to nothing.
            guard self.early.isArmed, self.early.armedAt == armedAt else { return }
            self.earlyText = text
            self.applyEarly(self.early.draftSettled(at: CACurrentMediaTime()))
        }
        return true
    }

    /// The stop under an early send was not confirmed: nothing is sent.
    func earlyStopFailed() {
        keptWhenStopped = false
        guard early.isArmed else { return }
        let held = early.holdCompleted
        applyEarly(early.stopFailed())
        if held { finish("Not sent: the stop was not confirmed") }
    }

    /// The thumbs-up hold completed: "Sending" now, and Send is pressed at once if the draft is already stable.
    func earlyHoldCompleted() {
        showSending(earlySession)
        applyEarly(early.holdWasCompleted(at: CACurrentMediaTime()))
    }

    /// From the 20 Hz tick while the hold runs: whether the send pose is still held.
    func earlyObserve(holding: Bool) {
        let stopped = early.stopConfirmed
        guard early.observe(holding: holding, at: CACurrentMediaTime()) == .keptNotSent else { return }
        let session = earlySession
        earlySession = nil
        earlyText = nil
        EnsembleLog.write("thumbs-up let go before the hold completed; the text stays unsent")
        if stopped, let session { showKept(session) } else { keptWhenStopped = true }
    }

    /// Sleep, a lock, switching off or an interrupted dictation: forget the early send without a word.
    func dropEarly() {
        early.drop()
        earlySession = nil
        earlyText = nil
        keptWhenStopped = false
        if !inFlight { showSending(nil) }
    }

    private func applyEarly(_ outcome: EarlySend.Outcome) {
        switch outcome {
        case .wait: return
        case .dropped, .keptNotSent:
            earlySession = nil
            earlyText = nil
        case .press:
            pressEarly()
        }
    }

    private func showKept(_ session: ClaudeSession) {
        ctx.overlay.showBanner(title: "Kept, not sent", body: ctx.name(of: session), style: .stopped, seconds: 2.5)
        playStopSound()
    }

    /// Every send rule again, right before the press: the gesture send setting, Claude in front, nothing else started,
    /// the stop counted as dictated (an interrupted dictation never does), the common refusals, no typing since the
    /// dictation ended, and a draft that is not empty. The bridge checks Claude in front and no typing or click since
    /// the dictation ended once more at the press, on its own queue.
    private func pressEarly() {
        let timeline = early.timeline()
        early.drop()
        let session = earlySession, text = earlyText
        earlySession = nil
        earlyText = nil
        inFlight = true
        EnsembleLog.write("send timeline: \(timeline)")
        guard ctx.settings.mapping.send != nil, let session else { finish(nil); return }
        guard claudeInFront() else { finish(nil); return }
        guard ctx.listening == nil, !ctx.busy else { finish("Send dropped: something else started"); return }
        guard let spoken = lastSpoken, spoken.session.id == session.id else { finish(nil); return }
        let inputAge = ClaudeBridge.secondsSinceTypingOrClick()
        if let why = ctx.commonRefusal(inputAge: inputAge) { finish("Not sent: \(why)"); return }
        if let why = SendRules.typedRefusal(spokenAgo: Date().timeIntervalSince(spoken.stoppedAt), inputAge: inputAge) {
            finish(why); return
        }
        guard let text else { finish("Could not read the dictated session's message box"); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { finish("The draft is empty"); return }
        EnsembleLog.write("sending (\(text.count) characters)")
        sendNow(session, shown: text, stoppedAt: spoken.stoppedAt, inputAge: { ClaudeBridge.secondsSinceTypingOrClick() })
    }

    /// The stop a pending send waited for is confirmed: send once the transcript has settled.
    func stopConfirmedForSend() {
        let byReturn = afterStopByReturn
        inFlight = true
        afterStop = false
        request(byReturn: byReturn, settle: true)
    }

    /// `byReturn`: asked for with Return pressed twice, not a gesture, so the gesture send setting does not apply and
    /// the Returns themselves do not count as typing. Every other rule is the same.
    /// `settle`: the dictation stopped a moment ago; wait for Claude to finish the transcript before reading it.
    func request(byReturn: Bool = false, settle: Bool = false) {
        inFlight = true
        inFlightByReturn = byReturn
        guard byReturn || ctx.settings.mapping.send != nil else { finish(nil); return }
        let inputAge: @Sendable () -> Double
        if byReturn { inputAge = returnInputAge } else { inputAge = { ClaudeBridge.secondsSinceTypingOrClick() } }
        // Acting only on Claude: a thumbs-up made while another app is in front sends nothing.
        guard claudeInFront() else { finish(nil); return }
        guard ctx.listening == nil, !ctx.busy else {
            finish("Send ignored: busy (\(ctx.listening != nil ? "still listening" : "a step in flight"))")
            return
        }
        if let why = ctx.commonRefusal(inputAge: inputAge()) { finish(why); return }
        // Ensemble's own dictation, or one Claude ran in the looked-at session that the refresh saw end; the most recent.
        let here = lookedAt()
        let picked = SendRules.dictated(ensembleAgo: lastSpoken.map { Date().timeIntervalSince($0.stoppedAt) },
                                        claudeAgo: ctx.claudeDictations.endedAgo(here?.id, now: CACurrentMediaTime()))
        if let why = SendRules.refusal(spokenAgo: picked?.ago, inputAge: inputAge()) { finish(why); return }
        if let picked, picked.source == .claude, let here {
            EnsembleLog.write("sending a dictation Claude ran without Ensemble (ended \(Int(picked.ago)) s ago)")
            lastSpoken = (here, Date().addingTimeInterval(-picked.ago))
        }
        guard let spoken = lastSpoken else { finish(nil); return }
        let session = spoken.session
        showSending(session)
        let bridge = ctx.bridge
        Task { @MainActor in
            // CoreAudio can stall while devices change; never read it on the main thread.
            if let other = await Task.detached(operation: { bridge.otherProcessCapturingInput() }).value {
                self.finish("\(other) is using a microphone"); return
            }
            let text = settle ? await self.settledDraft(session) : await bridge.draftText(session)
            // nil: the pane it was dictated into is not where it was (a layout change, a closed window); no other
            // pane's draft is read in its place.
            guard let text else { self.finish("Could not read the dictated session's message box"); return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.finish("The draft is empty"); return
            }
            // The draft read takes a moment; a new dictation or keystroke may have started meanwhile.
            guard self.ctx.listening == nil, !self.ctx.busy else { self.finish("Send dropped: something else started"); return }
            // An interruption (lock, sleep, switch-off) forgets the dictation: it is never sent afterwards.
            guard self.lastSpoken?.stoppedAt == spoken.stoppedAt else { self.finish(nil); return }
            guard self.claudeInFront() else { self.finish(nil); return }
            if let why = self.ctx.commonRefusal(inputAge: inputAge()) { self.finish("Not sent: \(why)"); return }
            if let why = SendRules.typedRefusal(spokenAgo: Date().timeIntervalSince(spoken.stoppedAt), inputAge: inputAge()) {
                self.finish(why); return
            }
            EnsembleLog.write("sending (\(text.count) characters)")
            self.sendNow(session, shown: text, stoppedAt: spoken.stoppedAt, inputAge: inputAge)
        }
    }

    /// Reads the draft until it has stopped changing (`DraftSettle`): a final transcript goes out after the quiet
    /// time instead of a fixed wait, and one Claude is still writing is waited for.
    private func settledDraft(_ session: ClaudeSession) async -> String? {
        var settle = DraftSettle(start: CACurrentMediaTime(), first: await ctx.bridge.draftText(session))
        while true {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if settle.observe(await ctx.bridge.draftText(session), at: CACurrentMediaTime()) { break }
        }
        EnsembleLog.write("transcript settled after \(Int((CACurrentMediaTime() - settle.start) * 1000)) ms (last change at \(Int(settle.lastChangeAfter * 1000)) ms)")
        return settle.text
    }

    /// Refuses with the "Not sent" notice unless Claude is the app in front. The bridge checks again right before the press.
    private func claudeInFront() -> Bool {
        guard let why = SendRules.frontRefusal(claudeInFront: ctx.bridge.claudeIsFrontmost()) else { return true }
        showSending(nil)
        ctx.refuse("Not sent: \(why)")
        return false
    }

    /// Ends a send that will not press Send: the "Sending" step gives way to the refusal (or nothing).
    private func finish(_ refusal: String?) {
        inFlight = false
        showSending(nil)
        // Every refusal of a send reads as "Not sent", so the island goes from "Sending" straight to the reason.
        if let refusal { ctx.refuse(refusal.hasPrefix("Send") || refusal.hasPrefix("Not sent") ? refusal : "Not sent: \(refusal)") }
    }

    private func showSending(_ session: ClaudeSession?) {
        ctx.overlay.setSending(name: session.map(ctx.name(of:)))
    }

    private func sendNow(_ session: ClaudeSession, shown: String, stoppedAt: Date, inputAge: @escaping @Sendable () -> Double) {
        guard claudeInFront() else { finish(nil); return }
        ctx.busy = true
        Task { @MainActor in
            let result = await self.ctx.bridge.sendDraft(session, shown: shown, stoppedAt: stoppedAt, inputAge: inputAge)
            self.ctx.busy = false
            switch result {
            case .done:
                EnsembleLog.write("sent"); self.lastSpoken = nil; Notifier.shared.playCue(.send)
                if !self.inFlightByReturn, !self.ctx.headphoneActive { self.ctx.usage.count(.gestureSucceeded(.thumbsUp)) }
                self.ctx.claudeDictations.forget(session.id)
                self.inFlight = false
                // "Sending" turns straight into "Sent": the banner replaces it in the same update.
                self.ctx.overlay.showBanner(title: "Sent", body: self.ctx.name(of: session), style: .sent, seconds: 1.5)
                self.showSending(nil)
            case .refused(let why): self.finish("Not sent: \(why)")
            case .unknown(let why):
                // Send was pressed but not confirmed: a second thumbs-up must not press it again.
                self.lastSpoken = nil
                self.finish("Not sent: \(why)")
            }
        }
    }
}
