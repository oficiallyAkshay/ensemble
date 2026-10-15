import ApplicationServices
import EnsembleCore
import CoreGraphics
import Foundation

extension ClaudeBridge {
    func draftText(_ s: ClaudeSession) async -> String? {
        await run { self.draftNow(s) }
    }

    private func draftNow(_ s: ClaudeSession) -> String? {
        guard let composer = liveEntry(s, rescanPane: true)?.elements.composer else { return nil }
        return AX.string(composer, kAXValueAttribute)
    }

    /// The permission-mode label exactly as Claude shows it ("Manual", "Plan", "Bypass permissions", ...).
    func permissionMode(_ s: ClaudeSession) async -> String? {
        await run { self.modeNow(s) }
    }

    private func modeNow(_ s: ClaudeSession) -> String? {
        guard let mode = liveEntry(s, rescanPane: true)?.elements.modeControl else { return nil }
        return AX.title(mode)
    }

    /// true while a Stop control is present; false when the composer is readable and has none; nil when unreadable.
    func isGenerating(_ s: ClaudeSession) async -> Bool? {
        await run { self.generatingNow(s) }
    }

    private func generatingNow(_ s: ClaudeSession) -> Bool? {
        guard let entry = liveEntry(s, rescanPane: true) else { return nil }
        if entry.elements.stopButton != nil { return true }
        return entry.elements.composer != nil ? false : nil
    }

    /// Presses Claude's own Send button. Refuses unless every guard holds; never types a key.
    /// `shown` is the draft read just before sending: if the composer no longer holds exactly that, nothing is sent.
    /// `spokenAt` is when the dictation stopped and `inputAge` the reader the caller checked typing with.
    func sendDraft(_ s: ClaudeSession, shown: String, spokenAt: Date, inputAge: @escaping @Sendable () -> Double) async -> BridgeResult {
        await run { self.sendNow(s, shown: shown, spokenAt: spokenAt, inputAge: inputAge) }
    }

    private func sendNow(_ s: ClaudeSession, shown: String, spokenAt: Date, inputAge: () -> Double) -> BridgeResult {
        guard let entry = liveEntry(s, rescanPane: true) else { return .refused(self.sessionNotFound) }
        let e = entry.elements

        // Any permission mode: the deliberate thumbs-up hold is the confirmation (owner decision, 2026-10-14).
        if e.stopButton != nil { return .refused("Claude is still generating") }
        guard let composer = e.composer else { return .refused("composer not found") }

        let micState = micStateSync(mic: e.mic)
        guard micState == .off else { return .refused("mic is not verifiably off: \(describe(micState))") }

        guard let draft = AX.string(composer, kAXValueAttribute),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused("draft is empty")
        }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == shown.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .refused("the draft changed after the countdown started")
        }
        guard let send = e.sendButton else { return .refused("no Send button found") }
        let v = AX.multi(send, [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXEnabledAttribute])
        guard (v[0] as? String) == "AXButton",
              (v[1] as? String) == ClaudeLabels.send || (v[2] as? String) == ClaudeLabels.send else {
            return .refused("Send button changed before pressing")
        }
        guard (v[3] as? NSNumber)?.boolValue == true else { return .refused("Send button is disabled") }
        if let why = SendRules.pressRefusal(claudeInFront: claudeIsFrontmost(),
                                            spokenAgo: Date().timeIntervalSince(spokenAt), inputAge: inputAge()) {
            return .refused(why)
        }

        let err = AX.perform(send, kAXPressAction)
        if err != .success { return .unknown("Send press returned error \(err.rawValue)") }

        // Polled, not waited: the result is known the moment the composer empties (usually well under 0.1 s).
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
            let value = AX.string(composer, kAXValueAttribute)
            if value == nil || value!.isEmpty { return .done }
            if AX.string(send, kAXRoleAttribute) == nil { return .done }
        }
        return .unknown("pressed Send; the draft was still present after 1.5 s")
    }

    // MARK: Scrolling

    /// Positive dy scrolls down the transcript. Fire and forget; `lastScrollMethod` reports what was used.
    /// Scrolls whatever is under a screen point right away, without touching the accessibility queue: posts a
    /// pixel scroll through the session event stream (the only route Claude honours) and restores the pointer.
    static func postScroll(at point: CGPoint, dy: Double) {
        let pixels = Int32(max(-6000, min(6000, dy.rounded())))
        guard pixels != 0, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.location = point
        let saved = CGEvent(source: nil)?.location
        event.post(tap: .cgSessionEventTap)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    func scroll(_ s: ClaudeSession, dy: Double) {
        guard dy != 0 else { return }
        queue.async {
            let token = self.inFlight.begin()
            defer { self.inFlight.end(token) }
            self.scrollNow(s, dy: dy)
        }
    }

    private func scrollNow(_ s: ClaudeSession, dy: Double) {
        guard let entry = liveEntry(s), let pid = claudePID else {
            setScrollMethod(.failed)
            return
        }
        if scrollViaAX(entry, dy: dy) {
            setScrollMethod(.accessibility)
            return
        }
        // Measured live: a positive pixel delta moves Claude's transcript content up, i.e. scrolls down.
        let pixels = Int32(max(-3000, min(3000, dy.rounded())))
        guard pixels != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else {
            setScrollMethod(.failed)
            return
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Claude (Electron) ignores scroll events posted to its process; only events through the session event
        // stream reach the page, routed to the window under the event's location. Posting there moves the
        // pointer to that location, so it is put straight back: measured live, the page still scrolls.
        event.location = CGPoint(x: s.frame.midX, y: s.frame.midY)
        let saved = CGEvent(source: nil)?.location
        event.post(tap: .cgSessionEventTap)
        if let saved { CGWarpMouseCursorPosition(saved) }
        setScrollMethod(.wheelEvent)
    }

    /// Moves a vertical scroll bar inside the pane if the page exposes one. Electron pages usually do not.
    private func scrollViaAX(_ entry: CachedSession, dy: Double) -> Bool {
        let id = entry.session.id
        if scrollAreaCooldownActive(id) { return false }
        guard let area = Self.findScrollArea(in: entry.elements.pane),
              let bar = AX.element(area, kAXVerticalScrollBarAttribute),
              AX.isSettable(bar, kAXValueAttribute),
              let current = AX.number(bar, kAXValueAttribute) else {
            suppressScrollAreaSearch(id, for: 30)
            return false
        }
        let height = max(1, AX.frame(area)?.height ?? 1)
        let next = max(0, min(1, current + dy / (height * 20)))
        return AX.set(bar, kAXValueAttribute, NSNumber(value: next)) == .success
    }

    static func findScrollArea(in pane: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        AX.walk(pane, maxDepth: 60, maxNodes: 6_000) { el, _ in
            if AX.role(el) == "AXScrollArea" { found = el; return false }
            return true
        }
        return found
    }
}
