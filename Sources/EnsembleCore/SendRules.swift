import Foundation

/// When a thumbs-up may send what was dictated.
public enum SendRules {
    /// A send is allowed only this long after dictation stopped.
    public static let window: TimeInterval = 30

    /// Why a send must wait or be dropped, or nil. `spokenAgo` is the time since the last dictation stopped
    /// (nil when nothing was dictated); `inputAge` the time since the keyboard, mouse or trackpad was used.
    public static func refusal(spokenAgo: TimeInterval?, inputAge: TimeInterval) -> String? {
        guard let ago = spokenAgo, ago <= window else { return "Nothing dictated in the last \(Int(window)) seconds" }
        return typedRefusal(spokenAgo: ago, inputAge: inputAge)
    }

    /// Acting only on Claude: with another app in front (a full-screen call swiped to, say) a thumbs-up sends nothing,
    /// however recent the dictation.
    public static func frontRefusal(claudeInFront: Bool) -> String? {
        claudeInFront ? nil : "Claude is not the app in front"
    }

    /// The last check, on the bridge queue right before Send is pressed: a press can wait there behind other
    /// Accessibility work, and another app may have come to the front or a key or click arrived meanwhile.
    public static func pressRefusal(claudeInFront: Bool, spokenAgo: TimeInterval, inputAge: TimeInterval) -> String? {
        frontRefusal(claudeInFront: claudeInFront) ?? typedRefusal(spokenAgo: spokenAgo, inputAge: inputAge)
    }

    /// The draft may have been edited by hand after dictation: input more recent than the dictation's end.
    public static func typedRefusal(spokenAgo: TimeInterval, inputAge: TimeInterval) -> String? {
        inputAge < spokenAgo ? "Typed or clicked since dictation; not sending" : nil
    }
}
