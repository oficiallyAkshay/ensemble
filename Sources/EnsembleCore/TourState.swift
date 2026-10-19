import Foundation

/// The five steps of the first-run tour, in order.
public enum TourStep: Int, CaseIterable, Sendable {
    case welcome, calibrate, gestures, permissions, done

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .calibrate: return "Calibrate every screen"
        case .gestures: return "Gestures"
        case .permissions: return "Permissions"
        case .done: return "You're set"
        }
    }
}

/// The tabs of the gestures step, in the order they appear: three hand gestures, then the headphone presses.
public enum TourGestureTab: Int, CaseIterable, Sendable {
    case dictate, send, scroll, headphones

    /// The headphone tab is guidance only: presses may never arrive during the tour (they reach the app only
    /// while it holds Now Playing), so finishing practice never waits for it.
    public var isHandGesture: Bool { self != .headphones }

    /// The tabs to offer: the headphone tab only while the Settings switch for headphone presses is on.
    public static func shown(headphones: Bool) -> [TourGestureTab] {
        allCases.filter { headphones || $0.isHandGesture }
    }
}

/// Drives the tour's step, Back/Next bounds, and which gesture tabs have been practiced. Pure: no UI, no
/// persistence. The owner persists completion ("tour completed"/"tour skipped") itself.
public final class TourStateMachine {
    public private(set) var step: TourStep
    public private(set) var practiceDone: Set<TourGestureTab> = []
    public private(set) var finished = false
    public private(set) var skipped = false
    /// True when replaying a single step: Back/Next are disabled and only that step is shown.
    public let isSingleStep: Bool

    public init(startAt step: TourStep = .welcome, singleStep: Bool = false) {
        self.step = step
        self.isSingleStep = singleStep
    }

    public var canGoBack: Bool { !isSingleStep && step.rawValue > TourStep.welcome.rawValue }
    public var canGoNext: Bool { !isSingleStep && step != .done }
    public var isLastStep: Bool { step == .done }

    @discardableResult
    public func next() -> Bool {
        guard canGoNext, let n = TourStep(rawValue: step.rawValue + 1) else { return false }
        step = n
        if step == .done { finished = true }
        return true
    }

    @discardableResult
    public func back() -> Bool {
        guard canGoBack, let p = TourStep(rawValue: step.rawValue - 1) else { return false }
        step = p
        return true
    }

    /// Jumps directly to a step (used by "Later" on calibration, and by single-step replay).
    public func jump(to step: TourStep) {
        self.step = step
        if step == .done { finished = true }
    }

    public func skip() {
        skipped = true
        finished = true
    }

    public func finish() {
        finished = true
    }

    public func markPracticeDone(_ tab: TourGestureTab) {
        practiceDone.insert(tab)
    }

    public var allPracticeDone: Bool { TourGestureTab.allCases.allSatisfy { !$0.isHandGesture || practiceDone.contains($0) } }
}
