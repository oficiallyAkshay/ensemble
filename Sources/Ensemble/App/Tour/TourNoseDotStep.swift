import SwiftUI

/// Asks whether to show the nose dot. The choice is the same setting as Settings' "Show nose dot", so a new
/// install starts on Off and nothing changes until a choice is pressed.
struct TourNoseDotStep: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 22) {
            Text("Show the nose dot?").font(.largeTitle.weight(.semibold))
            Text("A small dot that follows where your nose points. Ensemble works the same without it.\nYou can change this later in Settings.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.tourMuted)
                .frame(maxWidth: 460)
            Picker("Show the nose dot", selection: $settings.showNoseDot) {
                Text("Off").tag(false)
                Text("On").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }
}
