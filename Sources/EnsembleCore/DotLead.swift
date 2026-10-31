#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// Where the drawn dot's spring aims between head readings. A reading is already old when it is drawn and the spring
/// trails a moving goal, so during a quick move the goal runs ahead of the filtered reading along the filter's speed
/// estimate. The lead is `maxLead` for the first half of the gap to the next reading expected and fades to nothing by it, so a
/// head that stops is never extrapolated past its last reading; it never passes the unfiltered reading, which the
/// filtered one is closing on. Only the drawn dot reads it: focus and gestures keep the reading itself.
public struct DotLead: Equatable {
    /// The furthest ahead the goal runs (s).
    public static let maxLead: TimeInterval = 0.04
    /// Below this speed (pt/s) the nose counts as still and the goal is the reading: the rest rule settles a nose that
    /// stays within 6 pt for 0.15 s.
    public static let minSpeed: CGFloat = 40

    /// The filtered reading, its capture time and the filter's speed estimate (pt/s).
    public var point: CGPoint
    public var t: TimeInterval
    public var velocity: DotVelocity
    /// The unfiltered reading.
    public var aim: CGPoint
    /// The gap (s) to the next reading expected: the last gap between readings.
    public var interval: TimeInterval

    public init(point: CGPoint, t: TimeInterval, velocity: DotVelocity, aim: CGPoint, interval: TimeInterval) {
        self.point = point; self.t = t; self.velocity = velocity; self.aim = aim; self.interval = interval
    }

    /// How far ahead (s) the goal runs at display time `now`.
    public func lead(at now: TimeInterval) -> TimeInterval {
        let age = max(now - t, 0)
        guard age < interval, hypot(velocity.dx, velocity.dy) >= Self.minSpeed else { return 0 }
        // Full for the first half of the gap: a lead that starts fading at once cut the step lag by only 23 ms.
        return Self.maxLead * min(2 * (1 - age / interval), 1)
    }

    /// The spring's goal for the refresh shown at `now`.
    public func goal(at now: TimeInterval) -> CGPoint {
        let lead = lead(at: now)
        func axis(_ p: CGFloat, _ v: CGFloat, _ a: CGFloat) -> CGFloat {
            let ahead = p + v * lead
            return v > 0 ? min(ahead, max(p, a)) : max(ahead, min(p, a))
        }
        return CGPoint(x: axis(point.x, velocity.dx, aim.x), y: axis(point.y, velocity.dy, aim.y))
    }
}
