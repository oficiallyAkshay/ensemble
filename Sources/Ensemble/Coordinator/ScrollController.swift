import AppKit
import EnsembleCore

/// Delivers pinch-and-drag scrolling to Claude: hand motion is gathered and flushed on the 20 Hz tick, a 60 Hz
/// loop glides it out (and coasts after a fast release), and every frame checks Claude still owns the window.
@MainActor
final class ScrollController {
    private let ctx: CoordinatorContext
    private var glide = ScrollGlide()
    private var session: (session: ClaudeSession, lastAt: Date)?
    private var point: CGPoint?
    private var timer: Timer?
    private var lastOwnerCheck: TimeInterval = 0
    /// The last call to `scroll`: a gap of a second starts a new attempt for the usage count.
    private var lastScrollCall: TimeInterval = -.infinity

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    /// A scroll gesture is in progress.
    var isActive: Bool { session != nil }
    var isCoasting: Bool { glide.inertia != 0 }
    /// The 60 Hz loop is running.
    var isRunning: Bool { timer != nil }

    /// A drag of `handDy` points of hand travel (positive = hand moved up).
    func drag(handDy: Double, target: ClaudeSession?) {
        glide.catchPage()
        // Natural scrolling: the content follows the hand, so a hand moving up shows later content (scrolls down).
        scroll(ScrollGlide.shaped(handDy: handDy) * SystemPointer.speedFactor * (SystemPointer.naturalScrolling ? 1 : -1)
               * (ctx.settings.reverseScroll ? -1 : 1), target: target)
    }

    func scroll(_ dy: Double, target: ClaudeSession?) {
        guard dy.isFinite else { return }
        let now = CACurrentMediaTime()
        if now - lastScrollCall > 1 { ctx.usage.count(.gestureAttempted(.scroll)) }
        lastScrollCall = now
        guard ctx.commonRefusal(checkInput: false) == nil else { return }
        let found: ClaudeSession
        if let s = session { found = s.session } else if let t = ctx.listening ?? target { found = t } else { return }
        if session == nil { EnsembleLog.write("scroll started"); ctx.usage.count(.gestureSucceeded(.scroll)) }
        session = (found, Date())
        glide.add(dy, at: CACurrentMediaTime())    // flushed on the tick, so the pointer is touched at most 20 times a second
    }

    /// The pinch is gone. A slow release stops dead; a fast flick throws the page with momentum.
    func released() {
        if let v = glide.release(at: CACurrentMediaTime(), canCoast: point != nil) {
            EnsembleLog.write("flick: \(Int(v)) pt/s")
            startLoop()
        } else {
            stopLoop()
        }
        session = nil
    }

    func tick() {
        if let s = session, glide.flush() {
            let frame = ctx.sessions.first { $0.id == s.session.id }?.frame ?? s.session.frame
            point = CGPoint(x: frame.midX, y: frame.midY)
            startLoop()
        }
        if let s = session, Date().timeIntervalSince(s.lastAt) > 0.6 { session = nil }
    }

    /// Drops every piece of scrolling state, so nothing glides or coasts after this call.
    func cancel() {
        stopLoop()
        session = nil
        glide.reset()
        point = nil
    }

    private func startLoop() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / ScrollGlide.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
    }

    private func frame() {
        guard let step = glide.nextStep(pinchHeld: ctx.gestures.pinchHeld, secondsSinceInput: ClaudeBridge.secondsSincePhysicalInput(), hasTarget: point != nil),
              let at = point else {
            stopLoop()
            return
        }
        // Every 0.15 s: the window under the scroll point must still be Claude's, or the page would scroll
        // whatever another app has put there since the pinch began.
        let now = CACurrentMediaTime()
        if now - lastOwnerCheck >= 0.15 {
            lastOwnerCheck = now
            if ScreenFacts.topWindowOwner(at: at) != ctx.bridge.claudePID {
                EnsembleLog.write("scroll stopped: Claude is no longer the window under the scroll point")
                cancel()
                return
            }
        }
        ClaudeBridge.postScroll(at: at, dy: glide.take(step))
    }
}
