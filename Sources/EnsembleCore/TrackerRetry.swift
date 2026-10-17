import Foundation

/// How long to wait before starting a failed face tracker again. The first retry is immediate (a single slow cold
/// start under load is the usual cause); after that the wait doubles up to `cap` and never stops, because the
/// camera keeps running and nothing else would ever start the tracker again. A good head reading or a camera
/// start resets it and cancels a waiting retry.
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

    /// The retry now waiting, numbered so a wait that a reset cancelled finds it is no longer due.
    public private(set) var waiting: Int?
    private var lastWait = 0

    /// A tracker failure: counts it and returns the wait (`nextDelay`), numbering the retry when it has to wait. A
    /// failure while a retry already waits is the failed page reporting again, with no start since: nil, nothing counted.
    public mutating func failed() -> TimeInterval? {
        guard waiting == nil else { return nil }
        let delay = nextDelay()
        if delay > 0 { lastWait += 1; waiting = lastWait }
        return delay
    }

    /// True once, for the retry still waiting; false for one a reset cancelled.
    public mutating func due(_ wait: Int) -> Bool {
        guard wait == waiting else { return false }
        waiting = nil
        return true
    }

    /// A good head reading or a camera start: the tracker works or was just started, so a waiting retry is cancelled.
    public mutating func reset() { failures = 0; waiting = nil }
}
