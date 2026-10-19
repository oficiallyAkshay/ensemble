import CoreGraphics
import Foundation

/// Which Claude session the nose is on, and for how long. Focus follows the nose almost at once; the margin
/// between neighbouring panes and the longer dwell while dictating keep it from flipping. Pure: time comes
/// from the caller.
public struct FocusTracker {
    /// 0.075 s (2026-10-14: 0.6 s felt slow): focus follows the nose almost at once.
    public static let switchDwell = 0.075
    /// Moving from one session to another, the nose must be this far inside the new one.
    public static let switchMargin: CGFloat = 28
    /// While dictating, the nose must stay on another session this long before focus moves there.
    public static let listeningSwitchDwell = 2.0
    /// A session covered by another app's window is raised after the nose has rested on it this long.
    public static let raiseDwell = 0.8

    public private(set) var target: ClaudeSession?
    /// A session (or none) the nose moved onto, waiting out its dwell before the target follows.
    public private(set) var candidate: (session: ClaudeSession?, since: TimeInterval)?
    private var covered: (id: String, since: TimeInterval)?
    private var lastObserved: TimeInterval?

    public init() {}

    /// The session whose window is in front under the nose. Near the border between the current session and
    /// another, the current one stays: no flip-flopping between two panes.
    public static func session(at p: CGPoint, in sessions: [ClaudeSession], current: ClaudeSession?,
                               isInFront: (ClaudeSession) -> Bool) -> ClaudeSession? {
        var under = sessions.first { $0.frame.contains(p) && isInFront($0) }
        if let u = under, let t = current, u.id != t.id,
           !u.frame.insetBy(dx: switchMargin, dy: switchMargin).contains(p),
           let still = sessions.first(where: { $0.id == t.id }),
           still.frame.insetBy(dx: -switchMargin, dy: -switchMargin).contains(p) {
            under = still
        }
        return under
    }

    /// Feeds one reading. Returns the session the target just moved onto; nil when it did not move or moved
    /// to nothing. `held` (a pinch or scroll in progress) holds everything still. `speaking` (only meaningful
    /// while listening) freezes a running switch dwell: the time spent speaking does not count.
    public mutating func observe(under: ClaudeSession?, at t: TimeInterval, held: Bool, listening: Bool, speaking: Bool = false) -> ClaudeSession? {
        defer { lastObserved = t }
        if held {
            candidate = nil
        } else if under?.id == target?.id {
            // Same session, read again: keep its fresh frame so the highlight follows a pane that was resized.
            candidate = nil
            if under != nil { target = under }
        } else if let c = candidate, c.session?.id == under?.id {
            let dwell = listening && under != nil ? Self.listeningSwitchDwell : Self.switchDwell
            if listening, speaking, under != nil, let last = lastObserved {
                candidate = (c.session, c.since + max(0, t - last))
                return nil
            }
            if t - c.since >= dwell { target = under; candidate = nil; return under }
        } else {
            candidate = (under, t)
        }
        return nil
    }

    /// The session list was read again: the target and the candidate take their fresh frames, so the highlight
    /// follows a pane Claude resized or moved without waiting for the next reading. One no longer listed is kept as is.
    public mutating func refresh(from sessions: [ClaudeSession]) {
        if let t = target, let fresh = sessions.first(where: { $0.id == t.id }) { target = fresh }
        if let c = candidate, let s = c.session, let fresh = sessions.first(where: { $0.id == s.id }) { candidate = (fresh, c.since) }
    }

    /// The nose rests on a session hidden behind another window. True once it has rested for `raiseDwell`.
    public mutating func noteCovered(_ id: String, at t: TimeInterval) -> Bool {
        if covered?.id != id { covered = (id, t); return false }
        guard let c = covered else { return false }
        return t - c.since >= Self.raiseDwell
    }

    public mutating func clearCovered() { covered = nil }
    public mutating func forgetTarget() { target = nil }
    public mutating func forgetTargetAndCandidate() { target = nil; candidate = nil }
    public mutating func forgetAll() { target = nil; candidate = nil; covered = nil }
}

/// Where the drawn dot rests. A head held still still wobbles a few points after filtering, so a resting dot stays put
/// until the nose leaves `wakeRadius`; once it moves, the dot follows the filtered nose exactly, and it comes to rest
/// again where the nose stopped (the nose stays within `settleRadius` for `settleTime`). A plain leash would leave the
/// dot resting a leash short of where the nose stopped, which reads as drift.
public struct NoseDot {
    public var wakeRadius: CGFloat = 32
    public var settleRadius: CGFloat = 6
    public var settleTime: TimeInterval = 0.15
    /// Readings in a row the nose must spend beyond `wakeRadius`: one noisy reading never wakes the dot. Only fresh
    /// readings count: while the picture is still the camera engine hands the last reading on again ten times a
    /// second, and one stray real reading repeated that way would otherwise wake the dot once a second.
    public var wakeReadings = 3

    public private(set) var dot: CGPoint?
    public private(set) var moving = false
    private var anchor = CGPoint.zero
    private var anchorT = 0.0
    private var outside = 0

    public init() {}

    public mutating func reset() { dot = nil; moving = false; outside = 0 }

    /// The dot's position for this filtered nose reading at time `t`.
    @discardableResult
    public mutating func follow(nose p: CGPoint, at t: TimeInterval, fresh: Bool = true) -> CGPoint {
        guard let d = dot else {
            dot = p; moving = false
            return p
        }
        if !moving {
            guard fresh else { return d }
            guard hypot(p.x - d.x, p.y - d.y) > wakeRadius else { outside = 0; return d }
            outside += 1
            guard outside >= wakeReadings else { return d }
            outside = 0
            moving = true
            anchor = p; anchorT = t
        }
        if hypot(p.x - anchor.x, p.y - anchor.y) > settleRadius || t < anchorT {
            anchor = p; anchorT = t
        } else if t - anchorT >= settleTime {
            moving = false
        }
        dot = p
        return p
    }
}

public enum FocusAction: Equatable {
    case none                  // nothing to do (already focused, or already the dictating session)
    case retryLater            // the user is busy or typing; try again from the tick
    case stopDictationFirst    // dictating elsewhere: stop, keep the text, then move focus
    case focusNow
}

public enum FocusPolicy {
    /// What to do now that the nose settled on `session`. Coming back to the session that already has focus
    /// (after the target dropped for a moment) is not a switch.
    public static func action(for session: ClaudeSession, lastFocusedId: String?, claudeInFront: @autoclosure () -> Bool,
                              busy: Bool, secondsSinceInput: TimeInterval, inputQuiet: TimeInterval,
                              listeningId: String?) -> FocusAction {
        if session.id == lastFocusedId, claudeInFront() { return .none }
        guard !busy, secondsSinceInput >= inputQuiet else { return .retryLater }
        if let listening = listeningId { return listening == session.id ? .none : .stopDictationFirst }
        return .focusNow
    }
}
