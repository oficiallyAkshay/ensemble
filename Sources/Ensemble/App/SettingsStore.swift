import SwiftUI
import ServiceManagement
import EnsembleCore

/// User preferences, persisted in the "dev.ensemble.app" defaults suite.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let enabled = "enabled"
        static let showNoseDot = "showNoseDot"
        static let showHighlight = "showHighlight"
        static let cameraName = "cameraName"
        static let mapping = "mapping"
        static let sendCountdownSeconds = "sendCountdownSeconds"
        static let pointerSmoothing = "pointerSmoothing"
        static let correctForPosition = "correctForPosition"
        static let reverseScroll = "reverseScroll"
        static let liveSoundBars = "liveSoundBars"
        static let warnWhenLeavingClaude = "warnWhenLeavingClaude"
        static let playSounds = "playSounds"
        static let pauseAfterInputSeconds = "pauseAfterInputSeconds"
        static let pauseMediaWhileDictating = "pauseMediaWhileDictating"
        static let headphonePresses = "headphonePresses"
        static let useAnotherMicrophoneWhenLidClosed = "useAnotherMicrophoneWhenLidClosed"
        static let maximizeByPeace = "maximizeByPeace"
        static let evenOutByScissors = "evenOutByScissors"
        static let fitFocusedSession = "fitFocusedSession"
        static let calibration = "calibration"
        static let calibratedAt = "calibratedAt"
        static let calibrationDisplays = "calibrationDisplays"
        static let lastClaudeVersion = "lastClaudeVersion"
        static let tourCompleted = "tourCompleted"
        static let tourSkipped = "tourSkipped"
        static let setupProfiles = "setupProfiles"
        static let lastCameraID = "lastCameraID"
        static let lastRestoreSignature = "lastRestoreSignature"
        static let shareUsage = "shareUsage"
        static let usageNoticeDismissed = "usageNoticeDismissed"
    }

    static let countdownRange: ClosedRange<Double> = 0.5...3

    /// The store the preferences live in; the usage counters use the same one.
    let defaults: UserDefaults

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var showNoseDot: Bool { didSet { defaults.set(showNoseDot, forKey: Key.showNoseDot) } }
    @Published var showHighlight: Bool { didSet { defaults.set(showHighlight, forKey: Key.showHighlight) } }
    /// nil = automatic camera choice.
    @Published var cameraName: String? { didSet { defaults.set(cameraName, forKey: Key.cameraName) } }
    @Published var mapping: GestureMapping { didSet { saveMapping() } }
    @Published var pointerSmoothing: Double { didSet { defaults.set(pointerSmoothing, forKey: Key.pointerSmoothing) } }
    /// On by default: pointing accounts for where you sit, so moving along the desk keeps the nose on target.
    /// Off is the angle-only pointer that needs recalibrating when you move.
    @Published var correctForPosition: Bool { didSet { defaults.set(correctForPosition, forKey: Key.correctForPosition) } }
    /// Flips pinch-and-drag scrolling relative to the Mac's own scroll direction.
    @Published var reverseScroll: Bool { didSet { defaults.set(reverseScroll, forKey: Key.reverseScroll) } }
    /// Off by default: the listening sign is a blinking microphone dot and Ensemble never asks for the microphone.
    /// On: sound bars follow the voice level, which needs microphone permission.
    @Published var liveSoundBars: Bool { didSet { defaults.set(liveSoundBars, forKey: Key.liveSoundBars) } }
    /// While dictating, an amber glow on the edge of the session you face when your look is heading somewhere
    /// that is not Claude. On by default; the warning about another Claude session is always on.
    @Published var warnWhenLeavingClaude: Bool { didSet { defaults.set(warnWhenLeavingClaude, forKey: Key.warnWhenLeavingClaude) } }
    @Published var sendCountdownSeconds: Double {
        didSet {
            let clamped = min(max(sendCountdownSeconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
            if clamped != sendCountdownSeconds { sendCountdownSeconds = clamped; return }
            defaults.set(sendCountdownSeconds, forKey: Key.sendCountdownSeconds)
        }
    }
    /// How long Ensemble stays paused after the last key, click, scroll or pointer movement (`HandsBusy`).
    @Published var pauseAfterInputSeconds: Double {
        didSet {
            let clamped = min(max(pauseAfterInputSeconds, HandsBusy.quietRange.lowerBound), HandsBusy.quietRange.upperBound)
            if clamped != pauseAfterInputSeconds { pauseAfterInputSeconds = clamped; return }
            defaults.set(pauseAfterInputSeconds, forKey: Key.pauseAfterInputSeconds)
        }
    }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var pauseMediaWhileDictating: Bool { didSet { defaults.set(pauseMediaWhileDictating, forKey: Key.pauseMediaWhileDictating) } }
    /// With the lid closed, the default input moves to a microphone that works just before each dictation. On by default.
    @Published var useAnotherMicrophoneWhenLidClosed: Bool { didSet { defaults.set(useAnotherMicrophoneWhenLidClosed, forKey: Key.useAnotherMicrophoneWhenLidClosed) } }
    /// Stem presses on Bluetooth headphones drive dictation and send. On by default.
    @Published var headphonePresses: Bool { didSet { defaults.set(headphonePresses, forKey: Key.headphonePresses) } }
    /// A held peace sign widens the session you face to the chat's default width, the others giving up only what that needs. On by default.
    @Published var maximizeByPeace: Bool { didSet { defaults.set(maximizeByPeace, forKey: Key.maximizeByPeace) } }
    /// Scissors (a peace sign closed quickly) gives every session in that window an equal share. On by default.
    @Published var evenOutByScissors: Bool { didSet { defaults.set(evenOutByScissors, forKey: Key.evenOutByScissors) } }
    /// The session focus settles on widens to Claude's chat column when it is narrower. On by default.
    @Published var fitFocusedSession: Bool { didSet { defaults.set(fitFocusedSession, forKey: Key.fitFocusedSession) } }
    /// Anonymous daily usage counts (docs/telemetry.md). The default is `UsagePolicy.sharingDefault`.
    @Published var shareUsage: Bool { didSet { defaults.set(shareUsage, forKey: Key.shareUsage) } }
    /// The first-run notice about usage sharing was dismissed.
    @Published var usageNoticeDismissed: Bool { didSet { defaults.set(usageNoticeDismissed, forKey: Key.usageNoticeDismissed) } }
    /// Set only through `setLaunchAtLogin`, which talks to the system first.
    @Published private(set) var launchAtLogin: Bool
    @Published var launchAtLoginError: String?
    /// Opaque blob written by the coordinator.
    @Published var calibration: Data? { didSet { defaults.set(calibration, forKey: Key.calibration) } }
    @Published var calibratedAt: Date? { didSet { defaults.set(calibratedAt, forKey: Key.calibratedAt) } }
    /// The screen arrangement the calibration was made on; a different arrangement needs a new calibration.
    @Published var calibrationDisplays: String? { didSet { defaults.set(calibrationDisplays, forKey: Key.calibrationDisplays) } }
    /// The Claude version the last confirmed dictation ran on.
    @Published var lastClaudeVersion: String? { didSet { defaults.set(lastClaudeVersion, forKey: Key.lastClaudeVersion) } }
    /// The first-run tour has played to the end once.
    @Published var tourCompleted: Bool { didSet { defaults.set(tourCompleted, forKey: Key.tourCompleted) } }
    /// The owner skipped the first-run tour; the menu bar panel offers it until this or `tourCompleted` is true.
    @Published var tourSkipped: Bool { didSet { defaults.set(tourSkipped, forKey: Key.tourSkipped) } }
    /// Opaque blob written by the coordinator: an `EnsembleCore.SetupProfiles`, one calibration per camera,
    /// tagged per screen. `calibration`/`calibrationDisplays` above are the single setup this replaces;
    /// they stay for the one-time migration into this on first launch after the upgrade.
    @Published var setupProfiles: Data? { didSet { defaults.set(setupProfiles, forKey: Key.setupProfiles) } }
    /// The camera the engine last reported, so a launch can point with that camera's calibration before the camera
    /// starts. Not published: no view shows it.
    var lastCameraID: String? { didSet { defaults.set(lastCameraID, forKey: Key.lastCameraID) } }
    /// The setup the "Desk setup recognised" banner last announced, so a relaunch on the same setup stays quiet.
    var lastRestoreSignature: String? { didSet { defaults.set(lastRestoreSignature, forKey: Key.lastRestoreSignature) } }

    init(defaults: UserDefaults? = nil) {
        // In the packaged app the bundle identifier is "dev.ensemble.app", so the standard domain already is that
        // suite; naming it as a suite is rejected. Outside a bundle (swift run) the suite is used.
        let suite = "dev.ensemble.app"
        let store = defaults ?? (Bundle.main.bundleIdentifier == suite ? .standard : UserDefaults(suiteName: suite) ?? .standard)
        self.defaults = store
        func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }

        enabled = bool(Key.enabled, true)
        showNoseDot = bool(Key.showNoseDot, true)
        showHighlight = bool(Key.showHighlight, true)
        cameraName = store.string(forKey: Key.cameraName)
        playSounds = bool(Key.playSounds, true)
        pauseMediaWhileDictating = bool(Key.pauseMediaWhileDictating, true)
        headphonePresses = bool(Key.headphonePresses, true)
        useAnotherMicrophoneWhenLidClosed = bool(Key.useAnotherMicrophoneWhenLidClosed, true)
        maximizeByPeace = bool(Key.maximizeByPeace, true)
        evenOutByScissors = bool(Key.evenOutByScissors, true)
        fitFocusedSession = bool(Key.fitFocusedSession, true)
        shareUsage = bool(Key.shareUsage, UsagePolicy.sharingDefault)
        usageNoticeDismissed = bool(Key.usageNoticeDismissed, false)
        LoginAgent.repointIfStale()
        launchAtLogin = LoginAgent.isEnabled
        calibration = store.data(forKey: Key.calibration)
        calibratedAt = store.object(forKey: Key.calibratedAt) as? Date
        calibrationDisplays = store.string(forKey: Key.calibrationDisplays)
        lastClaudeVersion = store.string(forKey: Key.lastClaudeVersion)
        tourCompleted = bool(Key.tourCompleted, false)
        tourSkipped = bool(Key.tourSkipped, false)
        setupProfiles = store.data(forKey: Key.setupProfiles)
        lastCameraID = store.string(forKey: Key.lastCameraID)
        lastRestoreSignature = store.string(forKey: Key.lastRestoreSignature)

        pointerSmoothing = store.object(forKey: Key.pointerSmoothing) as? Double ?? PointerSmoothing.defaultLevel
        correctForPosition = bool(Key.correctForPosition, true)
        reverseScroll = store.bool(forKey: Key.reverseScroll)
        liveSoundBars = store.bool(forKey: Key.liveSoundBars)
        warnWhenLeavingClaude = bool(Key.warnWhenLeavingClaude, true)
        let seconds = store.object(forKey: Key.sendCountdownSeconds) as? Double ?? 0.75
        sendCountdownSeconds = min(max(seconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
        let pause = store.object(forKey: Key.pauseAfterInputSeconds) as? Double ?? HandsBusy.defaultQuiet
        pauseAfterInputSeconds = min(max(pause, HandsBusy.quietRange.lowerBound), HandsBusy.quietRange.upperBound)

        if let data = store.data(forKey: Key.mapping), var decoded = try? JSONDecoder().decode(GestureMapping.self, from: data) {
            // Version 2 made "gather" the talk gesture (start; gather then open to stop). Move hold-a-fist setups over once.
            if store.integer(forKey: "mappingVersion") < 2 {
                if decoded.talk == .fist { decoded.talk = .gather }
                store.set(2, forKey: "mappingVersion")
            }
            mapping = decoded
        } else {
            mapping = GestureMapping()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try LoginAgent.enable() } else { try LoginAgent.disable() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change open at login: \(error.localizedDescription)"
        }
        launchAtLogin = LoginAgent.isEnabled
    }

    func assign(_ pose: Pose?, to slot: GestureSlot) {
        var next = mapping
        next.assign(pose, to: slot)
        mapping = next
    }

    private func saveMapping() {
        if let data = try? JSONEncoder().encode(mapping) { defaults.set(data, forKey: Key.mapping) }
    }
}

enum GestureSlot: CaseIterable {
    case talk, send, scrollUp, scrollDown
}

extension GestureMapping {
    subscript(slot: GestureSlot) -> Pose? {
        get {
            switch slot {
            case .talk: return talk
            case .send: return send
            case .scrollUp: return scrollUp
            case .scrollDown: return scrollDown
            }
        }
        set {
            switch slot {
            case .talk: if let newValue { talk = newValue }
            case .send: send = newValue
            case .scrollUp: scrollUp = newValue
            case .scrollDown: scrollDown = newValue
            }
        }
    }

    /// Gives `slot` the pose; if another slot already used it, that slot takes this slot's previous pose
    /// (or an unused one when this slot was Off), so no two slots ever share a pose.
    mutating func assign(_ pose: Pose?, to slot: GestureSlot) {
        guard let pose else {
            self[slot] = nil
            return
        }
        let previous = self[slot]
        if let other = GestureSlot.allCases.first(where: { $0 != slot && self[$0] == pose }) {
            let used = Set(GestureSlot.allCases.compactMap { self[$0] })
            self[other] = previous ?? Pose.allCases.first(where: { !used.contains($0) })
        }
        self[slot] = pose
    }
}

extension Pose {
    var title: String {
        switch self {
        case .fist: return "Fist"
        case .openPalm: return "Open palm"
        case .thumbsUp: return "Thumbs up"
        case .twoFingers: return "Two fingers"
        case .gather: return "Gather (fingertips together)"
        case .pointUp: return "Point up"
        case .pointDown: return "Point down"
        }
    }

    /// SF Symbols has no closed-fist glyph; the filled raised hand stands in for it.
    var symbolName: String {
        switch self {
        case .fist: return "hand.raised.fill"
        case .openPalm: return "hand.raised.fingers.spread"
        case .thumbsUp: return "hand.thumbsup.fill"
        case .twoFingers: return "hand.point.up.fill"
        case .gather: return "hand.pinch.fill"
        case .pointUp: return "hand.point.up.left.fill"
        case .pointDown: return "hand.point.down.fill"
        }
    }
}

extension GestureSlot {
    var title: String {
        switch self {
        case .talk: return "Talk"
        case .send: return "Send"
        case .scrollUp: return "Scroll up"
        case .scrollDown: return "Scroll down"
        }
    }

    var detail: String {
        switch self {
        case .talk: return "Pinch twice to dictate into the session you are facing. Pinch twice again to stop."
        case .send: return "Sends the dictated draft once the gesture is held for the time below."
        case .scrollUp: return "Holding the gesture scrolls the session up, faster the longer you hold."
        case .scrollDown: return "Holding the gesture scrolls the session down, faster the longer you hold."
        }
    }

    /// The action's own icon, for Settings, Actions: what happens, not the hand shape that does it.
    var actionSymbol: String {
        switch self {
        case .talk: return "mic"
        case .send: return "paperplane"
        case .scrollUp: return "arrow.up"
        case .scrollDown: return "arrow.down"
        }
    }

    var allowsOff: Bool { self == .send || self == .scrollUp || self == .scrollDown }
}
