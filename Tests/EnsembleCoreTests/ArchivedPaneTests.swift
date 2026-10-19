import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct ArchivedPaneTests {
    private func anc(feed: Bool, mic: Bool = false) -> ArchivedAncestor { ArchivedAncestor(hasFeed: feed, hasMic: mic) }

    @Test func thePaneIsTheLowestAncestorHoldingTheFeed() {
        // window column, pane (feed, no mic), bar container
        #expect(ArchivedPane.index(among: [anc(feed: true), anc(feed: true), anc(feed: false)]) == 1)
    }

    @Test func aFeedSharedWithALiveSessionIsNotAnArchivedPane() {
        // The only ancestors holding a feed also hold a live session's checkbox: the bar's own pane has no feed.
        #expect(ArchivedPane.index(among: [anc(feed: true, mic: true), anc(feed: false)]) == nil)
        #expect(ArchivedPane.index(among: [anc(feed: true), anc(feed: true, mic: true)]) == nil)
    }

    @Test func noFeedMeansNoArchivedPane() {
        #expect(ArchivedPane.index(among: [anc(feed: false), anc(feed: false)]) == nil)
        #expect(ArchivedPane.index(among: []) == nil)
    }

    @Test func anArchivedSessionHighlightsItsBarAndALiveOneItsWindow() {
        let pane = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let bar = CGRect(x: 10, y: 960, width: 780, height: 40)
        #expect(ClaudeSession(id: "a", frame: pane, windowNumber: 1, archivedBar: bar).highlightFrame == bar)
        #expect(ClaudeSession(id: "b", frame: pane, windowNumber: 1).highlightFrame == pane)
    }
}
