import AppKit
import EnsembleCore

/// Peace sign and scissors: resizes the session panes of the Claude window you are facing with Claude's own keyboard
/// control of the dividers between them. The peace sign widens the session you look at to Claude's chat column plus
/// 10 percent, the same target as the fit below, and does nothing to a session already that wide; evening out gives
/// each the same width. Focus settling on a pane narrower than Claude's chat column widens it to that width
/// (`autoFit`), unless Settings turns it off.
///
/// A divider is given keyboard focus through Accessibility and moved with arrows, Shift and arrows, Home and End
/// (`PaneKeys` plans which), posted through the session event tap to Claude in front. The pointer never moves. Each
/// divider is visited once per pass and gets all its keys in one burst, so a resize lands as one move. The highlight
/// goes straight to where the plan puts the session and springs there
/// (`CoordinatorContext.resizeFrame`, `OverlayController.glide`); the frames read once the resize ends correct it.
/// Before every key it checks that Claude is still in front with that divider holding its keyboard, that no
/// dictation, send or Return watch is running, and that the keyboard, mouse and trackpad are untouched; otherwise
/// nothing more is pressed. From the moment a divider is asked to take the keyboard, keys you type are held back
/// (`ResizeKeyHold`): the resize stops, and they go out again once the keyboard is back in the message box. Afterwards
/// the keyboard goes back to the session's message box only if a divider of the row still holds it (`ResizeKeys`),
/// and with Claude not in front, when Claude next comes to the front.
@MainActor
final class PaneWidthController {
    private let ctx: CoordinatorContext
    /// A send is between its request and its result, or waits for a stop: no key may be pressed.
    var sendBusy: () -> Bool = { false }
    /// The Return watch is on (a dictation, or just after one): it would see Ensemble's keys.
    var keyWatchOn: () -> Bool = { false }
    /// The session frames were read again: the highlight is moved to them.
    var framesChanged: () -> Void = {}
    /// The session the nose is on now, nil when none: a fit stops when you look at another session.
    var focusedID: () -> String? = { nil }
    /// The session a running fit widens; nil for the peace sign and even out, which you asked for by hand.
    private var fitting: String?
    private(set) var isRunning = false
    private var cancelled = false
    /// When this resize began, for the hand-on-the-keyboard-or-mouse check, and whether it has pressed any key.
    private var startedAt: TimeInterval = 0
    private var pressedAny = false
    /// A divider was asked to take the keyboard during this resize, and the row's dividers that were.
    private var askedDivider = false
    private var askedDividers: [AnyObject] = []
    /// A resize ended with Claude not in front: when Claude next comes to the front, the keyboard goes back to this
    /// session's message box if one of these dividers still holds it.
    private var pendingRefocus: (target: ClaudeSession, dividers: [AnyObject])?
    private let keyHold = ResizeKeyHold()
    private var activationObserver: NSObjectProtocol?

    /// Plan, press, read back: the second pass corrects what Claude's rounding or a lost key left.
    private static let passes = 2
    /// Claude's frames show a key about 170 ms after it (measured 2026-10-15); the read-back waits this long.
    private static let settle: UInt64 = 220_000_000
    /// How long a divider may take to hold the keyboard: up to 1.6 s was measured after a burst of keys.
    private static let focusWait: TimeInterval = 2

    /// Claude's chat column, as measured reliably from a pane wide enough to show it.
    private var column = ChatColumn.Memory()
    /// Which panes recent fits widened and narrowed, so one glance never undoes the last fit.
    private var hold = SessionFit.Hold()

    init(ctx: CoordinatorContext) {
        self.ctx = ctx
        keyHold.onHeld = { [weak self] in
            guard let self, self.isRunning, !self.cancelled else { return }
            EnsembleLog.write("pane widths: a key was typed; stopping and handing it to the message box")
            self.cancel()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == ClaudeLabels.bundleID else { return }
            MainActor.assumeIsolated { self?.claudeCameToFront() }
        }
    }

    /// Claude is in front again after a resize ended without it: the keyboard goes back to the message box only if
    /// a divider of that row still holds it.
    private func claudeCameToFront() {
        guard let pending = pendingRefocus, !isRunning else { return }
        pendingRefocus = nil
        Task { @MainActor in
            let onDivider = await self.ctx.agent.keyboardOnDivider(pending.dividers)
            guard ResizeKeys.refocus(askedDivider: true, claudeInFront: self.ctx.agent.claudeIsFrontmost(),
                                     keyboardOnDivider: onDivider) == .now else { return }
            EnsembleLog.write("pane widths: Claude is in front again; \(await self.ctx.agent.focusComposerIfNeeded(pending.target))")
        }
    }

    /// Stops the running resize only: each run clears it as it ends, or `blocker` would refuse every later fit and
    /// peace sign as "interrupted" until Ensemble restarts.
    func cancel() { if isRunning { cancelled = true } }

    func request(_ maximize: Bool, target: ClaudeSession?) {
        let what = maximize ? "Maximize" : "Even out"
        guard !isRunning else { return }
        let gesture: UsageGesture = maximize ? .peace : .scissors
        ctx.usage.count(.gestureAttempted(gesture))
        if let why = ctx.commonRefusal() { ctx.refuse(why, title: what); return }
        guard let target else { ctx.refuse("Look at a Claude session first", title: what, resolves: .whenOnSession); return }
        if let why = blocker() { ctx.refuse(why, title: what); return }
        begin()
        // A layout you asked for replaces whatever earlier fits were holding.
        hold.reset()
        EnsembleLog.write("pane widths: \(maximize ? "maximize" : "even out") around \(place(of: target))")
        Task { @MainActor in
            let outcome: Outcome
            if maximize {
                outcome = await self.fitToColumn(target, row: PaneWidths.row(of: target, in: self.ctx.sessions), keepFits: false).outcome
            } else {
                outcome = await self.run(target: target, within: PaneKeys.arrow) { widths, _, _, _ in PaneKeys.evenWidths(widths) }
            }
            await self.end(target)
            EnsembleLog.write("pane widths: \(outcome)")
            if case .done = outcome { self.ctx.usage.count(.gestureSucceeded(gesture)) }
            if let refusal = outcome.refusal { self.ctx.refuse(refusal, title: what) }
        }
    }

    /// Why a fit did not start: the reason, for the log (fixed words and numbers only), and whether to try again
    /// while the nose still rests on the session.
    struct FitSkip: Equatable {
        let why: String
        let retry: Bool
    }

    /// The nose has rested on `target`: widen it to a little more than Claude's chat column if it is narrower, taking
    /// the width through as few dividers as possible (`SessionFit.restingFit`). Silent: it is not something you asked
    /// for, so it never shows a refusal; anything in the way (a dictation, a send, your hands on the keyboard or mouse, another
    /// app in front, the seconds after a calibration) skips it and says why. nil when it started. If you look at
    /// another session while it runs, it stops there and the caller fits that one instead.
    func autoFit(_ target: ClaudeSession, calibratedAt: TimeInterval) -> FitSkip? {
        guard !isRunning else { return FitSkip(why: "another resize is running", retry: true) }
        if let why = ctx.commonRefusal() ?? blocker() { return FitSkip(why: why, retry: ctx.agent.claudeIsFrontmost() && ctx.settings.enabled) }
        if let why = hold.refusal(now: CACurrentMediaTime(), calibratedAt: calibratedAt) { return FitSkip(why: why, retry: true) }
        let idle = ClaudeBridge.secondsSincePhysicalInput()
        if idle < CoordinatorContext.inputQuiet {
            // No seconds in the reason: it is logged once per rest, and a changing number made it log every tick.
            return FitSkip(why: "the keyboard or mouse was used in the last \(Int(CoordinatorContext.inputQuiet)) s", retry: true)
        }
        let row = PaneWidths.row(of: target, in: ctx.sessions)
        guard row.count >= 2 else { return FitSkip(why: "one session in its row", retry: false) }
        begin()
        fitting = target.id
        Task { @MainActor in
            let r = await self.fitToColumn(target, row: row, keepFits: true)
            await self.end(target)
            if case .done(let n) = r.outcome, n > 0, let f = r.fit {
                let narrowed = f.ids.indices.filter { $0 != f.k && f.to[$0] < f.from[$0] - PaneWidths.tolerance }.map { f.ids[$0] }
                self.hold.noteFit(target.id, width: f.to[f.k], narrowed: narrowed, at: CACurrentMediaTime())
            }
            if case .done(presses: 0) = r.outcome {
                EnsembleLog.write("pane widths: \(self.place(of: target)) already fits the chat column (\(Int(r.column)) pt)")
                return
            }
            EnsembleLog.write("pane widths: fit \(self.place(of: target)) to the chat column "
                              + "(\(Int(r.column)) pt, \(self.column.measured == nil ? "default" : "measured")): \(r.outcome)")
        }
        return nil
    }

    /// Widens `target` to the chat column plus its headroom, the one target of both the rest on a narrow session and the
    /// peace sign; a session already that wide is left alone. `keepFits`: panes fitted a moment ago keep their width
    /// while the others can give it (the rest fit); the peace sign was asked for by hand and ignores them.
    private func fitToColumn(_ target: ClaudeSession, row: [ClaudeSession], keepFits: Bool)
        async -> (outcome: Outcome, fit: (ids: [String], from: [Double], to: [Double], k: Int)?, column: Double) {
        let readings = await ctx.agent.chatColumns(in: row)
        column.note(row.map { readings[$0.id]?.column }, panes: row.map { Double($0.frame.width) })
        let width = column.width
        // The pane's padding beside its transcript, read with the transcript from the same frames: a pane frame
        // read after a pass with a transcript read before it gave a wrong padding and a second, smaller target.
        let paneColumn = ChatColumn.paneWidth(column: width, pane: target.frame, transcript: readings[target.id]?.transcript)
        let want = SessionFit.fitWidth(paneColumn: paneColumn)
        var fit: (ids: [String], from: [Double], to: [Double], k: Int)?
        // One plan, kept for every pass; a second pass only when Claude landed more than a Shift step off it.
        let outcome = await run(target: target, within: PaneKeys.shiftArrow) { widths, k, minimum, row in
            let ids = row.map(\.id)
            let floors = keepFits ? self.hold.floors(ids, focus: k, now: CACurrentMediaTime()) : []
            guard let planned = SessionFit.restingFit(current: widths, focus: k, width: want, keep: paneColumn,
                                                      minimum: max(PaneWidths.narrowWidth, minimum), floors: floors) else { return nil }
            if fit == nil { fit = (ids, widths, planned, k) }
            return planned
        }
        return (outcome, fit, width)
    }

    private enum Outcome: CustomStringConvertible {
        case done(presses: Int)
        case stopped(String)
        case refused(String)
        var refusal: String? { if case .refused(let why) = self { return why }; return nil }
        var description: String {
            switch self {
            case .done(let n): return "done after \(n) key\(n == 1 ? "" : "s")"
            case .stopped(let why): return "stopped: \(why)"
            case .refused(let why): return "refused: \(why)"
            }
        }
    }

    private func begin() {
        isRunning = true
        cancelled = false
        pressedAny = false
        askedDivider = false
        askedDividers = []
        pendingRefocus = nil
        fitting = nil
        startedAt = CACurrentMediaTime()
    }

    /// The keyboard goes back to the session's message box if a divider of the row still holds it (a box you clicked
    /// into meanwhile keeps it), keys held back meanwhile go out again, and the frames are read again once Claude has
    /// drawn the last key. Clears `cancelled` so one interrupted resize never blocks the next.
    private func end(_ target: ClaudeSession) async {
        if askedDivider {
            let dividers = askedDividers
            let onDivider = await ctx.agent.keyboardOnDivider(dividers)
            switch ResizeKeys.refocus(askedDivider: true, claudeInFront: ctx.agent.claudeIsFrontmost(), keyboardOnDivider: onDivider) {
            case .now: EnsembleLog.write("pane widths: \(await ctx.agent.focusComposerIfNeeded(target))")
            case .whenClaudeReturns:
                pendingRefocus = (target, dividers)
                EnsembleLog.write("pane widths: Claude is not in front; the message box gets the keyboard when it is")
            case .leave: EnsembleLog.write("pane widths: keyboard left where it is")
            }
            let held = keyHold.finish()
            if !held.isEmpty {
                let after = await ctx.agent.keyboardOnDivider(dividers)
                if ResizeKeys.replayHeld(claudeInFront: ctx.agent.claudeIsFrontmost(), keyboardOnDivider: after) {
                    ResizeKeyHold.repost(held)
                    EnsembleLog.write("pane widths: \(held.count) held key events passed on")
                } else {
                    EnsembleLog.write("pane widths: \(held.count) held key events dropped (a divider still holds the keyboard)")
                }
            }
        }
        if pressedAny {
            // Claude draws the last key about 170 ms after it: the highlight leaves the plan's frame for the real one.
            try? await Task.sleep(nanoseconds: Self.settle)
            await readFrames()
        }
        if pressedAny || ctx.resizeFrame != nil {
            ctx.resizeFrame = nil
            framesChanged()
        }
        ctx.overlay.glide(false)
        pressedAny = false
        fitting = nil
        isRunning = false
        cancelled = false
    }

    /// Plans and presses toward the widths `want` asks for, given the row's pane widths, the target's index, Claude's
    /// minimum pane width and the row's sessions; nil when there is nothing to do. Asked once, on the first pass; later
    /// passes run only while a pane is more than `within` off those widths. Reads the row again before each pass,
    /// until a pass has nothing to press, a pass changed nothing (Claude went no further), or the passes run out.
    private func run(target: ClaudeSession, within: Double,
                     want: ([Double], Int, Double, [ClaudeSession]) -> [Double]?) async -> Outcome {
        var total = 0
        var before: [Double]?
        var goalWidths: [Double]?
        for pass in 0..<Self.passes {
            let sessions = await ctx.agent.refreshSessions(watched: false).sessions
            if !sessions.isEmpty { ctx.sessions = sessions; framesChanged() }
            let row = PaneWidths.row(of: sessions.first { $0.id == target.id } ?? target, in: sessions)
            guard row.count >= 2, let k = row.firstIndex(where: { $0.id == target.id }) else {
                return pass == 0 ? .refused("Only one session in this window") : .stopped("the sessions changed")
            }
            let found = await ctx.agent.paneDividers(in: target)
            let xs = PaneWidths.dividers(between: row.map(\.frame), splitters: found.map(\.frame))
            let dividers = (xs ?? []).compactMap { x in found.first { abs(Double($0.frame.midX) - x) < 0.5 } }
            guard let xs, dividers.count == xs.count else {
                return pass == 0 ? .refused("Claude's pane dividers were not found") : .stopped("the dividers changed")
            }
            let widths = PaneWidths.layout(panes: row.map(\.frame), dividers: xs).widths
            if let before, before.count == widths.count, zip(before, widths).allSatisfy({ abs($0 - $1) < 1 }) {
                return .done(presses: total)
            }
            let pairs = (0..<(widths.count - 1)).map { widths[$0] + widths[$0 + 1] }
            let minimum = PaneKeys.minimum(pairWidths: pairs, minPercents: dividers.map(\.minPercent))
            var w: [Double]
            if let g = goalWidths, g.count == widths.count {
                if zip(widths, g).allSatisfy({ abs($0 - $1) <= within }) { return .done(presses: total) }
                // The row's total can move by a point between reads: the target pane takes the difference.
                w = g
                w[k] += widths.reduce(0, +) - g.reduce(0, +)
            } else {
                guard let planned = want(widths, k, minimum, row) else { return .done(presses: total) }
                goalWidths = planned
                w = planned
            }
            // Home or End and steps back where the target is nearer the limit than the divider is.
            let presses = PaneKeys.plan(from: widths, to: w, minimum: minimum)
            let predicted = PaneKeys.simulate(widths, minimum: minimum, presses: presses)
            guard !presses.isEmpty else { return .done(presses: total) }
            predict(target, row: row, dividers: xs, widths: predicted, k: k)
            EnsembleLog.write("pane widths: pass \(pass + 1), \(presses.count) keys, "
                              + "minimum \(Int(minimum)) pt, \(widths.map { Int($0) }) to \(predicted.map { Int($0) })")
            // A later pass corrects a first one that landed off, which keys dropped at the fast pace would explain.
            let pace = pass == 0 ? PaneKeys.interval : PaneKeys.safeInterval
            if let why = await press(presses, on: dividers.map(\.element), in: target, pace: pace) { return .stopped(why) }
            total += presses.count
            before = widths
            try? await Task.sleep(nanoseconds: Self.settle)
        }
        return .done(presses: total)
    }

    /// The highlight goes to where the plan puts the target and springs there now, instead of trailing Claude's
    /// frames; `end` replaces it with the frame Claude reports.
    private func predict(_ target: ClaudeSession, row: [ClaudeSession], dividers: [Double], widths: [Double]?, k: Int) {
        guard let widths, let frames = PaneWidths.frames(panes: row.map(\.frame), dividers: dividers, widths: widths) else { return }
        ctx.overlay.glide(true)
        ctx.resizeFrame = (target.id, frames[k])
        framesChanged()
    }

    /// The planned keys, each divider's in one burst `pace` seconds apart. nil when they all went, else why it
    /// stopped.
    private func press(_ presses: [PaneKeys.Press], on dividers: [AnyObject], in target: ClaudeSession,
                       pace seconds: Double) async -> String? {
        let pace = UInt64(seconds * 1_000_000_000)
        let since = startedAt
        func safe() -> String? {
            if let why = blocker() { return why }
            if let id = fitting, let now = focusedID(), now != id { return "you looked at another session" }
            // Hardware input only: the keys Ensemble posts never count, the owner's own hand always does.
            if ClaudeBridge.secondsSincePhysicalInput() < CACurrentMediaTime() - since { return "the keyboard or mouse was used" }
            return nil
        }
        ClaudeBridge.ownKeys(began: true)
        defer { ClaudeBridge.ownKeys(began: false) }
        var focused: Int?
        let began = CACurrentMediaTime()
        defer {
            EnsembleLog.write("pane widths: \(presses.count) keys over \(Set(presses.map(\.divider)).count) dividers in "
                              + "\(Int((CACurrentMediaTime() - began) * 1000)) ms")
        }
        for (i, p) in presses.enumerated() {
            if let why = safe() { return why }
            let divider = dividers[p.divider]
            if focused != p.divider {
                // From here a divider may hold the keyboard: your keys are held back, and the end puts it back.
                askedDivider = true
                for d in dividers where !askedDividers.contains(where: { CFEqual($0, d) }) { askedDividers.append(d) }
                keyHold.begin()
                if !(await ctx.agent.focusDivider(divider, in: target)) {
                    // Claude can take a second or more to move the keyboard after a burst of keys on another divider.
                    let until = CACurrentMediaTime() + Self.focusWait
                    var holds = false
                    while !holds, CACurrentMediaTime() < until {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        if let why = safe() { return why }
                        holds = await ctx.agent.dividerHoldsKeyboard(divider)
                    }
                    if !holds { return "the divider did not take the keyboard" }
                }
                focused = p.divider
            } else if !(await ctx.agent.dividerHoldsKeyboard(divider)) {
                return "the divider lost the keyboard"
            }
            // The checks above waited on Claude: look again right before the key.
            if let why = safe() { return why }
            pressedAny = true
            ClaudeBridge.postKey(p.key)
            // The last key of a burst needs no wait: the next divider's focus takes longer than any pace.
            if i + 1 < presses.count, presses[i + 1].divider == p.divider { try? await Task.sleep(nanoseconds: pace) }
        }
        return nil
    }

    /// Reads the session frames again and hands them to the highlight.
    private func readFrames() async {
        let sessions = await ctx.agent.refreshSessions(watched: false).sessions
        guard !sessions.isEmpty, ctx.listening == nil else { return }
        ctx.sessions = sessions
    }

    /// Where `target` sits in its row ("pane 2 of 4"), for logs: never its name, which is the owner's text.
    private func place(of target: ClaudeSession) -> String {
        let row = PaneWidths.row(of: target, in: ctx.sessions)
        guard let i = row.firstIndex(where: { $0.id == target.id }) else { return "a pane" }
        return "pane \(i + 1) of \(row.count)"
    }

    /// Why no key may be pressed right now, or nil.
    private func blocker() -> String? {
        if !ctx.settings.enabled { return "Ensemble is off" }
        if !ctx.agent.claudeIsFrontmost() { return "Claude is not in front" }
        if ctx.handsBusy { return "Paused while you type or use the mouse" }
        if ctx.listening != nil || ctx.busy { return "Dictation is starting or stopping" }
        if sendBusy() { return "A send is in progress" }
        if keyWatchOn() { return "Dictation has just ended" }
        if cancelled { return "interrupted" }
        return nil
    }
}
