#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// How often Claude's session panes are looked for, and what a scan that finds nothing is worth. A full walk of
/// Claude's accessibility tree runs on Claude's own main thread (thousands of nodes per window), so the check that
/// runs every second re-reads only what the last walk cached, and walks again only when something says the layout
/// may have changed.
public enum SessionScan {
    /// A full walk runs at least this often, to find a pane opened inside a window that did not move.
    public static let fullWalkEvery: TimeInterval = 10

    /// `cached`: sessions the last walk found. `windowsChanged`: Claude's window list (numbers, frames, on screen)
    /// differs from the last walk's. `cachedAnswer`: every cached dictation checkbox and pane still answers.
    public static func needsFullWalk(cached: Int, windowsChanged: Bool, cachedAnswer: Bool,
                                     sinceFullWalk: TimeInterval) -> Bool {
        cached == 0 || windowsChanged || !cachedAnswer || !(sinceFullWalk < fullWalkEvery)
    }

    /// While Claude's notifications are watched, the walk that runs regardless is only the net for one Chromium did
    /// not post (a pane opened in a window that did not move, with no divider reported moving).
    public static let safetyWalkEvery: TimeInterval = 15

    public enum Plan: Equatable, Sendable {
        /// Walk Claude's tree again.
        case walk
        /// Re-read each cached dictation checkbox, and each cached pane's frame when `frames`.
        case reread(frames: Bool)
    }

    /// What the 1 s check does. `windowSetChanged`: a Claude window opened, closed or went on or off screen since the
    /// last walk; `boundsChanged`: one moved or changed size (both from the window server, which costs Claude
    /// nothing). `changes`: what Claude's notifications reported since the last check. `observing`: those
    /// notifications are being received; without them every check reads the pane frames and any window change walks,
    /// as before. The dictation checkboxes are read on every check either way (the caller does it): no notification
    /// for them was ever seen, and the standing check needs them as fresh as before.
    public static func plan(cached: Int, windowSetChanged: Bool, boundsChanged: Bool, changes: ClaudeChanges,
                            observing: Bool, sinceFullWalk: TimeInterval) -> Plan {
        guard observing else {
            let walk = needsFullWalk(cached: cached, windowsChanged: windowSetChanged || boundsChanged, cachedAnswer: true,
                                     sinceFullWalk: sinceFullWalk)
            return walk ? .walk : .reread(frames: true)
        }
        if cached == 0 || windowSetChanged || changes.contains(.structure) || !(sinceFullWalk < safetyWalkEvery) {
            return .walk
        }
        return .reread(frames: boundsChanged || changes.contains(.frames))
    }

    /// A pane that moved or changed size inside a window that did not: the panes were laid out again (a divider moved,
    /// or a pane opened or closed), so a pane the cache does not hold may exist. A window move or resize moves every
    /// pane with it and is no reason to walk.
    public static func retiled(cachedFrame: CGRect, frame: CGRect, windowMoved: Bool) -> Bool {
        guard !windowMoved else { return false }
        return abs(cachedFrame.minX - frame.minX) > 1 || abs(cachedFrame.minY - frame.minY) > 1
            || abs(cachedFrame.width - frame.width) > 1 || abs(cachedFrame.height - frame.height) > 1
    }

    /// A window opened, closed, or went on or off screen (another Space, a full-screen app); a move or resize alone
    /// does not count. No earlier list counts as a change.
    public static func windowSetChanged(_ before: [WindowCandidate]?, _ now: [WindowCandidate]) -> Bool {
        guard let before else { return true }
        func set(_ w: [WindowCandidate]) -> [Int: Bool] {
            Dictionary(w.map { ($0.number, $0.onScreen) }, uniquingKeysWith: { a, b in a || b })
        }
        return set(before) != set(now)
    }

    /// Whether window `number` moved or changed size between the two lists; true when either list lacks it.
    public static func windowMoved(_ number: Int, from before: [WindowCandidate]?, to now: [WindowCandidate]) -> Bool {
        guard let old = before?.first(where: { $0.number == number })?.bounds,
              let new = now.first(where: { $0.number == number })?.bounds else { return true }
        return old != new
    }
}

/// What Claude reported changing, from its accessibility notifications and from NSWorkspace.
public struct ClaudeChanges: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Something moved or changed size, or a window may have opened: re-read the cached pane frames and compare the
    /// window server's list.
    public static let frames = ClaudeChanges(rawValue: 1)
    /// A cached element went away, or Claude launched or quit: walk the tree again.
    public static let structure = ClaudeChanges(rawValue: 2)

    /// From an accessibility notification's name (`kAX...Notification`). A window created is only `frames`: Claude
    /// creates and destroys a hidden window about every 22 s (measured 2026-10-15), and a real new window shows in the
    /// window server's list, which the refresh compares anyway.
    public init(notification name: String) {
        switch name {
        case "AXUIElementDestroyed": self = .structure
        case "AXWindowCreated", "AXWindowMoved", "AXWindowResized", "AXValueChanged", "AXLayoutChanged",
             "AXFocusedWindowChanged", "AXMainWindowChanged", "AXWindowMiniaturized", "AXWindowDeminiaturized":
            self = .frames
        default: self = []
        }
    }
}

/// Folds a burst of Claude's notifications into one refresh: dragging a window or a divider posts dozens a second,
/// and each would otherwise cost Claude a round of reads. The first notification schedules one refresh `delay` later;
/// everything until a refresh takes them is folded in.
public struct ChangeCoalescer: Sendable {
    public static let delay: TimeInterval = 0.1

    public private(set) var pending: ClaudeChanges = []
    public private(set) var scheduled = false

    public init() {}

    /// Returns true when the caller should schedule a refresh `delay` from now (none is scheduled yet).
    public mutating func note(_ change: ClaudeChanges) -> Bool {
        guard !change.isEmpty else { return false }
        pending.formUnion(change)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// The scheduled refresh came due; what it reports stays pending until a refresh takes it.
    public mutating func fired() { scheduled = false }

    /// Hands the pending changes to a refresh and clears them.
    public mutating func take() -> ClaudeChanges {
        defer { pending = [] }
        return pending
    }
}

/// Keeps the session list through one doubtful scan. Claude's tree can read empty for a moment while it re-renders
/// (seen as "found 0" between two "found 3" a second apart with Claude in front), and dropping every session for
/// that second refuses gestures and moves the highlight. A doubtful scan (nothing found, or a walk cut short) keeps
/// the previous sessions only while their own dictation checkboxes still answer, and never twice in a row.
public struct SessionListHold: Sendable {
    public private(set) var doubtfulInARow = 0

    public init() {}

    /// Returns true when the caller should keep the previous sessions instead of what this scan found.
    public mutating func keepPrevious(found: Int, walkComplete: Bool, previous: Int, previousAnswer: Bool) -> Bool {
        guard found == 0 || !walkComplete, previous > 0 else { doubtfulInARow = 0; return false }
        doubtfulInARow += 1
        return doubtfulInARow < 2 && previousAnswer
    }

    /// Claude quit or the list was cleared on purpose.
    public mutating func reset() { doubtfulInARow = 0 }
}

/// One of Claude's windows as the window server lists it.
public struct WindowCandidate: Equatable, Sendable {
    public var number: Int
    public var bounds: CGRect
    public var onScreen: Bool

    public init(number: Int, bounds: CGRect, onScreen: Bool) {
        self.number = number; self.bounds = bounds; self.onScreen = onScreen
    }
}

/// Which window-server window an accessibility window is. A session's id is built on the window number, so a wrong
/// or missing match changes every id in that window (and a stop or send looks its session up by id).
public enum WindowMatch {
    /// `axNumber`: the window number Accessibility gave for the window, when it gave one; it decides on its own.
    /// Otherwise the frames are compared, an on-screen window preferred over a hidden one with the same frame, and
    /// while a move or resize has the two frames briefly apart, the one on-screen window that shares at least 80%
    /// of both its own area and the frame's.
    public static func match(axNumber: Int?, axFrame: CGRect, among windows: [WindowCandidate]) -> WindowCandidate? {
        if let n = axNumber, n != 0, let w = windows.first(where: { $0.number == n }) { return w }
        let close = windows.filter { Self.close($0.bounds, axFrame) }
        if let w = close.first(where: \.onScreen) ?? close.first { return w }
        let area = axFrame.width * axFrame.height
        guard area > 0 else { return nil }
        let scored = windows.filter(\.onScreen).map { w -> (WindowCandidate, CGFloat) in
            let i = w.bounds.intersection(axFrame)
            let shared = i.isNull ? 0 : i.width * i.height
            return (w, min(shared / area, shared / max(1, w.bounds.width * w.bounds.height)))
        }
        // Two windows that both nearly cover the frame cannot be told apart: no match beats a wrong one.
        let near = scored.filter { $0.1 >= 0.8 }
        return near.count == 1 ? near[0].0 : nil
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}
