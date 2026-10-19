import Foundation

/// Decides the nose dot's stored value at the first launch of the version that turned it off by default.
public enum NoseDotDefault {
    public static let valueKey = "showNoseDot"
    public static let markerKey = "noseDotDefaultMigrated"

    /// Every key the app itself writes, except the dot's own and the marker. Keys other components write into the
    /// same defaults domain (the update framework's) are left out on purpose: a clean first launch may hold them.
    public static let appKeys = [
        "enabled", "showHighlight", "cameraName", "mapping", "mappingVersion", "sendCountdownSeconds",
        "pointerSmoothing", "correctForPosition", "reverseScroll", "liveSoundBars", "warnWhenLeavingClaude",
        "playSounds", "pauseAfterInputSeconds", "pauseMediaWhileDictating", "headphonePresses",
        "useAnotherMicrophoneWhenLidClosed", "maximizeByPeace", "evenOutByScissors", "fitFocusedSession",
        "calibration", "calibratedAt", "calibrationDisplays", "lastClaudeVersion", "tourCompleted",
        "tourSkipped", "setupProfiles", "lastCameraID", "lastRestoreSignature",
    ]

    /// Runs once, before the dot is read. With no stored dot value, an install that already holds any of the app's
    /// keys keeps the dot on and a clean one gets it off; either way the answer is written down, so a later launch
    /// never mistakes a new owner's tour flags for an old install.
    public static func migrate(_ store: UserDefaults) {
        guard !store.bool(forKey: markerKey) else { return }
        if store.object(forKey: valueKey) == nil {
            store.set(appKeys.contains { store.object(forKey: $0) != nil }, forKey: valueKey)
        }
        store.set(true, forKey: markerKey)
    }
}
