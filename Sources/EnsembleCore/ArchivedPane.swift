import Foundation

/// One ancestor of an archived session's note bar, as read from Claude's accessibility tree.
public struct ArchivedAncestor: Equatable, Sendable {
    /// The subtree holds a chat messages feed.
    public var hasFeed: Bool
    /// The subtree holds a dictation checkbox: a live session lives here, so this is not an archived pane.
    public var hasMic: Bool

    public init(hasFeed: Bool, hasMic: Bool) {
        self.hasFeed = hasFeed
        self.hasMic = hasMic
    }
}

/// An archived session has no message box and no dictation checkbox; in place of the message box it shows a note bar
/// with an Unarchive button. Its pane is the lowest ancestor of that bar that holds the session's chat messages feed.
public enum ArchivedPane {
    /// `ancestors` run from the outermost to the bar's parent. Returns an index into `ancestors`; nil when no ancestor
    /// holds a feed, or the lowest one that does also holds a dictation checkbox (a live pane's note, or a feed that
    /// belongs to a neighbouring live pane).
    public static func index(among ancestors: [ArchivedAncestor]) -> Int? {
        guard let i = ancestors.lastIndex(where: \.hasFeed), !ancestors[i].hasMic else { return nil }
        return i
    }
}
