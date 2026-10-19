import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox
import EnsembleCore

/// Owns the long-lived objects and wires them together.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let state = AppState()
    let settings = SettingsStore()
    let overlay = OverlayController()
    let notifier = Notifier.shared
    let updates = UpdateController()
    let usage: UsageTracker
    let usageReporter: UsageReporter

    private(set) lazy var coordinator: AppCoordinating = makeCoordinator(state: state, settings: settings, overlay: overlay, usage: usage)
    private(set) lazy var panelActions = PanelActions(
        calibrate: { [weak self] in self?.dismissMenuPanel(); self?.startCoordinatorIfNeeded(); self?.coordinator.calibrate() },
        openSettings: { [weak self] in self?.dismissMenuPanel(); self?.settingsWindow.show() },
        openCalibration: { [weak self] in self?.dismissMenuPanel(); self?.settingsWindow.show(tab: .calibration) },
        recalibrateScreen: { [weak self] id in
            self?.dismissMenuPanel(); self?.startCoordinatorIfNeeded(); self?.coordinator.calibrate(.screen(id))
        },
        // The panel stays open so the button itself can say what the check found.
        checkForUpdates: { [weak self] in self?.updates.checkForUpdates() },
        startTour: { [weak self] in self?.dismissMenuPanel(); self?.tourWindow.show() },
        dismissTourBanner: { [weak self] in self?.settings.tourSkipped = true },
        quit: { NSApp.terminate(nil) }
    )
    private(set) lazy var tourWindow: TourWindowController = {
        let controller = TourWindowController(state: state, settings: settings) { [unowned self] step, singleStep, close in
        TourModel(
            settings: settings, startAt: step, singleStep: singleStep,
            calibrate: { [weak self] in self?.startCoordinatorIfNeeded(); self?.coordinator.calibrate() },
            requestAccessibility: { Permissions.grantAccessibility() },
            enterPractice: { [weak self] sink in self?.coordinator.enterGesturePractice(sink) },
            exitPractice: { [weak self] in self?.coordinator.exitGesturePractice() },
            stepEntered: { [weak self] step in
                if FirstRunGate.stepNeedsCoordinator(step) { self?.startCoordinatorIfNeeded() }
            },
            close: close)
        }
        controller.onOpen = { [weak self] in self?.coordinator.enterTour() }
        controller.onClose = { [weak self] in
            self?.coordinator.exitTour()
            self?.startCoordinatorIfNeeded()
        }
        return controller
    }()
    private(set) lazy var floatingPanel = FloatingPanelController { [unowned self] in
        AnyView(
            MenuPanelView(state: state, settings: settings, updates: updates, actions: floatingActions)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.12)))
        )
    }
    let settingsNavigation = SettingsNavigation()
    private(set) lazy var settingsWindow = SettingsWindowController(navigation: settingsNavigation) { [unowned self] in
        AnyView(SettingsView(state: state, settings: settings, updates: updates, usage: usage, reporter: usageReporter, navigation: settingsNavigation,
                              calibrate: { [weak self] request in self?.startCoordinatorIfNeeded(); self?.coordinator.calibrate(request) },
                              removeSpot: { [weak self] id in self?.coordinator.removeCalibrationSpot(id) },
                              replayTour: { [weak self] step in
                                  if let step { self?.tourWindow.show(startAt: step, singleStep: true) } else { self?.tourWindow.show() }
                              }))
    }

    private init() {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        usage = UsageTracker(defaults: settings.defaults, sharing: settings.shareUsage,
                             appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
                             macOSVersion: "\(os.majorVersion).\(os.minorVersion)")
        usageReporter = UsageReporter(tracker: usage)
    }

    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var coordinatorStarted = false

    private var floatingActions: PanelActions {
        PanelActions(
            calibrate: { [weak self] in self?.floatingPanel.hide(); self?.startCoordinatorIfNeeded(); self?.coordinator.calibrate() },
            openSettings: { [weak self] in self?.floatingPanel.hide(); self?.settingsWindow.show() },
            openCalibration: { [weak self] in self?.floatingPanel.hide(); self?.settingsWindow.show(tab: .calibration) },
            recalibrateScreen: { [weak self] id in
                self?.floatingPanel.hide(); self?.startCoordinatorIfNeeded(); self?.coordinator.calibrate(.screen(id))
            },
            checkForUpdates: { [weak self] in self?.updates.checkForUpdates() },
            startTour: { [weak self] in self?.floatingPanel.hide(); self?.tourWindow.show() },
            dismissTourBanner: { [weak self] in self?.settings.tourSkipped = true },
            quit: { NSApp.terminate(nil) }
        )
    }

    func start() {
        updates.isBusy = { [weak self] in
            guard let self else { return true }
            return self.state.listening || self.state.calibrating || self.tourWindow.isShown || self.coordinator.isBusy
        }
        updates.notice = { [weak self] title, body in self?.overlay.showBanner(title: title, body: body, style: .info) }
        guard !started else { return }
        started = true
        if let version = UpdateController.justUpdatedTo {
            // After the overlay's panels exist, so the island can show it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.overlay.showBanner(title: "Updated to \(version)", body: "Ensemble is running the new version.", style: .info)
            }
        }

        usage.count(.launch)
        usageReporter.start()
        settings.$shareUsage.dropFirst().sink { [weak self] on in self?.usage.setSharing(on) }.store(in: &cancellables)

        notifier.overlay = overlay
        notifier.settings = settings

        Publishers.CombineLatest(settings.$showNoseDot, settings.$showHighlight)
            .sink { [weak self] dot, highlight in self?.overlay.setVisibility(showNoseDot: dot, showHighlight: highlight) }
            .store(in: &cancellables)

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.floatingPanel.toggle() }
        }

        // A new owner sees the tour before any permission prompt: the camera and the Accessibility prompt wait
        // until the tour leaves Welcome or closes. The safety sweep never waits.
        if FirstRunGate.shouldDeferStart(tourCompleted: settings.tourCompleted, tourSkipped: settings.tourSkipped) {
            coordinator.recoverAtLaunch()
            tourWindow.show()
        } else {
            startCoordinatorIfNeeded()
        }
        offerMoveToApplications()
    }

    private func startCoordinatorIfNeeded() {
        guard !coordinatorStarted else { return }
        coordinatorStarted = true
        coordinator.start()
    }

    /// Running from the disk image or Downloads: offer the standard move, once per install location.
    private func offerMoveToApplications() {
        guard InstallLocation.isTemporary(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory()) else { return }
        DispatchQueue.main.async { InstallMover.offer() }
    }

    func stop() {
        usage.flush()
        coordinator.shutdown()
        CalibrationController.shared.cancel()
    }

    /// Closes the menu-bar panel (a window-style MenuBarExtra stays open after a button press).
    private func dismissMenuPanel() {
        guard let key = NSApp.keyWindow, key is NSPanel else { return }
        key.close()
    }
}
