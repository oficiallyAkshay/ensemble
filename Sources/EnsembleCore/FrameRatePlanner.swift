import Foundation

/// Decides, for each camera frame, which analyses run. Full rate only where a gesture or a safety check needs it:
/// hand pose every frame while a hand is in view (and for `handHold` s after) with Claude in front, otherwise a slow
/// probe (gestures do nothing with another app in front, `otherAppInFront`); the face
/// tracker at `faceInterval`, or `slowFaceInterval` while nothing follows the nose closely (`wantsSlowFace`); and both
/// near zero once no face has been seen for `idleAfter` s. `forceFull` (dictating, a send pending, calibrating, a
/// gesture held) keeps the hand at every frame and cancels both slowdowns.
/// Not thread-safe; one queue owns it.
public struct FrameRatePlanner {
    public struct Plan: Equatable, Sendable {
        public var runHand: Bool
        public var runFace: Bool
        public var runLight: Bool
    }

    public var handProbeInterval: TimeInterval = 0.125
    public var handHold: TimeInterval = 1.0
    /// Every frame of a 30 fps camera: each head reading is a step of the nose dot. The face tracker takes one frame
    /// at a time (FrameGate), so a slow machine skips frames instead of queueing them.
    public var faceInterval: TimeInterval = 1.0 / 30.0
    /// 10 Hz while the face only keeps the target and the presence checks current (another app in front, no Claude
    /// session on screen, a long keyboard-or-mouse pause): a third of the face tracker's work, which is most of
    /// Ensemble's CPU (the JPEG encode, the web content's decode and landmark pass, the GPU process).
    public var slowFaceInterval: TimeInterval = 0.1
    /// A keyboard-or-mouse pause this long slows the face; a short one keeps it at full rate for a quick resume.
    public static let pausedSlowAfter: TimeInterval = 3.0
    public var idleAfter: TimeInterval = 3.0
    public var idleInterval: TimeInterval = 0.5
    public var lightInterval: TimeInterval = 0.1
    /// A frame may run this much early, so a 30 Hz target lands on every frame of a 30 fps camera.
    public var slack: TimeInterval = 0.012

    private var startedAt: TimeInterval?
    private var lastHandRun = -TimeInterval.infinity
    private var lastFaceRun = -TimeInterval.infinity
    private var lastLightRun = -TimeInterval.infinity
    private var handPresent = false
    private var lastHandSeen = -TimeInterval.infinity

    public init() {}

    /// Whether the face may run at `slowFaceInterval`: nothing needs every frame (`needsFull`), the tour is closed, and
    /// either another app is in front (Ensemble acts only on Claude), no Claude session is on screen, or you have been
    /// on the keyboard or mouse for `pausedSlowAfter` s (`pausedFor`, nil while not paused).
    public static func wantsSlowFace(needsFull: Bool, tourOpen: Bool, otherAppInFront: Bool, sessionsOnScreen: Bool,
                                     pausedFor: TimeInterval?) -> Bool {
        if needsFull || tourOpen { return false }
        return otherAppInFront || !sessionsOnScreen || (pausedFor ?? 0) >= pausedSlowAfter
    }

    public mutating func plan(now: TimeInterval, forceFull: Bool, lastFaceSeenAt: TimeInterval?, slowFace: Bool = false,
                              otherAppInFront: Bool = false) -> Plan {
        if startedAt == nil { startedAt = now }
        let faceReference = max(lastFaceSeenAt ?? -.infinity, startedAt ?? now)
        let idle = !forceFull && now - faceReference > idleAfter

        var runHand = false
        if !idle, forceFull || (!otherAppInFront && (handPresent || now - lastHandSeen < handHold)) {
            runHand = true
        } else {
            runHand = now - lastHandRun >= (idle ? idleInterval : handProbeInterval) - slack
        }
        let faceEvery = idle ? idleInterval : (slowFace && !forceFull ? slowFaceInterval : faceInterval)
        let runFace = now - lastFaceRun >= faceEvery - slack
        let runLight = now - lastLightRun >= lightInterval - slack

        if runHand { lastHandRun = now }
        if runFace { lastFaceRun = now }
        if runLight { lastLightRun = now }
        return Plan(runHand: runHand, runFace: runFace, runLight: runLight)
    }

    /// The result of a hand analysis the plan asked for.
    public mutating func noteHand(present: Bool, at t: TimeInterval) {
        handPresent = present
        if present { lastHandSeen = t }
    }
}
