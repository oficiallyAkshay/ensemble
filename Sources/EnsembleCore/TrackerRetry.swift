import Foundation

/// How long to wait before starting a failed face tracker again. The first retry is immediate (a single slow cold
/// start under load is the usual cause); after that the wait doubles up to `cap` and never stops, because the
/// camera keeps running and nothing else would ever start the tracker again. A good head reading or a camera
/// start resets it.
public struct TrackerRetry: Equatable {
    public static let cap: TimeInterval = 30
    /// Failures since the last reset.
    public private(set) var failures = 0

    public init() {}

    /// Counts one more failure and returns the wait before the next start: 0, 2, 4, 8, 16, then 30 s.
    public mutating func nextDelay() -> TimeInterval {
        failures += 1
        guard failures > 1 else { return 0 }
        return min(Self.cap, pow(2, Double(failures - 1)))
    }

    public mutating func reset() { failures = 0 }
}
