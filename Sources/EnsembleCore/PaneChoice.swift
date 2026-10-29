#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// One ancestor of a session's dictation checkbox, as read from Claude's accessibility tree: how big it is
/// and which parts of the page its subtree holds.
public struct PaneAncestor: Equatable, Sendable {
    public var frame: CGRect
    /// The session's own title button (its description ends in ", rename session").
    public var hasHeader: Bool
    public var hasTranscript: Bool
    public var hasComposer: Bool
    /// The left navigation group, which also carries the window's top bar buttons.
    public var hasSidebar: Bool
    /// Dictation checkboxes of other sessions inside this ancestor.
    public var otherMics: Int

    public init(frame: CGRect, hasHeader: Bool, hasTranscript: Bool, hasComposer: Bool,
                hasSidebar: Bool = false, otherMics: Int = 0) {
        self.frame = frame
        self.hasHeader = hasHeader
        self.hasTranscript = hasTranscript
        self.hasComposer = hasComposer
        self.hasSidebar = hasSidebar
        self.otherMics = otherMics
    }

    /// Everything a session consists of, and nothing of the window around it.
    var isWholeSessionOnly: Bool { hasHeader && hasTranscript && hasComposer && !hasSidebar }
}

/// Which ancestor of the dictation checkbox is the session's pane. The pane frame drives the highlight,
/// the focus target and the edge warnings, so it must be the chat session and nothing around it.
public enum PaneChoice {
    /// `ancestors` run from the outermost (just below the web area) to the checkbox's parent.
    /// With several sessions: the highest ancestor that holds only this checkbox, the session column.
    /// With one session that rule would be the whole page, so: the smallest ancestor that still holds the
    /// session's header, transcript and composer and no sidebar. Returns an index into `ancestors`.
    public static func index(among ancestors: [PaneAncestor]) -> Int? {
        guard !ancestors.isEmpty else { return nil }
        let highestAlone = ancestors.firstIndex { $0.otherMics == 0 }
        let shared = ancestors.contains { $0.otherMics > 0 }
        if shared { return highestAlone ?? ancestors.count - 1 }
        // Page parts not found (tree still building, labels changed): keep the old whole-column answer.
        return ancestors.lastIndex { $0.isWholeSessionOnly } ?? highestAlone ?? ancestors.count - 1
    }
}
