import SwiftUI

/// Step 6: nothing left to decide, just where to find this again.
struct TourDoneStep: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.ensembleBlue)
            Text("You're set").font(.largeTitle.weight(.semibold))
            Text("Replay this tour from the menu bar, the ⌥⌘K panel, or Settings, whole or one step at a time.\nIf you plug in a new camera or screen, Ensemble asks to calibrate it.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.tourMuted)
                .frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }
}
