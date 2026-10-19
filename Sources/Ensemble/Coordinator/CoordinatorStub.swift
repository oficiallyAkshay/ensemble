import AppKit
import EnsembleCore

@MainActor
protocol AppCoordinating: AnyObject {
    func start()
    /// Puts right anything an earlier run left (a dictation record, an input mute, lowered volume); needs no camera.
    func recoverAtLaunch()
    func stop(disarm: Bool)
    func calibrate()
    /// One screen only, or a new position beside the saved ones; `calibrate()` is `.recalibrate`.
    func calibrate(_ request: CalibrationRequest)
    /// Forgets one saved position for the camera in use; the last one cannot be removed.
    func removeCalibrationSpot(_ id: String)
    /// Called once as the app quits; must finish within about two seconds and leave nothing recording.
    func shutdown()
    var cameraNames: [String] { get }
    /// Something is under way that an update's relaunch would cut off: a press in flight, a dictation, a pending
    /// or running send, or a gesture being held.
    var isBusy: Bool { get }
    /// While the tour's gesture-practice step is open, real gesture intents and head readings go to `sink`
    /// instead of acting on Claude. Ends any dictation in progress first, the same as `calibrate()` does.
    func enterGesturePractice(_ sink: TourPracticeSink)
    func exitGesturePractice()
    /// While the tour window is open the camera keeps running for the tour, but nothing acts on Claude.
    func enterTour()
    func exitTour()
}

@MainActor
func makeCoordinator(state: AppState, settings: SettingsStore, overlay: OverlayController, usage: UsageCounting) -> AppCoordinating {
    Coordinator(state: state, settings: settings, overlay: overlay, usage: usage)
}
