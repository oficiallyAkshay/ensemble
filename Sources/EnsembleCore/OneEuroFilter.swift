import Foundation

/// One Euro filter (Casiez et al.): low-pass whose cutoff rises with signal speed, so slow drift is
/// smoothed hard and fast motion stays responsive.
public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var lastT: Double?
    private var lastRaw = 0.0
    private var lastFiltered = 0.0
    private var lastDerivative = 0.0

    public init(minCutoff: Double = 0.6, beta: Double = 3, dCutoff: Double = 1) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    /// The smoothed speed of the input (units per second) at the last reading; the drawn dot leads by it (`DotLead`).
    public var speed: Double { lastDerivative }

    public mutating func reset() { lastT = nil }

    public mutating func filter(_ x: Double, at t: Double) -> Double {
        // A NaN or infinity must never enter the state: it would poison every later reading until a reset.
        guard x.isFinite, t.isFinite else { return lastFiltered }
        guard let prevT = lastT else {
            lastT = t; lastRaw = x; lastFiltered = x; lastDerivative = 0
            return x
        }
        guard t > prevT else { return lastFiltered }
        let dt = t - prevT
        let rawDerivative = (x - lastRaw) / dt
        let derivative = lastDerivative + Self.alpha(cutoff: dCutoff, dt: dt) * (rawDerivative - lastDerivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let filtered = lastFiltered + Self.alpha(cutoff: cutoff, dt: dt) * (x - lastFiltered)
        lastT = t; lastRaw = x; lastFiltered = filtered; lastDerivative = derivative
        return filtered
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
