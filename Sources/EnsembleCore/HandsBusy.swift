#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// When to step back: while your hands are on the keyboard, mouse or trackpad, Ensemble moves no focus and holds the
/// highlight, so working by hand never meets a session switch you did not ask for. Gestures still act. Fed once per
/// tick with when each kind of hardware input last happened, on the same clock as `now`.
public struct HandsBusy: Equatable {
    public enum InputKind: String, Equatable, Sendable { case key, click, scroll, move }

    public static let defaultQuiet = 2.0
    public static let quietRange: ClosedRange<Double> = 1...5
    /// A pointer that drifts less than this from where it rested is a nudged desk, not use.
    public static let moveThreshold: CGFloat = 4
    /// A key read within this of a key Ensemble consumed or posted itself is that key.
    public static let ownKeyWindow = 0.25
    /// Ensemble's own scroll moves the pointer and puts it back; movement this close to one is not counted.
    public static let ownPointerWindow = 0.15
    /// Within this long after a resume, or after Ensemble raised Claude or moved its focus, one stray input reading does
    /// not pause again: a second reading with newer input within `confirmWindow` of it is needed. Measured 2026-10-15:
    /// 108 pauses in 46 minutes, 23 of them within 1 s of a resume and 10 within 1 s of Ensemble moving focus.
    public static let repauseGuard = 1.0
    public static let confirmWindow = 0.5

    private struct Reading: Equatable { var at: TimeInterval; var kind: InputKind }

    /// Seconds with no input before Ensemble acts again.
    public var quiet: Double
    public private(set) var lastInputAt: TimeInterval = -.infinity
    /// What the input that last counted was, for the log.
    public private(set) var lastInputKind: InputKind?
    private var anchor: CGPoint?
    private var lastMoveSeen: TimeInterval = -.infinity
    private var candidate: Reading?
    private var resumedAt: TimeInterval = -.infinity
    private var wasPaused = false

    public init(quiet: Double = HandsBusy.defaultQuiet) { self.quiet = quiet }

    /// One reading. `keyAt`, `clickAt`, `scrollAt` and `moveAt` are when that hardware input last happened;
    /// `ownKeyAt` when Ensemble last consumed (a Return it held back) or posted a key; `ownPointerAt` when it last
    /// moved the pointer for its own scroll; `ownFocusAt` when it last raised Claude or moved its keyboard focus.
    /// Returns whether Ensemble is paused.
    @discardableResult
    public mutating func update(now: TimeInterval, keyAt: TimeInterval, clickAt: TimeInterval, scrollAt: TimeInterval,
                                moveAt: TimeInterval, pointer: CGPoint, ownKeyAt: TimeInterval = -.infinity,
                                ownPointerAt: TimeInterval = -.infinity, ownFocusAt: TimeInterval = -.infinity) -> Bool {
        var fresh: Reading?
        let seen = max(lastInputAt, candidate?.at ?? -.infinity)
        func consider(_ t: TimeInterval, _ kind: InputKind) {
            if t.isFinite, t > seen, t > (fresh?.at ?? -.infinity) { fresh = Reading(at: t, kind: kind) }
        }
        if abs(keyAt - ownKeyAt) > Self.ownKeyWindow { consider(keyAt, .key) }
        consider(clickAt, .click)
        consider(scrollAt, .scroll)
        let movedSinceLast = moveAt > lastMoveSeen
        lastMoveSeen = max(lastMoveSeen, moveAt)
        let ownMove = now - ownPointerAt < Self.ownPointerWindow
        if let a = anchor, movedSinceLast, !ownMove {
            // Slow, steady movement adds up from where the pointer last rested, so it still counts.
            if hypot(pointer.x - a.x, pointer.y - a.y) > Self.moveThreshold {
                consider(moveAt, .move)
                anchor = pointer
            }
        } else {
            anchor = pointer
        }
        if let f = fresh {
            let guarded = !isPaused(at: now) && (now - resumedAt < Self.repauseGuard || now - ownFocusAt < Self.repauseGuard)
            if guarded, candidate.map({ f.at - $0.at > Self.confirmWindow }) ?? true {
                candidate = f
            } else {
                lastInputAt = f.at
                lastInputKind = f.kind
                candidate = nil
            }
        }
        let paused = isPaused(at: now)
        if wasPaused, !paused { resumedAt = now }
        wasPaused = paused
        return paused
    }

    public func isPaused(at now: TimeInterval) -> Bool { now - lastInputAt < quiet }
}
