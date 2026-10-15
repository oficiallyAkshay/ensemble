import Foundation

/// Turns real gesture intents, routed here instead of to Claude while the tour's practice step is open, into
/// "this tab is done" signals. Dictate needs a full start-then-stop pair, so a `talkBegan` alone does not
/// finish it; a `talkEnded` with no matching `talkBegan` (left over from a previous tab) does not either.
public final class TourPracticeDetector {
    private var sawTalkBegan = false

    public init() {}

    /// Called when the practiced tab changes, so an intent left over from the previous tab cannot complete the next one.
    public func reset() {
        sawTalkBegan = false
    }

    public func observe(_ intent: GestureIntent) -> TourGestureTab? {
        switch intent {
        case .talkBegan:
            sawTalkBegan = true
            return nil
        case .talkEnded:
            defer { sawTalkBegan = false }
            return sawTalkBegan ? .dictate : nil
        case .sendRequested:
            return .send
        case .dragScroll:
            return .scroll
        case .scroll, .dragScrollEnded, .maximizeSession, .evenOutSessions:
            return nil
        }
    }
}
