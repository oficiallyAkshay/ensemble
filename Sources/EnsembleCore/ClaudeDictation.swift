#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// A dictation can run in a Claude session that Ensemble did not start (Claude's own microphone button or shortcut).
/// These rules decide what a gesture does then. Stopping a microphone is always safe; starting one while it is on
/// never is, and a press on a checkbox whose state is unclear could start it, so an unclear state is never pressed.
public enum ClaudeDictation {
    public static let alreadyDictating = "Claude is already dictating here; pinch twice to stop"

    public enum TalkStep: Equatable, Sendable {
        /// The microphone is verifiably off: start a dictation as before.
        case start
        /// Claude is dictating in this session: stop that dictation the way Ensemble stops its own.
        case stopRunning
        /// The state is unclear: press nothing.
        case refuse(String)
    }

    /// The double pinch (or a headphone press) toggles what the looked-at session is doing.
    public static func talkStep(target: MicState) -> TalkStep {
        switch target {
        case .off: return .start
        case .on: return .stopRunning
        case .unknown(let why): return .refuse(unclear(why))
        }
    }

    public enum SendStep: Equatable, Sendable {
        /// Claude is dictating in the looked-at session: stop it, wait for the transcript, then send.
        case stopThenSend
        /// Nothing is recording there: send what was dictated, under the usual rules.
        case sendDictated
    }

    /// A thumbs-up (or two Returns, or a headphone double press) while the looked-at session is dictating, whoever
    /// started it, stops that dictation first. Only a definite "on" counts: an unclear state is never pressed.
    public static func sendStep(target: MicState) -> SendStep {
        target == .on ? .stopThenSend : .sendDictated
    }

    /// Why a start press found the microphone not verifiably off, in the words the owner sees; nil when it is off.
    public static func startRefusal(_ state: MicState) -> String? {
        switch state {
        case .off: return nil
        case .on: return alreadyDictating
        case .unknown(let why): return unclear(why)
        }
    }

    static func unclear(_ why: String) -> String {
        "Claude's microphone reads neither on nor off here (\(why)); nothing pressed"
    }
}

/// Dictations running in Claude that Ensemble did not start, as the session refresh sees them (the checkbox label,
/// read about once a second). A dictation seen recording in a session that then ends counts as dictated for the send
/// window from the moment the refresh saw it end, so a thumbs-up after Claude's own button sends it.
public struct ForeignDictations: Sendable {
    public private(set) var recording: Set<String> = []
    private var endedAt: [String: TimeInterval] = [:]

    public init() {}

    /// One refresh: `present` is every session id found, `recordingNow` those whose checkbox reads recording.
    /// A session that leaves the list takes what was seen in it along: its id may name another pane later.
    public mutating func observe(present: [String], recordingNow: Set<String>, at t: TimeInterval) {
        let present = Set(present)
        for id in recording where present.contains(id) && !recordingNow.contains(id) { endedAt[id] = t }
        for id in recordingNow { endedAt[id] = nil }
        recording = recordingNow.intersection(present)
        endedAt = endedAt.filter { present.contains($0.key) }
    }

    public func isRecording(_ id: String?) -> Bool {
        id.map { recording.contains($0) } ?? false
    }

    /// Seconds since a dictation Ensemble did not start was seen to end in this session; nil when none was.
    public func endedAgo(_ id: String?, now: TimeInterval) -> TimeInterval? {
        guard let id, let t = endedAt[id] else { return nil }
        return now - t
    }

    /// Ensemble started, took over or sent a dictation in this session: what the refresh saw there is accounted for.
    public mutating func forget(_ id: String) {
        recording.remove(id)
        endedAt[id] = nil
    }

    /// Sleep, a lock, the safety check or switching off: nothing seen before it is sendable afterwards.
    public mutating func forgetAll() {
        recording = []
        endedAt = [:]
    }
}

/// Which pane a dictated draft is read from and sent in. A session id names a window and a checkbox's order in it,
/// so when Claude changes its layout (one pane shown, then four; seen 2026-10-15, one second after a stop) the same
/// id can name another pane, and the old fallback by overlap could pick another window's pane at the same place.
/// A draft is only ever read from, and sent in, the pane it was dictated into.
public enum SessionMatch {
    /// Panes must share at least this much of the smaller one's area.
    public static let minShared: CGFloat = 0.6

    /// Whether `found` is the pane `wanted` named: the same window (when both numbers are known), the same title
    /// (when both are read), and mostly the same place.
    public static func same(_ wanted: ClaudeSession, _ found: ClaudeSession) -> Bool {
        if wanted.windowNumber != 0, found.windowNumber != 0, wanted.windowNumber != found.windowNumber { return false }
        if let a = wanted.title, let b = found.title, a != b { return false }
        return shared(wanted.frame, found.frame) >= minShared
    }

    /// Among freshly found panes, the index of the one that is `wanted`: its own id first, then the pane sharing the
    /// most area; nil when none passes `same`. No pane is better than another pane's draft.
    public static func pick(_ wanted: ClaudeSession, among found: [ClaudeSession]) -> Int? {
        let ok = found.indices.filter { same(wanted, found[$0]) }
        if let exact = ok.first(where: { found[$0].id == wanted.id }) { return exact }
        return ok.max { shared(wanted.frame, found[$0].frame) < shared(wanted.frame, found[$1].frame) }
    }

    static func shared(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? i.width * i.height / smaller : 0
    }
}
