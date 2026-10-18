import Foundation

/// Plans the key presses that resize the side-by-side session panes of one Claude window.
///
/// Claude's divider between two panes (an `AXSplitter` labelled "Resize pane columns") moves with the keyboard once
/// it holds keyboard focus: an arrow moves it 8 pt, Shift and an arrow 32 pt, Home and End to the pair's limit (the
/// pane on that side down to Claude's minimum width). Setting its value through Accessibility is accepted and
/// ignored. A press changes only the two panes beside that divider, so width reaches a pane two places away by
/// moving every divider in between, the outer one first. Measured on the owner's Claude on 2026-10-15: keys 10 ms
/// apart all land, Claude's frames read back about 170 ms after a key, and moving the keyboard to another divider
/// takes 12 to 140 ms after a single key and 0.7 to 1.6 s after a burst. So a plan visits each divider once, sends
/// all of that divider's keys in one burst, and uses as few keys as it can: Home or End wherever a move ends on a
/// limit, Shift steps for the bulk of any other move and at most two arrows, never a long run of arrows.
///
/// Widths here are the panes' own widths without the gaps between them; a press keeps the pair's sum.
public enum PaneKeys {
    public enum Key: Equatable, Sendable {
        case left, right, shiftLeft, shiftRight, home, end

        /// How far the divider moves, in points, right positive; nil for Home and End, which go to a limit.
        public var step: Double? {
            switch self {
            case .left: return -arrow
            case .right: return arrow
            case .shiftLeft: return -shiftArrow
            case .shiftRight: return shiftArrow
            case .home, .end: return nil
            }
        }
    }

    public struct Press: Equatable, Sendable {
        public let divider: Int
        public let key: Key
        public init(_ divider: Int, _ key: Key) { self.divider = divider; self.key = key }
    }

    public static let arrow: Double = 8
    public static let shiftArrow: Double = 32
    /// Seconds between the keys of one divider's burst, as fast as the owner asked for (0.2.20): a 20-key move
    /// takes about 40 ms, one quick slide. Not measured on Claude yet; a pass that lands off its plan is followed by
    /// one at `safeInterval`, the pace measured to land every key.
    public static let interval: Double = 0.002
    /// Keys 10 ms apart all landed (measured 2026-10-15), and Claude draws the burst as one move.
    public static let safeInterval: Double = 0.01
    /// Claude's minimum pane width when its dividers report no limits (the limits read 24 percent of a 1320 pt pair).
    public static let fallbackMinimum: Double = 316

    /// Claude's minimum pane width from its dividers. Each reports its pair's limits in whole percent of the pair's
    /// width; the largest reading is used so a planned width is never one Claude refuses.
    public static func minimum(pairWidths: [Double], minPercents: [Double?]) -> Double {
        let readings = zip(pairWidths, minPercents).compactMap { w, p -> Double? in
            guard let p, p > 0, p < 50, w.isFinite, w > 0 else { return nil }
            return w * p / 100
        }
        return readings.max() ?? fallbackMinimum
    }

    /// Every pane the same width.
    public static func evenWidths(_ widths: [Double]) -> [Double]? {
        guard widths.count >= 2, valid(widths) else { return nil }
        return Array(repeating: widths.reduce(0, +) / Double(widths.count), count: widths.count)
    }

    /// The presses that take the row from `widths` toward `target`, each divider once in an order where every move
    /// fits: dividers moving right go from the rightmost of each run inward, dividers moving left from the leftmost,
    /// so a divider never runs into a neighbour that has yet to make room. A move that ends on a limit is Home or End.
    /// Any other is Shift steps and at most two arrows, or with `jumps` a Home or End and Shift steps back when the
    /// target is nearer that limit than the divider is now. Empty when nothing needs to move or the input does not describe one row (counts differ, totals
    /// differ, non-finite).
    public static func plan(from widths: [Double], to target: [Double], minimum m: Double, jumps: Bool = true) -> [Press] {
        let n = widths.count
        guard n >= 2, target.count == n, valid(widths), valid(target), m.isFinite, m > 0,
              abs(widths.reduce(0, +) - target.reduce(0, +)) <= 1 else { return [] }
        var cur = widths
        var out: [Press] = []
        let goal = edges(target)
        let start = edges(widths)
        let moves = (0..<(n - 1)).filter { abs(goal[$0] - start[$0]) > arrow / 2 }
        let rightward = moves.filter { goal[$0] > start[$0] }
        let leftward = moves.filter { goal[$0] < start[$0] }
        // A rightward divider waits for the one to its right when that one also moves right; a leftward one for the
        // one to its left. Runs are independent of each other.
        var order: [Int] = []
        for j in (0..<(n - 1)) where moves.contains(j) {
            if rightward.contains(j), !rightward.contains(j - 1) {
                var end = j
                while rightward.contains(end + 1) { end += 1 }
                order += (j...end).reversed()
            } else if leftward.contains(j), !leftward.contains(j - 1) {
                var end = j
                while leftward.contains(end + 1) { end += 1 }
                order += Array(j...end)
            }
        }
        for j in order {
            let at = edges(cur)
            let lo = (j == 0 ? 0 : at[j - 1]) + m
            let hi = at[j + 1] - m
            guard lo <= hi else { continue }
            let to = min(max(goal[j], lo), hi)
            let keys = moveKeys(from: at[j], to: to, lo: lo, hi: hi, jumps: jumps).map { Press(j, $0) }
            cur = simulate(cur, minimum: m, presses: keys)
            out += keys
        }
        return out
    }

    /// How long the keys take at `pace`, not counting the moves of the keyboard from one divider to the next.
    public static func duration(_ presses: [Press], pace: Double = interval) -> Double { Double(presses.count) * pace }

    /// What the presses do to a row whose panes cannot go below `minimum`, as Claude does it.
    public static func simulate(_ widths: [Double], minimum: Double, presses: [Press]) -> [Double] {
        var w = widths
        for p in presses where p.divider >= 0 && p.divider + 1 < w.count {
            let pair = w[p.divider] + w[p.divider + 1]
            guard pair >= 2 * minimum else { continue }
            let left: Double
            switch p.key {
            case .home: left = minimum
            case .end: left = pair - minimum
            default: left = min(max(w[p.divider] + (p.key.step ?? 0), minimum), pair - minimum)
            }
            w[p.divider] = left
            w[p.divider + 1] = pair - left
        }
        return w
    }

    /// The keys that move one divider from `x` to `y`, its limits `lo` and `hi`. A move to a limit is Home or End
    /// alone, so it lands exactly where Claude's own minimum puts it whatever the estimate. With `jumps`, a target
    /// nearer the limit it moves toward than to where the divider is now starts with Home or End, one key for the
    /// bulk of the move, and Shift steps back from that limit correct it.
    static func moveKeys(from x: Double, to y: Double, lo: Double, hi: Double, jumps: Bool) -> [Key] {
        let d = y - x
        if abs(y - hi) < 0.5 && d > 0 { return [.end] }
        if abs(y - lo) < 0.5 && d < 0 { return [.home] }
        let steps = stepKeys(d)
        guard jumps else { return steps }
        let (jump, from) = d > 0 ? (Key.end, hi) : (Key.home, lo)
        guard abs(y - from) < abs(d) else { return steps }
        let alt = [jump] + stepKeys(y - from)
        return alt.count <= steps.count ? alt : steps
    }

    /// Shift steps for the bulk and at most two arrows, to the nearest arrow: a rest of three arrows is one more
    /// Shift step and one arrow back.
    static func stepKeys(_ d: Double) -> [Key] {
        let a = abs(d)
        var shifts = Int(a / shiftArrow)
        var arrows = Int(((a - Double(shifts) * shiftArrow) / arrow).rounded())
        if arrows * Int(arrow) >= Int(shiftArrow) { shifts += 1; arrows = 0 }
        let (shift, fine, back): (Key, Key, Key) = d > 0 ? (.shiftRight, .right, .left) : (.shiftLeft, .left, .right)
        if arrows > 2 { return Array(repeating: shift, count: shifts + 1) + Array(repeating: back, count: 4 - arrows) }
        return Array(repeating: shift, count: shifts) + Array(repeating: fine, count: arrows)
    }

    /// Where each divider sits, measured from the row's left edge in pane widths only.
    static func edges(_ widths: [Double]) -> [Double] {
        var sum = 0.0
        return widths.map { sum += $0; return sum }
    }

    static func valid(_ w: [Double]) -> Bool { w.allSatisfy { $0.isFinite && $0 > 0 } }
}
