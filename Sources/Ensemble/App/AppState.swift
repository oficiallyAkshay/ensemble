import SwiftUI
import QuartzCore
import EnsembleCore

enum AppStatus: Equatable {
    case off
    case watching
    /// Your hands are on the keyboard, mouse or trackpad: focus and the highlight hold; gestures still work (`HandsBusy`).
    case pausedForInput
    case listening
    case cameraCovered
    /// The picture has stayed too dim for tracking to be trusted (`DimPicture`); gestures keep working.
    case pictureDim
    case needsCalibration
    case needsPermission(String)
    case claudeNotRunning
    case claudeNotOnScreen
    case error(String)
}

/// What a Calibrate press asks for.
enum CalibrationRequest: Equatable {
    /// Every screen, replacing the position in use now.
    case recalibrate
    /// Only this screen (stable id), in the position in use now; every other screen keeps its calibration.
    case screen(String)
    /// Every screen, from where the owner is now, kept beside the positions already saved.
    case newPosition
}

/// One saved position, as Settings lists it: "Position 2", "2 screens, Oct 14".
struct CalibrationSpotSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
}

/// A connected screen, as Settings and the panel's screen arrangement show it.
struct ScreenChoice: Identifiable, Equatable {
    let id: String
    /// "DELL U2723QE, left" with several screens, the bare name with one.
    let name: String
    /// The name macOS gives the screen (`NSScreen.localizedName`).
    let displayName: String
    /// Global, top-left origin: where the screen sits in the arrangement.
    let frame: CGRect
    /// The screen with the menu bar (the first in `NSScreen.screens`).
    let isMain: Bool
    /// Its calibration is usable now (not a new or moved screen).
    let calibrated: Bool
    /// When each saved position last calibrated this screen, by position id.
    let calibratedAt: [String: Date]
}

/// Read by the UI, written by the coordinator. Screen-space values are global, top-left origin.
@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .off
    /// The last refusal, while it still describes the moment (`RefusalNotice`); the status above it is always live.
    @Published private(set) var lastRefusal: String?
    @Published var listening = false
    @Published var muted = false
    @Published var fps = 0
    /// The refresh rate of the screen the nose dot is on: the dot window moves once per refresh.
    @Published var dotRate = 0
    @Published var cameraName: String?
    @Published var cameraNames: [String] = []
    @Published var calibrating = false
    /// "Calibrated for 2 screens", or nil when none of the connected screens is calibrated.
    @Published var calibratedLine: String?
    /// The positions calibrated for the camera in use, for Settings, and the one the pointer uses now.
    @Published var calibrationSpots: [CalibrationSpotSummary] = []
    @Published var spotInUse: String?
    /// The connected screens, for recalibrating just one of them.
    @Published var screenChoices: [ScreenChoice] = []

    private var refusal: RefusalNotice?
    private var refusalExpiry: Task<Void, Never>?

    func showRefusal(_ text: String, resolves: RefusalNotice.Resolves = .byTime) {
        refusal = RefusalNotice(text: text, shownAt: CACurrentMediaTime(), resolves: resolves)
        set(\.lastRefusal, text)
        // The camera loop may be off (Ensemble switched off, screen locked), so the lifetime has its own timer.
        refusalExpiry?.cancel()
        refusalExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RefusalNotice.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearRefusal()
        }
    }

    /// Called on every tick: drops the refusal as soon as what it described no longer holds.
    func clearRefusalIfStale(now: TimeInterval, lastInputAt: TimeInterval, dictating: Bool, onSession: Bool) {
        guard let refusal, refusal.isStale(now: now, lastInputAt: lastInputAt, dictating: dictating, onSession: onSession) else { return }
        clearRefusal()
    }

    func clearRefusal() {
        refusal = nil
        refusalExpiry?.cancel()
        refusalExpiry = nil
        set(\.lastRefusal, nil)
    }

    /// `@Published` announces a change on every write, even of an equal value; the camera loop writes several
    /// of these on every frame, so those writes go through here and only real changes reach the views.
    func set<T: Equatable>(_ path: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}

extension AppStatus {
    var title: String {
        switch self {
        case .off: return "Off"
        case .watching: return "Watching"
        case .pausedForInput: return "Focus holds while you type or use the mouse"
        case .listening: return "Claude dictation on"
        case .cameraCovered: return "Camera is covered"
        case .pictureDim: return "Turn on a light"
        case .needsCalibration: return "Needs calibration"
        case .needsPermission(let what): return "Needs permission: \(what)"
        case .claudeNotRunning: return "Claude is not running"
        case .claudeNotOnScreen: return "Claude isn't on screen"
        case .error(let message): return message
        }
    }
}
