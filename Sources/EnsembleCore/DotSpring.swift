#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// A speed in points per second along each axis. Local so the spring does not need CoreGraphics' vector type.
public struct DotVelocity: Equatable {
    public var dx: CGFloat
    public var dy: CGFloat

    public static let zero = DotVelocity(dx: 0, dy: 0)
}

/// Moves the drawn nose dot toward the latest pointer reading on every screen refresh, as a critically damped
/// spring. Head readings arrive 15 to 30 times a second and the screen refreshes 50 to 120 times; a spring carries
/// its speed from one reading into the next, so the dot glides through them instead of stopping at each one (an
/// exponential glide restarts from rest at every reading, which reads as a stutter at the reading rate). Critical
/// damping never overshoots, so the dot never swings past where the nose points.
public struct DotSpring {
    /// Stiffness as an angular frequency (1/s). A step is 90% covered after about 3.9 / omega seconds.
    public var omega: Double
    public private(set) var position: CGPoint?
    public private(set) var velocity = DotVelocity.zero

    /// The dot counts as arrived inside this distance (pt) and below this speed (pt/s); the caller can stop ticking.
    public static let restDistance: CGFloat = 0.25
    public static let restSpeed: CGFloat = 2
    /// Above this speed (pt/s) the dot moves more than 8 pt a frame at 60 Hz, almost half its width, so its window asks
    /// the screen for 120 Hz; slower, 60 Hz looks the same at half the refreshes.
    public static let fastSpeed: CGFloat = 480

    public var isFast: Bool { hypot(velocity.dx, velocity.dy) > Self.fastSpeed }

    public init(omega: Double = 32) { self.omega = omega }

    /// Puts the dot straight at `p` with no motion (the first reading, or after it was hidden).
    public mutating func reset(to p: CGPoint) {
        position = p
        velocity = .zero
    }

    public mutating func clear() {
        position = nil
        velocity = .zero
    }

    /// Advances `dt` seconds toward `goal` and returns where the dot is now. Exact for any `dt`, so a late or
    /// dropped refresh never makes it overshoot or wobble.
    @discardableResult
    public mutating func step(toward goal: CGPoint, dt: Double) -> CGPoint {
        // A non-finite goal must never enter the state: it would poison every later step.
        guard goal.x.isFinite, goal.y.isFinite else { return position ?? goal }
        guard let p = position else { reset(to: goal); return goal }
        guard dt > 0, dt.isFinite else { return p }
        let w = omega, e = exp(-w * dt)
        func axis(_ x0: Double, _ v0: Double) -> (Double, Double) {
            // x(t) = (x0 + (v0 + w x0) t) e^(-wt), relative to the goal.
            let c = v0 + w * x0
            return ((x0 + c * dt) * e, (v0 - w * c * dt) * e)
        }
        let (x, vx) = axis(Double(p.x - goal.x), Double(velocity.dx))
        let (y, vy) = axis(Double(p.y - goal.y), Double(velocity.dy))
        let next = CGPoint(x: goal.x + CGFloat(x), y: goal.y + CGFloat(y))
        position = next
        velocity = DotVelocity(dx: vx, dy: vy)
        return next
    }

    /// True once the dot sits on `goal` and has stopped moving.
    public func isResting(at goal: CGPoint) -> Bool {
        guard let p = position else { return true }
        return hypot(p.x - goal.x, p.y - goal.y) < Self.restDistance && hypot(velocity.dx, velocity.dy) < Self.restSpeed
    }
}
