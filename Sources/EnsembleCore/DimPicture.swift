import Foundation

/// Decides whether the picture has stayed too dim for face tracking to be trusted, so the person can be told to turn
/// on a light. Its threshold sits above the covered-lens rule (`CoverDetector`), and it is never true while the lens is covered.
public final class DimPicture {
    public private(set) var dim = false

    static let dimBelow = 0.15
    static let clearAbove = 0.20
    static let holdDim = 4.0
    static let holdClear = 1.0

    private var dimSince: TimeInterval?
    private var brightSince: TimeInterval?

    public init() {}

    /// Returns the new state when it changes, otherwise nil. Between the two thresholds the state holds, so a light
    /// flickering around one level does not flicker the hint.
    public func push(_ l: FrameLight, covered: Bool) -> Bool? {
        if covered {
            dimSince = nil; brightSince = nil
            guard dim else { return nil }
            dim = false
            return false
        }
        dimSince = l.meanLuma < Self.dimBelow ? (dimSince ?? l.t) : nil
        brightSince = l.meanLuma > Self.clearAbove ? (brightSince ?? l.t) : nil
        if !dim, let since = dimSince, l.t - since >= Self.holdDim {
            dim = true
            return true
        }
        if dim, let since = brightSince, l.t - since >= Self.holdClear {
            dim = false
            return false
        }
        return nil
    }
}
