#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// Fitting the session you look at to Claude's chat column.
///
/// Claude's transcript text never grows past a fixed column (its `--max-content-width`, centred in the pane), so a
/// pane wider than that column only adds empty margins and a pane narrower wraps the text early. When focus settles
/// on a pane narrower than the column, the pane is widened to a little more than the column (`headroom`), the width
/// taken through as few dividers as possible and from panes that stay at the column where the row allows, none going
/// below `PaneWidths.narrowWidth`.
public enum SessionFit {
    /// How long the nose must rest inside one session, with focus on it the whole time, before it is fitted, so a
    /// nose passing over a pane never resizes it. 0.6 s fitted panes the nose only crossed (owner, 0.2.18).
    public static let settle: Double = 0.8
    /// Claude's chat column, used until one is measured: a 768 pt text measure plus a 32 pt gutter each side, read
    /// from the stylesheet of the Claude desktop app installed on the owner's Mac on 2026-10-15 (the default
    /// transcript width; Claude's wider settings use 960 and 1280).
    public static let fallbackColumn: Double = 832

    /// How much wider than the chat column a fit makes a pane: a little room so the text is never wrapped early,
    /// never more (owner, 0.2.20: "only expand 10% more than the default chat width").
    public static let headroom = 1.10

    /// The width a fit gives a pane whose transcript shows the whole column at `paneColumn` (the column plus the
    /// pane's own padding, `ChatColumn.paneWidth`).
    public static func fitWidth(paneColumn: Double) -> Double { paneColumn * headroom }

    /// The width of every pane in the row so pane `focus` reaches `width`, never more, moving as few of Claude's
    /// dividers as possible. A divider only shifts width between its two panes, so taking from the next pane costs
    /// one divider and from the one after it two. The width comes from the fewest panes beside the focus that can
    /// give it while each stays at or above `keep` (the chat column), the wider side first; only when no such panes
    /// can do they give it down to `minimum` or their entry in `floors` (a pane fitted a moment ago keeps its fit),
    /// again from the fewest. Inside the chosen panes the width above `keep` goes first, widest first, then the rest in
    /// equal shares. When the whole row cannot give it all, the pane gets what it can. nil when the pane is already
    /// within `PaneWidths.tolerance` of `width`, or nothing can give.
    ///
    /// The owner's row on 0.2.20, [565, 320, 1674] fitting the middle pane, took 240 pt from each side, left the first
    /// pane at Claude's minimum while the last stayed twice the column, and moved both dividers: now the last pane
    /// gives it all through one divider.
    public static func widths(current: [Double], focus k: Int, width: Double, keep: Double? = nil,
                              minimum: Double = PaneWidths.narrowWidth, floors: [Double] = []) -> [Double]? {
        let n = current.count
        guard n >= 2, current.indices.contains(k), width.isFinite, current.allSatisfy(\.isFinite) else { return nil }
        let need = width - current[k]
        guard need > PaneWidths.tolerance else { return nil }
        let keep = min(keep ?? width, width)
        let low = current.indices.map { i in max(minimum, floors.indices.contains(i) && floors[i].isFinite ? floors[i] : 0) }
        let high = current.indices.map { max(keep, low[$0]) }
        func room(_ i: Int, _ floor: [Double]) -> Double { i == k ? 0 : max(0, current[i] - floor[i]) }
        // Every run of panes around the focus, fewest dividers first; ties go to the side that can give more.
        var spans: [(lo: Int, hi: Int, cost: Int)] = []
        for lo in 0...k { for hi in k..<n { spans.append((lo, hi, hi - lo)) } }
        func best(_ floor: [Double]) -> (lo: Int, hi: Int)? {
            spans.filter { s in (s.lo...s.hi).map { room($0, floor) }.reduce(0, +) >= need }
                .min { a, b in
                    a.cost != b.cost ? a.cost < b.cost
                        : (a.lo...a.hi).map { room($0, floor) }.reduce(0, +) > (b.lo...b.hi).map { room($0, floor) }.reduce(0, +)
                }
                .map { ($0.lo, $0.hi) }
        }
        let span = best(high) ?? best(low) ?? (0, n - 1)
        let donors = (span.lo...span.hi).filter { $0 != k }
        var out = current
        var left = need
        // Width above the column first, widest first: it is only empty margin beside the column.
        for i in donors.sorted(by: { current[$0] > current[$1] }) where left > 0 {
            let give = min(left, room(i, high))
            out[i] -= give
            left -= give
        }
        // Then equal shares; a pane that reaches its floor gives what it has and the rest is shared by the others.
        var spare = current.indices.map { donors.contains($0) ? max(0, out[$0] - low[$0]) : 0 }
        var giving = donors.filter { spare[$0] > 0 }
        while left > 0.001, !giving.isEmpty {
            let share = left / Double(giving.count)
            let short = giving.filter { spare[$0] < share }
            if short.isEmpty {
                for i in giving { out[i] -= share }
                left = 0
            } else {
                for i in short { out[i] -= spare[i]; left -= spare[i]; spare[i] = 0 }
                giving.removeAll { spare[$0] == 0 }
            }
        }
        out[k] = current[k] + need - max(0, left)
        return out[k] - current[k] > PaneWidths.tolerance ? out : nil
    }

    /// The widths for fitting pane `focus`, the one the nose rests on: panes fitted within `Hold.window` keep their
    /// fit (`floors`) while the others can give the width, so fits do not undo each other; when they cannot, the pane
    /// you rest on wins and every other pane gives its equal share. nil when there is nothing to do.
    public static func restingFit(current: [Double], focus k: Int, width: Double, keep: Double? = nil,
                                  minimum: Double = PaneWidths.narrowWidth, floors: [Double]) -> [Double]? {
        if let kept = widths(current: current, focus: k, width: width, keep: keep, minimum: minimum, floors: floors),
           kept[k] >= width - PaneWidths.tolerance { return kept }
        return widths(current: current, focus: k, width: width, keep: keep, minimum: minimum)
    }

    /// What earlier fits leave in force. A pane fitted within `window` keeps its fitted width as a floor while
    /// another pane is fitted (`restingFit`), and nothing is fitted in the first `afterCalibration` seconds after a
    /// calibration, while the nose is still settling. A pane a fit narrowed is fitted again as soon as you rest on
    /// it: every fit now waits for a rest (`Trigger`), and a rule that kept those panes narrow for three minutes
    /// refused the session the owner was working in (0.2.18).
    public struct Hold: Sendable {
        public static let window: TimeInterval = 180
        public static let afterCalibration: TimeInterval = 5

        private var fitted: [String: (width: Double, at: TimeInterval)] = [:]

        public init() {}

        /// Why no pane may be fitted now, or nil. `calibratedAt`: when a calibration last ran (-infinity if never).
        public func refusal(now: TimeInterval, calibratedAt: TimeInterval) -> String? {
            now - calibratedAt < Self.afterCalibration ? "calibration just ended" : nil
        }

        /// The width each pane of the row keeps: its fitted width when it was fitted within `window`, else 0. The
        /// pane `focus` is about to be fitted itself and keeps nothing.
        public func floors(_ ids: [String], focus k: Int, now: TimeInterval) -> [Double] {
            ids.indices.map { i in
                guard i != k, let f = fitted[ids[i]], now - f.at < Self.window else { return 0 }
                return f.width
            }
        }

        /// A fit of `id` to `width` ran; `narrowed` are the panes it took width from, which no longer keep a fit.
        public mutating func noteFit(_ id: String, width: Double, narrowed ids: [String], at now: TimeInterval) {
            fitted[id] = (width, now)
            for n in ids { fitted[n] = nil }
        }

        /// The owner asked for a layout (maximize, even out): earlier fits no longer hold anything.
        public mutating func reset() { fitted = [:] }
    }

    /// Once per focus change, after the nose has rested inside the focused session for `settle`.
    public struct Trigger: Sendable {
        private var session: String?
        private var since: TimeInterval = 0
        private var fired = false

        public init() {}

        /// The session to fit now, or nil. Feed it the focused session and whether the nose is inside its frame on
        /// every tick; it answers once per focus change, and only after that session has been the focus with the
        /// nose inside it for `settle` seconds without a break. A focus change starts the wait again.
        public mutating func observe(_ focused: String?, inside: Bool, at t: TimeInterval) -> String? {
            if focused != session { session = focused; since = t; fired = false }
            if !inside { since = t }
            guard let id = session, !fired, t - since >= SessionFit.settle else { return nil }
            fired = true
            return id
        }

        /// The fit it answered could not run yet (hands on the keyboard, another resize running): it answers again
        /// on the next tick while the nose still rests there, and never once focus has moved on.
        public mutating func retry() { fired = false }

        /// True while `observe` may still answer for `focused`: a focus it has not seen yet, or one still settling.
        /// The tick runs on a timer only while this or another time-based step waits.
        public func waiting(for focused: String?) -> Bool {
            guard let focused else { return false }
            return focused != session || !fired
        }
    }
}

/// Claude's chat column, read from the accessibility tree.
///
/// In a pane wider than the column, the column is an element centred in the transcript with empty space on both
/// sides; in a narrower pane it fills the transcript and the column's own width cannot be seen. So the column is
/// read from whichever pane is wide enough to show it, remembered, and `SessionFit.fallbackColumn` stands in until
/// one is.
public enum ChatColumn {
    /// Wider than any text measure Claude offers (1280 pt plus gutters); larger readings are not the column.
    static let widest: Double = 1400
    /// Narrower than any Claude offers; smaller readings are a message bubble or a card, not the column.
    static let narrowest: Double = 600
    /// The column must leave at least this much empty transcript beside it, so a pane only a little wider than its
    /// column (where padding and the column are hard to tell apart) is never read.
    static let slack: Double = 96
    /// How far off the transcript's centre the column may sit (a scrollbar or uneven gutters).
    static let offCentre: Double = 12

    /// The column's width in one pane: the widest element under the transcript that is centred in it and leaves
    /// `slack` beside it. nil when the pane is not wide enough to show the column.
    public static func measure(transcript: CGRect, elements: [CGRect]) -> Double? {
        guard transcript.width > 0, transcript.minX.isFinite else { return nil }
        let fits = elements.filter { e in
            let w = Double(e.width)
            return w >= narrowest && w <= widest && Double(transcript.width) - w >= slack
                && abs(Double(e.midX - transcript.midX)) <= offCentre
        }
        return fits.map { Double($0.width) }.max()
    }

    /// How wide a pane must be for its transcript to show the whole column: the column plus whatever the pane holds
    /// beside its transcript (borders, a scrollbar), read from that pane. A transcript that cannot be read, or reads
    /// wider than its pane, adds nothing.
    public static func paneWidth(column: Double, pane: CGRect, transcript: CGRect?) -> Double {
        guard let t = transcript, t.width > 0 else { return column }
        let beside = Double(pane.width - t.width)
        return column + (beside >= 0 && beside <= 200 ? beside : 0)
    }

    /// The widest column read reliably, kept: a reading counts only when it is one of Claude's own columns (its
    /// three transcript widths with their gutters, `known`) or when panes at least `spread` apart in width read the
    /// same column. A reading that follows the pane's width is padding, not the column: on 2026-10-15 a pane of
    /// 742 to 960 pt read as its own width less 128, and taking each latest reading shrank the column 832, 736, 646.
    public struct Memory: Sendable {
        /// Claude's 768, 960 and 1280 pt text measures with their 32 pt gutters.
        public static let known: [Double] = [832, 1024, 1344]
        /// The same three text measures without their gutters. On 0.2.20 the owner's panes read 773 pt, the 768 pt
        /// text and not the column around it, and a fit to 773 wrapped the text narrower than Claude's own column.
        static let text: [Double] = [768, 960, 1280]
        static let gutters: Double = 64
        static let textMatch: Double = 12
        static let match: Double = 4
        static let spread: Double = 64
        static let kept = 12

        public private(set) var measured: Double?
        private var seen: [(column: Double, pane: Double)] = []

        public init() {}
        /// Never narrower than Claude's narrowest column, which is also the default.
        public var width: Double { max(measured ?? SessionFit.fallbackColumn, SessionFit.fallbackColumn) }

        /// A reading of a text measure alone is that measure with its gutters.
        static func column(_ r: Double) -> Double {
            text.first { abs($0 - r) <= textMatch }.map { $0 + gutters } ?? r
        }

        /// One scan's readings, one per pane, with each pane's width.
        public mutating func note(_ readings: [Double?], panes: [Double]) {
            for (raw, pane) in zip(readings, panes) {
                guard let raw, raw.isFinite, pane.isFinite else { continue }
                let r = Self.column(raw)
                let known = Self.known.contains { abs($0 - r) <= Self.match }
                let agreed = seen.contains { abs($0.column - r) <= Self.match && abs($0.pane - pane) >= Self.spread }
                if known || agreed { measured = max(measured ?? 0, r) }
                seen.append((r, pane))
                if seen.count > Self.kept { seen.removeFirst(seen.count - Self.kept) }
            }
        }
    }
}
