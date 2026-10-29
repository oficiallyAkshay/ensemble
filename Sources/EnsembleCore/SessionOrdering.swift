#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Orders open Claude sessions the way they sit on screen, for the island's "focus is moving" glyph.
public enum SessionOrdering {
    /// `sessions` left to right: by screen (left to right, by `screens[i].minX`), then by each session's own
    /// `frame.minX` within that screen. A session whose centre falls inside no given screen sorts after every
    /// session that is on one. `group` increases at each boundary between screens or between windows on the
    /// same screen, so the layout can widen the gap there; it never increases within one window on one screen.
    public static func ordered(_ sessions: [ClaudeSession], screens: [CGRect]) -> [(session: ClaudeSession, group: Int)] {
        func screenIndex(of s: ClaudeSession) -> Int {
            let p = CGPoint(x: s.frame.midX, y: s.frame.midY)
            return screens.firstIndex { $0.contains(p) } ?? screens.count
        }
        let sorted = sessions.enumerated().sorted { a, b in
            let sa = screenIndex(of: a.element), sb = screenIndex(of: b.element)
            if sa != sb { return sa < sb }
            if a.element.frame.minX != b.element.frame.minX { return a.element.frame.minX < b.element.frame.minX }
            return a.offset < b.offset
        }.map(\.element)

        var result: [(session: ClaudeSession, group: Int)] = []
        var group = 0
        var previousKey: (screen: Int, window: Int)?
        for s in sorted {
            let key = (screen: screenIndex(of: s), window: s.windowNumber)
            if let previous = previousKey, previous != key { group += 1 }
            result.append((s, group))
            previousKey = key
        }
        return result
    }
}
