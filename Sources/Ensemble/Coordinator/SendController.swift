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
    var returnInputAge: () -> Double = { ClaudeBridge.secondsSinceTypingOrClick() }
    /// A send is between its request and its result (reading the draft, waiting for it to settle, pressing Send).
    private(set) var inFlight = false {
        didSet { if !inFlight { inFlightByReturn = false } }
    }
    private var inFlightByReturn = false
    /// A send asked for with Return is pending or in flight: the key watch stays on until it ends, so a key typed
    /// meanwhile is seen and refuses it.
    var returnSendPending: Bool { afterStopByReturn || (inFlight && inFlightByReturn) }

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
        let inputAge = { byReturn ? self.returnInputAge() : ClaudeBridge.secondsSinceTypingOrClick() }
        // Acting only on Claude: a thumbs-up made while another app is in front sends nothing.
        guard claudeInFront() else { finish(nil); return }
        guard ctx.listening == nil, !ctx.busy else {
            finish("Send ignored: busy (\(ctx.listening != nil ? "still listening" : "a step in flight"))")
            return
        }
        if let why = ctx.commonRefusal(inputAge: inputAge()) { finish(why); return }
        let spokenAgo = lastSpoken.map { Date().timeIntervalSince($0.stoppedAt) }
        if let why = SendRules.refusal(spokenAgo: spokenAgo, inputAge: inputAge()) { finish(why); return }
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
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            self.sendNow(session, shown: text, spokenAt: spoken.stoppedAt, byReturn: byReturn)
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

    private func sendNow(_ session: ClaudeSession, shown: String, spokenAt: Date, byReturn: Bool) {
        guard claudeInFront() else { finish(nil); return }
        ctx.busy = true
        // The same reader as the checks above, run on the bridge queue right before the press. The Return-send
        // reader's key record lives on the main thread, so it is read there.
        let inputAge: @Sendable () -> Double = byReturn
            ? { DispatchQueue.main.sync { MainActor.assumeIsolated { self.returnInputAge() } } }
            : { ClaudeBridge.secondsSinceTypingOrClick() }
        Task { @MainActor in
            let result = await self.ctx.bridge.sendDraft(session, shown: shown, spokenAt: spokenAt, inputAge: inputAge)
            self.ctx.busy = false
            switch result {
            case .done:
                EnsembleLog.write("sent"); self.lastSpoken = nil; Notifier.shared.playCue(.send)
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
