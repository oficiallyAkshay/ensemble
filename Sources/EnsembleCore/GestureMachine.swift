#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// Turns the stream of per-frame hand readings into intents. Pure: time comes only from the
/// observations and from `tick(now:)`, so it replays deterministically.
public final class GestureMachine {
    public var mapping: GestureMapping
    public private(set) var talking = false
    /// Double-tap thresholds, in palm lengths with hysteresis: closed below `pinchClosed`, open again above `pinchOpen`.
    /// Measured on the owner's hand (2026-10-14): a pinch closes to 0.03–0.11 palm lengths, often held 1–2 s, and
    /// between quick taps only reopens to 0.12–0.18; a relaxed hand rests around 0.20–0.26. Single-frame spikes
    /// occur inside a held pinch, so both edges need two frames in a row.
    public var pinchClosed = 0.12
    static let reopenAbove = 0.14            // reopened when above this AND `reopenRise` above the closed minimum
    static let reopenRise = 0.06
    static let edgeFrames = 2
    static let tapMin = 0.05
    static let tapMax = 2.0            // longest a pinch may stay closed and still count as a tap
    /// Second pinch must close within this long after the first opened, else the pair resets. Measured 2026-10-14:
    /// Deliberate pairs leave 0.2–1.5 s between release and the next touch; 0.6 s missed most of them.
    static let tapGap = 1.2
    /// Fingertips brush together while a thumbs-up is lowered; a pinch that closes this soon after one is not a tap
    /// (measured 2026-10-14: a lowered thumbs-up read as a double pinch 2.6 s after a send).
    static let quietAfterSendPose = 0.7
    static let toggleCooldown = 0.8
    private var pinchIsClosed = false
    private var pinchClosedAt: TimeInterval?
    private var pinchMin = 1.0
    /// Pinch and drag scrolls: once a held pinch moves this far (frame heights), it is a drag, never a tap.
    public static let dragStart = 0.03
    /// Scroll points per frame height of hand travel, before the system speed factor the coordinator applies.
    public static let dragPointsPerFrameHeight = 5000.0
    /// Pointer-style acceleration: faster hand motion scrolls disproportionately further (gain 1x at rest,
    /// up to 1 + dragAccel x at one frame height per second).
    public static let dragAccel = 3.0
    private var dragging = false
    private var dragOriginY: Double?
    private var dragLastY: Double?
    private var dragLastT: Double?
    private var dragFilter = OneEuroFilter(minCutoff: 1.0, beta: 2, dCutoff: 1)
    private var dragFilterX = OneEuroFilter(minCutoff: 1.0, beta: 2, dCutoff: 1)
    private var dragOriginX: Double?
    private var dragLastX: Double?
    public private(set) var isDragging = false
    /// A pinch is closed right now (tap, drag or hold in progress): the coordinator holds focus still meanwhile.
    public var pinchHeld: Bool { pinchIsClosed }
    /// The current pinch already toggled on touch; its release must not start a new pair.
    private var pinchToggled = false
    private var edgeCount = 0
    /// The current pinch closed during a quiet period: it may still drag, but never counts as a tap.
    private var pinchSuspect = false
    private var lastSendPoseT: TimeInterval = -.infinity
    private var lastTapEnd: TimeInterval?
    private var lastToggleAt: TimeInterval = -.infinity

    // Timing rules (seconds).
    static let staleHold = 1.0
    /// Holding the send pose this long sends: the hold itself is the confirmation (settable).
    public var sendHold = 1.5
    /// Going straight from the talk pose to the send pose stops dictation and sends. Held a little longer than
    /// a plain send, and still shorter than `releaseHold`, so it is read before the hold counts as released.
    static let stopAndSendHold = 0.35
    static let sendAfterTalkEnd = 0.5
    /// After a send fires, the send pose must be gone this long before a new hold can count. A thumbs-up still up
    /// after the send that flickers for a frame (a misread pose) otherwise started a second hold: the bar filled
    /// again after the send and a second send was asked for.
    static let sendRearm = 0.3
    static let scrollHold = 0.25

    // Scroll: while a pointing pose is held, each frame scrolls speed * frame time. The speed ramps from
    // `scrollMinSpeed` to `scrollMaxSpeed` points per second over `scrollRamp` seconds of scrolling.
    static let scrollMinSpeed = 300.0
    static let scrollMaxSpeed = 1200.0
    static let scrollRamp = 1.5
    static let scrollMaxGap = 0.2

    /// A continuous stretch of one pose. `startedWhileTalking` taints it for send and scroll so the pose
    /// that ends a dictation hold can never also trigger an action.
    private struct Run {
        var pose: Pose
        var start: TimeInterval
        var startedWhileTalking: Bool
        var fired = false
        var stoppedForSend = false     // this send pose already ended a dictation; it may still send
        var blocked = false            // a send pose that returned too soon after a send fired: it never acts
        var lastT: TimeInterval
    }

    private var run: Run?
    private var lastPushT: TimeInterval?
    private var lastTalkEndT: TimeInterval?
    /// The last frame of a send pose that fired (or was blocked), for `sendRearm`.
    private var firedSendLastT: TimeInterval = -.infinity

    /// A send pose is held and can still send (not fired, not too soon after a send): an early send stays armed.
    public var holdingSend: Bool {
        guard let r = run, r.pose == mapping.send else { return false }
        return !r.fired && !r.blocked
    }

    /// The send pose that just stopped a dictation is still held toward its send: the coordinator stops dictation
    /// and settles the transcript during the hold, so Send can be pressed the moment it completes.
    public var holdingSendAfterStop: Bool {
        guard let r = run, r.pose == mapping.send else { return false }
        return r.stoppedForSend && !r.fired && !r.blocked
    }

    /// Peace sign to maximize the session under the nose, scissors to even the sessions out. Both on by default.
    public var maximizeByPeace = true
    public var evenOutByScissors = true
    private var widths = WidthGestures()
    private var twoFingersHold = TwoFingersHold()
    private var diagnostics: [String] = []
    /// A peace sign is up and counting: the coordinator reads every hand frame meanwhile, so the timing holds.
    public var peaceOpen: Bool { widths.peaceOpen }

    public init(mapping: GestureMapping = .init()) { self.mapping = mapping }

    /// The pose currently held and how far its hold has progressed toward acting, for on-screen feedback.
    public var progress: GestureProgress? {
        if awaitingSecondTap { return GestureProgress(pose: .gather, action: talking ? .stop : .talk, progress: 0.5, willAct: true, active: false) }
        if talking, run?.pose != mapping.send { return GestureProgress(pose: .gather, action: .talk, progress: 1, willAct: true, active: true) }
        guard let r = run else { return nil }
        let held = r.lastT - r.start
        func make(_ action: GestureAction, _ need: Double, _ can: Bool) -> GestureProgress {
            GestureProgress(pose: r.pose, action: action, progress: min(max(held / need, 0), 1), willAct: can, active: false)
        }
        if talking { return nil }
        if r.pose == mapping.send { return make(.send, sendHold, (!r.startedWhileTalking || r.stoppedForSend) && !r.fired && !r.blocked) }
        if let direction = scrollDirection(r.pose) {
            let p = make(direction < 0 ? .scrollUp : .scrollDown, Self.scrollHold, !r.startedWhileTalking)
            return GestureProgress(pose: p.pose, action: p.action, progress: p.progress, willAct: p.willAct, active: p.willAct && p.progress >= 1)
        }
        return nil
    }

    public func reset() {
        talking = false
        pinchIsClosed = false; pinchClosedAt = nil; lastTapEnd = nil
        pinchToggled = false; dragging = false; isDragging = false; edgeCount = 0
        pinchSuspect = false; lastSendPoseT = -.infinity; firedSendLastT = -.infinity
        lastToggleAt = -.infinity
        run = nil
        lastPushT = nil
        lastTalkEndT = nil
        widths.reset()
        twoFingersHold.reset()
    }

    /// Log lines gathered since the last call (one per two-fingers hold, see `TwoFingersHold`), oldest first.
    public func takeDiagnostics() -> [String] {
        defer { diagnostics.removeAll() }
        return diagnostics
    }

    /// The coordinator refused or failed to start the dictation this machine just announced: forget it
    /// without emitting an end, so the next double tap starts again instead of being read as a stop.
    public func abortTalk() {
        talking = false
        lastTapEnd = nil
        lastToggleAt = -.infinity
    }

    /// Dictation was started by something other than the double pinch (a headphone press). The machine takes the
    /// same state a double pinch leaves, so a later double pinch stops it and a stale camera ends it.
    public func beginTalkExternally() {
        talking = true
        lastTapEnd = nil
    }

    public func push(_ observation: HandObservation) -> [GestureIntent] {
        // A non-finite reading is a missing reading: it must not reach the filters or the pinch hysteresis.
        var h = observation
        if let d = h.pinch, !d.isFinite { h.pinch = nil }
        if let c = h.palmCenter, !(c.x.isFinite && c.y.isFinite) { h.palmCenter = nil }
        if let s = h.fingerSpread, !s.isFinite { h.fingerSpread = nil }
        guard h.t.isFinite else { return [] }
        lastPushT = h.t
        var intents: [GestureIntent] = []
        if h.present, let send = mapping.send, h.pose == send { lastSendPoseT = h.t }
        if let end = lastTapEnd, h.t - end > Self.tapGap, !pinchIsClosed { lastTapEnd = nil }   // first tap expired
        trackTaps(h, into: &intents)
        let widthsAllowed = !talking && !pinchIsClosed && !mapping.usesTwoFingers
        let width = widths.push(t: h.t, pose: h.present ? h.pose : nil, spread: h.fingerSpread, maximize: maximizeByPeace,
                                evenOut: evenOutByScissors, allowed: widthsAllowed)
        if let width { intents.append(width) }
        if let line = twoFingersHold.push(h, allowed: widthsAllowed, fired: width) { diagnostics.append(line) }

        guard h.present, let pose = h.pose else {
            noteSendRunEnding()
            run = nil
            return intents
        }

        if run?.pose != pose {
            noteSendRunEnding()
            var fresh = Run(pose: pose, start: h.t, startedWhileTalking: talking, lastT: h.t)
            fresh.blocked = pose == mapping.send && h.t - firedSendLastT < Self.sendRearm
            run = fresh
        }
        guard var r = run else { return intents }
        let held = h.t - r.start

        if talking, pose == mapping.send, !r.stoppedForSend, held >= Self.stopAndSendHold {
            // Straight from the talk pose to the send pose: stop dictating now; keep holding to send.
            r.stoppedForSend = true
            endTalk(.released, at: h.t, into: &intents)
        } else if !talking {
            if pose == mapping.send, !r.startedWhileTalking || r.stoppedForSend, !r.fired, !r.blocked, held >= sendHold,
               r.stoppedForSend || (lastTalkEndT.map({ h.t - $0 >= Self.sendAfterTalkEnd }) ?? true) {
                r.fired = true
                intents.append(.sendRequested)
            } else if let direction = scrollDirection(pose), !r.startedWhileTalking, held >= Self.scrollHold {
                let dt = h.t - r.lastT
                if dt > 0, dt <= Self.scrollMaxGap {
                    let ramp = min((held - Self.scrollHold) / Self.scrollRamp, 1)
                    let speed = Self.scrollMinSpeed + (Self.scrollMaxSpeed - Self.scrollMinSpeed) * ramp
                    intents.append(.scroll(dy: direction * speed * dt))
                }
            }
        }
        r.lastT = h.t
        run = r
        return intents
    }

    /// Call on a timer. Ends a dictation hold when the camera stopped delivering frames.
    public func tick(now: TimeInterval) -> [GestureIntent] {
        guard talking, let last = lastPushT, now - last >= Self.staleHold else { return [] }
        var intents: [GestureIntent] = []
        endTalk(.stale, at: now, into: &intents)
        return intents
    }

    /// Two quick thumb-to-index taps toggle dictation. Taps are read from the pinch distance alone, so any hand
    /// shape works; a pinch held longer than `tapMax` (holding something) never counts.
    private func trackTaps(_ h: HandObservation, into intents: inout [GestureIntent]) {
        guard h.present, let d = h.pinch else {
            if dragging { intents.append(.dragScrollEnded) }
            pinchIsClosed = false; pinchClosedAt = nil; edgeCount = 0
            dragging = false; isDragging = false
            return
        }
        if !pinchIsClosed {
            edgeCount = d < pinchClosed ? edgeCount + 1 : 0
            guard edgeCount >= Self.edgeFrames else { return }
            pinchIsClosed = true; edgeCount = 0
            pinchClosedAt = h.t; pinchMin = d
            pinchToggled = false
            dragging = false; isDragging = false
            dragFilter.reset(); dragFilterX.reset()
            dragOriginY = h.palmCenter.map { dragFilter.filter(Double($0.y), at: h.t) }
            dragOriginX = h.palmCenter.map { dragFilterX.filter(Double($0.x), at: h.t) }
            dragLastY = dragOriginY; dragLastX = dragOriginX
            if let end = lastTapEnd, h.t - end > Self.tapGap { lastTapEnd = nil }
            pinchSuspect = h.t - lastSendPoseT < Self.quietAfterSendPose
            if pinchSuspect { lastTapEnd = nil }
            // The second pinch acts the moment it touches; holding it afterwards changes nothing.
            if lastTapEnd != nil, h.t - lastToggleAt >= Self.toggleCooldown {
                lastTapEnd = nil
                lastToggleAt = h.t
                pinchToggled = true
                if talking { endTalk(.released, at: h.t, into: &intents) } else { talking = true; intents.append(.talkBegan) }
            }
        } else {
            // Pinch and drag: a held pinch that moves vertically scrolls, with the hand position smoothed.
            // Release first: fingers that have parted while dragging end the drag before any movement counts.
            if dragging, d > max(pinchClosed, min(pinchMin, d) + Self.reopenRise * 0.6) {
                pinchIsClosed = false; edgeCount = 0; pinchClosedAt = nil
                dragging = false; isDragging = false; lastTapEnd = nil
                intents.append(.dragScrollEnded)
                return
            }
            // Hands move in arcs: the scroll follows the distance the pinch travels, signed by its vertical direction.
            if !pinchToggled, let p = h.palmCenter, let originY = dragOriginY, let originX = dragOriginX {
                let y = dragFilter.filter(Double(p.y), at: h.t)
                let x = dragFilterX.filter(Double(p.x), at: h.t)
                if !dragging, hypot(x - originX, y - originY) >= Self.dragStart { dragging = true; isDragging = true; lastTapEnd = nil }
                if dragging, let ly = dragLastY, let lx = dragLastX, let lt = dragLastT, h.t > lt {
                    let dy = y - ly, dx = (x - lx) * (640.0 / 480.0)   // frame is 4:3: put both axes in frame-height units
                    // Like dragging the page: each frame scrolls by the signed vertical move, so going up and then
                    // back down past the start scrolls back past where it began. When the move is mainly vertical
                    // the sideways part of an arc counts too (the full step length, signed by up or down); when it
                    // is mainly sideways only its small vertical part counts, so sideways jitter cannot drive it.
                    let step = abs(dy) >= 0.5 * abs(dx) ? (dy >= 0 ? 1.0 : -1.0) * hypot(dx, dy) : dy
                    if step != 0 {
                        let speed = abs(step) / (h.t - lt)                  // frame heights per second
                        let gain = 1 + Self.dragAccel * min(speed, 1)
                        intents.append(.dragScroll(handDy: step * Self.dragPointsPerFrameHeight * gain))
                    }
                }
                dragLastT = h.t
                dragLastY = y; dragLastX = x
            }
            pinchMin = min(pinchMin, d)
            // While dragging, opening the fingers even a little ends the drag at once (one frame, a lower bar),
            // so the page never follows a hand that has let go.
            let opened = dragging ? d > max(pinchClosed, pinchMin + Self.reopenRise * 0.6) : d > max(Self.reopenAbove, pinchMin + Self.reopenRise)
            edgeCount = opened ? edgeCount + 1 : 0
            if dragging, opened { edgeCount = Self.edgeFrames }
            if let start = pinchClosedAt, h.t - start > Self.tapMax { lastTapEnd = nil }   // held: not a tap
            guard edgeCount >= Self.edgeFrames else { return }
            pinchIsClosed = false; edgeCount = 0
            guard let start = pinchClosedAt else { return }
            pinchClosedAt = nil
            let closedFor = h.t - start
            if pinchToggled { pinchToggled = false; lastTapEnd = nil; return }
            if dragging { dragging = false; isDragging = false; lastTapEnd = nil; intents.append(.dragScrollEnded); return }
            guard closedFor >= Self.tapMin, closedFor <= Self.tapMax, !pinchSuspect else { lastTapEnd = nil; return }
            lastTapEnd = h.t
        }
    }

    /// One line of machine state for the per-frame trace.
    public var traceState: String {
        "talk=\(talking ? 1 : 0) closed=\(pinchIsClosed ? 1 : 0) await=\(awaitingSecondTap ? 1 : 0) drag=\(dragging ? 1 : 0) suspect=\(pinchSuspect ? 1 : 0)"
    }

    /// Feedback for the bubble: after one tap, the second tap is awaited.
    public var awaitingSecondTap: Bool {
        guard let end = lastTapEnd, let now = lastPushT else { return false }
        return now - end <= Self.tapGap
    }

    private func noteSendRunEnding() {
        if let r = run, r.pose == mapping.send, r.fired || r.blocked { firedSendLastT = r.lastT }
    }

    private func endTalk(_ reason: TalkEndReason, at t: TimeInterval, into intents: inout [GestureIntent]) {
        talking = false
        lastTalkEndT = t
        // On release the current run stays, still marked as started while talking. After a stale camera
        // the next pose is a new arrival.
        if reason != .released { run = nil }
        intents.append(.talkEnded(reason))
    }

    /// -1 for the scroll-up pose, +1 for scroll-down, nil for any other pose.
    private func scrollDirection(_ pose: Pose) -> Double? {
        if pose == mapping.scrollUp { return -1 }
        if pose == mapping.scrollDown { return 1 }
        return nil
    }
}
