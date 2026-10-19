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

    public enum Dictated: Equatable, Sendable {
        /// A dictation Ensemble started (or took over) and stopped.
        case ensemble
        /// A dictation Claude ran without Ensemble, seen recording in the looked-at session and then seen to end.
        case claude
    }

    /// Which dictation a send is for, and how long ago it ended: the most recent one that ended within the window,
    /// Ensemble's own on a tie. nil when neither did, which the send refuses as "Nothing dictated".
    public static func dictated(ensembleAgo: TimeInterval?, claudeAgo: TimeInterval?) -> (source: Dictated, ago: TimeInterval)? {
        let own = ensembleAgo.flatMap { $0 <= window ? $0 : nil }
        let claude = claudeAgo.flatMap { $0 <= window ? $0 : nil }
        switch (own, claude) {
        case let (a?, b?): return b < a ? (.claude, b) : (.ensemble, a)
        case let (a?, nil): return (.ensemble, a)
        case let (nil, b?): return (.claude, b)
        case (nil, nil): return nil
        }
    }

    /// Acting only on Claude: with another app in front (a full-screen call swiped to, say) a thumbs-up sends nothing,
    /// however recent the dictation.
    public static func frontRefusal(claudeInFront: Bool) -> String? {
        claudeInFront ? nil : "Claude is not the app in front"
    }

    /// The last check, right before Send is pressed and on the queue that presses it, however long the press waited.
    public static func pressRefusal(claudeInFront: Bool, spokenAgo: TimeInterval, inputAge: TimeInterval) -> String? {
        frontRefusal(claudeInFront: claudeInFront) ?? typedRefusal(spokenAgo: spokenAgo, inputAge: inputAge)
    }

    /// The draft may have been edited by hand after dictation: input more recent than the dictation's end.
    public static func typedRefusal(spokenAgo: TimeInterval, inputAge: TimeInterval) -> String? {
        inputAge < spokenAgo ? "Typed or clicked since dictation; not sending" : nil
    }
}
