import Foundation

/// The gestures the daily summary counts, one per action. `pinch` is Talk and `thumbsUp` is Send however the owner
/// mapped the pose; a headphone press or Return does not count as the gesture.
public enum UsageGesture: String, CaseIterable, Sendable {
    case pinch
    case thumbsUp = "thumbs_up"
    case scroll
    case peace
    case scissors
}

/// Why a send was refused, as a fixed word. The refusal notices are free text, so `classify` maps them; its tests run
/// the real rules, so a reworded notice fails there instead of silently turning into `other`.
public enum SendRefusal: String, CaseIterable, Sendable {
    case notInFront = "not_in_front"
    case nothingDictated = "nothing_dictated"
    case typedOrClicked = "typed_or_clicked"
    case emptyDraft = "empty_draft"
    case claudeNotReady = "claude_not_ready"
    case otherMicrophone = "other_microphone"
    case busy
    case noFace = "no_face"
    case cameraCovered = "camera_covered"
    case screenLocked = "screen_locked"
    case stopUnconfirmed = "stop_unconfirmed"
    case turnedOff = "turned_off"
    case other

    public static func classify(_ notice: String) -> SendRefusal {
        let text = notice.lowercased()
        let table: [(String, SendRefusal)] = [
            ("not the app in front", .notInFront),
            ("nothing dictated", .nothingDictated),
            ("typed or clicked", .typedOrClicked),
            ("draft is empty", .emptyDraft),
            ("message box", .claudeNotReady), ("generating", .claudeNotReady), ("composer", .claudeNotReady),
            ("send button", .claudeNotReady), ("no longer where", .claudeNotReady), ("draft changed", .claudeNotReady),
            ("using a microphone", .otherMicrophone),
            ("busy", .busy), ("something else started", .busy), ("still in flight", .busy),
            ("no face", .noFace),
            ("camera is covered", .cameraCovered),
            ("screen is locked", .screenLocked),
            ("stop was not confirmed", .stopUnconfirmed),
            ("is off", .turnedOff),
        ]
        return table.first { text.contains($0.0) }?.1 ?? .other
    }
}

/// Why the app itself ended a dictation, per docs/safety.md. Ending one with the gesture, Return or a headphone
/// press is not a stop.
public enum SafetyStop: String, CaseIterable, Sendable {
    case deadMan = "dead_man"
    case standingCheck = "standing_check"
    case multipleFaces = "multiple_faces"
    case noFace = "no_face"
    case cameraCovered = "camera_covered"
    case otherMicrophone = "other_microphone"
    case typingOrClick = "typing_or_click"
    case inputDeviceChanged = "input_device_changed"
    case sleepOrLock = "sleep_or_lock"
    case claudeQuit = "claude_quit"
}

/// Everything the app reports to the counter. Each case is a number or a fixed word; there is no payload that could
/// carry text.
public enum UsageEvent: Equatable, Sendable {
    case launch
    case gestureAttempted(UsageGesture)
    case gestureSucceeded(UsageGesture)
    case sendRefused(SendRefusal)
    case safetyStop(SafetyStop)
    /// Focus moved to the session being looked at.
    case focusMoved
    /// The camera format in use (frame rate 0 when the device does not say).
    case cameraFormat(width: Int, height: Int, fps: Int)
}

/// What the Coordinator's controllers are handed to report with.
@MainActor
public protocol UsageCounting: AnyObject {
    func count(_ event: UsageEvent)
    /// About once a second while the camera runs; adds to the active minutes.
    func activeTick()
}
