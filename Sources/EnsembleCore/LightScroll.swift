/// Light mode: with another app in front, a pinch-and-drag may scroll the window under the look point, and nothing
/// else Ensemble does reaches that app. Off, or with Claude in front, none of this applies.
public enum LightScroll {
    /// The process whose window may be scrolled, or nil. Only the front app's own window under the look point counts,
    /// so a window of another app laid over it, the desktop, or Ensemble's overlay never scrolls. A session of Claude
    /// under the look point, a dictation, or hands on the keyboard or mouse leave it to the usual rules.
    public static func owner(enabled: Bool, claudeFront: Bool, onClaudeSession: Bool, dictating: Bool, handsBusy: Bool,
                             frontPID: Int32?, ownerAtLook: Int32?) -> Int32? {
        guard enabled, !claudeFront, !onClaudeSession, !dictating, !handsBusy,
              let front = frontPID, front == ownerAtLook else { return nil }
        return front
    }

    /// The only intents that reach another app: the pinch-and-drag and its end. Talk, send, the pose-held scrolls and
    /// the width gestures stay Claude-only.
    public static func allows(_ intent: GestureIntent) -> Bool {
        switch intent {
        case .dragScroll, .dragScrollEnded: return true
        case .talkBegan, .talkEnded, .sendRequested, .scroll, .maximizeSession, .evenOutSessions: return false
        }
    }
}
