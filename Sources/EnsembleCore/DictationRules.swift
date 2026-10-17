import Foundation

/// What the facts about Claude's microphone permit. The app reads the facts (CoreAudio, Claude's checkbox, what is
/// in flight); these rules decide, so each one can be tested without Claude, a camera or a clock.
public enum DictationRules {
    /// Only a definite "not capturing" reading proves Claude's microphone is off. CoreAudio's process list is
    /// unreadable (nil) while the audio system restarts, which says nothing about Claude, so an unreadable state
    /// never deletes the safety record, never undoes the safety mute and never counts as a confirmed stop.
    public static func confirmedOff(capture: Bool?) -> Bool { capture == false }

    /// Whether the safety record may be deleted: capture has read definitely off for `settle` seconds, and no start
    /// press is queued or running. A press in flight can open the microphone after an "off" reading, and with the
    /// record gone nothing would stop it, sound the alarm or mute the input.
    public static func recordMayGo(capture: Bool?, startInFlight: Bool, offFor: TimeInterval, settle: TimeInterval) -> Bool {
        confirmedOff(capture: capture) && !startInFlight && offFor >= settle
    }

    /// A definite "off" reading with the safety record open: when the off period started, and whether the record may
    /// go. A start press in flight restarts the off count, so the record goes only once the press has landed and
    /// capture has read off for `settle` seconds since. The launch sweep passes no earlier start and no settle window.
    public static func offReading(offSince: Date?, now: Date, startInFlight: Bool,
                                  settle: TimeInterval) -> (offSince: Date?, recordMayGo: Bool) {
        let since = startInFlight ? nil : offSince ?? now
        return (since, recordMayGo(capture: false, startInFlight: startInFlight, offFor: now.timeIntervalSince(since ?? now), settle: settle))
    }

    /// What a start press leads to once it has returned.
    public enum AfterStart: Equatable {
        /// The microphone is on and the pose is still held: keep listening.
        case keepListening
        /// The microphone is on but the hand opened while the press was in flight: stop with the usual tail.
        case stopReleased
        /// The microphone is on but Ensemble was switched off while the press was in flight: stop at once.
        case stopSwitchedOff
        /// The press was not confirmed on. Nothing is listening; the safety record stays for the standing check.
        case notStarted
    }

    /// Switching off wins over a held pose: a press that lands after the switch-off is stopped at once.
    public static func afterStart(confirmedOn: Bool, switchedOff: Bool, poseHeld: Bool) -> AfterStart {
        guard confirmedOn else { return .notStarted }
        if switchedOff { return .stopSwitchedOff }
        return poseHeld ? .keepListening : .stopReleased
    }

    /// How long switching off waits for a start, stop or send press in flight. A start press takes a focus, one
    /// press and up to 1.5 s of confirmation, and can queue behind a slow Accessibility walk.
    public static let disarmWait: TimeInterval = 8

    public enum DisarmStep: Equatable {
        /// A press is in flight and the wait is not over.
        case wait
        /// Nothing that could open the microphone is in flight: stop, confirm off, then clear the record.
        case proceed
        /// A start press is still in flight after the wait: leave the safety record in place and stop the
        /// dictation the moment the press lands. The standing check clears the record once capture is off.
        case stopWhenStarted
    }

    /// The safety record is never cleared while a start press could still open the microphone.
    public static func disarmStep(stepInFlight: Bool, startInFlight: Bool, waited: TimeInterval) -> DisarmStep {
        guard stepInFlight else { return .proceed }
        if waited < disarmWait { return .wait }
        return startInFlight ? .stopWhenStarted : .proceed
    }

    public enum StopAllVerdict: Equatable {
        /// Every session pane found shows the microphone confirmed off.
        case allOff
        /// No session pane was found, so nothing was pressed and nothing was confirmed.
        case nothingFound
        /// At least one pane did not confirm off.
        case notAllOff
    }

    /// `paneConfirmedOff` holds one entry per session pane found: whether its stop confirmed the microphone off.
    /// Finding no pane is not a confirmation: Claude's window may be closed while its microphone still records.
    public static func stopAll(paneConfirmedOff: [Bool]) -> StopAllVerdict {
        if paneConfirmedOff.isEmpty { return .nothingFound }
        return paneConfirmedOff.allSatisfy { $0 } ? .allOff : .notAllOff
    }

    /// How long an unreadable microphone state may last, with a dictation record open and no hold, before the
    /// alarm sounds and the input is muted. Unreadable is never "off", so waiting for it to clear could last forever.
    public static let unreadableLimit: TimeInterval = 3

    public static func escalateUnreadable(recordOpen: Bool, holdActive: Bool, unreadableFor: TimeInterval) -> Bool {
        recordOpen && !holdActive && unreadableFor >= unreadableLimit
    }

    /// The dead-man check: while a hold is active, the talk pose must be seen at least this often.
    public static let heartbeatTimeout: TimeInterval = 1
    /// An Accessibility call stuck longer than this means presses cannot be trusted to land, so the hold ends.
    public static let stallLimit: TimeInterval = 3

    public enum HoldLoss: Equatable {
        case noHeartbeat
        case stalled
    }

    /// Why an active hold must end now, or nil. A missing heartbeat is checked first.
    public static func holdLoss(holdActive: Bool, heartbeatAge: TimeInterval, longestStall: TimeInterval) -> HoldLoss? {
        guard holdActive else { return nil }
        if heartbeatAge > heartbeatTimeout { return .noHeartbeat }
        return longestStall > stallLimit ? .stalled : nil
    }

    /// How long capture must read definitely off, with no hold, before the safety record is deleted.
    public static let settleWindow: TimeInterval = 3
    /// How long a stop may stay unconfirmed before the alarm sounds and the input is muted.
    public static let escalateAfter: TimeInterval = 3

    public static func escalateStop(alarmOn: Bool, owedFor: TimeInterval) -> Bool {
        !alarmOn && owedFor >= escalateAfter
    }

    /// How long after a hold ends the standing check leaves the stop to the press already under way.
    public static let standingCheckGrace: TimeInterval = 1

    /// The standing check acts only on an open record with no hold, once the grace after the hold has passed.
    public static func standingCheckActs(recordOpen: Bool, holdActive: Bool, sinceHoldEnded: TimeInterval) -> Bool {
        recordOpen && !holdActive && sinceHoldEnded > standingCheckGrace
    }

    /// Written before pressed: `writeRecord` runs only when nothing refused the start, and the press is permitted
    /// (nil) only once it reports the record on disk. A crash after the press then always leaves a record to act on.
    public static func pressRefusal(_ refusal: String?, writeRecord: () -> Bool) -> String? {
        if let refusal { return refusal }
        return writeRecord() ? nil : "Could not write the safety record; not starting"
    }

    /// A new dictation may not start while an earlier one is still owed a confirmed stop: starting would replace
    /// that dictation's record and abandon its stop, its alarm and its mute. `muteInEffect` counts only a safety
    /// mute still set on a connected device.
    public static func startRefusal(stopOwed: Bool, alarmOn: Bool, muteInEffect: Bool) -> String? {
        if stopOwed || alarmOn { return "The last dictation's stop is not confirmed yet; the safety check is still stopping it" }
        if muteInEffect { return "The safety mute is still on; it is undone once the microphone is confirmed off" }
        return nil
    }

    /// Whether a confirmed stop leaves the dictation sendable by a later thumbs-up. A stop forced at once (switch-off,
    /// sleep, lock, the safety check), or any stop of a dictation that was interrupted along the way, never is.
    public static func sendableAfterStop(immediate: Bool, interrupted: Bool) -> Bool {
        !immediate && !interrupted
    }
}

/// When the dictated draft is ready to send. Claude finishes the transcript a moment after its microphone stops, so
/// a send waits until the draft has not changed for `quiet` seconds (and is not empty), never longer than `cap`.
/// It replaces a fixed 0.6 s wait: a draft that is already final goes out after `quiet`, a late one is waited for.
public struct DraftSettle {
    public static let quiet: TimeInterval = 0.3
    public static let cap: TimeInterval = 1.2

    public let start: TimeInterval
    public private(set) var text: String?
    public private(set) var changedAt: TimeInterval
    /// Seconds from `start` to the last change seen, for the log.
    public var lastChangeAfter: TimeInterval { changedAt - start }

    public init(start: TimeInterval, first: String?) {
        self.start = start
        text = first
        changedAt = start
    }

    /// One fresh reading of the draft. True once the draft may be sent, or the wait is over.
    public mutating func observe(_ reading: String?, at t: TimeInterval) -> Bool {
        if reading != text { text = reading; changedAt = t }
        if t - start >= Self.cap { return true }
        let nonEmpty = !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return nonEmpty && t - changedAt >= Self.quiet
    }
}
