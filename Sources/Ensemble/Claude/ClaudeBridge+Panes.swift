import ApplicationServices
import CoreGraphics
import EnsembleCore
import Foundation

/// Pane widths. Claude resizes its side-by-side panes only through the divider between two of them, an `AXSplitter`
/// labelled `ClaudeLabels.paneResize`. Setting its value through Accessibility is accepted and ignored; once the
/// divider holds keyboard focus, the arrows, Home and End move it (`PaneKeys`, docs/gotchas.md, 2).
extension ClaudeBridge {
    /// The pane-column dividers in the window holding `s`. Empty when none answer. The transcript is not entered:
    /// it holds most of the nodes and never holds a divider.
    func paneDividers(in s: ClaudeSession) async -> [PaneDivider] {
        await run {
            guard let entry = self.liveEntry(s) else { return [] }
            var found: [PaneDivider] = []
            var count = 0
            let deadline = Date().addingTimeInterval(1)
            func go(_ el: AXUIElement, _ depth: Int) {
                count += 1
                if count > 12_000 || depth > 70 || (count % 64 == 0 && Date() >= deadline) { return }
                let v = AX.multi(el, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
                let desc = v[1] as? String
                if (v[0] as? String) == "AXSplitter", desc == ClaudeLabels.paneResize {
                    if let f = AX.frame(el) { found.append(PaneDivider(element: el, frame: f, minPercent: AX.number(el, kAXMinValueAttribute))) }
                    return
                }
                if desc == ClaudeLabels.transcript { return }
                for c in (v[2] as? [AXUIElement]) ?? [] { go(c, depth + 1) }
            }
            go(entry.elements.window, 0)
            return found
        }
    }

    /// Gives `divider` keyboard focus, so the keys Ensemble posts next move it, and confirms that it holds it. Only
    /// with Claude in front; never raises Claude or moves it in front. With several Claude windows the session's own
    /// is made main if the focus does not land. False when it has not landed yet: right after a burst of keys on
    /// another divider it took up to 1.6 s (measured 2026-10-15), so the caller keeps checking `dividerHoldsKeyboard`.
    func focusDivider(_ handle: AnyObject, in s: ClaudeSession) async -> Bool {
        let divider = handle as! AXUIElement
        return await run {
            guard self.claudeIsFrontmost(), let pid = self.claudePID else { return false }
            if self.holdsKeyboard(divider, pid: pid) { return true }
            AX.set(divider, kAXFocusedAttribute, kCFBooleanTrue)
            if self.waitForKeyboard(divider, pid: pid) { return true }
            guard let entry = self.liveEntry(s) else { return false }
            AX.set(entry.elements.window, kAXMainAttribute, kCFBooleanTrue)
            AX.set(divider, kAXFocusedAttribute, kCFBooleanTrue)
            return self.waitForKeyboard(divider, pid: pid)
        }
    }

    /// True while Claude is in front and `divider` still holds its keyboard focus: a key posted now moves it.
    func dividerHoldsKeyboard(_ handle: AnyObject) async -> Bool {
        let divider = handle as! AXUIElement
        return await run {
            guard self.claudeIsFrontmost(), let pid = self.claudePID else { return false }
            return self.holdsKeyboard(divider, pid: pid)
        }
    }

    /// Whether Claude's keyboard focus is on one of `dividers`, whether or not Claude is in front; nil when Claude's
    /// focused element cannot be read.
    func keyboardOnDivider(_ handles: [AnyObject]) async -> Bool? {
        let dividers = handles as! [AXUIElement]
        return await run {
            guard let pid = self.claudePID, let focused = AX.element(AX.application(pid: pid), kAXFocusedUIElementAttribute) else {
                return nil
            }
            return dividers.contains { CFEqual($0, focused) }
        }
    }

    private func holdsKeyboard(_ el: AXUIElement, pid: pid_t) -> Bool {
        AX.element(AX.application(pid: pid), kAXFocusedUIElementAttribute).map { CFEqual($0, el) } ?? false
    }

    /// Focus lands a moment after it is set (about 20 ms from the message box); polls for up to 0.2 s. Longer waits
    /// are the caller's, between short reads, so the bridge queue is never held.
    private func waitForKeyboard(_ el: AXUIElement, pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(0.2)
        while true {
            if holdsKeyboard(el, pid: pid) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// For each session: its transcript's frame, and the chat column's width where that pane is wide enough to
    /// show it (`ChatColumn.measure`). Read only, and shallow: the column sits a few levels under the transcript,
    /// so each walk stops 10 levels down, after 800 nodes or 0.25 s, never reading the message text.
    func chatColumns(in sessions: [ClaudeSession]) async -> [String: (transcript: CGRect?, column: Double?)] {
        await run {
            var out: [String: (transcript: CGRect?, column: Double?)] = [:]
            for s in sessions {
                var entry = self.liveEntry(s)
                if entry?.elements.transcript.flatMap(AX.frame) == nil { entry = self.liveEntry(s, rescanPane: true) }
                guard let transcript = entry?.elements.transcript, let frame = AX.frame(transcript) else {
                    out[s.id] = (nil, nil)
                    continue
                }
                var frames: [CGRect] = []
                let deadline = Date().addingTimeInterval(0.25)
                var n = 0
                AX.walk(transcript, maxDepth: 10, maxNodes: 800) { el, depth in
                    n += 1
                    if n % 32 == 0, Date() >= deadline { return false }
                    if depth > 0, let f = AX.frame(el), f.width >= 400 { frames.append(f) }
                    return true
                }
                out[s.id] = (frame, ChatColumn.measure(transcript: frame, elements: frames))
            }
            return out
        }
    }

    /// One press and release of `key`, through the session event tap to the app in front, with exactly the Shift
    /// flag the key needs and no other. The caller has confirmed a divider holds Claude's keyboard focus and marks
    /// the keys as its own (`ownKeys(began:)`), so they never count as the owner typing.
    static func postKey(_ key: PaneKeys.Key) {
        let code: CGKeyCode
        switch key {
        case .left, .shiftLeft: code = 123
        case .right, .shiftRight: code = 124
        case .home: code = 115
        case .end: code = 119
        }
        let flags: CGEventFlags = key == .shiftLeft || key == .shiftRight ? .maskShift : []
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            // Marked as Ensemble's own so the resize's key hold (`ResizeKeyHold`) lets it through.
            event.setIntegerValueField(.eventSourceUserData, value: ResizeKeyHold.ownTag)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
