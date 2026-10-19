import AppKit
import EnsembleCore

/// Drives one open tour window: the step machine, the live permission facts for step 5, and (while step 3 is
/// open) turning real gesture intents into "this tab is done" checkmarks instead of letting
/// them reach Claude.
@MainActor
final class TourModel: ObservableObject, TourPracticeSink {
    @Published private(set) var step: TourStep
    @Published private(set) var practiceDone: Set<TourGestureTab> = []
    @Published var activeTab: TourGestureTab = .dictate
    @Published var cameraAccess = Permissions.cameraAccess
    @Published var accessibilityGranted = Permissions.accessibilityTrusted

    let isSingleStep: Bool
    private let machine: TourStateMachine
    private let settings: SettingsStore
    let calibrateNow: () -> Void
    let requestAccessibility: () -> Void
    private let enterPractice: (TourPracticeSink) -> Void
    private let exitPractice: () -> Void
    private let close: () -> Void
    /// Told as each step opens, so the app can hold the camera and the Accessibility prompt back on Welcome.
    private let stepEntered: (TourStep) -> Void

    /// What the system currently sees of the owner's hand, for the gestures step's inset.
    let handInset = TourHandInsetModel()

    private let detector = TourPracticeDetector()
    private var practicing = false
    private var permissionsTimer: Timer?

    init(settings: SettingsStore, startAt step: TourStep = .welcome, singleStep: Bool = false,
         calibrate: @escaping () -> Void, requestAccessibility: @escaping () -> Void,
         enterPractice: @escaping (TourPracticeSink) -> Void, exitPractice: @escaping () -> Void,
         stepEntered: @escaping (TourStep) -> Void = { _ in },
         close: @escaping () -> Void) {
        self.settings = settings
        self.isSingleStep = singleStep
        self.machine = TourStateMachine(startAt: step, singleStep: singleStep)
        self.step = machine.step
        self.calibrateNow = calibrate
        self.requestAccessibility = requestAccessibility
        self.enterPractice = enterPractice
        self.exitPractice = exitPractice
        self.close = close
        self.stepEntered = stepEntered
    }

    var canGoBack: Bool { machine.canGoBack }
    var canGoNext: Bool { machine.canGoNext }
    var isLastStep: Bool { machine.isLastStep }
    var allPracticeDone: Bool { machine.allPracticeDone }

    func onAppear() { enteringStep(machine.step) }

    func next() {
        leavingStep(machine.step)
        machine.next()
        step = machine.step
        enteringStep(machine.step)
    }

    func back() {
        leavingStep(machine.step)
        machine.back()
        step = machine.step
        enteringStep(machine.step)
    }

    /// "Later" on the calibration step: continues the tour without calibrating.
    func jump(to newStep: TourStep) {
        leavingStep(machine.step)
        machine.jump(to: newStep)
        step = machine.step
        enteringStep(machine.step)
    }

    func skipTour() {
        leavingStep(machine.step)
        machine.skip()
        if !isSingleStep { settings.tourSkipped = true; settings.tourCompleted = false }
        close()
    }

    func finishTour() {
        leavingStep(machine.step)
        machine.finish()
        if !isSingleStep { settings.tourCompleted = true; settings.tourSkipped = false }
        close()
    }

    /// The window closed by its own button or Esc, not by Skip or Done: treat it as Skip, but without
    /// recursing back into closing the (already closing) window.
    func windowWillClose() {
        stopPracticing()
        permissionsTimer?.invalidate()
        guard !isSingleStep, !machine.finished else { return }
        machine.skip()
        settings.tourSkipped = true
        settings.tourCompleted = false
    }

    private func enteringStep(_ step: TourStep) {
        stepEntered(step)
        if step == .gestures { startPracticing() }
        if step == .permissions { refreshPermissions() } else { permissionsTimer?.invalidate() }
    }

    private func leavingStep(_ step: TourStep) {
        if step == .gestures { stopPracticing() }
    }

    // MARK: - Gesture practice (step 3)

    func selectTab(_ tab: TourGestureTab) {
        activeTab = tab
        detector.reset()
    }

    private func startPracticing() {
        guard !practicing else { return }
        practicing = true
        detector.reset()
        handInset.reset()
        enterPractice(self)
    }

    private func stopPracticing() {
        guard practicing else { return }
        practicing = false
        exitPractice()
    }

    func tourPractice(intent: GestureIntent) {
        guard let tab = detector.observe(intent), tab == activeTab else { return }
        markDone(tab)
    }

    func tourPractice(hand: HandObservation) {
        handInset.ingest(hand)
    }

    func tourPractice(headphone: HeadphoneAction) {
        guard settings.headphonePresses, activeTab == .headphones else { return }
        markDone(.headphones)
    }

    private func markDone(_ tab: TourGestureTab) {
        machine.markPracticeDone(tab)
        practiceDone = machine.practiceDone
    }

    // MARK: - Permissions (step 5)

    private func refreshPermissions() {
        cameraAccess = Permissions.cameraAccess
        accessibilityGranted = Permissions.accessibilityTrusted
        permissionsTimer?.invalidate()
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.step == .permissions else { return }
                self.cameraAccess = Permissions.cameraAccess
                self.accessibilityGranted = Permissions.accessibilityTrusted
            }
        }
    }
}
