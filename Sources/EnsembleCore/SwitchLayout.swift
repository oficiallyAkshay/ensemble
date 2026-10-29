#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// One column's position and width inside the glyph, left to right.
public struct SessionColumn: Equatable, Sendable {
    public var x: CGFloat
    public var width: CGFloat
    public init(x: CGFloat, width: CGFloat) { self.x = x; self.width = width }
}

/// The pure layout math for the island's "focus is moving" glyph: one outlined column per open session,
/// and where the lit column sits between the session losing focus and the one gaining it.
public enum SwitchLayout {
    /// Columns stay at a legible size for at least this many open sessions before spacing starts to compress.
    public static let legibleColumns = 10

    private static let baseSpacing: CGFloat = 3
    private static let minSpacing: CGFloat = 0.75
    private static let minColumnWidth: CGFloat = 2
    /// How much wider a gap between groups (different screens or windows) is than a gap within one.
    private static let groupGapScale: CGFloat = 1.8

    /// One column per open session, always scaled to fill `width` exactly: spacing compresses toward its
    /// floor first, keeping columns legible as long as the width allows; column width shrinks only once
    /// spacing is already at that floor. `groupBreaks` holds the column index (1..<count) that starts each
    /// new screen or window group; those gaps use `groupGapScale`. Total width never exceeds `width`.
    public static func columns(count: Int, groupBreaks: Set<Int>, width: CGFloat) -> [SessionColumn] {
        guard count > 0, width > 0 else { return [] }
        let breaks = groupBreaks.filter { $0 > 0 && $0 < count }
        let gapUnits = CGFloat(count - 1 - breaks.count) + CGFloat(breaks.count) * groupGapScale

        var spacing = baseSpacing
        var colWidth = gapUnits > 0 ? (width - gapUnits * spacing) / CGFloat(count) : width / CGFloat(count)
        if gapUnits > 0, colWidth < minColumnWidth {
            colWidth = minColumnWidth
            spacing = max(minSpacing, (width - CGFloat(count) * colWidth) / gapUnits)
            if spacing == minSpacing {
                colWidth = (width - gapUnits * minSpacing) / CGFloat(count)
            }
        }
        colWidth = max(0, colWidth)

        // So many columns that even the floors above do not fit (minimum spacing alone exceeds width): shrink
        // both together by whatever it takes, so the total still lands on width, not past it.
        let total = CGFloat(count) * colWidth + gapUnits * spacing
        if total > width {
            let scale = width / total
            colWidth *= scale
            spacing *= scale
        }

        var cols: [SessionColumn] = []
        var x: CGFloat = 0
        for i in 0..<count {
            if i > 0 { x += breaks.contains(i) ? spacing * groupGapScale : spacing }
            cols.append(SessionColumn(x: x, width: colWidth))
            x += colWidth
        }
        return cols
    }

    /// The lit column while focus moves from `from` to `to`: `progress` 0 sits over `from`, 1 over `to`.
    /// Indices outside `columns` clamp to the first or last column; `nil` only when there are no columns.
    public static func litColumn(from: Int, to: Int, progress: Double, in columns: [SessionColumn]) -> SessionColumn? {
        guard !columns.isEmpty else { return nil }
        let f = columns[min(max(from, 0), columns.count - 1)]
        let t = columns[min(max(to, 0), columns.count - 1)]
        let p = CGFloat(min(max(progress, 0), 1))
        return SessionColumn(x: f.x + (t.x - f.x) * p, width: f.width + (t.width - f.width) * p)
    }
}
