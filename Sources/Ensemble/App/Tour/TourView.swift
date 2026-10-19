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
                    Button("Back") { model.back() }.ensembleButtonStyle()
                }
                Button(nextTitle) { advance() }.ensembleButtonStyle(prominent: true)
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

/// The tour's light palette, the website demo's: near-black ink, grey for secondary text, hairline grey for lines.
extension Color {
    static let tourInk = Color(red: 0.039, green: 0.039, blue: 0.039)
    static let tourMuted = Color(red: 0.451, green: 0.451, blue: 0.451)
    static let tourLine = Color(red: 0.831, green: 0.831, blue: 0.831)
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
