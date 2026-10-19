import AppKit
import SwiftUI
import EnsembleCore

/// The tour's chrome: step indicator, Skip tour, Back/Next, and the current step's content.
struct TourView: View {
    @ObservedObject var model: TourModel
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.top, 28)
            footer
        }
        .foregroundStyle(Color.tourInk)
        .tint(Color.ensembleBlue)
        .onAppear { model.onAppear() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: TourWelcomeStep()
        case .calibrate: TourCalibrateStep(model: model, state: state, settings: settings)
        case .gestures: TourGesturesStep(model: model, headphones: settings.headphonePresses)
        case .noseDot: TourNoseDotStep(settings: settings)
        case .permissions: TourPermissionsStep(model: model)
        case .done: TourDoneStep()
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if !model.isSingleStep { StepDots(current: model.step) }
            HStack {
                if !model.isSingleStep, model.step != .done {
                    Button("Skip tour") { model.skipTour() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.tourMuted)
                }
                Spacer()
                if model.canGoBack {
                    Button("Back") { model.back() }.ensembleButtonStyle().controlSize(.regular)
                }
                Button(nextTitle) { advance() }.ensembleButtonStyle(prominent: true).controlSize(.large)
            }
        }
        .padding(20)
    }

    private var nextTitle: String {
        model.isSingleStep || model.step == .done ? "Done" : "Next"
    }

    private func advance() {
        if model.isSingleStep || model.step == .done { model.finishTour() } else { model.next() }
    }
}

/// The tour's palette follows the system's light or dark setting: primary ink, secondary text, hairline lines and a
/// raised surface for panels that sit on the window.
extension Color {
    static let tourInk = Color.primary
    static let tourMuted = Color.secondary
    static let tourLine = Color.secondary.opacity(0.35)
    static let tourSurface = Color(nsColor: .controlBackgroundColor)
    static let tourHairline = Color.primary.opacity(0.12)
}

private struct StepDots: View {
    let current: TourStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TourStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.ensembleBlue : Color.tourLine)
                    .frame(width: step == current ? 8 : 6, height: step == current ? 8 : 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
    }
}
