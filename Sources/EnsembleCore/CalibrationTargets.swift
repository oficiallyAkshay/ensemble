#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Where a screen's five calibration dots go: centre, left, right, top, bottom, in global top-left coordinates.
public enum CalibrationTargets {
    /// Share of the screen's width and height the edge dots sit in from each edge. 4%, set by the owner on 2026-10-15
    /// (was 8%): sessions at a screen's edge are then measured by the calibration rather than extrapolated.
    public static let inset = 0.04
    /// The dot's largest drawn radius (its breathing halo, 84 points across): every edge dot stays this far in, so it
    /// is drawn whole on a small screen too.
    public static let dotRadius: CGFloat = 42

    /// `topReserve`: points at the top of the screen the dot must also clear (the menu bar, or the notch's safe area).
    public static func points(in frame: CGRect, topReserve: CGFloat = 0) -> [CGPoint] {
        let dx = max(frame.width * inset, dotRadius)
        let top = max(frame.height * inset, max(topReserve, 0) + dotRadius)
        let bottom = max(frame.height * inset, dotRadius)
        return [
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.minX + dx, y: frame.midY),
            CGPoint(x: frame.maxX - dx, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + top),
            CGPoint(x: frame.midX, y: frame.maxY - bottom),
        ]
    }
}
